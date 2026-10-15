# DriftCorrect for Apple silicon

This is a Swift port of the embryo drift-correction scripts (`nd2_to_tif.py`, `find_threshold.py`,
`centroid_align_xy.py`, their GUIs, and the manual-shift helpers in
`useful_functions.py`). It contains:

- **DriftCorrect.app**: a SwiftUI app. It has the launcher and four tool windows: Convert ND2 to TIFF, Mask embryo, Align movie, and Manual XY shift.
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
dc manual-xy --tif P0_concat.ome.tif --row 0,5,120,130,118,141 [--row …]
dc nd2-info file.nd2 --checksums          # metadata and frame checksums as JSON
dc bench                                  # CPU vs Metal timing
```

Add `--cpu` to `align` or `manual-xy` to use the CPU reference instead of Metal.

## Manual XY window

Load a TIFF (or its threshold YAML). The left pane shows timepoint `t` and the right
pane shows `t+1`. Browse both with the shared time slider or Previous/Next buttons.
Each pane has its own Z slider. Timepoints and slices use zero-based indices.

Select the same landmark in both panes, then choose **Preview correction** and
**Accept correction**. Each accepted correction applies to the moving timepoint
and every later timepoint, across all channels and Z slices. Additional corrections
accumulate. **Remove correction here** removes only the current boundary's offset.
Selecting landmarks again at an already corrected boundary adds the remaining
displacement to that boundary's correction.

Navigation or display-setting changes discard an unaccepted preview. Display
smoothing is optional and does not affect exported intensities. Export applies the
cumulative offset once to each original frame and writes the existing OME-TIFF and
per-channel movie outputs. Corrections remain in the window until another file is
loaded or the window's state is discarded; there is no saved correction-session file.
The `dc manual-xy` CLI retains its existing per-target row behavior.

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
3. **Manual XY shift.** This now has a window and a CLI command.

Defects fixed:

4. **`--use_nd2` crash.** The run no longer stops with a `NameError` at the movie step.
5. **Missing import.** `align_frame_xy` and the manual-shift functions used `scipy.ndimage.shift` without an import. As a result, `--no_enlarge_canvas` failed on the CPU path.
6. **Single channel or single Z-slice.** Files with one channel or one Z-slice now load. tifffile removes singleton axes, so `T, C, Z, Y, X = series.shape` failed.
7. **ND2 axis order.** ND2 files are read by axis name. The Python code assumed the loop order T, P, Z.
8. **Mask tool preview.** The preview now smooths ND2 data in float32, as alignment does. Before, it smoothed uint16 data, and the result was truncated to uint16.

Other changes:

9. **Concatenated TIFFs** keep uint16. The values are unchanged, and the files are half the size.
10. **Metadata warnings.** The concatenation compares channel names and calibration. The Python code compared the raw OME-XML, and it always warned, because every file has its own UUID.
11. **File names.**
    - The unaligned movie is `{stem}_{channel}_unaligned.mp4` in both canvas modes.
12. **Closing a tool window** does not stop a run. Quitting the app asks for confirmation first.
13. **Legacy ND2 files** (JPEG 2000, format 1.0) and RGB ND2 files show an error message.

## Code layout

```
Sources/DCCore/     file formats (TIFF, OME-XML, ND2), exact CPU algorithms, pipelines
Sources/DCApple/    Metal backend (Shaders.swift, MetalBackend.swift), HEVC writer
Sources/dc/         command-line tool
Sources/DriftCorrectApp/  SwiftUI app
Tests/              parity tests against the Python outputs, Metal-vs-CPU tests
scripts/            reference-data generator, ND2 dump, comparison and build scripts
```
