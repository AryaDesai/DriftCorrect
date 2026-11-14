"""centroid_align_xy.py aligns an embryo movie in xy, with optional z correction.

It writes one OME-TIFF and one aligned and one unaligned MP4 for each channel.

The xy alignment matches the image of each timepoint with the timepoint before it, by shift and by rotation, and
holds the body in place with the embryo mask. image_match.py describes it. The embryo mask comes from a threshold
YAML file of the Mask tool (find_threshold.py), and every setting of that file is used.

With --z_correct, z correction runs after the xy alignment and moves whole slices. z_drift.py describes it.

The alignment runs in two passes. Pass 1 measures every timepoint. Pass 2 pads the canvas so that no data is
clipped and writes the output. --no_enlarge_canvas keeps the original canvas, so edge data may be clipped.

The GPU is used automatically when CUDA is available, and --cpu forces NumPy and SciPy.

Usage:
    python centroid_align_xy.py P0_concat.ome.tif --yaml P0_Venus_threshold.yaml
    python centroid_align_xy.py P0_concat.ome.tif --yaml P0_Venus_threshold.yaml --xy_channel mCherry --z_correct --z_channel mCherry
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np

import image_match
import z_drift
from backend import get_backend
from useful_functions import (
    ChannelMovies, FrameSource, detect_embryo_xy, get_threshold_params_for_timepoint, load_threshold_yaml, log,
    ome_metadata, ordered_map, physical_memory, pipeline_width, progress, save_ome_tiff, shift_line, stem_without_ome,
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Align embryo movies in xy, with optional z correction.")
    parser.add_argument("movie", help="The OME-TIFF or ND2 movie to align.")
    parser.add_argument("--yaml", help="Threshold YAML from the Mask tool. It is needed to hold the body in place and "
                                       "to follow the embryo mask.")
    parser.add_argument("--fps", type=float, default=2, help="Frames per second of the movies (default: 2)")
    parser.add_argument("--no_enlarge_canvas", action="store_true",
                        help="Keep the original canvas (edge data may be clipped).")
    parser.add_argument("--low_memory", action="store_true",
                        help="Do not keep frames in memory between the two passes.")
    parser.add_argument("--no_movies", action="store_true", help="Do not write MP4 movies.")
    parser.add_argument("--cpu", action="store_true", help="Use NumPy/SciPy even when CUDA is available.")

    parser.add_argument("--xy_method", choices=("image", "none"), default="image",
                        help="image matches the image of each timepoint with the timepoint before it (default). none "
                             "leaves xy as it is, for z correction alone.")
    parser.add_argument("--xy_channel", help="The channel that image matching compares, given as a name or as an index "
                                             "that starts at 0. A nuclear marker is the best choice. The default is the "
                                             "threshold channel of the YAML file.")
    parser.add_argument("--xy_region", choices=("whole", "mask", "box"), default="whole",
                        help="The part of the image that image matching follows.")
    parser.add_argument("--xy_box", nargs=4, type=int, metavar=("X", "Y", "WIDTH", "HEIGHT"),
                        help="A box over cells that should stay still, in pixels of the first timepoint.")
    parser.add_argument("--xy_no_hold", action="store_true",
                        help="Do not hold the body in place with the embryo mask. The frame can then slowly travel "
                             "when the cells move through the body.")
    parser.add_argument("--xy_mask_metric", choices=("centroid", "median"), default="centroid",
                        help="The mask center used to hold the body in place (default: centroid). Median uses the "
                             "median X and Y coordinates of the mask pixels.")
    parser.add_argument("--xy_smoothing", type=float, default=10.0,
                        help="The number of timepoints over which the position of the body and the turn are averaged "
                             "(default: 10).")
    parser.add_argument("--xy_max_angle", type=float, default=3.0,
                        help="The largest turn between two neighbouring timepoints that image matching looks for, in "
                             "degrees (default: 3). With 0 the matching only shifts.")

    parser.add_argument("--xy_no_rotation", action="store_true",
                        help="Do not correct rotation. Image matching then only shifts.")

    parser.add_argument("--z_correct", action="store_true", help="Correct z drift after the xy alignment.")
    parser.add_argument("--z_channel", help="The channel to follow in z, given as a name or as an index that starts at "
                                            "0. The default is the threshold channel of the YAML file.")
    parser.add_argument("--z_region", choices=("whole", "mask", "box"), default="whole",
                        help="The part of the image to follow in z.")
    parser.add_argument("--z_box", nargs=4, type=int, metavar=("X", "Y", "WIDTH", "HEIGHT"),
                        help="A box over cells that should stay in the same slice, in pixels of the first timepoint.")
    parser.add_argument("--z_drop_above", type=float,
                        help="Leave out timepoints whose movement from the last kept timepoint exceeds this many slices.")
    parser.add_argument("--z_span", type=int, default=5,
                        help="Each timepoint is also compared with the one this many timepoints earlier, which catches "
                             "slow movement (default: 5). With 1 only neighbours are compared.")
    args = parser.parse_args(argv)
    if args.xy_no_rotation:
        args.xy_max_angle = 0.0
    if args.xy_smoothing < 0 or args.xy_max_angle < 0:
        parser.error("--xy_smoothing and --xy_max_angle must be 0 or positive")
    if args.xy_method == "none" and not args.z_correct:
        parser.error("--xy_method none needs --z_correct")
    if args.z_span < 1:
        parser.error("--z_span must be 1 or more")
    if args.z_drop_above is not None and not args.z_drop_above > 0:
        parser.error("--z_drop_above must be a positive number of slices")
    return args


def resolve_channel(value, names, count, fallback, label):
    """Return the index of the channel given as a name or as an index. `fallback` is used when none is given."""
    if value is None or value == "":
        return fallback
    if value in names[:count]:
        return names.index(value)
    try:
        channel = int(value)
    except ValueError:
        raise ValueError(f'{label} channel "{value}" not found. The channels are: {", ".join(names[:count])}') from None
    if not 0 <= channel < count:
        raise ValueError(f"{label} channel index {channel} is out of range (the data has {count} channel(s))")
    return channel


def follow_setting(region, box, label, width, height):
    """Return the region setting that image_match.region takes, which is "whole", "mask" or the box."""
    if region != "box":
        return region
    if box is None or min(box) < 0 or min(box[2:]) <= 0:
        raise ValueError(f"Give the {label} box as X Y WIDTH HEIGHT with a positive width and height")
    if box[0] + box[2] > width or box[1] + box[3] > height:
        raise ValueError(f"The {label} box must be inside the image")
    return tuple(box)


def describe_follow(follow):
    if follow == "whole":
        return "the whole frame"
    if follow == "mask":
        return "the embryo mask"
    return f"the box x {follow[0]}, y {follow[1]}, {follow[2]} × {follow[3]} px"


def align(args):
    """Run the alignment. Returns (output TIFF paths, shifts[p][t] = (dy, dx))."""
    backend = get_backend(prefer_gpu=not args.cpu)
    cfg = load_threshold_yaml(Path(args.yaml)) if args.yaml else None

    # An ND2 file can hold several embryos, and a TIFF file holds one.
    src_path = Path(args.movie)
    if not src_path.is_file():
        raise FileNotFoundError(f"File not found: {src_path}")
    log(f"Loading {src_path.name} ...")
    source = FrameSource(src_path)
    base = src_path.stem if source.is_nd2 else stem_without_ome(src_path)
    stem = base
    log(f"  Shape: T={source.T}, P={source.P}, Z={source.Z}, C={source.C}, Y={source.Y}, X={source.X}")
    out_dir = src_path.parent / f"aligned_{base}"
    names = source.channel_names
    log(f"  Channels: {names}")
    threshold_channel = 0
    if cfg is not None:
        top = get_threshold_params_for_timepoint({"parameters": cfg["parameters"]}, 0)
        threshold_channel = top["channel_index"]
        if 0 <= threshold_channel < len(names):
            log(f"  Threshold channel: {names[threshold_channel]} (index {threshold_channel})")
        log(f"  sigma={top['sigma']}, percentile={top['percentile']}, method={top['method']}")
    log(f"  Compute: {backend.name}")
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"  Output: {out_dir}")

    T, P, C, Z, Y, X = source.T, source.P, source.C, source.Z, source.Y, source.X
    width = pipeline_width(source.frame_bytes)
    image = args.xy_method == "image"
    hold = image and not args.xy_no_hold
    mid_x, mid_y = (X - 1) / 2, (Y - 1) / 2

    def channel_name(c):
        return names[c] if c < len(names) else f"ch{c}"

    xy_channel = resolve_channel(args.xy_channel, names, C, threshold_channel, "XY") if image else 0
    xy_follow = follow_setting(args.xy_region, args.xy_box, "XY", X, Y) if image else "whole"
    z_channel = resolve_channel(args.z_channel, names, C, threshold_channel, "Z") if args.z_correct else 0
    z_follow = follow_setting(args.z_region, args.z_box, "Z", X, Y) if args.z_correct else "whole"
    # The embryo mask is needed to hold the body in place, and for matching that follows the mask.
    needs_mask = hold or xy_follow == "mask" or z_follow == "mask"
    if needs_mask and cfg is None:
        raise ValueError("These settings need an embryo mask, and no threshold YAML file was given.")
    if image:
        log(f"  XY: image matching of {channel_name(xy_channel)} (index {xy_channel}), following {describe_follow(xy_follow)}")
        log(f"      The {args.xy_mask_metric} of the embryo mask holds the body in place, averaged over {args.xy_smoothing:g} timepoints." if hold
            else "      The body is not held in place.")
        # The matching runs on the GPU when the backend does.
        xp, nd = image_match.modules(backend.is_gpu)
    else:
        log("  XY: left as it is")
    if args.z_correct:
        log(f"  Z correction: {channel_name(z_channel)} (index {z_channel}), following {describe_follow(z_follow)}")
    suffix = "_z" if args.z_correct else ""
    # The name of a TIFF output says which corrections it holds.
    kind_tag = suffix if args.xy_method == "none" else f"_xy{suffix}"

    def tiff_path(p):
        return out_dir / (f"{base}_P{p}{suffix}.ome.tif" if source.is_nd2 else f"{stem}{kind_tag}.ome.tif")

    def movie_paths(p, aligned):
        kind = "aligned" if aligned else "unaligned"
        tag = suffix if aligned else ""
        if source.is_nd2:
            return [out_dir / f"{base}_P{p}{tag}_{ch}_{kind}.mp4" for ch in names[:C]]
        return [out_dir / (f"{stem}{kind_tag}_{ch}_aligned.mp4" if aligned else f"{stem}_{ch}_unaligned.mp4") for ch in names[:C]]

    def movies(p, aligned, h, w):
        return None if args.no_movies else ChannelMovies(movie_paths(p, aligned), w, h, args.fps)

    def params_at(t):
        return get_threshold_params_for_timepoint(cfg, t)

    shifts = [[] for _ in range(P)]
    # With image matching, the step that moves each kept timepoint onto the kept one before it, and the pose of the
    # body.
    steps = [[] for _ in range(P)]
    poses = [[] for _ in range(P)]
    trackers = []
    written = []
    try:
        cache = {} if (not args.low_memory and source.frame_bytes * T * P <= 0.4 * physical_memory()) else None
        log("\n--- Pass 1: precomputing shifts ---")
        for p in range(P):
            log(f"\n  Embryo {p}/{P - 1}:")
            unaligned = movies(p, False, Y, X)
            tracker = z_drift.Tracker(span=args.z_span, maximum_step=args.z_drop_above) if args.z_correct else None
            trackers.append(tracker)
            # The previous timepoint for image matching, with its mask.
            previous = None
            # The transform that moves the current timepoint onto the first one, which is the sum of the steps.
            to_first = np.eye(3)

            def pass1(t, p=p, unaligned=unaligned):
                frame = source.read_frame(t, p)
                mask = detect_embryo_xy(frame, params_at(t), backend)[0] if needs_mask else None
                projections = backend.max_project_all(frame) if unaligned or image else None
                gray = ChannelMovies.gray_frames(projections) if unaligned else None
                if cache is not None:
                    cache[(p, t)] = frame
                return frame, mask, gray, projections[xy_channel] if image else None

            try:
                for t, (frame, mask, gray, projection) in enumerate(ordered_map(pass1, T, width)):
                    # The xy movement of this timepoint. `step` moves it onto the last kept timepoint.
                    step = np.eye(3)
                    if image:
                        current = image_match.prepare(projection, xp)
                        cost = 0.0
                        if previous is not None:
                            compared = image_match.region(xy_follow, previous[1], to_first, X, Y)
                            step, cost = image_match.match(previous[0], current, compared, args.xy_max_angle, xp, nd)
                        moved_x, moved_y = image_match.apply(step, mid_x, mid_y)
                        line = (shift_line(moved_y - mid_y, moved_x - mid_x) + f"  angle={image_match.angle_of(step):+6.2f}"
                                + "  mismatch " + (f"{cost:.3f}" if np.isfinite(cost) else "--"))
                        if not cost <= image_match.WEAK_COST:
                            line += "  [weak match]"
                    else:
                        line = ""
                    on_first = to_first @ step
                    # Z correction compares each timepoint with earlier ones after moving it onto them in xy.
                    keep = True
                    if tracker:
                        followed = image_match.region(z_follow, mask, on_first, X, Y)
                        measured = tracker.add(lambda m, f=frame, r=followed: z_drift.describe(f, z_channel, r, m), step)
                        line += ("   " if line else "") + z_drift.line(measured)
                        keep = tracker.kept[-1] == t
                    log(line if keep else line + "  [dropped]")
                    # A dropped timepoint is not stored, so the next timepoint is matched to the last kept one.
                    if keep:
                        to_first = on_first
                        if image:
                            previous = (current, mask)
                            steps[p].append(step)
                            poses[p].append(image_match.pose(mask, args.xy_mask_metric) if hold and mask is not None else None)
                        else:
                            shifts[p].append((0.0, 0.0))
                        if unaligned:
                            unaligned.append(gray)
                    progress(f"Pass 1: shifts (embryo {p})", t + 1, T)
                if unaligned:
                    unaligned.close()
            except BaseException:
                if unaligned:
                    unaligned.cancel()
                raise

        # With image matching, work out where every timepoint goes in the output.
        transforms = []
        if image:
            for p in range(P):
                held = hold and all(q is not None for q in poses[p])
                if hold and not held:
                    log(f"\n  The embryo mask of embryo {p} is empty at some timepoint, so the body is not held in place.")
                placed = image_match.place(steps[p], poses[p] if held else None, args.xy_smoothing, X, Y)
                transforms.append(placed)
                moved = [image_match.apply(m, mid_x, mid_y) for m in placed]
                shifts[p] = [(my - mid_y, mx - mid_x) for mx, my in moved]

        dys = [s[0] for row in shifts for s in row]
        dxs = [s[1] for row in shifts for s in row]
        log("\nShift summary (pixels):")
        log(f"  dy  min={min(dys):+.1f}  max={max(dys):+.1f}  mean={np.mean(dys):+.1f}")
        log(f"  dx  min={min(dxs):+.1f}  max={max(dxs):+.1f}  mean={np.mean(dxs):+.1f}")
        pad = (0, 0, 0, 0)
        if image:
            angles = [image_match.angle_of(m) for row in transforms for m in row]
            log(f"  angle  min={min(angles):+.1f}  max={max(angles):+.1f} degrees")
            if not args.no_enlarge_canvas:
                pad = image_match.covering_pad([m for row in transforms for m in row], X, Y)
        log(f"\nCanvas padding:  top={pad[0]}  bottom={pad[1]}  left={pad[2]}  right={pad[3]}")
        H, W = Y + pad[0] + pad[1], X + pad[2] + pad[3]
        log(f"  Expanded canvas: Y={H}  X={W}")

        # Work out the z shift of every timepoint in whole slices, for each embryo. When the canvas is not
        # enlarged, slices that leave the stack are dropped.
        plans = [tracker.plan(pad=not args.no_enlarge_canvas) if tracker else None for tracker in trackers]
        for p, correction in enumerate(plans):
            if correction is not None:
                log(f"\nZ correction, embryo {p}:")
                for text in trackers[p].summary(correction, Z):
                    log(text)

        log(f"\n--- Pass 2: aligning {P} embryo(s) × {T} timepoints ---")
        for p in range(P):
            log(f"\n  Embryo {p}/{P - 1}")
            path = tiff_path(p)
            log(f"    Saving {path.name}{' (streaming)' if args.low_memory else ''} ...")
            aligned = movies(p, True, H, W)
            correction = plans[p]
            kept = correction.kept if correction is not None else np.arange(T)
            depth = Z + correction.pad_low + correction.pad_high if correction is not None else Z

            def pass2(index, p=p, aligned=aligned, correction=correction, kept=kept):
                t = int(kept[index])
                frame = cache.pop((p, t)) if cache is not None and (p, t) in cache else source.read_frame(t, p)
                # The xy shifts and transforms hold the kept timepoints only.
                if image:
                    out = backend.warp(frame, pad, transforms[p][index])
                else:
                    # Without an xy correction the pixel values and the sample type stay as they are.
                    out = np.asarray(frame)
                gray = ChannelMovies.gray_frames(backend.max_project_all(out)) if aligned else None
                # Move whole slices and leave the gaps empty. The movie frames are made before this step because a
                # maximum projection along z does not change.
                if correction is not None:
                    out = z_drift.place(out, correction.shift[t], correction.pad_low, correction.pad_high)
                return out, gray

            def frames(aligned=aligned, p=p, kept=kept):
                for index, (out, gray) in enumerate(ordered_map(pass2, len(kept), width)):
                    if aligned:
                        aligned.append(gray)
                    progress(f"Pass 2: aligning (embryo {p})", index + 1, len(kept))
                    yield out

            metadata = None
            if correction is not None and len(kept) != T and source.period_s is not None:
                # Record the original acquisition time of every plane, because timepoints were left out.
                metadata = ome_metadata(names, source.vox, source.period_s)
                times = [int(t) * source.period_s for t in kept for _ in range(C * depth)]
                metadata["Plane"] = {"DeltaT": times, "DeltaTUnit": ["s"] * len(times)}
            try:
                save_ome_tiff(path, frames(), names, source.vox, source.period_s, shape=(len(kept), C, depth, H, W),
                              dtype=np.uint16 if image else source.dtype, metadata=metadata,
                              bigtiff=True if args.low_memory else None)
                if aligned:
                    aligned.close()
            except BaseException:
                if aligned:
                    aligned.cancel()
                raise
            log(f"    Saved {path.name}")
            if correction is not None:
                table = path.with_name(f"{stem_without_ome(path)}_shifts.csv")
                trackers[p].save_csv(table, correction)
                log(f"    Saved {table.name}")
            written.append(path)
            for m in (movie_paths(p, True) + movie_paths(p, False)) if not args.no_movies else []:
                log(f"    Saved {m.name}")
    finally:
        source.close()
    return written, shifts


def main(argv=None):
    args = parse_args(argv)
    start = time.time()
    align(args)
    log(f"\nFinished in {time.time() - start:.1f} s")


if __name__ == "__main__":
    sys.exit(main())
