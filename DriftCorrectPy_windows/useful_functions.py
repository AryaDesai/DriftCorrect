"""Shared I/O, image processing and helpers for the drift-correction tools.

The results match the Swift app (DriftCorrect for Apple silicon):
- Every threshold YAML setting is used (method, invert, levels, selected
  classes, block size, per-timepoint parameters).
- The Gaussian always follows scipy (reflect edges); the shift mode is a
  choice: "subpixel" (scipy bilinear) or "integer" (whole pixels).
- Concatenated TIFFs keep the stored sample type.
- Multi-level Otsu runs in float64 (multi_otsu.py).

The heavy per-frame work (Z projection, Gaussian, shift) goes through
backend.py, which uses CUDA when available and NumPy/SciPy otherwise.
"""

import csv
import json
import os
import sys
import tempfile
import threading
import uuid
import xml.etree.ElementTree as ET
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import tifffile
import yaml
from scipy import fft as sp_fft
from scipy.ndimage import label

from backend import get_backend
from multi_otsu import MAX_OTSU_LEVELS, MULTIOTSU_NBINS, multiotsu_thresholds_and_classes

# ── General helpers ──────────────────────────────────────────────────────────


class Cancelled(Exception):
    """Raised when the user stops a run."""


def log(msg=""):
    print(msg, flush=True)


def progress(phase, current, total):
    """Machine-readable progress line for the GUIs (they parse lines starting with @progress)."""
    print(f"@progress {current} {total} {phase}", flush=True)


def physical_memory():
    """Total RAM in bytes (Windows, macOS, Linux)."""
    try:
        if sys.platform == "win32":
            import ctypes

            class MemoryStatus(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("sullAvailExtendedVirtual", ctypes.c_ulonglong)]
            status = MemoryStatus()
            status.dwLength = ctypes.sizeof(MemoryStatus)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
            return int(status.ullTotalPhys)
        return int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"))
    except Exception:
        return 8 << 30


def pipeline_width(frame_bytes):
    """Frames in flight: bounded to about 2 GB and to the CPU count."""
    by_memory = max(1, (2 << 30) // max(1, frame_bytes))
    return max(2, min(os.cpu_count() or 4, 8, by_memory))


def ordered_map(fn, count, width):
    """Yield fn(0), fn(1), ... in order while up to `width` calls run in threads.

    NumPy, SciPy, tifffile and CuPy release the GIL in their heavy parts, so
    disk reads, GPU work and CPU analysis of several frames overlap.
    """
    if count <= 0:
        return
    with ThreadPoolExecutor(max_workers=max(1, width)) as pool:
        pending = deque()
        next_index = 0
        try:
            for i in range(count):
                while next_index < count and next_index < i + width:
                    pending.append(pool.submit(fn, next_index))
                    next_index += 1
                yield pending.popleft().result()
        finally:
            for f in pending:
                f.cancel()


def stem_without_ome(path):
    stem = Path(path).stem
    return stem[:-4] if stem.endswith(".ome") else stem


# ── Threshold parameters (YAML) ──────────────────────────────────────────────


def normalize_threshold_params(params):
    """Complete a threshold parameter dict with defaults."""
    out = dict(params)
    out["method"] = out.get("method", "percentile")
    out["block_size"] = out.get("block_size", 64)
    out["invert"] = out.get("invert", False)
    out["levels"] = out.get("levels", 3)
    out["selected_levels"] = out.get("selected_levels", None)
    return out


def get_threshold_params_for_timepoint(cfg, t):
    """Parameters for timepoint t: timepoint_parameters[t] when present, else parameters."""
    per_t = cfg.get("timepoint_parameters")
    if per_t is None:
        return normalize_threshold_params(cfg["parameters"])
    if t < 0 or t >= len(per_t):
        raise IndexError(f"timepoint_parameters has {len(per_t)} entries, cannot read T={t}")
    return normalize_threshold_params(per_t[t])


def load_threshold_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def resolve_tif_from_yaml(yaml_path, cfg):
    """The source TIF of a threshold YAML: source.file when it is an existing TIF,
    else `{P-id}*.ome.tif` next to the YAML. Returns (tif_path, base)."""
    yaml_path = Path(yaml_path)
    src = Path(cfg["source"]["file"])
    if src.is_file() and src.suffix.lower() in (".tif", ".tiff"):
        return src, stem_without_ome(src)
    try:
        p_id = "P" + yaml_path.stem.split("_P")[1].split("_")[0]
    except IndexError as e:
        raise ValueError(f"Could not derive embryo ID from {yaml_path.name} and source file not found.") from e
    candidates = sorted(yaml_path.parent.glob(f"{p_id}*.ome.tif"))
    if not candidates:
        raise FileNotFoundError(f"no TIF found for {p_id} in {yaml_path.parent}")
    return candidates[0], p_id


# ── ND2 input ────────────────────────────────────────────────────────────────


def load_nd2_metadata(file_path):
    """(channel_names, vox, period_s) without reading image data."""
    import nd2

    with nd2.ND2File(file_path) as f:
        channel_names = [ch.channel.name for ch in f.metadata.channels]
        vox = f.voxel_size()
        period_s = next((loop.parameters.periodMs / 1000.0 for loop in f.experiment if loop.type == "TimeLoop"), None)
    return channel_names, vox, period_s


class ND2Reader:
    """Frames of an ND2 file as (C, Z, Y, X), addressed by axis name.

    Works for any loop order and for files without a P, Z, T or C axis (the
    old code assumed the shape (T, P, Z, C, Y, X)).
    """

    def __init__(self, path):
        import nd2

        self.path = Path(path)
        self._f = nd2.ND2File(path)
        sizes = dict(self._f.sizes)
        if "S" in sizes:
            raise ValueError(f"{self.path.name} is an RGB ND2 file; only monochrome channels are supported.")
        if sizes.get("U", 1) != 1:
            raise ValueError(f"{self.path.name} has a custom loop axis (U), which the pipeline does not support.")
        self.T, self.P, self.Z = sizes.get("T", 1), sizes.get("P", 1), sizes.get("Z", 1)
        self.C, self.Y, self.X = sizes.get("C", 1), sizes["Y"], sizes["X"]
        self._coord_axes = [k for k in sizes if k not in ("C", "Y", "X", "S")]
        self._coord_shape = [sizes[k] for k in self._coord_axes]
        self.dtype = np.dtype(self._f.dtype)
        self.channel_names = [ch.channel.name for ch in self._f.metadata.channels]
        if len(self.channel_names) < self.C:
            self.channel_names += [f"ch{i}" for i in range(len(self.channel_names), self.C)]
        self.vox = self._f.voxel_size()
        self.period_s = next((lp.parameters.periodMs / 1000.0 for lp in self._f.experiment if lp.type == "TimeLoop"), None)
        self._lock = threading.Lock()

    @property
    def frame_bytes(self):
        return self.C * self.Z * self.Y * self.X * self.dtype.itemsize

    def _seq(self, t, p, z):
        if not self._coord_axes:
            return 0
        coords = {"T": t, "P": p, "Z": z}
        return int(np.ravel_multi_index(tuple(coords.get(a, 0) for a in self._coord_axes), self._coord_shape))

    def read_frame(self, t, p=0):
        out = np.empty((self.C, self.Z, self.Y, self.X), dtype=self.dtype)
        for z in range(self.Z):
            with self._lock:
                plane = np.array(self._f.read_frame(self._seq(t, p, z)), copy=True)
            out[:, z] = plane.reshape(self.C, self.Y, self.X)
        return out

    def close(self):
        self._f.close()


# ── TIFF input ───────────────────────────────────────────────────────────────


def load_tif_metadata(file_path):
    """(channel_names, vox, period_s) of an OME, ImageJ, or tifffile JSON TIFF.

    Each value is read on its own: a missing PhysicalSizeZ no longer discards
    the channel names.
    """
    with tifffile.TiffFile(file_path) as tif:
        return _tif_metadata(tif, _stack_shape(tif)[0][1])


def _tif_metadata(tif, n_channels):
    desc = tif.pages[0].description or ""
    try:
        meta = json.loads(desc)
        names = meta["Channel"]["Name"]
        names = [names] if isinstance(names, str) else list(names)
        vox = SimpleNamespace(x=float(meta.get("PhysicalSizeX", 1.0)), y=float(meta.get("PhysicalSizeY", 1.0)),
                              z=float(meta.get("PhysicalSizeZ", 1.0)))
        return names, vox, meta.get("TimeIncrement")
    except Exception:
        pass
    names = [f"ch{i}" for i in range(n_channels)]
    vox = SimpleNamespace(x=1.0, y=1.0, z=1.0)
    period = None
    if tif.ome_metadata:
        try:
            root = ET.fromstring(tif.ome_metadata)
            ns = root.tag.split("}")[0] + "}" if "}" in root.tag else ""
            p = root.find(f".//{ns}Pixels")
            chans = p.findall(f"{ns}Channel")
            if chans:
                names = [ch.get("Name", f"ch{i}") for i, ch in enumerate(chans)]

            def num(key):
                v = p.get(key)
                return float(v) if v is not None else None

            vox = SimpleNamespace(x=num("PhysicalSizeX") or 1.0, y=num("PhysicalSizeY") or 1.0, z=num("PhysicalSizeZ") or 1.0)
            period = num("TimeIncrement")
        except Exception as e:
            log(f"  Could not read OME-XML metadata ({e}), using default values.")
    elif tif.is_imagej:
        meta = tif.imagej_metadata or {}
        # ImageJ resolution tags are pixels per declared unit; output uses microns.
        unit = str(meta.get("unit", "")).lower().replace("\u03bc", "u").replace("\u00b5", "u")
        scale = {"micron": 1.0, "microns": 1.0, "um": 1.0, "nm": 0.001,
                 "mm": 1000.0, "cm": 10000.0, "m": 1000000.0}.get(unit)
        if scale is not None:
            for axis in ("x", "y"):
                tag = tif.pages[0].tags.get(axis.upper() + "Resolution")
                if tag is not None:
                    numerator, denominator = tag.value
                    if numerator > 0 and denominator > 0:
                        setattr(vox, axis, scale * denominator / numerator)
            try:
                spacing = float(meta.get("spacing", 0))
                if spacing > 0:
                    vox.z = spacing * scale
            except (TypeError, ValueError):
                pass
        try:
            # ImageJ's finterval defaults to seconds when tunit is absent.
            time_scale = {"sec": 1.0, "s": 1.0, "second": 1.0, "seconds": 1.0,
                          "ms": 0.001, "min": 60.0, "hour": 3600.0}.get(
                              str(meta.get("tunit", "sec")).lower())
            interval = float(meta.get("finterval", 0))
            if interval > 0 and time_scale is not None:
                period = interval * time_scale
        except (TypeError, ValueError):
            pass
    return names, vox, period


def _stack_shape(tif):
    """(T, C, Z, Y, X) and page strides of series 0, with singleton axes kept."""
    s = tif.series[0]
    axes = s.get_axes(False) if hasattr(s, "get_axes") else s.axes
    shape = s.get_shape(False) if hasattr(s, "get_shape") else s.shape
    dims = dict(T=1, C=1, Z=1)
    page_axes = []
    for a, n in zip(axes, shape):
        if a in "YXS":
            continue
        key = a if a in "TCZ" else "T"  # other stack axes (Q, I, ...) count as time
        dims[key] *= n
        page_axes.append((key, n))
    # Row-major page order over the non-image axes.
    strides = dict(T=0, C=0, Z=0)
    step = 1
    for key, n in reversed(page_axes):
        if n > 1 and strides[key] == 0:
            strides[key] = step
        step *= n
    Y, X = shape[axes.index("Y")], shape[axes.index("X")]
    return (dims["T"], dims["C"], dims["Z"], Y, X), strides


class TiffStack:
    """A TIFF as (T, C, Z, Y, X); reads one timepoint at a time."""

    def __init__(self, path):
        self.path = Path(path)
        self._tif = tifffile.TiffFile(path)
        self.shape, self._strides = _stack_shape(self._tif)
        self.T, self.C, self.Z, self.Y, self.X = self.shape
        self._series = self._tif.series[0]
        self.dtype = np.dtype(self._series.dtype)
        self.channel_names, self.vox, self.period_s = _tif_metadata(self._tif, self.C)
        self.ome_metadata = self._tif.ome_metadata
        self._lock = threading.Lock()
        self._mapped_planes = None
        if self._tif.is_imagej and len(self._series.pages) < self.T * self.C * self.Z:
            # Large ImageJ stacks can store all planes after a single IFD.
            # Reuse the same plane indices without materializing the whole stack.
            try:
                self._mapped_planes = tifffile.memmap(path, series=0, mode="r").reshape(
                    -1, self.Y, self.X)
            except Exception:
                self._tif.close()
                raise

    @property
    def frame_bytes(self):
        return self.C * self.Z * self.Y * self.X * self.dtype.itemsize

    def page_index(self, t, c, z):
        s = self._strides
        return t * s["T"] + c * s["C"] + z * s["Z"]

    def read_pages(self, indices):
        with self._lock:
            if self._mapped_planes is None:
                data = self._tif.asarray(key=list(indices), series=0)
            else:
                # Allocate only the requested planes, with the usual native dtype.
                data = np.empty((len(indices), self.Y, self.X), dtype=self.dtype)
                for i, index in enumerate(indices):
                    data[i] = self._mapped_planes[index]
        return data.reshape(len(indices), self.Y, self.X)

    def read_frame(self, t):
        idx = [self.page_index(t, c, z) for c in range(self.C) for z in range(self.Z)]
        return self.read_pages(idx).reshape(self.C, self.Z, self.Y, self.X)

    def read_channel(self, t, c):
        return self.read_pages([self.page_index(t, c, z) for z in range(self.Z)])

    def close(self):
        if self._mapped_planes is not None:
            self._mapped_planes._mmap.close()
            self._mapped_planes = None
        self._tif.close()


class FrameSource:
    """Common (t, p) → (C, Z, Y, X) access for a TIFF stack or an ND2 file."""

    def __init__(self, path):
        path = Path(path)
        self.is_nd2 = path.suffix.lower() == ".nd2"
        if self.is_nd2:
            r = ND2Reader(path)
            self.T, self.P, self.C, self.Z, self.Y, self.X = r.T, r.P, r.C, r.Z, r.Y, r.X
        else:
            r = TiffStack(path)
            self.T, self.C, self.Z, self.Y, self.X = r.shape
            self.P = 1
        self.reader = r
        self.dtype = r.dtype
        self.channel_names, self.vox, self.period_s = r.channel_names, r.vox, r.period_s
        self.frame_bytes = r.frame_bytes

    def read_frame(self, t, p=0):
        return self.reader.read_frame(t, p) if self.is_nd2 else self.reader.read_frame(t)

    def close(self):
        self.reader.close()


# ── OME-TIFF output ──────────────────────────────────────────────────────────


def ome_metadata(channel_names, vox, period_s):
    return {
        "axes": "TCZYX",
        "PhysicalSizeX": vox.x, "PhysicalSizeXUnit": "µm",
        "PhysicalSizeY": vox.y, "PhysicalSizeYUnit": "µm",
        "PhysicalSizeZ": vox.z, "PhysicalSizeZUnit": "µm",
        "TimeIncrement": period_s, "TimeIncrementUnit": "s",
        "Channel": {"Name": list(channel_names)},
    }


def _atomic_imwrite(filepath, data, **kwargs):
    """Write to a temporary file in the same folder, then rename (no partial outputs)."""
    filepath = Path(filepath)
    filepath.parent.mkdir(parents=True, exist_ok=True)
    tmp = filepath.with_name(f".writing-{uuid.uuid4().hex}-{filepath.name}")
    try:
        tifffile.imwrite(tmp, data, photometric="minisblack", **kwargs)
        os.replace(tmp, filepath)
    finally:
        if tmp.exists():
            tmp.unlink()


def save_ome_tiff(filepath, volume, channel_names, vox, period_s, shape=None, dtype=None, metadata=None, bigtiff=None):
    """Write a (T, C, Z, Y, X) array, or an iterator of (C, Z, Y, X) frames with shape/dtype."""
    extra = {}
    if shape is None:
        shape, dtype = volume.shape, volume.dtype
    else:
        extra = {"shape": shape, "dtype": dtype}  # iterator input
    nbytes = int(np.prod(shape)) * np.dtype(dtype).itemsize
    if bigtiff is None:
        bigtiff = nbytes > (1 << 32) - (1 << 25)
    _atomic_imwrite(filepath, volume, bigtiff=bigtiff,
                    metadata=metadata or ome_metadata(channel_names, vox, period_s), **extra)


def concatenate_tifs(tif_paths, output_path):
    """Join OME-TIFFs along T, streaming one timepoint at a time.

    The stored sample type is kept (float32 only when inputs differ).
    Metadata is compared by channel names and calibration, not by the raw
    OME-XML (which always differs because of its UUID).
    """
    paths = sorted(tif_paths, key=lambda p: Path(p).name)
    stacks = [TiffStack(p) for p in paths]
    try:
        ref = stacks[0]
        for s in stacks[1:]:
            for axis, (a, b) in enumerate(zip(s.shape[1:], ref.shape[1:]), start=1):
                if a != b:
                    raise ValueError(f"Dimension mismatch on axis {axis}: {Path(paths[0]).name} has {b} "
                                     f"but {s.path.name} has {a}.")
        key = lambda s: (s.channel_names, (s.vox.x, s.vox.y, s.vox.z), s.period_s)  # noqa: E731
        if ref.ome_metadata is not None:
            for s in stacks[1:]:
                if s.ome_metadata is None:
                    log(f"Warning: {s.path.name} has no OME metadata")
                elif key(s) != key(ref):
                    log(f"Warning: OME metadata in {s.path.name} differs from {ref.path.name}")
        total = sum(s.T for s in stacks)
        log(f"Concatenating {len(stacks)} files -> {total} total along axis 0")

        metadata = {"axes": "TCZYX"}
        if ref.ome_metadata is not None:
            root = ET.fromstring(ref.ome_metadata)
            ns = root.tag.split("}")[0] + "}" if "}" in root.tag else ""
            px = root.find(f".//{ns}Pixels")
            if px is not None:
                for attr in ("PhysicalSizeX", "PhysicalSizeY", "PhysicalSizeZ", "TimeIncrement"):
                    if px.get(attr) is not None:
                        metadata[attr] = float(px.get(attr))
                for attr in ("PhysicalSizeXUnit", "PhysicalSizeYUnit", "PhysicalSizeZUnit", "TimeIncrementUnit"):
                    if px.get(attr) is not None:
                        metadata[attr] = px.get(attr)
            names = [ch.get("Name") for ch in root.findall(f".//{ns}Channel") if ch.get("Name")]
            if names:
                metadata["Channel"] = {"Name": names}
        dtype = ref.dtype if all(s.dtype == ref.dtype for s in stacks) else np.dtype(np.float32)

        def frames():
            for k, s in enumerate(stacks):
                for t in range(s.T):
                    yield s.read_frame(t).astype(dtype, copy=False)
                progress("Concatenating", k + 1, len(stacks))

        _atomic_imwrite(output_path, frames(), shape=(total, *ref.shape[1:]), dtype=dtype, bigtiff=True,
                        metadata=metadata)
        log(f"Done. Output: {output_path}")
    finally:
        for s in stacks:
            s.close()


# ── Thresholding ─────────────────────────────────────────────────────────────


def cv2_otsu(values_u8):
    """cv2.threshold(u8, 0, 255, THRESH_BINARY + THRESH_OTSU) threshold value (exact port)."""
    h = np.bincount(np.asarray(values_u8, dtype=np.uint8).ravel(), minlength=256)
    scale = 1.0 / h.sum()
    flt_eps = float(np.finfo(np.float32).eps)
    mu = 0.0
    for i in range(256):
        mu += i * float(h[i])
    mu *= scale
    mu1 = q1 = max_sigma = 0.0
    max_val = 0
    for i in range(256):
        p_i = h[i] * scale
        mu1 *= q1
        q1 += p_i
        q2 = 1.0 - q1
        if min(q1, q2) < flt_eps or max(q1, q2) > 1.0 - flt_eps:
            continue
        mu1 = (mu1 + i * p_i) / q1
        mu2 = (mu - q1 * mu1) / q2
        sigma = q1 * q2 * (mu1 - mu2) * (mu1 - mu2)
        if sigma > max_sigma:
            max_sigma, max_val = sigma, i
    return max_val


def otsu_threshold_of(values):
    """Otsu threshold of float32 values after scaling to uint8; None when constant."""
    values = np.asarray(values, dtype=np.float32)
    vmin, vmax = values.min(), values.max()
    if not vmax > vmin:
        return None
    u8 = np.clip((values - vmin) / (vmax - vmin) * 255, 0, 255).astype(np.uint8)
    t = cv2_otsu(u8)
    return np.float32(t / 255.0) * (vmax - vmin) + vmin


def _threshold_percentile(smoothed, percentile):
    return smoothed > np.percentile(smoothed, percentile)


def _threshold_global_otsu(smoothed):
    th = otsu_threshold_of(smoothed)
    if th is None:
        return np.zeros(smoothed.shape, dtype=bool)
    return smoothed > th


def roi_otsu_threshold(smoothed, percentile_threshold):
    """Otsu threshold fitted to the largest 4-connected region above the percentile, or None."""
    regions, _ = label(smoothed > percentile_threshold)
    sizes = np.bincount(regions.ravel())
    sizes[0] = 0
    if sizes.max() == 0:
        return None
    return otsu_threshold_of(smoothed[regions == sizes.argmax()])


def _threshold_percentile_otsu_roi(smoothed, percentile):
    q = np.percentile(smoothed, percentile)
    th = roi_otsu_threshold(smoothed, q)
    return smoothed > q if th is None else smoothed > th


def _threshold_multiotsu(smoothed, levels, selected_levels, class_map=None):
    if not selected_levels:
        return np.zeros(smoothed.shape, dtype=bool)
    if class_map is None:
        class_map = multiotsu_thresholds_and_classes(smoothed, levels)[1]
    return np.isin(class_map, list(selected_levels))


def _otsu_rows(hist, patch):
    """batched_otsu (float32) for histograms along axis 0: returns the first argmax per column."""
    hist = hist.astype(np.float32)
    bins = np.arange(256, dtype=np.float32)[:, None]
    w1 = np.cumsum(hist, axis=0, dtype=np.float32)
    w2 = np.float32(patch) - w1
    cs = np.cumsum(hist * bins, axis=0, dtype=np.float32)
    total = cs[-1:]
    eps = np.float32(1e-8)
    m1 = cs / (w1 + eps)
    m2 = (total - cs) / (w2 + eps)
    d = m1 - m2
    return np.argmax(w1 * w2 * (d * d), axis=0)


def _threshold_local_otsu(smoothed, percentile, block_size=32, interp=True):
    """Local Otsu (the former torch methods local_otsu_interp / local_otsu_pixel), in NumPy."""
    H, W = smoothed.shape
    vmin, vmax = smoothed.min(), smoothed.max()
    if not vmax > vmin:
        return smoothed > vmin
    img = np.clip((smoothed - vmin) / (vmax - vmin) * np.float32(255.0), 0, 255).astype(np.uint8)
    bs = max(1, int(block_size))
    if not interp:
        pad_l = bs // 2
        pad_r = pad_l - 1 if bs % 2 == 0 else pad_l
        padded = np.pad(img, ((pad_l, pad_r), (pad_l, pad_r)), mode="reflect")
        out = np.empty((H, W), dtype=np.float32)
        onehot = np.zeros((256, padded.shape[1] + 1), dtype=np.int32)
        for y in range(H):
            band = padded[y:y + bs]
            onehot[:] = 0
            np.add.at(onehot, (band, np.broadcast_to(np.arange(1, padded.shape[1] + 1), band.shape)), 1)
            cum = np.cumsum(onehot, axis=1)
            hist = cum[:, bs:bs + W] - cum[:, 0:W]
            out[y] = _otsu_rows(hist, bs * bs)
        thresh_index = out
    else:
        gh, gw = max(1, H // bs), max(1, W // bs)
        blocks = img[:gh * bs, :gw * bs].reshape(gh, bs, gw, bs).transpose(0, 2, 1, 3).reshape(gh * gw, bs * bs)
        hist = np.zeros((256, gh * gw), dtype=np.int64)
        np.add.at(hist, (blocks.T, np.broadcast_to(np.arange(gh * gw), blocks.T.shape)), 1)
        block = _otsu_rows(hist, bs * bs).astype(np.float32).reshape(gh, gw)

        def weights(out_size, in_size):
            scale = np.float32(in_size) / np.float32(out_size)
            real = np.maximum(scale * (np.arange(out_size, dtype=np.float32) + np.float32(0.5)) - np.float32(0.5), 0)
            i0 = np.minimum(np.floor(real).astype(int), in_size - 1)
            l1 = np.clip(real - i0, 0, 1).astype(np.float32)
            i1 = i0 + (i0 < in_size - 1)
            return i0, i1, (np.float32(1) - l1), l1

        y0, y1, ly0, ly1 = weights(H, gh)
        x0, x1, lx0, lx1 = weights(W, gw)
        top = lx0[None, :] * block[y0][:, x0] + lx1[None, :] * block[y0][:, x1]
        bottom = lx0[None, :] * block[y1][:, x0] + lx1[None, :] * block[y1][:, x1]
        thresh_index = ly0[:, None] * top + ly1[:, None] * bottom
    thresh = (thresh_index / np.float32(255.0)) * (vmax - vmin) + vmin
    return (smoothed > thresh) & (smoothed > np.percentile(smoothed, percentile))


def find_largest_mask_xy(smoothed, percentile, method="percentile", block_size=32, invert=False,
                         levels=3, selected_levels=None, class_map=None):
    """Threshold a 2-D image; return (mask of the largest 8-connected blob, [cy, cx]).

    Methods: 'percentile' (default and fallback), 'multiotsu', 'global_otsu',
    'percentile_otsu_roi', 'local_otsu_interp', 'local_otsu_pixel'.
    With no foreground the centroid is the frame centre, so the shift is zero.
    """
    smoothed = np.asarray(smoothed, dtype=np.float32)
    if method == "multiotsu":
        if selected_levels is None:
            selected_levels = [int(np.clip(levels, 2, MAX_OTSU_LEVELS)) - 1]
        binary = _threshold_multiotsu(smoothed, levels, selected_levels, class_map=class_map)
    elif method == "global_otsu":
        binary = _threshold_global_otsu(smoothed)
    elif method == "percentile_otsu_roi":
        binary = _threshold_percentile_otsu_roi(smoothed, percentile)
    elif method == "local_otsu_interp":
        binary = _threshold_local_otsu(smoothed, percentile, block_size=block_size, interp=True)
    elif method == "local_otsu_pixel":
        binary = _threshold_local_otsu(smoothed, percentile, block_size=block_size, interp=False)
    else:
        binary = _threshold_percentile(smoothed, percentile)
    if invert:
        binary = ~binary
    labeled, _ = label(binary, structure=np.ones((3, 3)))
    sizes = np.bincount(labeled.ravel())
    sizes[0] = 0
    if sizes.max() == 0:
        return np.zeros(smoothed.shape, dtype=bool), np.array([smoothed.shape[0] / 2, smoothed.shape[1] / 2])
    mask = labeled == sizes.argmax()
    return mask, np.argwhere(mask).mean(axis=0)


def compute_shift_xy(frame, params, backend=None):
    """(dy, dx) that moves the embryo centroid of one (C, Z, Y, X) frame to the frame centre.

    `params` is a normalized threshold parameter dict (see get_threshold_params_for_timepoint).
    """
    backend = backend or get_backend()
    ch = params["channel_index"]
    if not 0 <= ch < frame.shape[0]:
        raise ValueError(f"Threshold channel index {ch} is out of range (the data has {frame.shape[0]} channel(s))")
    Y, X = frame.shape[2], frame.shape[3]
    projection = backend.max_project(frame, ch)
    smoothed = backend.gaussian(projection, params["sigma"])
    _, centroid = find_largest_mask_xy(smoothed, params["percentile"], method=params.get("method", "percentile"),
                                       block_size=params.get("block_size", 64), invert=params.get("invert", False),
                                       levels=params.get("levels", 3), selected_levels=params.get("selected_levels"))
    return Y / 2 - centroid[0], X / 2 - centroid[1]


def shift_line(dy, dx):
    return f"dy={dy:+7.2f}  dx={dx:+7.2f}"


def covering_pad(dys, dxs):
    """(top, bottom, left, right) so that no shifted pixel leaves the canvas."""
    dys, dxs = np.asarray(dys, dtype=np.float64), np.asarray(dxs, dtype=np.float64)
    return (int(np.ceil(max(0, -dys.min()))), int(np.ceil(max(0, dys.max()))),
            int(np.ceil(max(0, -dxs.min()))), int(np.ceil(max(0, dxs.max()))))


# ── Display ──────────────────────────────────────────────────────────────────


def auto_contrast(img, percentile=99.5):
    """float32 image → uint8, clipped at the given percentile."""
    img = np.asarray(img, dtype=np.float32)
    vmax = np.percentile(img, percentile)
    if vmax == 0:
        vmax = 1
    return np.clip(img / vmax * 255, 0, 255).astype(np.uint8)


LEVEL_COLORS = [(255, 50, 50), (50, 200, 255), (120, 255, 80), (255, 220, 40), (220, 100, 255)]


def render_composite(img, mask, centroid, class_map=None, selected_levels=None):
    """Gray image + translucent overlay (alpha 100, PIL alpha_composite arithmetic) + cyan crosshair.

    Returns an (Y, X, 4) uint8 RGBA array.
    """
    gray = auto_contrast(img)
    h, w = gray.shape
    out = np.empty((h, w, 4), dtype=np.uint8)
    out[..., :3] = gray[..., None]
    out[..., 3] = 255
    color = np.zeros((h, w, 3), dtype=np.uint32)
    covered = np.zeros((h, w), dtype=bool)
    if class_map is None:
        covered = np.asarray(mask, dtype=bool)
        color[covered] = (255, 50, 50)
    else:
        for i in selected_levels or []:
            sel = class_map == i
            color[sel] = LEVEL_COLORS[i % len(LEVEL_COLORS)]
            covered |= sel
    src_a = 100
    outa255 = src_a * 255 + 255 * (255 - src_a)
    coef1 = src_a * 255 * 255 * (1 << 7) // outa255
    coef2 = 255 * (1 << 7) - coef1
    tmp = color[covered] * coef1 + gray[covered][:, None].astype(np.uint32) * coef2 + (0x80 << 7)
    out[covered, :3] = ((((tmp >> 8) + tmp) >> 8) >> 7).astype(np.uint8)
    cy, cx = int(round(float(centroid[0]))), int(round(float(centroid[1])))
    for y0, y1, x0, x1 in ((cy - 3, cy + 3, cx - 25, cx + 25), (cy - 25, cy + 25, cx - 3, cx + 3)):
        ya, yb, xa, xb = max(0, y0), min(h - 1, y1), max(0, x0), min(w - 1, x1)
        if ya <= yb and xa <= xb:
            out[ya:yb + 1, xa:xb + 1] = (0, 255, 255, 255)
    return out


# ── Z registration ───────────────────────────────────────────────────────────


def _upsampled_dft(data, region, upsample, offsets):
    for n_items, ax_offset in list(zip(data.shape, offsets))[::-1]:
        kernel = (np.arange(region) - ax_offset)[:, None] * sp_fft.fftfreq(n_items, upsample)
        kernel = np.exp(-1j * 2 * np.pi * kernel)
        data = np.tensordot(kernel, data, axes=(1, -1))
    return data


def phase_cross_correlation(reference, moving, upsample_factor=1):
    """skimage.registration.phase_cross_correlation (normalization="phase") — shift only."""
    src = sp_fft.fftn(reference)
    tgt = sp_fft.fftn(moving)
    shape = src.shape
    product = src * tgt.conj()
    eps = np.finfo(product.real.dtype).eps
    product /= np.maximum(np.abs(product), 100 * eps)
    cc = sp_fft.ifftn(product)
    maxima = np.unravel_index(np.argmax(np.abs(cc)), cc.shape)
    midpoint = np.array([np.trunc(n / 2) for n in shape])
    shift = np.stack(maxima).astype(np.float64)
    shift[shift > midpoint] -= np.array(shape)[shift > midpoint]
    if upsample_factor > 1:
        up = np.float64(upsample_factor)
        shift = np.round(shift * up) / up
        region = np.ceil(up * 1.5)
        dftshift = np.trunc(region / 2.0)
        cc = _upsampled_dft(product.conj(), int(region), up, dftshift - shift * up).conj()
        maxima = np.stack(np.unravel_index(np.argmax(np.abs(cc)), cc.shape)).astype(np.float64)
        shift += (maxima - dftshift) / up
    for d in range(len(shape)):
        if shape[d] == 1:
            shift[d] = 0
    return shift


def _clip_roi_zyx(vol, roi):
    if roi is None:
        return vol
    y0, y1, x0, x1 = [int(v) for v in roi]
    _, ym, xm = vol.shape
    y0 = max(0, min(y0, ym - 1))
    y1 = max(y0 + 1, min(y1, ym))
    x0 = max(0, min(x0, xm - 1))
    x1 = max(x0 + 1, min(x1, xm))
    return vol[:, y0:y1, x0:x1]


def _project_for_z(vol, mode):
    if mode == "yz":
        return vol.max(axis=2)
    if mode == "xz":
        return vol.max(axis=1)
    if mode == "z_profile_1d":
        return vol.max(axis=(1, 2))
    raise ValueError(f"Unknown projection_mode: {mode}")


def _update_roi_bounds(vol, roi):
    y0, y1, x0, x1 = [int(v) for v in roi]
    h, w = max(1, y1 - y0), max(1, x1 - x0)
    cy, cx = np.unravel_index(np.argmax(vol.max(axis=0)), vol.shape[1:])
    ny0, nx0 = int(round(cy - h / 2)), int(round(cx - w / 2))
    return (ny0, ny0 + h, nx0, nx0 + w)


def compute_z_shifts_for_tif(tif_path, ch_idx=0, projection_mode="yz", use_roi=False, roi=None, static_roi=True,
                             roi_update_interval=10, mode="frame_to_frame", segments=None, upsample_factor=10):
    """Per-timepoint (dz, dy, dx) shifts from one channel of an OME-TIFF."""
    stack = TiffStack(tif_path)
    try:
        T = stack.T
        shifts = [[0.0, 0.0, 0.0] for _ in range(T)]
        state = {"roi": roi}

        def proj(t, ref_t):
            vol = stack.read_channel(t, ch_idx)
            if use_roi and state["roi"] is not None:
                if not static_roi and ref_t is not None and roi_update_interval > 0 and (t - ref_t) % roi_update_interval == 0:
                    state["roi"] = _update_roi_bounds(vol, state["roi"])
                vol = _clip_roi_zyx(vol, state["roi"])
            return _project_for_z(vol, projection_mode)

        def estimate(a, b):
            s = phase_cross_correlation(a, b, upsample_factor=upsample_factor)
            if projection_mode == "yz":
                return [float(-s[0]), float(-s[1]), 0.0]
            if projection_mode == "xz":
                return [float(-s[0]), 0.0, float(-s[1])]
            return [float(-s[0]), 0.0, 0.0]

        if mode == "frame_to_frame":
            for t in range(1, T):
                shifts[t] = estimate(proj(t - 1, 0), proj(t, 0))
                progress("Z shifts", t, max(1, T - 1))
        elif mode == "reference":
            segments = segments or []
            total = max(1, sum(max(0, e - s + 1 - (1 if s <= r <= e else 0)) for r, s, e in segments))
            step = 0
            for ref_t, start, end in segments:
                ref = proj(ref_t, ref_t)
                for t in range(start, end + 1):
                    if t == ref_t:
                        shifts[t] = [0.0, 0.0, 0.0]
                        continue
                    shifts[t] = estimate(ref, proj(t, ref_t))
                    step += 1
                    progress(f"Z shifts (ref={ref_t})", step, total)
        else:
            raise ValueError("mode must be 'frame_to_frame' or 'reference'")
        return shifts
    finally:
        stack.close()


def save_shifts_csv(filepath, shifts):
    """Rows t, dz, dy, dx, total_dz, total_dy, total_dx (t from 1, totals rounded to 0.1)."""
    shifts = np.asarray(shifts, dtype=np.float64)
    cumulative = np.round(np.cumsum(shifts, axis=0), 1)
    t_col = np.arange(1, len(shifts) + 1).reshape(-1, 1)
    rows = np.hstack([t_col, shifts, cumulative])
    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["t", "dz", "dy", "dx", "total_dz", "total_dy", "total_dx"])
        writer.writerows(rows.tolist())


def load_total_dz_from_csv(csv_path):
    with open(csv_path) as f:
        return [round(float(row["total_dz"])) for row in csv.DictReader(f)]


def z_offsets(dz_values, Z):
    offsets, bottom_pad, new_Z = [], 0, Z
    for v in dz_values:
        off = bottom_pad - int(round(v))
        if off < 0:
            extra = -off
            bottom_pad += extra
            new_Z += extra
            offsets = [o + extra for o in offsets]
            off = 0
        new_Z = max(new_Z, off + Z)
        offsets.append(off)
    return offsets, new_Z


def apply_z_shifts_to_tif(tif_path, dz_values, out_path=None):
    """Place each timepoint at its Z offset on a taller stack; writes {stem}_z.ome.tif."""
    tif_path = Path(tif_path)
    out_path = Path(out_path) if out_path else tif_path.with_name(f"{stem_without_ome(tif_path)}_z.ome.tif")
    stack = TiffStack(tif_path)
    try:
        T, C, Z, Y, X = stack.shape
        if len(dz_values) != T:
            raise ValueError(f"Expected {T} dz values, got {len(dz_values)}")
        offsets, new_Z = z_offsets(dz_values, Z)

        def frame(t):
            padded = np.zeros((C, new_Z, Y, X), dtype=stack.dtype)
            padded[:, offsets[t]:offsets[t] + Z] = stack.read_frame(t)
            return padded

        def frames():
            for t, f in enumerate(ordered_map(frame, T, pipeline_width(stack.frame_bytes))):
                progress("Z apply", t + 1, T)
                yield f

        save_ome_tiff(out_path, frames(), stack.channel_names, stack.vox, stack.period_s,
                      shape=(T, C, new_Z, Y, X), dtype=stack.dtype, bigtiff=True)
        log(f"Saved {out_path.name}")
        return out_path
    finally:
        stack.close()


# ── Movies ───────────────────────────────────────────────────────────────────


class ChannelMovies:
    """One HEVC movie per channel: auto_contrast of the Z max-projection of each frame."""

    def __init__(self, paths, width, height, fps):
        from ffmpeg_runtime import MovieWriter

        self.paths = [Path(p) for p in paths]
        self._writers = [MovieWriter(p, width, height, fps) for p in self.paths]

    @staticmethod
    def gray_frames(projections):
        return [auto_contrast(p) for p in projections]

    def append(self, gray_frames):
        for w, g in zip(self._writers, gray_frames):
            w.append(g)

    def close(self):
        for w in self._writers:
            w.close()

    def cancel(self):
        for w in self._writers:
            w.cancel()
