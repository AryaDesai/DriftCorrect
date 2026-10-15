# Drift correction (Python, CUDA or CPU)

Tools to convert ND2 files, mask embryos, align movies in XY, register in Z, and apply manual XY shifts. The results are the same as the Swift app and the original scripts.

## Install

1. Install Python 3.10 or later.
2. Run `pip install -r requirements.txt`.
3. For an NVIDIA GPU, also install CuPy for your CUDA version: `pip install cupy-cuda12x` or `pip install cupy-cuda13x`.
4. Make FFmpeg available. Use one of these:
   - put `ffmpeg` on PATH,
   - set `DRIFT_CORRECT_FFMPEG` to the full path of the FFmpeg program,
   - put an `ffmpeg_vendor` folder next to `drift_correct.py`.

## Start

Run `python drift_correct.py`. The launcher has five buttons:

| Button | Script | Output |
|---|---|---|
| Convert ND2 to TIFF | `nd2_to_tif.py` | `{name}_P{p}.ome.tif`, `P{p}_concat.ome.tif` |
| Mask embryo | `find_threshold.py` | `…_threshold.yaml` next to the input |
| Align movie | `centroid_align_xy.py` | `aligned_{base}/` with OME-TIFF and MP4 files |
| Z alignment | `z_align.py` | `{stem}_z_shifts.csv`, `{stem}_z.ome.tif` |
| Manual XY shift | `manual_xy.py` | `aligned_{stem}/{stem}_xy_manual.ome.tif` and MP4 files |

Each script also runs from the command line. Use `--help` to see its options.

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
- Z alignment and Manual XY shift have windows.

## Tests

Run `python -m pytest tests`. The tests compare the results with reference data from the original scripts. On a CUDA machine they also check the GPU backend.

## Packaging

`drift_correct.py` imports every tool explicitly, so Nuitka and PyInstaller find all modules. Keep `ffmpeg.nuitka-package.config.yml` next to it for Nuitka builds. CuPy adds approximately 1 GB to a packaged build. To make a CPU-only build, do not install CuPy in the build environment.
