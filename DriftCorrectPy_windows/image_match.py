"""XY alignment by image matching, and the anchor that holds the body in place.

Each timepoint is compared with the timepoint before it. The later image is turned and slid over the earlier
one, and for every candidate the mismatch is the sum of the absolute differences divided by the sum of both
images, over the pixels that both hold inside the region. The candidate with the smallest mismatch is the
movement between the two. This file follows XYMatch.swift and Rigid.swift of the Mac version.

A transform is a 3 by 3 matrix that maps the point (x, y, 1). A positive angle turns the x axis toward the y
axis, which is clockwise on screen because y points down in an image.
"""

import math

import numpy as np
from scipy import ndimage

# The coarse copy is binned until its longer side is at most this many pixels, which keeps the full search fast.
COARSE_SIDE = 128
# An offset is only considered when the pixels compared cover at least this share of the region.
MIN_OVERLAP = 0.3
# The step between the candidate angles on the coarsest copy, in degrees. Each finer copy halves it.
ANGLE_STEP = 0.5
# A turn is accepted only when it lowers the mismatch by at least this share compared with no turn. A turned
# image is interpolated, which smooths it slightly and can lower the mismatch without a real turn.
TURN_MARGIN = 0.02
# A match with a mismatch above this value is flagged in the log.
WEAK_COST = 0.27


def rotation(degrees, cx, cy):
    """Return the rotation by `degrees` about the point (cx, cy)."""
    r = math.radians(degrees)
    co, si = math.cos(r), math.sin(r)
    return np.array([[co, -si, cx - co * cx + si * cy], [si, co, cy - si * cx - co * cy], [0, 0, 1]])


def shift(dx, dy):
    return np.array([[1, 0, dx], [0, 1, dy], [0, 0, 1.0]])


def angle_of(transform):
    """Return the angle of the rotation in degrees, between -180 and 180."""
    return math.degrees(math.atan2(transform[1, 0], transform[0, 0]))


def apply(transform, x, y):
    return (transform[0, 0] * x + transform[0, 1] * y + transform[0, 2],
            transform[1, 0] * x + transform[1, 1] * y + transform[1, 2])


def blur(image, sigma):
    """Blur with a Gaussian that reaches 3 sigma. A pixel beyond the edge takes the value of the edge pixel."""
    radius = max(1, math.ceil(3 * sigma))
    return ndimage.gaussian_filter(image, sigma, mode="nearest", radius=radius)


def dilate(mask, radius):
    """Grow a mask by `radius` pixels along x and along y."""
    return ndimage.maximum_filter(mask, size=2 * radius + 1, mode="constant", cval=0)


def modules(prefer_gpu):
    """Return the array module and its ndimage module, which are CuPy when a CUDA GPU is in use."""
    if prefer_gpu:
        try:
            import cupy
            import cupyx.scipy.ndimage as cupy_ndimage
            cupy.cuda.runtime.getDeviceCount()
            return cupy, cupy_ndimage
        except Exception:
            pass
    return np, ndimage


class Level:
    """One copy of a prepared image, binned by `bin`."""

    def __init__(self, bin, pixels, valid):
        self.bin, self.pixels, self.valid = bin, pixels, valid


class Frame:
    """One timepoint prepared for the matching. It holds the maximum projection of the compared channel binned
    by a coarse factor, binned by 2, and at full resolution."""

    def __init__(self, levels, height, width):
        self.levels, self.height, self.width = levels, height, width


def _binned(pixels, valid, b, xp):
    """Bin by `b`. A binned pixel holds the mean of its pixels and is valid when all of them hold data."""
    h, w = pixels.shape[0] // b, pixels.shape[1] // b
    p = pixels[:h * b, :w * b].reshape(h, b, w, b).mean(axis=(1, 3), dtype=xp.float32)
    v = valid[:h * b, :w * b].reshape(h, b, w, b).all(axis=(1, 3))
    return p, v


def _binned_region(region, b, xp):
    """Bin a region by `b`. A binned pixel is in the region when more than half of its pixels are."""
    if b == 1:
        return region
    h, w = region.shape[0] // b, region.shape[1] // b
    return 2 * region[:h * b, :w * b].reshape(h, b, w, b).sum(axis=(1, 3)) > b * b


def prepare(projection, xp=np):
    """Prepare the maximum projection of one timepoint. A pixel that is 0 holds no data, for example in the
    empty border of a merged file."""
    projection = np.asarray(projection, dtype=np.float32)
    h, w = projection.shape
    valid = projection > 0
    # Subtract the background level, which is a low percentile of the data, and blur lightly so that single
    # noisy pixels do not decide the match.
    sample = projection.ravel()[::max(1, projection.size // 200_000)]
    sample = np.sort(sample[sample > 0])
    background = sample[int(0.05 * (len(sample) - 1))] if len(sample) else 0
    pixels = blur(np.maximum(projection - background, 0), 1.0)
    coarse = 8
    while max(w, h) // coarse > COARSE_SIDE:
        coarse *= 2
    while coarse > 2 and max(w, h) // coarse < COARSE_SIDE // 4:
        coarse //= 2
    pixels, valid = xp.asarray(pixels), xp.asarray(valid)
    levels = []
    for b in ([coarse, 2, 1] if coarse > 2 else [2, 1]):
        levels.append(Level(b, *((pixels, valid) if b == 1 else _binned(pixels, valid, b, xp))))
    return Frame(levels, h, w)


def _rotated(level, degrees, frame, xp, nd):
    """Turn a level by `degrees` about the centre of the frame. A pixel is valid when the pixels it is
    interpolated from are valid."""
    if degrees == 0:
        return level
    # The centre of the frame in pixels of this level.
    cx = ((frame.width - 1) / 2 - (level.bin - 1) / 2) / level.bin
    cy = ((frame.height - 1) / 2 - (level.bin - 1) / 2) / level.bin
    # Each output pixel reads the source at the position that the opposite rotation gives. ndimage works in
    # (row, column) order.
    back = rotation(-degrees, cx, cy)
    matrix = xp.asarray([[back[1, 1], back[1, 0]], [back[0, 1], back[0, 0]]])
    offset = (float(back[1, 2]), float(back[0, 2]))
    pixels = nd.affine_transform(level.pixels, matrix, offset=offset, order=1, mode="constant", cval=0)
    valid = nd.affine_transform(level.valid.astype(xp.float32), matrix, offset=offset, order=1, mode="constant", cval=0) > 0.999
    return Level(level.bin, pixels * valid, valid)


def _windows(rows, width, first, count, xp):
    """Return the `count` windows of `width` columns that start at column `first` and each one column further, as
    an array of shape (rows, count, width)."""
    view = getattr(getattr(getattr(xp, "lib", None), "stride_tricks", None), "sliding_window_view", None)
    if view is not None:
        return view(rows, width, axis=1)[:, first:first + count]
    # Older CuPy versions have no sliding window view, so the windows are copied.
    return xp.stack([rows[:, k:k + width] for k in range(first, first + count)], axis=1)


def _search(la, lb, region, count, cy, cx, ry, rx, xp):
    """Try every whole offset within (ry, rx) of (cy, cx) and return (dy, dx, mismatch) of the best one. When `b`
    is moved by (dy, dx), pixel (y, x) of `a` meets pixel (y - dy, x - dx) of `b`. Both sides are first scaled to
    the same mean so that a change in brightness does not count."""
    h, w = la.pixels.shape
    span_y, span_x = abs(cy) + ry, abs(cx) + rx
    # Pad the later image with pixels that hold no data, so that every offset reads a full window.
    pb = xp.zeros((h + 2 * span_y, w + 2 * span_x), dtype=xp.float32)
    vb = xp.zeros((h + 2 * span_y, w + 2 * span_x), dtype=bool)
    pb[span_y:span_y + h, span_x:span_x + w] = lb.pixels
    vb[span_y:span_y + h, span_x:span_x + w] = lb.valid
    inside = region & la.valid
    a = la.pixels
    best = (0, 0, math.inf)
    k0 = span_x - (cx + rx)
    dxs = cx + rx - np.arange(2 * rx + 1)
    for dy in range(cy - ry, cy + ry + 1):
        # All offsets along x for this row offset are compared at once.
        rows = slice(span_y - dy, span_y - dy + h)
        bw = _windows(pb[rows], w, k0, 2 * rx + 1, xp)
        vw = _windows(vb[rows], w, k0, 2 * rx + 1, xp)
        m = vw & inside[:, None, :]
        n = m.sum(axis=(0, 2))
        sa = (a[:, None, :] * m).sum(axis=(0, 2), dtype=xp.float64)
        sb = (bw * m).sum(axis=(0, 2), dtype=xp.float64)
        ok = (n >= MIN_OVERLAP * count) & (sa > 0) & (sb > 0)
        ka = xp.where(ok, n / xp.where(ok, sa, 1), 0).astype(xp.float32)
        kb = xp.where(ok, n / xp.where(ok, sb, 1), 0).astype(xp.float32)
        diff = (xp.abs(a[:, None, :] * ka[None, :, None] - bw * kb[None, :, None]) * m).sum(axis=(0, 2), dtype=xp.float64)
        # The sum of both sides after scaling is 2n.
        cost = xp.where(ok, diff / xp.maximum(2 * n, 1), xp.inf)
        cost = cost.get() if hasattr(cost, "get") else cost
        # The offsets run from the largest dx down, so the first minimum from the other end is the smallest dx.
        k = len(cost) - 1 - int(np.argmin(cost[::-1]))
        if cost[k] < best[2]:
            best = (dy, int(dxs[k]), float(cost[k]))
    return best


def match(a, b, region=None, maximum_angle=0.0, xp=np, nd=ndimage):
    """Return the transform that moves `b`, the later timepoint, onto `a`, the earlier one, and the mismatch
    there. The transform turns `b` about the centre of the frame and then shifts it by whole pixels. `region` is
    in pixels of `a` at full resolution, and without it the whole frame is used. Angles up to `maximum_angle`
    degrees in either direction are tried. With 0 the match only shifts."""
    whole = xp.ones((a.height, a.width), dtype=bool) if region is None else xp.asarray(region)
    best, angle, step, previous_bin = (0, 0, math.inf), 0.0, ANGLE_STEP, 0
    for la, lb in zip(a.levels, b.levels):
        r = _binned_region(whole, la.bin, xp)
        count = int((r & la.valid).sum())
        if previous_bin == 0:
            # The coarsest copy first searches half the frame in each direction without turning, so that a
            # large jump is found. It then tries every candidate angle close to that offset.
            h, w = la.pixels.shape
            best = _search(la, lb, r, count, 0, 0, h // 2, w // 2, xp)
            if not math.isfinite(best[2]):
                return np.eye(3), math.nan
            straight, turn, turn_angle = best, (0, 0, math.inf), 0.0
            candidate = -maximum_angle
            while maximum_angle > 0 and candidate <= maximum_angle + 1e-9:
                if abs(candidate) > 1e-9:
                    m = _search(la, _rotated(lb, candidate, a, xp, nd), r, count, straight[0], straight[1], 2, 2, xp)
                    if m[2] < turn[2]:
                        turn, turn_angle = m, candidate
                candidate += step
            if turn[2] < straight[2] * (1 - TURN_MARGIN):
                best, angle = turn, turn_angle
        else:
            # Each finer copy searches around the result of the copy before it, far enough to cover its
            # rounding. It tries no turn, and the angle found so far with half a step to either side.
            scale = previous_bin // la.bin
            cy, cx, radius = best[0] * scale, best[1] * scale, scale // 2 + 1
            step /= 2
            straight = _search(la, lb, r, count, cy, cx, radius, radius, xp)
            turn, turn_angle = (0, 0, math.inf), 0.0
            for candidate in ([angle, angle - step, angle + step] if maximum_angle > 0 else []):
                if abs(candidate) > 1e-9:
                    m = _search(la, _rotated(lb, candidate, a, xp, nd), r, count, cy, cx, radius, radius, xp)
                    if m[2] < turn[2]:
                        turn, turn_angle = m, candidate
            if turn[2] < straight[2] * (1 - TURN_MARGIN):
                best, angle = turn, turn_angle
            elif math.isfinite(straight[2]):
                best, angle = straight, 0.0
            else:
                return np.eye(3), math.nan
        previous_bin = la.bin
    turn = rotation(angle, (a.width - 1) / 2, (a.height - 1) / 2)
    return shift(best[1], best[0]) @ turn, best[2]


def region(follow, mask, to_first, width, height):
    """Return the pixels of one timepoint that the matching compares, or None for the whole frame. `follow` is
    "whole", "mask", or a box (x, y, width, height) in pixels of the first timepoint. `mask` is the embryo mask of
    that timepoint. `to_first` moves that timepoint onto the first one, where the box was drawn."""
    if follow == "whole":
        return None
    if follow == "mask":
        # Grow the mask by 12 pixels so that the edge of the tissue, which carries most of the pattern, is included.
        if mask is None or mask.shape != (height, width):
            return None
        return dilate(np.asarray(mask, dtype=bool), 12)
    # A pixel is in the region when its position on the first timepoint lies inside the box.
    bx, by, bw, bh = follow
    y, x = np.mgrid[0:height, 0:width]
    px, py = apply(to_first, x, y)
    return (px >= bx) & (px < bx + bw) & (py >= by) & (py < by + bh)


# The anchor
#
# Image matching between neighbouring timepoints measures sudden movement well, but the sum of its steps follows
# the cells. When the cells travel through the body, that sum slowly carries the frame away and slowly turns it.
# The embryo mask says where the body is at every timepoint. It is rough at a single timepoint and reliable over
# many. The anchor therefore takes the movement between neighbouring timepoints from the image matching and the
# position of the body from the centroid of the mask, averaged over nearby timepoints.
#
# The direction of the body is not taken from the mask. The long axis of a mask changes when the frame cuts off a
# different part of the tissue, without the body turning, and following it would turn the image for no reason. The
# microscope does not turn, so the direction in the acquired movie is the direction of the body. The anchor removes
# the sudden turns that the matching finds and leaves the slow turning as it was acquired.


def pose(mask):
    """Return the centroid (x, y) of a mask, or None when the mask is empty."""
    ys, xs = np.nonzero(mask)
    return (xs.mean(), ys.mean()) if len(xs) else None


def smooth(values, sigma):
    """Average `values` over nearby timepoints with a Gaussian of width `sigma` timepoints."""
    values = np.asarray(values, dtype=float)
    if sigma <= 0 or len(values) < 2:
        return values
    radius = math.ceil(3 * sigma)
    weights = np.exp(-0.5 * np.arange(radius + 1) ** 2 / sigma ** 2)
    out = np.empty_like(values)
    for t in range(len(values)):
        k = np.arange(max(0, t - radius), min(len(values) - 1, t + radius) + 1)
        out[t] = (weights[np.abs(k - t)] * values[k]).sum() / weights[np.abs(k - t)].sum()
    return out


def unwrap(values, period):
    """Remove the jumps of a full `period` from a series of angles, so that neighbouring values stay close."""
    out = np.array(values, dtype=float)
    for t in range(1, len(out)):
        out[t] -= period * round((out[t] - out[t - 1]) / period)
    return out


def place(steps, poses, smoothing, width, height):
    """Return the transform that places every timepoint in the output. `steps[t]` moves timepoint t onto the
    timepoint before it, and the first one is ignored. `poses[t]` is the pose of the body at timepoint t in its own
    frame. When `poses` is None, or a timepoint has no pose, the body is not held and the result is the sum of the
    steps. `smoothing` is the number of timepoints over which the position of the body and the turn are averaged."""
    # Add up the steps. `chain[t]` moves timepoint t onto the first timepoint.
    chain = []
    for t, s in enumerate(steps):
        chain.append(np.eye(3) if t == 0 else chain[-1] @ s)
    if poses is None or len(poses) != len(steps) or any(p is None for p in poses):
        return chain
    # Follow the centroid of the body in the movie where the steps are added up, and average it over nearby
    # timepoints.
    centres = [apply(m, p[0], p[1]) for m, p in zip(chain, poses)]
    cx, cy = smooth([c[0] for c in centres], smoothing), smooth([c[1] for c in centres], smoothing)
    # Take the slow part of the summed turn back out. What stays is the sudden turns, which are removed.
    turn_back = -smooth(unwrap([angle_of(m) for m in chain], 360), smoothing)
    # Turn each timepoint about the averaged centroid and then move that centroid to the middle of the frame.
    mid_x, mid_y = (width - 1) / 2, (height - 1) / 2
    return [shift(mid_x - cx[t], mid_y - cy[t]) @ rotation(turn_back[t], cx[t], cy[t]) @ chain[t] for t in range(len(chain))]


def covering_pad(transforms, width, height):
    """Return the padding (top, bottom, left, right) that keeps every pixel on the canvas when frames of the given
    size are moved by `transforms`."""
    w, h = width - 1, height - 1
    xs, ys = [0.0, w], [0.0, h]
    for m in transforms:
        for x, y in ((0, 0), (w, 0), (0, h), (w, h)):
            qx, qy = apply(m, x, y)
            xs.append(qx)
            ys.append(qy)
    def up(v):
        return int(math.ceil(max(0.0, v)))
    return up(-min(ys)), up(max(ys) - h), up(-min(xs)), up(max(xs) - w)
