# Drift correction (Python, CUDA or CPU)

Tools to convert ND2 files, mask embryos, and align movies in xy with optional z correction. The results are the same as the Swift app and the original scripts.

## Install

1. Install Python 3.10 or later.
2. Run `pip install -r requirements.txt`.
3. For an NVIDIA GPU, also install CuPy for your CUDA version: `pip install cupy-cuda12x` or `pip install cupy-cuda13x`.
4. Make FFmpeg available. Use one of these:
   - put `ffmpeg` on PATH,
   - set `DRIFT_CORRECT_FFMPEG` to the full path of the FFmpeg program,
   - put an `ffmpeg_vendor` folder next to `drift_correct.py`.

## Start

Run `python drift_correct.py`. The launcher has two buttons:

| Button | Script | Output |
|---|---|---|
| Convert ND2 to TIFF | `nd2_to_tif.py` | `{name}_P{p}.ome.tif`, `P{p}_concat.ome.tif` |
| Align movie | `centroid_align_xy.py` | `aligned_{base}/` with OME-TIFF and MP4 files |

The Mask window (`find_threshold.py`) opens from the Alignment window when a run needs the embryo mask. It writes `…_threshold.yaml` next to the movie.

Each script also runs from the command line. Use `--help` to see its options.

## Alignment

The Alignment window has three tabs. **XYZ** corrects the movie in xy and then in z. **XY only** and **Z only** run one of the two.

1. Select the movie, which is an OME-TIFF or ND2 file.
2. Choose the channel whose pattern is followed. A nuclear marker is the best choice.
3. When the settings use the embryo mask, an **Embryo mask** row appears. **Make mask…** opens the Mask window on the movie and starts from a threshold estimated from the image. Saving there writes the YAML file next to the movie and fills in the row. A YAML file saved earlier next to the movie is found automatically.
4. Run.

**Advanced options** holds the settings that change how the correction works. Each one shows an explanation when the pointer rests on it.

There are two xy methods.

- **Image matching** compares each timepoint with the one before it. It tries shifts and small turns and keeps the one where the two images differ least. The centroid of the embryo mask, averaged over nearby timepoints, then decides where the body sits. Sudden turns are removed, and slow turning stays as it was acquired. The cells can move inside the body while the body stays put.
- **Mask centroid** moves the centroid of the embryo mask to the frame centre at every timepoint.

Image matching can follow the whole frame, the embryo mask, or a box given as `x, y, width, height` in pixels of the first timepoint.

The z correction runs after the xy alignment. It compares the stack of each timepoint with the stack of the timepoint before it and with the one five timepoints earlier, and then moves whole slices. It does not interpolate between slices. Empty slices are added so that no slice is lost, and a table `…_shifts.csv` records what was measured and applied at every timepoint.

```shell
python centroid_align_xy.py P0_Venus_threshold.yaml --input P0_concat.ome.tif --xy_method image --xy_channel mCherry --z_correct --z_channel mCherry
python centroid_align_xy.py --input P0_concat.ome.tif --xy_method none --z_correct --z_channel mCherry
```

The first line corrects xy and z. The second corrects z alone and needs no mask.

Run `python centroid_align_xy.py --help` for the other settings, such as `--xy_smoothing`, `--xy_max_angle`, `--xy_no_hold`, `--z_span` and `--z_drop_above`.

## Tests

Run `python -m pytest tests`. The tests build a small synthetic movie and check the image matching, the anchor and the z correction on it.

## GPU and CPU

- The tools use CUDA through CuPy when a CUDA GPU is available. If not, they use NumPy and SciPy.
- To force the CPU, set `DRIFT_CORRECT_CPU=1`, use `--cpu`, or tick "Use CPU only" in the Align window.
- The CUDA kernels calculate in float64 without fused multiply-add, so the GPU output is bit-identical to SciPy.
- The Align window shows which backend it uses.

## Shift modes

- `subpixel` (default): bilinear shift, the same as `scipy.ndimage.shift(order=1)`.
- `integer`: shift by whole pixels. The old `--use_gpu` flag gives this mode.

## Changes from the original scripts

- JAX and PyTorch are removed. CuPy replaces them on the GPU. Multi-level Otsu runs in NumPy float64.
- Missing imports and other bugs are fixed, for example the missing `shift` import in `align_frame_xy`.
- Frames are read one timepoint at a time. The full movie is not loaded into memory.
- Reading, calculation and writing run at the same time in a thread pipeline.
- Movies are encoded during the alignment passes. The encoder order is NVENC, VideoToolbox, Quick Sync, then CPU.
- Output files are written under a temporary name and renamed when complete. A stopped run leaves no partial file.

## Packaging

`drift_correct.py` imports every tool explicitly, so Nuitka and PyInstaller find all modules. Keep `ffmpeg.nuitka-package.config.yml` next to it for Nuitka builds. CuPy adds approximately 1 GB to a packaged build. To make a CPU-only build, do not install CuPy in the build environment.
