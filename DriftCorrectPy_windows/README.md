# Drift correction (Python, CUDA or CPU)

Tools to convert ND2 files, mask embryos, and align movies in xy and z. 

## Install

For automatic setup from Anaconda Prompt, download and run the
installer using the [installation commands](../README.md#windows).

## Start

Run `python drift_correct.py`. The launcher has three buttons.

| Button | Script | Output |
|---|---|---|
| Convert ND2 to TIFF | `nd2_to_tif.py` | `{name}_P{p}.ome.tif`, `P{p}_concat.ome.tif` |
| Align movie | `centroid_align_xy.py` | `aligned_{base}/` with OME-TIFF and MP4 files |
| Export movies | `export_movies.py` | MP4 files next to the movie |

The Mask window (`find_threshold.py`) opens from the Alignment window when a run needs the embryo mask. It writes `…_threshold.yaml` next to the movie.

Each script also runs from the command line. Use `--help` to see its options.

## Alignment

The Alignment window has three tabs. **XYZ** corrects the movie in xy and then in z. **XY only** and **Z only** run one of the two.

1. Select the movie, which is an OME-TIFF or ND2 file.
2. Choose the channel whose pattern is followed. A nuclear marker is the best choice.
3. When the settings use the embryo mask, an **Embryo mask** row appears. **Make mask…** opens the Mask window on the movie and starts from a threshold estimated from the image. Saving there writes the YAML file next to the movie and fills in the row. A YAML file saved earlier next to the movie is found automatically.
4. Run.

**Advanced options** holds the settings that change how the correction works

The xy alignment compares each timepoint with the one before it. It tries shifts and small turns and keeps the one where the two images differ least. The search stops at whole pixels and at steps of the angle, and the mismatch at the neighbouring pixels and angles then places both between those steps. The centroid of the embryo mask, averaged over nearby timepoints, then decides where the body sits. Sudden turns are removed, and slow turning stays as it was acquired. The cells can move inside the body while the body stays put.

Image matching can follow the whole frame, the embryo mask, or a box given as `x, y, width, height` in pixels of the first timepoint.

The z correction runs after the xy alignment. It compares the stack of each timepoint with the stack of the timepoint before it and with the one five timepoints earlier, and then moves whole slices. It does not interpolate between slices. Empty slices are added so that no slice is lost and a table `…_shifts.csv` records what was measured and applied at every timepoint.

```shell
python centroid_align_xy.py P0_concat.ome.tif --yaml P0_Venus_threshold.yaml --xy_channel mCherry --z_correct --z_channel mCherry
python centroid_align_xy.py P0_concat.ome.tif --xy_method none --z_correct --z_channel mCherry
```

The first line corrects xy and z. The second corrects z alone and needs no mask.

Run `python centroid_align_xy.py --help` for the other settings, such as `--xy_smoothing`, `--xy_max_angle`, `--xy_no_hold`, `--z_span` and `--z_drop_above`.

## Export

The Export window writes MP4 movies of any OME-TIFF or ND2 file, such as the movie before alignment, the output of the alignment, or the output of the z correction. The movies are saved next to the file. Each setting shows an explanation when the pointer rests on it.

- **Channel** is all channels, which writes one movie for each channel, or a single channel.
- **View** is the maximum projection along z, or one slice counted from 1. A single slice is the way to see z correction, because the projection along z does not change when slices move.
- **Compare with** is an optional second file shown to the right of the first one, such as the unaligned movie next to the aligned one. The second file shows the channel with the same name. When the two files differ in length, the export stops after the shorter one.
- **Speed** is the number of frames per second. Each timepoint is one frame.
- **Contrast** is the whole movie or each frame. With the whole movie, the brightness is set once from 20 timepoints spread over the movie, so a cell keeps its brightness from frame to frame. With each frame, every frame sets its own brightness, as the movies of the alignment do, and the movie can flicker. In both cases the brightest 0.5% of the pixels are white.
- **Codec** is HEVC or H.264. HEVC files are about half the size. H.264 plays in more programs, such as older versions of PowerPoint.
- **Quality** runs from 1 to 100. Higher values keep more detail and give larger files. The default is 65, which gives the same movies as before the quality could be chosen.

A movie is named after the file, the channel and the view, for example `P0_concat_xy_z_mCherry_z9.mp4`. With a second file, `_vs_` and the name of that file are added.

```shell
python export_movies.py P0_concat_xy_z.ome.tif --channel mCherry --slice 9 --compare P0_concat.ome.tif --codec h264
```

On Windows, NVIDIA NVENC is tried first, then Intel Quick Sync, then the CPU encoder. The encoder that worked is remembered for each codec
## Tests

Run `python -m pytest tests`. The tests build a small synthetic movie and check the image matching, the anchor and the z correction on it.

## GPU and CPU

- The tools use CUDA through CuPy when a CUDA GPU is available. If not, they use NumPy and SciPy.
- To force the CPU, set `DRIFT_CORRECT_CPU=1`, use `--cpu`, or tick "Use CPU only" in the Align window.
- The CUDA Gaussian calculates in float64 without fused multiply-add so it is identical to SciPy.
- The Align window shows which backend it uses.

## Packaging

`drift_correct.py` imports every tool explicitly, so Nuitka and PyInstaller find all modules. Keep `ffmpeg.nuitka-package.config.yml` next to it for Nuitka builds. CuPy adds approximately 1 GB to a packaged build. To make a CPU-only build, do not install CuPy in the build environment.

In Alignment -> Advanced options -> XY, **Mask metric** selects **Centroid**
(the default, mean X and Y of the mask pixels) or **Median** (median X and Y).
It controls the mask center used when holding the body in place.
