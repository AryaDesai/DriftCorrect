# DriftCorrect for Macs

For automatic setup, download and run the standalone installer using the
[installation commands](../README.md#mac).

This is a Swift port of the embryo drift-correction scripts (`nd2_to_tif.py`, `find_threshold.py`,
`centroid_align_xy.py`, and their GUIs). It contains:

- **DriftCorrect.app**: a SwiftUI app. The launcher opens three windows, Convert ND2 to TIFF, Align movie and Export movies. The Mask window opens from the Alignment window when a run needs the embryo mask.
- **dc**: a command-line tool. `dc convert` and `dc align` 

## Requirements

- A Mac with Apple silicon.
- macOS 14 or later. 
- Xcode 16 or later, or its command-line tools (`xcode-select --install`).

## Build and test

```bash
cd DriftCorrect
scripts/build_and_test.sh      # builds, runs all tests and a benchmark qwhich outputs to build/report.txt
scripts/bundle_app.sh          # makes build/DriftCorrect.app and build/dc
```

The first build downloads Yams (YAML) and swift-argument-parser from GitHub.


## Command line

```bash
dc convert /path/to/nd2_folder [--output_dir DIR] [--position 0] [--parallel false] [--concat_only]
dc align P0_concat.ome.tif --yaml P0_Venus_threshold.yaml [--fps 2] [--no_enlarge_canvas] [--low_memory]
dc align P0_concat.ome.tif --yaml P0_Venus_threshold.yaml [--xy-channel NAME] [--xy-region whole|mask|box] [--xy-box x,y,width,height]
dc align P0_concat.ome.tif --yaml P0_Venus_threshold.yaml --z-correct [--z-channel NAME] [--z-region whole|mask|box] [--z-box x,y,width,height]
dc correct-z P0_concat_xy.ome.tif [--z-channel NAME] [--yaml P0_Venus_threshold.yaml] [--no_enlarge_stack] [--low_memory]
dc export P0_concat_xy_z.ome.tif [--channel NAME] [--slice 9] [--compare P0_concat.ome.tif] [--fps 2] [--contrast movie|frame] [--codec hevc|h264] [--quality 65]
dc nd2-info file.nd2 --checksums          # metadata and frame checksums as JSON
dc accuracy P0_concat.ome.tif [--channel NAME] [--pairs 12]   # measures the error of the matching on a real movie
dc bench                                  # CPU vs Metal timing
```

Add `--cpu` to `align` to use the CPU reference instead of Metal.

## Alignment window

The Alignment window has three tabs. **XYZ** corrects the movie in xy and then in z. **XY only** and **Z only** run one of the two.

1. Select the movie, which is an OME-TIFF or ND2 file.
2. Choose the channel whose pattern is followed. A nuclear marker is the best choice.
3. When the settings use the embryo mask, an **Embryo mask** row appears. **Make mask…** opens the Mask window on the movie and starts from a threshold estimated from the image. Saving there writes the YAML file next to the movie and fills in the row. A YAML file saved earlier next to the movie is found automatically.
4. Run.

With the default settings, XYZ and XY only use the mask to hold the body in place and Z does not need it.

**Advanced options** holds the settings that change how the correction works.

## Image matching

Image matching is how the Align tool measures drift in xy and in z. It compares each timepoint with the timepoint before it.

The later image is slid over the earlier one, and in xy it is also turned by candidate angles. For every offset, the tool takes the pixels that both images hold inside the region it follows, scales both sides to the same mean so that bleaching does not count, and adds up the absolute differences. That divided by the sum of both images is the mismatch, which is 0 for identical images and 1 for images with nothing in common. The offset with the smallest mismatch is estimated to be the movement between timepoints. A turn is accepted only when it lowers the mismatch by a clear margin compared with no turn.

The region can be the whole frame, the embryo mask, or a box that you draw over cells that should stay still. The embryo mask needs the threshold YAML file from the Mask tool. A box is drawn on the first timepoint before the alignment and the tool moves it along with the tissue.

A match is marked `[weak match]` in the log when it is not clearly better than a wrong placement. The search tries many placements of the same two timepoints, and most of them are wrong, so the median of their mismatches is the mismatch of two images that do not match. A match is weak when its mismatch is above 0.65 of that median. The mismatch of images that do not match depends on the pattern, and it is much lower for membranes than for nuclei, so the limit is taken from the two timepoints themselves. A weak timepoint is worth a look, because a wrong step moves every later timepoint by the same amount.

## XY alignment

Image matching compares each timepoint with the one before it, as the section above describes, on the maximum projection of the chosen channel. The search starts on a copy binned until its longer side is at most 128 pixels, across half the frame in each direction, so that the jump after the embryo was centred again is found. It then refines the shift and the angle on copies binned by 2 and at full resolution.

The search stops at whole pixels and at steps of the angle. On the full-resolution copy, the tool then compares the mismatch one pixel to each side of the best shift and one angle step to each side of the best angle. A parabola through the three values places the shift and the angle between those steps. An angle of 0 is left alone, so that a movie without turns is not turned.

`dc accuracy FILE` measures the error of the matching on a real movie. It moves timepoints by a known shift, turn and z offset, matches the moved copies, and reports how far the answers are from the known moves. It writes nothing. On one test movie, placing the shift and the angle between steps brought the mean error of the shift at the frame centre from 0.37 to 0.04 pixels, and at the frame corner from 0.66 to 0.14 pixels. Run it on your own movie before and after a change to the matching.

### Holding the body in place

Image matching follows the cells. When the cells move through the body, as they do in a growing tail, the sum of the steps slowly carries the frame away from where it started. The output then shows the frame travelling across an empty canvas.

With **Hold the body in place with the embryo mask**, which is on by default, the tool uses the mask to say where the body is. It follows the centroid of the mask and averages it over nearby timepoints, because the mask is rough at a single timepoint and reliable over many. Each timepoint is then placed so that the averaged centroid/meidan sits in the middle of the frame. The sudden movement between neighbouring timepoints still comes from the image matching, so jumps and jitter are removed, and the cells are free to move inside the body.

The direction of the body is not taken from the mask. The long axis of a mask changes when the frame cuts off a different part of the tissue, without the body turning, and following it would turn the image for no reason. The microscope does not turn, so the direction in the acquired movie is the direction of the body. The tool removes the sudden turns that the matching finds and leaves the slow turning as it was acquired.

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

The correction moves whole slices and does not interpolate between slices. Where a timepoint has no data for a slice, the output has an empty slice that is filled with zeros. The stack becomes deeper so that no slice is lost, in the same way that the xy canvas becomes larger. The first timepoint keeps its slices where they are, and every other timepoint moves to match it.

The shift of a timepoint changes only when the tissue has moved more than 0.65 of a slice from the slice it was last assigned to. Without this margin, tissue that sits halfway between two slices would make the output switch back and forth between them.

The output can be much deeper than the input when the embryo was centred again several times, because each jump adds as many empty slices as the jump is large. When the stack is not enlarged, it keeps its depth and the slices that leave it are dropped. This follows **Enlarge the canvas and the stack so that nothing is cut off** under Advanced options.

### Settings

- The z channel is the channel whose pattern the tool follows. A nuclear marker is the best choice, because its pattern stays the same while a reporter that oscillates changes from one timepoint to the next. The app selects a channel whose name looks like a nuclear marker when the file has one.
- The region is the part of the image that should stay in the same slice, as the section "Image matching" describes. The default is the whole frame. Different parts of an embryo can move differently in z, so the whole frame and the embryo mask can give different answers. On the command line the box is `--z-box x,y,width,height` in pixels of the first timepoint.
- **Drop time points with large shifts** leaves out every timepoint that moved more than **Maximum shift (slices)** from the last kept timepoint. On the command line it is `--z-drop-above 5`. The other timepoints are aligned in xy and z as if the dropped ones were never recorded. When the tissue stays at the new depth, only the first timepoint after the move is dropped. The aligned and unaligned movies leave out the same timepoints, and the input file does not change.

### Outputs

- The corrected stack is `{name}_z.ome.tif` from the Z only tab and `{name}_xy_z.ome.tif` from the XYZ tab.
- A CSV file with the same name and the ending `_shifts.csv` has one row for each timepoint. A row holds the timepoint in the input and in the output, the stage z position, the measured movement, the mismatch, the position of the tissue, the number of whole slices the timepoint was moved, and a flag when the timepoint needs a look or was left out.
- When timepoints are left out, the output keeps their original acquisition times in the `DeltaT` of the OME metadata.
- The log lists the slices of the output that hold data at every timepoint. A slice in that list is a good place to start looking at the result.
- The movies are maximum projections along z, so z correction does not change them. The Z only tab does not write movies.

### Stage positions

The Convert tool stores the stage z positions from the ND2 file in the OME-TIFF as the standard `PositionZ` of each `Plane`. Concatenation, alignment and z correction keep this metadata, and z correction updates it for the slices it moved.

## Export window

The Export window writes MP4 movies of any OME-TIFF or ND2 file, such as the movie before alignment, the output of the alignment, or the output of the z correction. The movies are saved next to the file. 

- **Channel** can choose all channels or a siongle channel
- **View** is the maximum projection along z or one slice. A single slice is the way to see z correction
- **Compare with** is an optional second file shown to the right of the first one, such as the unaligned movie next to the aligned one. The second file shows the channel with the same name. When the two files differ in length the export stops after the shorter one.
- **Speed** is the number of frames per second. Each timepoint is one frame.
- **Contrast** is the whole movie or each frame. With the whole movie, the brightness is set once from 20 timepoints spread over the movie, so a cell keeps its brightness from frame to frame. With each frame, every frame sets its own brightness and the movie can flicker. In both cases the brightest 0.5% of the pixels are white.
- **Codec** is HEVC or H.264. HEVC files are about half the size. H.264 plays in more programs, such as older versions of PowerPoint.
- **Quality** runs from 1 to 100. Higher values keep more detail and give larger files. The default is 65

A movie is named after the file, the channel and the view, for example `P0_concat_xy_z_mCherry_z9.mp4`. With a second file, `_vs_` and the name of that file are added.

## Check the ND2 reader on your own files

 To check it against a real file:

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
| Gaussian blur | Metal, separable (2·(2r+1) taps per pixel) |
| Z max-projection, sub-pixel and whole-pixel shift | Metal, zero-copy on unified memory |
| Percentile, labelling, Otsu, multi-Otsu | CPU, on all cores and several frames are processed at the same time |
| Image matching in xy and z, and the moving of slices | CPU, on all cores |
| HEVC movies | Media engine (VideoToolbox), encoded while frames pass through |
| TIFF / ND2 I/O | `pread` into page-aligned buffers that Metal uses without a copy |

### Numerical agreement with the Python code

- **CPU implementations.** The outputs are identical to scipy, numpy, and OpenCV. This includes the Gaussian, the percentile, the histogram, the labels, Otsu and multi-Otsu. The unit tests check this against data that `scripts/make_reference.py` made with the original functions.
- **Multi-Otsu.** It runs in float64. The Python code used float32 JAX. The thresholds agree on all test images.


## Code layout

```
Sources/DCCore/     file formats (TIFF, OME-XML, ND2), exact CPU algorithms, pipelines
Sources/DCApple/    Metal backend (Shaders.swift, MetalBackend.swift), HEVC writer
Sources/dc/         command-line tool
Sources/DriftCorrectApp/  SwiftUI app
Tests/              parity tests against the Python outputs, Metal-vs-CPU tests
scripts/            reference-data generator, ND2 dump, comparison and build scripts
```

In Alignment/Advanced options /XY, **Mask metric** selects **Centroid**
(the default, mean X and Y of the mask pixels) or **Median** (median X and Y).
It controls the mask center used when holding the body in place.
