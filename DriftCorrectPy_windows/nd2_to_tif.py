"""Convert a folder of ND2 files into per-embryo concatenated OME-TIFFs.

Each ND2 file (in filename order) becomes one OME-TIFF per embryo position,
{name}_P{p}.ome.tif. Then the TIFFs of each position are joined along T into
P{p}_concat.ome.tif. With --parallel (the default), each ND2 file is read
once and all positions are written at the same time.

Usage:
    python nd2_to_tif.py /path/to/nd2_folder
    python nd2_to_tif.py /path/to/nd2_folder --output_dir /path/to/output --position 0
"""

import argparse
import re
import sys
import threading
import time
from pathlib import Path

from useful_functions import (
    ND2Reader, concatenate_tifs, log, ome_metadata, ordered_map, pipeline_width, progress, save_ome_tiff,
)


def parse_bool(value):
    value = value.lower()
    if value in {"true", "1", "yes"}:
        return True
    if value in {"false", "0", "no"}:
        return False
    raise argparse.ArgumentTypeError("Expected true or false")


def convert_file(nd2_path, output_dir, positions, parallel, file_label):
    reader = ND2Reader(nd2_path)
    try:
        T, P, Z, C, Y, X = reader.T, reader.P, reader.Z, reader.C, reader.Y, reader.X
        log(f"  Shape: T={T}, P={P}, Z={Z}, C={C}, Y={Y}, X={X}")
        if positions is None:
            positions = list(range(P))
        for p in positions:
            if not 0 <= p < P:
                raise ValueError(f"Position {p} is out of range: {nd2_path.name} has {P} position(s)")
        base = nd2_path.stem
        groups = [positions] if parallel else [[p] for p in positions]
        for group in groups:
            # One reader thread fills a queue per position; each position's TIFF is written by its own thread.
            items = [(t, p) for t in range(T) for p in group]
            queues = {p: [] for p in group}
            conds = {p: threading.Condition() for p in group}
            errors = []

            def producer():
                try:
                    width = pipeline_width(reader.frame_bytes)
                    for i, frame in enumerate(ordered_map(lambda k: reader.read_frame(*items[k]), len(items), width)):
                        p = items[i][1]
                        with conds[p]:
                            while len(queues[p]) >= 4 and not errors:
                                conds[p].wait()
                            queues[p].append(frame)
                            conds[p].notify_all()
                        progress(f"Converting {file_label}", i + 1, len(items))
                except BaseException as e:
                    errors.append(e)
                    for c in conds.values():
                        with c:
                            c.notify_all()

            def frames(p):
                for _ in range(T):
                    with conds[p]:
                        while not queues[p] and not errors:
                            conds[p].wait()
                        if errors:
                            raise RuntimeError("reading the ND2 file failed") from errors[0]
                        frame = queues[p].pop(0)
                        conds[p].notify_all()
                    yield frame

            def writer(p):
                try:
                    out = output_dir / f"{base}_P{p}.ome.tif"
                    save_ome_tiff(out, frames(p), None, None, None, shape=(T, C, Z, Y, X), dtype=reader.dtype,
                                  metadata=ome_metadata(reader.channel_names[:C], reader.vox, reader.period_s))
                except BaseException as e:
                    errors.append(e)
                    for c in conds.values():
                        with c:
                            c.notify_all()

            for p in group:
                log(f"  Writing {base}_P{p}.ome.tif ...")
            threads = [threading.Thread(target=producer)] + [threading.Thread(target=writer, args=(p,)) for p in group]
            for th in threads:
                th.start()
            for th in threads:
                th.join()
            if errors:
                raise errors[0]
        return positions
    finally:
        reader.close()


def convert(nd2_folder, output_dir=None, position=None, parallel=True, concat_only=False):
    nd2_folder = Path(nd2_folder)
    if not nd2_folder.is_dir():
        raise NotADirectoryError(f"Error: not a directory: {nd2_folder}")
    nd2_files = sorted(nd2_folder.glob("*.nd2"))
    if not nd2_files:
        raise FileNotFoundError(f"Error: no .nd2 files found in {nd2_folder}")
    output_dir = Path(output_dir) if output_dir else nd2_folder / "tifs"
    output_dir.mkdir(parents=True, exist_ok=True)
    log(f"Found {len(nd2_files)} ND2 file(s) in {nd2_folder}")
    log(f"Output directory: {output_dir}")

    positions = None
    for k, nd2_path in enumerate([] if concat_only else nd2_files):
        log(f"\nOpening {nd2_path.name} ...")
        positions = convert_file(nd2_path, output_dir, None if position is None else [position],
                                 parallel and position is None, f"{nd2_path.name} ({k + 1}/{len(nd2_files)})")
    if concat_only:
        positions = [position] if position is not None else sorted(
            {int(m[1]) for f in output_dir.glob("*_P*.ome.tif") if (m := re.search(r"_P(\d+)\.ome\.tif$", f.name))})

    log("\nConcatenating per-embryo TIFFs ...")
    for p in positions or []:
        tifs = sorted(output_dir.glob(f"*_P{p}.ome.tif"))
        if len(tifs) < 2:
            log(f"  P{p}: only {len(tifs)} file(s), skipping concatenation")
            continue
        concat_path = output_dir / f"P{p}_concat.ome.tif"
        log(f"  P{p}: concatenating {len(tifs)} files -> {concat_path.name}")
        concatenate_tifs(tifs, concat_path)
    log("\nDone.")
    return output_dir


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert a folder of ND2 files into per-embryo concatenated OME-TIFFs.")
    parser.add_argument("nd2_folder", nargs="?", default=".", help="Directory containing .nd2 files (default: current).")
    parser.add_argument("--output_dir", help="Directory for output TIFFs (default: tifs inside the ND2 folder).")
    parser.add_argument("--parallel", type=parse_bool, default=True,
                        help="Read each ND2 file once and write all positions at the same time (default: true).")
    parser.add_argument("--position", type=int, default=None, help="Extract only this embryo position index (e.g. 0).")
    parser.add_argument("--concat_only", action="store_true", help="Skip conversion; only join existing per-embryo TIFFs.")
    args = parser.parse_args(argv)
    start = time.time()
    try:
        convert(args.nd2_folder, args.output_dir, args.position, args.parallel, args.concat_only)
    except (NotADirectoryError, FileNotFoundError) as e:
        print(str(e), file=sys.stderr)
        return 1
    log(f"Finished in {time.time() - start:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
