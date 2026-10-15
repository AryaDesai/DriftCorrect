"""centroid_align_xy.py — align embryo movies by XY centroid tracking.

Reads a threshold YAML from the Mask tool (find_threshold.py), shifts the
embryo to the frame centre at every timepoint, and writes one OME-TIFF and
one aligned and one unaligned MP4 per channel.

Every YAML setting is used: method, invert, levels, selected classes, block
size and the per-timepoint parameters.

Two-pass canvas expansion is the default: Pass 1 computes all shifts,
Pass 2 pads the canvas so no data is clipped and applies the shifts.
--no_enlarge_canvas uses one pass on the original canvas.

Shift modes: "subpixel" (scipy bilinear, the default) or "integer" (whole
pixels, which the old --use_gpu path produced). The GPU is used
automatically when CUDA is available; --cpu forces NumPy/SciPy.

Usage:
    python centroid_align_xy.py nd1181_P0_Venus_threshold.yaml
    python centroid_align_xy.py nd1181_P0_Venus_threshold.yaml --use_nd2 --shift_mode integer
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np

from backend import SHIFT_MODES, get_backend
from useful_functions import (
    ChannelMovies, FrameSource, compute_shift_xy, covering_pad, get_threshold_params_for_timepoint,
    load_threshold_yaml, log, ordered_map, physical_memory, pipeline_width, progress, resolve_tif_from_yaml,
    save_ome_tiff, shift_line, stem_without_ome,
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Centroid-align embryo movies.")
    parser.add_argument("yaml_file", help="Threshold YAML from the Mask tool")
    parser.add_argument("--use_nd2", action="store_true", help="Load from the ND2 file instead of the per-embryo TIF.")
    parser.add_argument("--fps", type=float, default=2, help="Frames per second of the movies (default: 2)")
    parser.add_argument("--no_enlarge_canvas", action="store_true",
                        help="Single pass without canvas expansion (edge data may be clipped).")
    parser.add_argument("--shift_mode", choices=SHIFT_MODES, default=None,
                        help="subpixel (bilinear, default) or integer (whole pixels).")
    parser.add_argument("--use_gpu", action="store_true",
                        help="Kept for old scripts: same as --shift_mode integer. The GPU is used automatically.")
    parser.add_argument("--low_memory", action="store_true",
                        help="Do not keep frames in memory between the two passes.")
    parser.add_argument("--no_movies", action="store_true", help="Do not write MP4 movies.")
    parser.add_argument("--cpu", action="store_true", help="Use NumPy/SciPy even when CUDA is available.")
    args = parser.parse_args(argv)
    if args.shift_mode is None:
        args.shift_mode = "integer" if args.use_gpu else "subpixel"
    return args


def align(args):
    """Run the alignment. Returns (output TIFF paths, shifts[p][t] = (dy, dx))."""
    backend = get_backend(prefer_gpu=not args.cpu)
    yaml_path = Path(args.yaml_file)
    cfg = load_threshold_yaml(yaml_path)

    if args.use_nd2:
        src_path = Path(cfg["source"]["file"])
        if not src_path.is_file():
            raise FileNotFoundError(f"ND2 file not found: {src_path}")
        log(f"Loading {src_path} ...")
        source = FrameSource(src_path)
        base = src_path.stem
        stem = base
        log(f"  Shape: T={source.T}, P={source.P}, Z={source.Z}, C={source.C}, Y={source.Y}, X={source.X}")
    else:
        src_path, base = resolve_tif_from_yaml(yaml_path, cfg)
        if src_path == Path(cfg["source"]["file"]):
            log(f"Using source file from YAML: {src_path}")
        log(f"Loading {src_path.name} ...")
        source = FrameSource(src_path)
        stem = stem_without_ome(src_path)
        log(f"  Shape: T={source.T}, C={source.C}, Z={source.Z}, Y={source.Y}, X={source.X}")
    out_dir = src_path.parent / f"aligned_{base}"
    names = source.channel_names
    top = get_threshold_params_for_timepoint({"parameters": cfg["parameters"]}, 0)
    log(f"  Channels: {names}")
    if 0 <= top["channel_index"] < len(names):
        log(f"  Threshold channel: {names[top['channel_index']]} (index {top['channel_index']})")
    log(f"  sigma={top['sigma']}, percentile={top['percentile']}, method={top['method']}")
    log(f"  Compute: {backend.name}, shift: {args.shift_mode}")
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"  Output: {out_dir}")

    T, P, C, Z, Y, X = source.T, source.P, source.C, source.Z, source.Y, source.X
    width = pipeline_width(source.frame_bytes)

    def tiff_path(p):
        return out_dir / (f"{base}_P{p}.ome.tif" if source.is_nd2 else f"{stem}_xy.ome.tif")

    def movie_paths(p, aligned):
        kind = "aligned" if aligned else "unaligned"
        if source.is_nd2:
            return [out_dir / f"{base}_P{p}_{ch}_{kind}.mp4" for ch in names[:C]]
        return [out_dir / (f"{stem}_xy_{ch}_aligned.mp4" if aligned else f"{stem}_{ch}_unaligned.mp4") for ch in names[:C]]

    def movies(p, aligned, h, w):
        return None if args.no_movies else ChannelMovies(movie_paths(p, aligned), w, h, args.fps)

    def params_at(t):
        return get_threshold_params_for_timepoint(cfg, t)

    shifts = [[] for _ in range(P)]
    written = []
    try:
        if not args.no_enlarge_canvas:
            cache = {} if (not args.low_memory and source.frame_bytes * T * P <= 0.4 * physical_memory()) else None
            log("\n--- Pass 1: precomputing shifts ---")
            for p in range(P):
                log(f"\n  Embryo {p}/{P - 1}:")
                unaligned = movies(p, False, Y, X)

                def pass1(t, p=p, unaligned=unaligned):
                    frame = source.read_frame(t, p)
                    dy, dx = compute_shift_xy(frame, params_at(t), backend)
                    gray = ChannelMovies.gray_frames(backend.max_project_all(frame)) if unaligned else None
                    if cache is not None:
                        cache[(p, t)] = frame
                    return dy, dx, gray

                try:
                    for t, (dy, dx, gray) in enumerate(ordered_map(pass1, T, width)):
                        log(shift_line(dy, dx))
                        shifts[p].append((dy, dx))
                        if unaligned:
                            unaligned.append(gray)
                        progress(f"Pass 1: shifts (embryo {p})", t + 1, T)
                    if unaligned:
                        unaligned.close()
                except BaseException:
                    if unaligned:
                        unaligned.cancel()
                    raise

            dys = [s[0] for row in shifts for s in row]
            dxs = [s[1] for row in shifts for s in row]
            log("\nShift summary (pixels):")
            log(f"  dy  min={min(dys):+.1f}  max={max(dys):+.1f}  mean={np.mean(dys):+.1f}")
            log(f"  dx  min={min(dxs):+.1f}  max={max(dxs):+.1f}  mean={np.mean(dxs):+.1f}")
            pad = covering_pad(dys, dxs)
            log(f"\nCanvas padding:  top={pad[0]}  bottom={pad[1]}  left={pad[2]}  right={pad[3]}")
            H, W = Y + pad[0] + pad[1], X + pad[2] + pad[3]
            log(f"  Expanded canvas: Y={H}  X={W}")

            log(f"\n--- Pass 2: aligning {P} embryo(s) × {T} timepoints ---")
            for p in range(P):
                log(f"\n  Embryo {p}/{P - 1}")
                path = tiff_path(p)
                log(f"    Saving {path.name}{' (streaming)' if args.low_memory else ''} ...")
                aligned = movies(p, True, H, W)

                def pass2(t, p=p, aligned=aligned):
                    frame = cache.pop((p, t)) if cache is not None and (p, t) in cache else source.read_frame(t, p)
                    dy, dx = shifts[p][t]
                    out = backend.shift(frame, pad, dy, dx, args.shift_mode)
                    gray = ChannelMovies.gray_frames(backend.max_project_all(out)) if aligned else None
                    return out, gray

                def frames(aligned=aligned, p=p):
                    for t, (out, gray) in enumerate(ordered_map(pass2, T, width)):
                        if aligned:
                            aligned.append(gray)
                        progress(f"Pass 2: aligning (embryo {p})", t + 1, T)
                        yield out

                try:
                    save_ome_tiff(path, frames(), names, source.vox, source.period_s, shape=(T, C, Z, H, W),
                                  dtype=np.uint16, bigtiff=True if args.low_memory else None)
                    if aligned:
                        aligned.close()
                except BaseException:
                    if aligned:
                        aligned.cancel()
                    raise
                log(f"    Saved {path.name}")
                written.append(path)
                for m in (movie_paths(p, True) + movie_paths(p, False)) if not args.no_movies else []:
                    log(f"    Saved {m.name}")
        else:
            log(f"\nAligning {P} embryo(s) × {T} timepoints ...")
            for p in range(P):
                log(f"\n  Embryo {p}/{P - 1}")
                path = tiff_path(p)
                log(f"    Saving {path.name}{' (streaming)' if args.low_memory else ''} ...")
                aligned, unaligned = movies(p, True, Y, X), movies(p, False, Y, X)

                def one_pass(t, p=p, aligned=aligned):
                    frame = source.read_frame(t, p)
                    dy, dx = compute_shift_xy(frame, params_at(t), backend)
                    out = backend.shift(frame, (0, 0, 0, 0), dy, dx, args.shift_mode)
                    a = u = None
                    if aligned:
                        a = ChannelMovies.gray_frames(backend.max_project_all(out))
                        u = ChannelMovies.gray_frames(backend.max_project_all(frame))
                    return dy, dx, out, a, u

                def frames(p=p, aligned=aligned, unaligned=unaligned):
                    for t, (dy, dx, out, a, u) in enumerate(ordered_map(one_pass, T, width)):
                        log(shift_line(dy, dx))
                        shifts[p].append((dy, dx))
                        if aligned:
                            aligned.append(a)
                            unaligned.append(u)
                        progress(f"Aligning timepoints (embryo {p})", t + 1, T)
                        yield out

                try:
                    save_ome_tiff(path, frames(), names, source.vox, source.period_s, shape=(T, C, Z, Y, X),
                                  dtype=np.uint16, bigtiff=True if args.low_memory else None)
                    for m in (aligned, unaligned):
                        if m:
                            m.close()
                except BaseException:
                    for m in (aligned, unaligned):
                        if m:
                            m.cancel()
                    raise
                log(f"    Saved {path.name}")
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
