# DriftCorrect for Apple silicon

This is a Swift port of the embryo drift-correction scripts (`nd2_to_tif.py`, `find_threshold.py`,
`centroid_align_xy.py`, and their GUIs). It contains:

- **DriftCorrect.app**: a SwiftUI app. It has the launcher and three tool windows: Convert ND2 to TIFF, Mask embryo, and Align movie.
- **dc**: a command-line tool. `dc convert` and `dc align` accept the same arguments as the Python workers.

No Python, FFmpeg, or other runtime is necessary.

## Requirements

- A Mac with Apple silicon.
- macOS 14 or later. macOS 26 is recommended.
- Xcode 16 or later, or its command-line tools (`xcode-select --install`).

## Build and test

```bash
cd DriftCorrect
scripts/build_and_test.sh      # builds, runs all tests and a benchmark → build/report.txt
scripts/bundle_app.sh          # makes build/DriftCorrect.app and build/dc
```

The first build downloads two packages from GitHub: Yams (YAML) and swift-argument-parser.

If the build or a test fails, send `build/report.txt`.

To work in Xcode, open `Package.swift`, select the `DriftCorrectApp` scheme, and run.

## Command line

```bash
dc convert /path/to/nd2_folder [--output_dir DIR] [--position 0] [--parallel false] [--concat_only]
dc align P0_Venus_threshold.yaml [--use_nd2] [--fps 2] [--no_enlarge_canvas] [--use_gpu] [--low_memory]
dc align P0_Venus_threshold.yaml --z-correct [--z-channel mCherry] [--z-region mask|whole|box] [--z-box x,y,w,h]
dc z-shifts P0_concat.ome.tif --z-channel mCherry   # measure z drift only and save a CSV
dc nd2-info file.nd2 --checksums          # metadata and frame checksums as JSON
dc bench                                  # CPU vs Metal timing
```

Add `--cpu` to `align` to use the CPU reference instead of Metal.

## Z correction

The Align tool can also correct drift in z. It runs after the xy alignment. In the app, tick
**Correct z drift (after xy)**; on the command line, add `--z-correct`.

Each timepoint is compared with the one before it, in three steps:

1. **Stage position.** The microscope records the stage z of every frame. When imaging is paused and the
   embryo is re-centred in z, the change in stage z gives the size of the jump, even when the two stacks
   no longer overlap.
2. **Image comparison.** The slices of the two timepoints are compared at every offset near the stage
   estimate, with a small xy search. The offset where the images differ least wins (sum of absolute
   differences, not cross-correlation).
3. **Nuclei.** Nucleus centres are detected in both timepoints and matched. When at least 30% of them agree
   on one movement, the median of their z movements replaces the image estimate.

The correction moves whole slices; nothing is interpolated. Empty (zero) slices fill the gaps, and the stack
grows so that no slice is lost, as the xy canvas does. The first timepoint keeps its slices; every other
timepoint moves to match it (`ZCorrectionOptions.referenceTimepoint` in the code).

Settings:

- **Z channel**: the channel to follow. A nuclear marker works best, because its pattern does not change
  with an oscillating reporter. The default is the threshold channel of the YAML; the app starts on a
  channel named like a nuclear marker (mCherry, H2B, …) when there is one.
- **Follow**: the embryo mask from the YAML, the whole frame, or a box that you draw over cells that
  should stay in the same slice (`--z-box x,y,width,height` in pixels of the first timepoint).

Outputs, next to the usual ones:

- `{name}_xy_z.ome.tif`: the corrected stack. `{name}_xy.ome.tif` is not written in the same run.
- `{name}_xy_z_shifts.csv`: one row per timepoint with the stage z, the three estimates, the value used,
  the whole-slice shift, and a flag for timepoints that need a look (`weak match`, `stage only`).
- The movies are max projections over z, so z correction does not change them.

Things to know:

- **Stage positions come from Convert.** The Convert tool now stores the stage z in the OME-TIFF (as the
  standard `Plane` `PositionZ`), and concatenation and alignment keep it. TIFFs converted before this
  change have none; z correction then uses the images alone and cannot measure a jump larger than the
  stack. Convert the ND2 files again to get them, or use **Load directly from the raw ND2 file**.
- **The file grows.** A movie whose embryo was re-centred several times needs many empty slices. For
  example, jumps of 26, 15, 14, -4 and 6 slices turn a 27-slice stack into about 70 slices.
- **Without "Enlarge canvas"** the stack keeps its depth and slices that leave it are dropped.

`dc z-shifts FILE` measures the drift of a TIFF or ND2 and saves the CSV without writing a stack. It applies
no xy alignment, so use it on files that are already steady in xy, or to preview the drift.

## Check the ND2 reader on your own files

The ND2 reader is native Swift. It was tested on synthetic files that the `nd2` package reads correctly. To check it against a real file:

```bash
python scripts/nd2_dump.py file.nd2 > python.json
build/dc nd2-info file.nd2 --checksums > swift.json
python scripts/compare_json.py python.json swift.json
```

To compare full outputs with the Python pipeline, run both on the same input. Then, for each pair of files:

```bash
python scripts/compare_tiffs.py python_out/X.ome.tif swift_out/X.ome.tif
```

## How the hardware is used

| Step | Where it runs |
|---|---|
| Gaussian blur | Metal, separable (2·(2r+1) taps per pixel; the Python GPU path used a full (2r+1)² kernel) |
| Z max-projection, sub-pixel and whole-pixel shift | Metal, zero-copy on unified memory |
| Percentile, labelling, Otsu, multi-Otsu | CPU, on all cores; several frames are processed at the same time |
| HEVC movies | Media engine (VideoToolbox), encoded while frames pass through |
| TIFF / ND2 I/O | `pread` into page-aligned buffers that Metal uses without a copy; reads, compute and writes overlap |

Other changes that make the pipeline faster:

- The two-pass alignment keeps Pass 1 frames in memory for Pass 2 when they fit in 40% of RAM. With `--low_memory`, Pass 2 reads the frames again.
- The movies are made during the passes. The Python code read the TIFFs again to make them.
- The conversion reads each ND2 file once and writes all positions at the same time.
- The Mask tool reads one frame at a time. It reads the next frame in the background.

### Numerical agreement with the Python code

- **CPU implementations.** They match scipy, numpy, and OpenCV bit for bit. This includes the Gaussian, the percentile, the histogram, the labels, Otsu, multi-Otsu, and `scipy.ndimage.shift`. The unit tests check this against data that `scripts/make_reference.py` made with the original functions.
- **Metal kernels.** scipy calculates in float64, and Apple GPUs have no float64. For this reason, the kernels emulate float64 with float-float arithmetic.
  - The shift is bit-identical to scipy (0 differences in 3.4 million test pixels).
  - For the Gaussian, about 1 pixel in 250,000 is different, by 1 ulp (float32 unit in the last place).
- **Multi-Otsu.** It runs in float64. The Python code used float32 JAX. The thresholds agree on all test images.

## Differences from the Python scripts

Resolved as agreed:

1. **YAML settings.** Alignment uses every YAML setting: method, invert, levels, selected classes, block size, and per-timepoint parameters. `centroid_align_xy.py` used only sigma, percentile, and channel.
2. **Blur and shift.** The blur always uses scipy's rules. The shift mode is a choice:
   - sub-pixel (as the Python CPU path)
   - whole-pixel (as the Python GPU path)

Defects fixed:

3. **`--use_nd2` crash.** The run no longer stops with a `NameError` at the movie step.
4. **Missing import.** `align_frame_xy` and the manual-shift functions used `scipy.ndimage.shift` without an import. As a result, `--no_enlarge_canvas` failed on the CPU path.
5. **Single channel or single Z-slice.** Files with one channel or one Z-slice now load. tifffile removes singleton axes, so `T, C, Z, Y, X = series.shape` failed.
6. **ND2 axis order.** ND2 files are read by axis name. The Python code assumed the loop order T, P, Z.
7. **Mask tool preview.** The preview now smooths ND2 data in float32, as alignment does. Before, it smoothed uint16 data, and the result was truncated to uint16.

Other changes:

8. **Concatenated TIFFs** keep uint16. The values are unchanged, and the files are half the size.
9. **Metadata warnings.** The concatenation compares channel names and calibration. The Python code compared the raw OME-XML, and it always warned, because every file has its own UUID.
10. **File names.**
    - The unaligned movie is `{stem}_{channel}_unaligned.mp4` in both canvas modes.
11. **Closing a tool window** does not stop a run. Quitting the app asks for confirmation first.
12. **Legacy ND2 files** (JPEG 2000, format 1.0) and RGB ND2 files show an error message.
13. **Z correction** is new; the Python scripts in this repository have none. See "Z correction" above.
14. **Stage z positions** from the ND2 file are stored in every OME-TIFF.

## Code layout

```
Sources/DCCore/     file formats (TIFF, OME-XML, ND2), exact CPU algorithms, pipelines
Sources/DCApple/    Metal backend (Shaders.swift, MetalBackend.swift), HEVC writer
Sources/dc/         command-line tool
Sources/DriftCorrectApp/  SwiftUI app
Tests/              parity tests against the Python outputs, Metal-vs-CPU tests
scripts/            reference-data generator, ND2 dump, comparison and build scripts
```
