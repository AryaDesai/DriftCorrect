# DriftCorrect for Apple silicon

This is a Swift port of the embryo drift-correction scripts (`nd2_to_tif.py`, `find_threshold.py`,
`centroid_align_xy.py`, and their GUIs). It contains:

- **DriftCorrect.app**: a SwiftUI app. It has the launcher and four tool windows: Convert ND2 to TIFF, Mask embryo, Align movie, and Correct z drift.
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
dc align P0_Venus_threshold.yaml --z-correct [--z-channel NAME] [--z-region mask|whole|box] [--z-box x,y,width,height]
dc correct-z P0_concat_xy.ome.tif [--z-channel NAME] [--yaml P0_Venus_threshold.yaml] [--no_enlarge_stack] [--low_memory]
dc z-shifts P0_concat_xy.ome.tif [--z-channel NAME]   # measures the z drift and saves a CSV
dc nd2-info file.nd2 --checksums          # metadata and frame checksums as JSON
dc bench                                  # CPU vs Metal timing
```

Add `--cpu` to `align` to use the CPU reference instead of Metal.

## Z correction

The tools can also correct drift along z. The correction keeps the same tissue in the same slice at every timepoint.

There are two ways to run it.

- The **Correct z drift** window, or `dc correct-z FILE`, corrects one OME-TIFF or ND2 file without aligning it in xy. Use it on a file that is already steady in xy, such as the `{name}_xy.ome.tif` file from an earlier alignment. It writes `{name}_z.ome.tif` next to the input file.
- The **Correct z drift (after xy)** option of the Align tool, or `dc align --z-correct`, runs the xy alignment and the z correction in one run. The z drift is measured on the frames after they are centred in xy. It writes `{name}_xy_z.ome.tif` in place of `{name}_xy.ome.tif`.

### How the drift is measured

The tool compares each timepoint with the timepoint before it and estimates how many slices the tissue moved between them. It makes this estimate in three steps.

1. The microscope records the stage z position of every frame. When the person at the microscope pauses the imaging and centres the embryo again in z, the stage position changes. The size of that change gives the first estimate of the jump. This estimate is available even when the jump is so large that the two stacks have almost no slices in common.
2. The tool then compares the images. It tries every offset close to the first estimate, together with a small search in xy, and it measures how different the slices of the two timepoints are at each offset. The measure is the sum of the absolute differences between the pixel values. The offset with the smallest difference becomes the second estimate.
3. Finally the tool finds the centres of the nuclei in both timepoints and pairs each nucleus with the nuclei close to where the second estimate predicts it. When a large enough share of the nuclei agree on one movement, the median of their z movements replaces the second estimate. The thresholds are constants at the top of `ZDrift` in the code.

### How the correction is applied

The correction moves whole slices and does not interpolate between slices. Where a timepoint has no data for a slice, the output has an empty slice that is filled with zeros. The stack becomes deeper so that no slice is lost, in the same way that the xy canvas becomes larger. The first timepoint keeps its slices where they are, and every other timepoint moves to match it. The reference timepoint is `ZCorrectionOptions.referenceTimepoint` in the code, and the app does not show it yet.

The output can be much deeper than the input when the embryo was centred again several times, because each jump adds as many empty slices as the jump is large. When the stack is not enlarged, it keeps its depth and the slices that leave it are dropped. In the Align tool this follows **Enlarge canvas to prevent clipping**. In the Correct z drift window it is the option **Add empty slices so that no slice is lost**.

### Settings

- The z channel is the channel whose pattern the tool follows. A nuclear marker is the best choice, because its pattern stays the same while a reporter that oscillates changes from one timepoint to the next. The app selects a channel whose name looks like a nuclear marker when the file has one.
- The region is the part of the image that should stay in the same slice. It can be the whole frame, the embryo mask, or a box that you draw over cells that should not move in z. The embryo mask needs the threshold YAML file from the Mask tool. On the command line the box is `--z-box x,y,width,height` in pixels of the first timepoint.

### Outputs

- The corrected stack is `{name}_z.ome.tif` from the Correct z drift window and `{name}_xy_z.ome.tif` from the Align tool.
- A CSV file with the same name and the ending `_shifts.csv` has one row for each timepoint. A row holds the stage z position, the three estimates, the value that was used, the number of whole slices the timepoint was moved, and a flag when the estimate needs a look.
- The movies of the Align tool are maximum projections along z, so z correction does not change them. The Correct z drift window does not write movies.

`dc z-shifts FILE` measures the drift and saves the CSV file without writing a corrected stack.

### Stage positions

The Convert tool stores the stage z positions from the ND2 file in the OME-TIFF, as the standard `PositionZ` of each `Plane`. Concatenation, alignment and z correction keep them. An OME-TIFF that was converted before this change has no stage positions. For such a file the z correction uses the images alone, and it cannot measure a jump that leaves too few slices in common. To get the stage positions, convert the ND2 files again, or in the Align tool select **Load directly from the raw ND2 file**.

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
| Z drift measurement and the moving of slices | CPU, on all cores |
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
13. **Z correction.** The tools can correct drift along z, which the Python scripts in this repository do not do. The section "Z correction" above describes it.
14. **Stage z positions.** The stage z positions from the ND2 file are stored in every OME-TIFF that the tools write.

## Code layout

```
Sources/DCCore/     file formats (TIFF, OME-XML, ND2), exact CPU algorithms, pipelines
Sources/DCApple/    Metal backend (Shaders.swift, MetalBackend.swift), HEVC writer
Sources/dc/         command-line tool
Sources/DriftCorrectApp/  SwiftUI app
Tests/              parity tests against the Python outputs, Metal-vs-CPU tests
scripts/            reference-data generator, ND2 dump, comparison and build scripts
```
