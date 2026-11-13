"""Measurement and correction of drift along z.

Each timepoint is compared with the timepoint before it, after the xy alignment. The stack of the later
timepoint is moved up and down against the earlier one, one slice at a time, with a small search in xy. The
offset where the two stacks differ least is the movement of the tissue. Each timepoint is also compared with one
a few timepoints earlier, where a slow movement is large enough to measure. The correction then moves whole
slices and fills the gaps with empty slices. It does not interpolate between slices. This file follows
ZDrift.swift and ZCorrection.swift of the Mac version.
"""

import csv
import math
from dataclasses import dataclass

import numpy as np
from scipy import ndimage
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import spsolve

from image_match import WEAK_COST, blur


@dataclass
class Descriptor:
    """The data that z correction keeps of one timepoint, which is a reduced copy of the channel it follows."""
    planes: np.ndarray          # (Z, h, w) binned by 4
    valid: np.ndarray
    region: np.ndarray
    coarse: np.ndarray          # binned by 16, for the coarse search in xy
    coarse_valid: np.ndarray
    coarse_region: np.ndarray


@dataclass
class Step:
    """The z movement measured between one timepoint and the timepoint before it."""
    dz: float = 0.0             # slices the tissue moved, positive toward a higher slice index
    cost: float = math.nan      # the mismatch at the best offset
    flag: str = ""              # the reason the measurement needs a look, or empty


@dataclass
class Plan:
    """The shift of every timepoint in whole slices, and the number of empty slices to add."""
    position: np.ndarray
    shift: np.ndarray
    pad_low: int
    pad_high: int
    kept: np.ndarray

    def visible_slices(self, z):
        """Return the output slices, counted from 1, that hold data at every timepoint that is written."""
        if not len(self.kept):
            return []
        lo = max(0, self.pad_low + int(self.shift[self.kept].max()))
        hi = min(z + self.pad_low + self.pad_high, z + self.pad_low + int(self.shift[self.kept].min()))
        return list(range(lo + 1, hi + 1))


def _bin4(a, reduce):
    h, w = a.shape[-2] // 4, a.shape[-1] // 4
    return reduce(a[..., :h * 4, :w * 4].reshape(*a.shape[:-2], h, 4, w, 4), axis=(-3, -1))


def _assemble(planes, valid, region):
    """Build a descriptor from planes binned by 4. This adds the copy binned by 16 for the coarse search in xy.
    A coarse pixel is valid when all of its pixels hold data, and it is in the region when at least half of them
    are."""
    coarse = _bin4(planes, np.mean).astype(np.float32)
    return Descriptor(planes, valid, region, coarse, _bin4(valid, np.all), _bin4(region, np.sum) >= 8)


def _moved(image, transform, order):
    """Move a (Y, X) image by `transform`. A pixel outside the image counts as 0."""
    dx, dy = transform[0, 2], transform[1, 2]
    if np.array_equal(transform[:2, :2], np.eye(2)) and dx == round(dx) and dy == round(dy):
        # A shift by whole pixels copies the pixels without interpolation.
        dx, dy = int(dx), int(dy)
        h, w = image.shape
        out = np.zeros_like(image)
        if abs(dy) < h and abs(dx) < w:
            out[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)] = image[max(0, -dy):h + min(0, -dy), max(0, -dx):w + min(0, -dx)]
        return out
    # Each output pixel reads the source at the position that the opposite transform gives. ndimage works in
    # (row, column) order.
    back = np.linalg.inv(transform)
    return ndimage.affine_transform(image, [[back[1, 1], back[1, 0]], [back[0, 1], back[0, 0]]],
                                    offset=(back[1, 2], back[0, 2]), order=order, mode="constant", cval=0)


def describe(frame, channel, region=None, transform=None):
    """Reduce one (C, Z, Y, X) timepoint to the data that the comparison with another timepoint needs. `region`
    marks the pixels of the frame to follow, and without it the whole frame is followed. `transform` moves the
    timepoint in xy before it is reduced. The xy alignment gives it, so that two timepoints are compared in z with
    the same tissue on top of each other."""
    full = np.asarray(frame[channel], dtype=np.float32)
    moving = transform is not None and not np.array_equal(transform, np.eye(3))
    if moving:
        full = np.stack([_moved(p, transform, 1) for p in full])
    planes = _bin4(full, np.mean).astype(np.float32)
    valid = (planes > 0).any(axis=0)
    if planes.size:
        # Subtract the background level, which is a low percentile of the data, and then blur each plane lightly
        # in xy. The blur makes the comparison tolerant of a small misalignment in xy.
        sample = planes.ravel()[::max(1, planes.size // 200_000)]
        sample = np.sort(sample[sample > 0])
        background = sample[int(0.05 * (len(sample) - 1))] if len(sample) else 0
        planes = np.stack([blur(np.maximum(p - background, 0), 1.0) for p in planes])
    # Bin the region by 4. A binned pixel is in the region when any of its pixels is.
    if region is None:
        region4 = np.ones(valid.shape, dtype=bool)
    else:
        region = np.asarray(region, dtype=np.uint8)
        region4 = _bin4(_moved(region, transform, 0) if moving else region, np.any)
    return _assemble(planes, valid, region4)


def cost_curve(a, b, sy, sx, ds, coarse=False):
    """Measure the mismatch between `a` and `b` for every z offset in `ds`, with `b` moved by (sy, sx) pixels. The
    mismatch is the sum of |a - b| divided by the sum of (a + b) over the slices that both stacks share at that
    offset. Both stacks are first scaled to the same mean so that a change in brightness does not count."""
    pa, pb = (a.coarse, b.coarse) if coarse else (a.planes, b.planes)
    va, vb = (a.coarse_valid, b.coarse_valid) if coarse else (a.valid, b.valid)
    ra, rb = (a.coarse_region, b.coarse_region) if coarse else (a.region, b.region)
    z, h, w = pa.shape
    costs = np.full(len(ds), np.nan)
    y0, y1, x0, x1 = max(0, sy), min(h, h + sy), max(0, sx), min(w, w + sx)
    if y0 >= y1 or x0 >= x1:
        return costs
    aa, bb = np.s_[y0:y1, x0:x1], np.s_[y0 - sy:y1 - sy, x0 - sx:x1 - sx]
    # Keep the pixels that hold data in both stacks and lie in the region of either one.
    keep = va[aa] & vb[bb] & (ra[aa] | rb[bb])
    if keep.sum() < (12 if coarse else 64):
        return costs
    left, right = pa[:, aa[0], aa[1]][:, keep], pb[:, bb[0], bb[1]][:, keep]
    for i, d in enumerate(ds):
        lo, hi = max(0, -d), z - max(0, d)
        if hi <= lo:
            continue
        av, bv = left[lo:hi], right[lo + d:hi + d]
        sa, sb = av.sum(dtype=np.float64), bv.sum(dtype=np.float64)
        if sa > 0 and sb > 0:
            costs[i] = np.abs(av * np.float32(av.size / sa) - bv * np.float32(bv.size / sb)).sum(dtype=np.float64) / (2 * av.size)
    return costs


def _best(costs):
    return int(np.nanargmin(costs)) if np.isfinite(costs).any() else None


def match(a, b):
    """Measure the z movement of the tissue from `a`, the earlier timepoint, to `b`."""
    step = Step()
    z = a.planes.shape[0]
    if z <= 1 or a.planes.shape != b.planes.shape or a.planes.shape[1] == 0 or a.planes.shape[2] == 0:
        step.flag = "stack sizes differ" if z > 1 else "single slice"
        return step
    # Consider the offsets that leave at least 5 slices in common, or half the stack when it is thinner.
    limit = z - min(5, max(1, z // 2))
    ds = list(range(-limit, limit + 1))
    # Coarse pass. Try every xy shift within 3 coarse pixels together with every offset.
    sy = sx = 0
    coarse_best = None
    if a.coarse.shape[1] > 0 and a.coarse.shape[2] > 0:
        for cy in range(-3, 4):
            for cx in range(-3, 4):
                c = cost_curve(a, b, cy, cx, ds, coarse=True)
                i = _best(c)
                if i is not None and (coarse_best is None or c[i] < coarse_best[0]):
                    coarse_best, sy, sx = (c[i], ds[i]), cy * 4, cx * 4
    # Fine pass at the resolution binned by 4, within 2 slices of the coarse result. When the region is too small
    # for the coarse pass, search every offset.
    fine_ds = [d for d in ds if abs(d - coarse_best[1]) <= 2] if coarse_best else ds
    best = None
    for oy in (-2, 0, 2):
        for ox in (-2, 0, 2):
            c = cost_curve(a, b, sy + oy, sx + ox, fine_ds)
            i = _best(c)
            if i is not None and (best is None or c[i] < best[0]):
                best = (c[i], fine_ds[i], sy + oy, sx + ox)
    if best is None:
        step.flag = "no data in the region"
        return step
    # Fit a parabola through the mismatch at the best offset and at its two neighbours to place the minimum
    # between slices.
    cost, d, by, bx = best
    three = cost_curve(a, b, by, bx, [d - 1, d, d + 1])
    dz = float(d)
    if np.isfinite(three[0]) and np.isfinite(three[2]) and abs(d) < limit:
        den = three[0] - 2 * three[1] + three[2]
        if den > 0:
            dz += min(0.5, max(-0.5, 0.5 * (three[0] - three[2]) / den))
    step.dz, step.cost = dz, float(cost)
    if cost > WEAK_COST:
        step.flag = "weak match"
    return step


def positions(count, edges):
    """Find the z position of every timepoint from measured movements between pairs of timepoints. An edge
    (i, j, d) says that the tissue moved by `d` slices from timepoint i to timepoint j. Neighbouring timepoints
    give one edge each, and pairs further apart give more. The positions are the ones that agree best with all
    edges. An edge that disagrees strongly with the rest counts less. The first timepoint is at 0."""
    z = np.zeros(count)
    if count < 2 or not edges:
        return z
    i = np.array([e[0] for e in edges])
    j = np.array([e[1] for e in edges])
    d = np.array([e[2] for e in edges], dtype=float)
    # Start from the sum of the movements between neighbours.
    neighbour = np.zeros(count)
    neighbour[j[j == i + 1]] = d[j == i + 1]
    z = np.cumsum(neighbour)
    rows = np.arange(len(edges))
    for _ in range(8):
        # Give each edge a weight that falls off once its error exceeds about a third of a slice.
        weight = 1 / np.sqrt(1 + ((z[j] - z[i] - d) / 0.3) ** 2)
        # Each row of the matrix is one edge. The column of the first timepoint is left out because it stays at 0.
        a = coo_matrix((np.r_[np.ones(len(edges)), -np.ones(len(edges))], (np.r_[rows, rows], np.r_[j, i])),
                       shape=(len(edges), count)).tocsc()[:, 1:]
        normal = (a.T.multiply(weight) @ a).tocsc()
        z = np.r_[0, spsolve(normal, a.T @ (weight * d))]
    return z


def _round(value):
    # Round a half away from zero, as the Mac version does.
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


def plan(steps, position=None, reference=0, dead_band=0.15, pad=True, maximum_step=None):
    """Turn the movements between timepoints into a shift of whole slices for every timepoint. `position` is the
    position of the tissue at every timepoint, and without it the movements are added up. `reference` is the
    timepoint whose slices stay where they are. The shift changes only when the position is `dead_band` beyond the
    midpoint between two slices, because a position that stays close to a midpoint would otherwise make the output
    switch between two slices. With `pad`, empty slices are added so that no slice is lost."""
    if maximum_step is not None and (not math.isfinite(maximum_step) or maximum_step <= 0):
        raise ValueError("Maximum shift must be a positive number of slices")
    if position is None or len(position) != len(steps):
        position = np.cumsum([0.0] + [s.dz for s in steps[1:]]) if len(steps) else np.array([])
    position = np.array(position, dtype=float)
    whole = np.zeros(len(position), dtype=int)
    if len(position):
        ref = min(max(0, reference), len(position) - 1)
        position -= position[ref]
        # Follow the position in whole slices, forward and then backward from the reference timepoint.
        for indices in (range(ref + 1, len(position)), range(ref - 1, -1, -1)):
            previous = ref
            for t in indices:
                whole[t] = _round(position[t]) if abs(position[t] - whole[previous]) >= 0.5 + dead_band else whole[previous]
                previous = t
    # The correction moves each timepoint opposite to the movement of the tissue.
    shifts = -whole
    kept = np.array([t for t, step in enumerate(steps) if t == 0 or maximum_step is None or abs(step.dz) <= maximum_step], dtype=int)
    selected = shifts[kept]
    return Plan(position, shifts, max(0, -int(selected.min())) if pad and len(selected) else 0,
                max(0, int(selected.max())) if pad and len(selected) else 0, kept)


def place(frame, shift, pad_low, pad_high):
    """Move the slices of a (C, Z, Y, X) frame by `shift` inside a stack that has `pad_low` + `pad_high` extra
    slices. An output slice that no input slice lands on stays empty. An input slice that lands outside the stack
    is dropped."""
    c, z, h, w = frame.shape
    out = np.zeros((c, z + pad_low + pad_high, h, w), dtype=frame.dtype)
    start = int(shift) + pad_low
    lo, hi = max(0, start), min(out.shape[1], start + z)
    if lo < hi:
        out[:, lo:hi] = frame[:, lo - start:hi - start]
    return out


def line(step):
    """Format the measurement of one timepoint for the log."""
    text = f"dz={step.dz:+6.2f}  mismatch " + (f"{step.cost:.3f}" if math.isfinite(step.cost) else "--")
    return text + (f"  [{step.flag}]" if step.flag else "")


class Tracker:
    """Follows one embryo through time. The descriptor of each timepoint is added in the order of time."""

    def __init__(self, span=5, dead_band=0.15, maximum_step=None):
        self.span, self.dead_band, self.maximum_step = span, dead_band, maximum_step
        self.recent = []        # the last few timepoints, each with the xy step that moves it onto the one before
        self.steps = []
        self.edges = []

    def add(self, describe_moved, step=None):
        """Compare the timepoint with the previous one and store the result. `describe_moved(transform)` returns
        the descriptor of this timepoint after it is moved in xy by `transform`. `step` is the xy transform that
        moves this timepoint onto the previous one. The timepoint is also compared with the one `span` timepoints
        earlier, where a slow movement is large enough to measure."""
        step = np.eye(3) if step is None else step
        t = len(self.steps)
        s = match(self.recent[-1][0], describe_moved(step)) if self.recent else Step()
        self.steps.append(s)
        if t > 0:
            self.edges.append((t - 1, t, s.dz))
        if self.span > 1 and len(self.recent) >= self.span:
            # Join the xy steps of the timepoints in between, so that this timepoint lands on the earlier one.
            joined = step
            for k in range(len(self.recent) - 1, len(self.recent) - self.span, -1):
                joined = self.recent[k][1] @ joined
            far = match(self.recent[-self.span][0], describe_moved(joined))
            # Use the comparison only when it and every step it spans matched well.
            if not far.flag and all(not x.flag for x in self.steps[t - self.span + 1:t + 1]):
                self.edges.append((t - self.span, t, far.dz))
        # Keep this timepoint in its own frame, where later timepoints are moved onto it.
        self.recent.append((describe_moved(np.eye(3)), step))
        if len(self.recent) > max(1, self.span):
            self.recent.pop(0)
        return s

    def plan(self, pad=True):
        """Return the shift of every timepoint in whole slices."""
        return plan(self.steps, position=positions(len(self.steps), self.edges), dead_band=self.dead_band, pad=pad,
                    maximum_step=self.maximum_step)

    def summary(self, correction, z):
        """Build the lines that the log shows after all timepoints are measured."""
        kept = correction.position[correction.kept]
        lines = [f"  z position  min={kept.min():+.1f}  max={kept.max():+.1f} slices" if len(kept) else "  z position  --",
                 f"  Empty slices added:  low={correction.pad_low}  high={correction.pad_high}   "
                 f"Z: {z} -> {z + correction.pad_low + correction.pad_high}"]
        flagged = [(t, s.flag) for t, s in enumerate(self.steps) if s.flag]
        if flagged:
            lines.append(f"  {len(flagged)} timepoint(s) need a look: " + ", ".join(f"t{t} ({f})" for t, f in flagged[:12])
                         + (", …" if len(flagged) > 12 else ""))
        dropped = sorted(set(range(len(self.steps))) - set(int(t) for t in correction.kept))
        if dropped:
            lines.append("Dropped timepoints (0-based): " + ", ".join(map(str, dropped)))
        visible = correction.visible_slices(z)
        lines.append("Embryo visible in slices:")
        lines.append(", ".join(map(str, visible)) if visible else "None")
        return lines

    def save_csv(self, path, correction):
        """Write the table with one row for each timepoint. A row holds what was measured and the shift that was
        applied."""
        output = {int(t): i for i, t in enumerate(correction.kept)}
        with open(path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["t", "output_t", "dz", "mismatch", "position_slices", "shift_slices", "flag"])
            for t, s in enumerate(self.steps):
                flag = "; ".join(x for x in (s.flag, "" if t in output else "dropped (large shift)") if x)
                writer.writerow([t, output.get(t, ""), f"{s.dz:.3f}", f"{s.cost:.3f}" if math.isfinite(s.cost) else "",
                                 f"{correction.position[t]:.3f}", int(correction.shift[t]), flag])
