"""export_movies.py writes MP4 movies of an OME-TIFF or ND2 file, one for each channel, next to the file.

Each frame is the maximum projection along z or one slice, in gray. The brightest 0.5% of the pixels are white. With
--compare, a second file is shown to the right of the first one.

Usage:
    python export_movies.py P0_concat_xy_z.ome.tif
    python export_movies.py P0_concat_xy_z.ome.tif --channel mCherry --slice 9 --compare P0_concat.ome.tif --codec h264
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np

from backend import get_backend
from centroid_align_xy import resolve_channel
from ffmpeg_runtime import CODECS, DEFAULT_QUALITY, MovieWriter
from useful_functions import FrameSource, log, ordered_map, pipeline_width, progress, stem_without_ome

# The share of the pixels that is shown as white is 100 minus this percentile. This is the same rule that the movies of
# the alignment use.
PERCENTILE = 99.5
# The brightness of the whole movie comes from this many timepoints, spread evenly over the movie. Reading every
# timepoint for it would read the whole movie twice.
CONTRAST_SAMPLES = 20


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Write MP4 movies of an OME-TIFF or ND2 file, one for each channel.")
    parser.add_argument("movie", help="An OME-TIFF or ND2 file.")
    parser.add_argument("--channel", help="The channel to export, given as a name or as an index that starts at 0. "
                                          "Without it every channel is exported.")
    parser.add_argument("--slice", type=int, help="Show this slice, counted from 1. Without it the movie shows the "
                                                  "maximum projection along z.")
    parser.add_argument("--fps", type=float, default=2, help="Frames per second (default: 2).")
    parser.add_argument("--contrast", choices=("movie", "frame"), default="movie",
                        help="movie sets the brightness once for the whole movie (default). frame sets it for each "
                             "frame.")
    parser.add_argument("--compare", help="A second OME-TIFF or ND2 file, shown to the right of the first one.")
    parser.add_argument("--codec", choices=CODECS, default=CODECS[0],
                        help="hevc (default) or h264. H.264 plays in more programs, and its files are larger.")
    parser.add_argument("--quality", type=float, default=DEFAULT_QUALITY,
                        help="The quality from 1 to 100 (default: 65). Higher values give larger files with fewer "
                             "artefacts.")
    parser.add_argument("--cpu", action="store_true", help="Use NumPy even when CUDA is available.")
    args = parser.parse_args(argv)
    if not args.fps > 0:
        parser.error("--fps must be a positive number")
    if not 1 <= args.quality <= 100:
        parser.error("--quality must be between 1 and 100")
    return args


def image(frame, channel, slice_number, backend):
    """Return the image of one channel of a (C, Z, Y, X) frame, which is one slice or the maximum projection."""
    if slice_number is not None:
        return np.asarray(frame[channel, slice_number - 1], dtype=np.float32)
    return backend.max_project(frame, channel)


def scale(img, white):
    """Return the image as uint8 gray with `white` shown as 255, as auto_contrast does."""
    return np.clip(img / white * 255, 0, 255).astype(np.uint8)


def brightness(source, channels, position, slice_number, count, backend):
    """Return the value that is shown as white for each channel of one movie. It is the percentile of the pixels of
    timepoints spread evenly over the movie. Every fourth pixel is used, which gives the same value to within a gray
    level and keeps the memory small."""
    n = min(count, CONTRAST_SAMPLES)
    times = [k * (count - 1) // (n - 1) if n > 1 else 0 for k in range(n)]
    values = [[] for _ in channels]
    for t in times:
        frame = source.read_frame(t, position)
        for i, c in enumerate(channels):
            values[i].append(image(frame, c, slice_number, backend).ravel()[::4])
    whites = [float(np.percentile(np.concatenate(v), PERCENTILE)) for v in values]
    return [w if w > 0 else 1.0 for w in whites]


def export(args):
    """Write the movies and return their paths. Every setting is checked before the first movie is started, so that a
    wrong setting does not leave some movies written and others missing."""
    backend = get_backend(prefer_gpu=not args.cpu)
    first_path = Path(args.movie)
    sources = []
    try:
        # Open the first movie and report its size.
        log(f"Loading {first_path.name} ...")
        a = FrameSource(first_path)
        sources.append(a)
        log(f"  Shape: T={a.T}, P={a.P}, Z={a.Z}, C={a.C}, Y={a.Y}, X={a.X}")
        names_a = list(a.channel_names[:a.C])

        # A file without channel names gets ch0, ch1 and so on.
        def name(c):
            return names_a[c] if c < len(names_a) else f"ch{c}"

        # Export every channel of the first movie, or the one channel that was chosen.
        if args.channel is None or args.channel == "":
            channels_a = list(range(a.C))
        else:
            channels_a = [resolve_channel(args.channel, names_a, a.C, 0, "Export")]
        b, channels_b = None, []
        if args.compare:
            compare_path = Path(args.compare)
            log(f"Comparing with {compare_path.name}")
            b = FrameSource(compare_path)
            sources.append(b)
            log(f"  Shape: T={b.T}, P={b.P}, Z={b.Z}, C={b.C}, Y={b.Y}, X={b.X}")
            names_b = list(b.channel_names[:b.C])
            # The second movie shows the channel with the same name. The channel order can differ between files, so a
            # match by name is safer. When no name matches, the channel with the same index is used.
            for c in channels_a:
                if name(c) in names_b:
                    channels_b.append(names_b.index(name(c)))
                elif c < b.C:
                    channels_b.append(c)
                else:
                    raise ValueError(f"The second movie has no channel {name(c)}. Its channels are {', '.join(names_b)}.")
            # A file with one embryo can be compared with every embryo of the first movie. Files with several
            # embryos must hold the same number, so that each embryo is compared with the same embryo.
            if b.P > 1 and b.P != a.P:
                raise ValueError(f"The two movies hold a different number of embryos ({a.P} and {b.P}).")
        # The slice must exist in both movies. A stack that z correction enlarged has more slices than its input.
        if args.slice is not None:
            for path, source in [(first_path, a)] + ([(Path(args.compare), b)] if b else []):
                if not 1 <= args.slice <= source.Z:
                    raise ValueError(f"Slice {args.slice} is outside {path.name}, which has {source.Z} slices.")
        # The two movies can differ in length, for example when z correction dropped timepoints. The export then stops
        # after the shorter movie, because there is nothing to show on the other side.
        T = a.T
        if b is not None and b.T != a.T:
            T = min(a.T, b.T)
            log(f"  The two movies have {a.T} and {b.T} timepoints. The export stops after {T}.")

        # The movies are saved next to the first movie. The name says the channel, the view and the compared movie, so
        # that exports with different settings do not overwrite each other.
        view = f"z{args.slice}" if args.slice is not None else "max"
        versus = f"_vs_{stem_without_ome(Path(args.compare))}" if args.compare else ""
        stem_a = first_path.stem if a.is_nd2 else stem_without_ome(first_path)
        written = []
        # Each embryo of an ND2 file gets its own movies.
        for p in range(a.P):
            sides = [(a, channels_a, p)] + ([(b, channels_b, p if b.P > 1 else 0)] if b else [])
            stem = stem_a + (f"_P{p}" if a.P > 1 else "")
            paths = [first_path.parent / f"{stem}_{name(c).replace(' ', '_')}_{view}{versus}.mp4" for c in channels_a]
            # The two movies sit side by side, so the frame is as wide as both and as tall as the taller one.
            width = sum(source.X for source, _, _ in sides)
            height = max(source.Y for source, _, _ in sides)

            # Set the brightness of each channel of each movie from a sample of timepoints spread over the movie. Each
            # side gets its own value, so that a dimmer movie is not shown darker than the other one.
            whites = None
            if args.contrast == "movie":
                log(f"  Setting the brightness from {min(T, CONTRAST_SAMPLES)} timepoints ...")
                whites = [brightness(source, channels, q, args.slice, T, backend) for source, channels, q in sides]

            # Each channel gets a black frame, and each movie is copied into it at its place from the left. A shorter
            # movie leaves black below it.
            def frames(t, sides=sides, whites=whites, paths=paths, width=width, height=height):
                canvas = [np.zeros((height, width), np.uint8) for _ in paths]
                left = 0
                for k, (source, channels, q) in enumerate(sides):
                    frame = source.read_frame(t, q)
                    for i, c in enumerate(channels):
                        pixels = image(frame, c, args.slice, backend)
                        # Scale with the brightness of the whole movie, or with the brightness of this frame alone.
                        white = whites[k][i] if whites else float(np.percentile(pixels, PERCENTILE)) or 1.0
                        canvas[i][:source.Y, left:left + source.X] = scale(pixels, white)
                    left += source.X
                return canvas

            # Read the timepoints in parallel and write the frames in order. A failure deletes the partial movies.
            writers = [MovieWriter(path, width, height, args.fps, args.codec, args.quality) for path in paths]
            try:
                frame_bytes = sum(source.frame_bytes for source, _, _ in sides)
                for t, canvas in enumerate(ordered_map(frames, T, pipeline_width(frame_bytes))):
                    for writer, gray in zip(writers, canvas):
                        writer.append(gray)
                    progress("Exporting" + (f" (embryo {p})" if a.P > 1 else ""), t + 1, T)
                for writer in writers:
                    writer.close()
            except BaseException:
                for writer in writers:
                    writer.cancel()
                raise
            for path in paths:
                log(f"  Saved {path.name}")
            written += paths
        return written
    finally:
        for source in sources:
            source.close()


def main(argv=None):
    args = parse_args(argv)
    start = time.time()
    export(args)
    log(f"\nFinished in {time.time() - start:.1f} s")


if __name__ == "__main__":
    sys.exit(main())
