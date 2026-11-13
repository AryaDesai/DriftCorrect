# DriftCorrect for Macs

This is a Swift port of the embryo drift-correction scripts (`nd2_to_tif.py`, `find_threshold.py`,
`centroid_align_xy.py`, and their GUIs). It contains:

- **DriftCorrect.app**: a SwiftUI app. The launcher opens two windows, Convert ND2 to TIFF and Align movie. The Mask window opens from the Alignment window when a run needs the embryo mask.
- **dc**: a command-line tool. `dc convert` and `dc align` accept the same arguments as the Python workers in the general version

## Requirements

- A Mac with Apple silicon.
- macOS 14 or later. 
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
dc align P0_Venus_threshold.yaml --xy-method image [--xy-channel NAME] [--xy-region whole|mask|box] [--xy-box x,y,width,height]
dc align P0_Venus_threshold.yaml --z-correct [--z-channel NAME] [--z-region whole|mask|box] [--z-box x,y,width,height]
dc correct-z P0_concat_xy.ome.tif [--z-channel NAME] [--yaml P0_Venus_threshold.yaml] [--no_enlarge_stack] [--low_memory]
dc z-shifts P0_concat_xy.ome.tif [--z-channel NAME]   # measures the z drift and saves a CSV
dc nd2-info file.nd2 --checksums          # metadata and frame checksums as JSON
dc bench                                  # CPU vs Metal timing
```

Add `--cpu` to `align` to use the CPU reference instead of Metal.

## Alignment window

The Alignment window has three tabs. **XYZ** corrects the movie in xy and then in z. **XY only** and **Z only** run one of the two.

1. Select the movie, which is an OME-TIFF or ND2 file.
2. Choose the channel whose pattern is followed. A nuclear marker is the best choice.
3. When the settings use the embryo mask, an **Embryo mask** row appears. **Make mask…** opens the Mask window on the movie with a suggested threshold. Adjust it and save, and the saved YAML file appears in the row. A YAML file saved earlier next to the movie is found automatically.
4. Run.

With the default settings, XYZ and XY only use the mask to hold the body in place, and Z only does not need it.

**Advanced options** holds the settings that change how the correction works. Each one has an explanation under it.

## Image matching

Image matching is how z correction measures drift, and it is one of the two ways the Align tool can measure drift in xy. It compares each timepoint with the timepoint before it.

The later image is slid over the earlier one, and in xy it is also turned by candidate angles. For every offset, the tool takes the pixels that both images hold inside the region it follows, scales both sides to the same mean so that bleaching does not count, and adds up the absolute differences. That sum divided by the sum of both images is the mismatch, which is 0 for identical images and 1 for images with nothing in common. The offset with the smallest mismatch is the movement between the two timepoints. A turn is accepted only when it lowers the mismatch by a clear margin compared with no turn, because a turned image is interpolated and that alone can lower the mismatch slightly.

The region can be the whole frame, the embryo mask, or a box that you draw over cells that should stay still. The embryo mask needs the threshold YAML file from the Mask tool. A box is drawn on the first timepoint before the alignment, and the tool moves it along with the tissue.

A match with a mismatch above 0.27 is marked `[weak match]` in the log. Such a timepoint is worth a look, because a wrong step moves every later timepoint by the same amount.

## XY alignment

The **Method** under Advanced options, or `dc align --xy-method`, chooses how the xy movement is found.

- **Image matching** compares each timepoint with the one before it, as the section above describes, on the maximum projection of the chosen channel. The search starts on a copy binned until its longer side is at most 128 pixels, across half the frame in each direction, so that the jump after the embryo was centred again is found. It then refines the shift and the angle on copies binned by 2 and at full resolution.
- **Mask centroid** moves every timepoint so that the centroid of the embryo mask sits in the centre of the frame, without turning. This is what the Python scripts did. The centroid moves whenever the mask changes shape, and the movie then wobbles with it.

### Holding the body in place

Image matching follows the cells. When the cells move through the body, as they do in a growing tail, the sum of the steps slowly carries the frame away from where it started. The output then shows the frame travelling across an empty canvas.

With **Hold the body in place with the embryo mask**, which is on by default, the tool uses the mask to say where the body is. It follows the centroid of the mask and the direction of its long axis, and averages both over nearby timepoints, because the mask is rough at a single timepoint and reliable over many. Each timepoint is then placed so that the averaged centroid sits in the middle of the frame and the long axis keeps the direction it had at the first timepoint. The sudden movement between neighbouring timepoints still comes from the image matching, so jumps and jitter are removed, and the cells are free to move inside the body.

The long axis is used only when the mask is clearly elongated at every timepoint. For a nearly round mask the tool removes sudden turns and leaves slow turning as it is.

The output is written with one move for each timepoint, which is a rotation and a shift with interpolation between pixels.

## Z correction

The tools can also correct drift along z. The correction keeps the same tissue in the same slice at every timepoint.

There are two ways to run it.

- The **Z only** tab, or `dc correct-z FILE`, corrects one OME-TIFF or ND2 file without aligning it in xy. Use it on a file that is already steady in xy, such as the `{name}_xy.ome.tif` file from an earlier alignment. It writes `{name}_z.ome.tif` next to the input file.
- The **XYZ** tab, or `dc align --z-correct`, runs the xy alignment and the z correction in one run. Each timepoint is moved in xy onto the timepoint it is compared with before the z drift is measured. It is also compared with the timepoint five back, where a slow movement is large enough to measure, and the positions are the ones that agree best with both sets of comparisons. It writes `{name}_xy_z.ome.tif` in place of `{name}_xy.ome.tif`.

### How the drift is measured

The z drift is measured by image matching. The stack of each timepoint is moved up and down against the stack before it, one slice at a time, and the mismatch is calculated over the slices that the two share. Only offsets that leave at least 5 shared slices are tried, so a jump of nearly a whole stack cannot be measured. A small search in xy at the same time makes the result tolerant of a slightly imperfect xy alignment. A parabola through the mismatch at the best offset and its two neighbours places the movement between slices.

The stage z positions in the file do not affect the measurement. The operator moves the stage to centre the embryo again, so the stage change does not say how far the tissue moved in the image.

### How the correction is applied

The correction moves whole slices and does not interpolate between slices. Where a timepoint has no data for a slice, the output has an empty slice that is filled with zeros. The stack becomes deeper so that no slice is lost, in the same way that the xy canvas becomes larger. The first timepoint keeps its slices where they are, and every other timepoint moves to match it. The reference timepoint is `ZCorrectionOptions.referenceTimepoint` in the code, and the app does not show it yet.

The shift of a timepoint changes only when the tissue has moved more than 0.65 of a slice from the slice it was last assigned to. Without this margin, tissue that sits halfway between two slices would make the output switch back and forth between them.

The output can be much deeper than the input when the embryo was centred again several times, because each jump adds as many empty slices as the jump is large. When the stack is not enlarged, it keeps its depth and the slices that leave it are dropped. This follows **Enlarge the canvas and the stack so that nothing is cut off** under Advanced options.

### Settings

- The z channel is the channel whose pattern the tool follows. A nuclear marker is the best choice, because its pattern stays the same while a reporter that oscillates changes from one timepoint to the next. The app selects a channel whose name looks like a nuclear marker when the file has one.
- The region is the part of the image that should stay in the same slice, as the section "Image matching" describes. The default is the whole frame. Different parts of an embryo can move differently in z, so the whole frame and the embryo mask can give different answers. On the command line the box is `--z-box x,y,width,height` in pixels of the first timepoint.
- **Drop time points with large shifts** leaves out every timepoint that moved more than **Maximum shift (slices)** from the timepoint before it. It starts unchecked, with a limit of 5 slices. On the command line it is `--z-drop-above 5`. The movement of a timepoint that is left out still counts for the timepoints after it. The aligned and unaligned movies leave out the same timepoints, and the input file does not change.

### Outputs

- The corrected stack is `{name}_z.ome.tif` from the Z only tab and `{name}_xy_z.ome.tif` from the XYZ tab.
- A CSV file with the same name and the ending `_shifts.csv` has one row for each timepoint. A row holds the timepoint in the input and in the output, the stage z position, the measured movement, the mismatch, the position of the tissue, the number of whole slices the timepoint was moved, and a flag when the timepoint needs a look or was left out.
- When timepoints are left out, the output keeps their original acquisition times in the `DeltaT` of the OME metadata.
- The log lists the slices of the output that hold data at every timepoint. A slice in that list is a good place to start looking at the result.
- The movies are maximum projections along z, so z correction does not change them. The Z only tab does not write movies.

`dc z-shifts FILE` measures the drift and saves the CSV file without writing a corrected stack.

### Stage positions

The Convert tool stores the stage z positions from the ND2 file in the OME-TIFF as the standard `PositionZ` of each `Plane`. Concatenation, alignment and z correction keep this metadata, and z correction updates it for the slices it moved.

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
| Image matching in xy and z, and the moving of slices | CPU, on all cores |
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
15. **XY alignment by image matching.** The Align tool can find the xy shift by image matching in place of the mask centroid. The section "XY alignment" above describes it.

## Code layout

```
Sources/DCCore/     file formats (TIFF, OME-XML, ND2), exact CPU algorithms, pipelines
Sources/DCApple/    Metal backend (Shaders.swift, MetalBackend.swift), HEVC writer
Sources/dc/         command-line tool
Sources/DriftCorrectApp/  SwiftUI app
Tests/              parity tests against the Python outputs, Metal-vs-CPU tests
scripts/            reference-data generator, ND2 dump, comparison and build scripts
```
