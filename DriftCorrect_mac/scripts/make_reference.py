"""Generate reference data for the Swift parity tests from the original Python code.

Usage:
    python make_reference.py PATH_TO_ORIGINAL_SCRIPTS OUT_DIR

PATH_TO_ORIGINAL_SCRIPTS holds useful_functions.py, multi_otsu_jax.py,
centroid_align_xy.py and nd2_to_tif.py. Every expected value comes from
those functions (or from numpy/scipy/skimage/cv2 calls that they make).
"""

import contextlib
import io
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np

SCRIPTS = Path(sys.argv[1]).resolve()
OUT = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import cv2  # noqa: E402
import tifffile  # noqa: E402
import yaml  # noqa: E402
from scipy.ndimage import gaussian_filter, label, shift  # noqa: E402

import useful_functions as uf  # noqa: E402
from make_synthetic_nd2 import write_nd2  # noqa: E402

if OUT.exists():
    shutil.rmtree(OUT)
OUT.mkdir(parents=True)
(OUT / "bin").mkdir()
manifest = {}
_counter = [0]
rng = np.random.default_rng(12345)


def arr(a):
    """Store an array; return a JSON descriptor."""
    a = np.ascontiguousarray(a)
    _counter[0] += 1
    name = f"bin/a{_counter[0]:05d}.bin"
    (OUT / name).write_bytes(a.astype(a.dtype.newbyteorder("<"), copy=False).tobytes())
    return {"file": name, "dtype": str(a.dtype), "shape": list(a.shape)}


def blob_image(h, w, cy, cx, r, base=100.0, amp=900.0, noise=20.0):
    yy, xx = np.mgrid[0:h, 0:w]
    img = base + amp * np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2.0 * r * r)))
    img = img + rng.normal(0, noise, (h, w))
    return img.astype(np.float32)


# ── Gaussian ──────────────────────────────────────────────────────────────────
cases = []
for (h, w, sigma) in [(20, 17, 1), (12, 9, 3), (5, 4, 2), (64, 72, 2.5), (64, 72, 7), (33, 31, 15), (128, 96, 20)]:
    img = (rng.random((h, w)) * 60000).astype(np.float32)
    cases.append({"input": arr(img), "sigma": sigma, "expected": arr(gaussian_filter(img, sigma))})
manifest["gaussian"] = cases

# ── Percentile ────────────────────────────────────────────────────────────────
cases = []
for n in [1, 2, 7, 1000, 4097]:
    a = (rng.random(n) * 1000).astype(np.float32)
    if n > 10:
        a[: n // 10] = a[0]  # ties
    qs = [0.0, 0.5, 10.0, 50.0, 90.0, 92.5, 99.5, 100.0]
    cases.append({"input": arr(a), "q": qs, "expected": [float(np.percentile(a, q)) for q in qs]})
manifest["percentile"] = cases

# ── Histogram (float64 edges, as multi-Otsu uses) ─────────────────────────────
cases = []
for bins in [17, 1024]:
    img = blob_image(40, 50, 20, 25, 8)
    counts, edges = np.histogram(img.astype(np.float64), bins=bins)
    cases.append({"input": arr(img), "bins": bins, "counts": counts.tolist(), "edges": edges.tolist()})
manifest["histogram"] = cases

# ── Labels ────────────────────────────────────────────────────────────────────
cases = []
for k in range(8):
    h, w = int(rng.integers(5, 40)), int(rng.integers(5, 40))
    m = rng.random((h, w)) < (0.3 + 0.05 * k)
    for eight in (False, True):
        lab, n = label(m, structure=np.ones((3, 3)) if eight else None)
        cases.append({"mask": arr(m.astype(np.uint8)), "eight": eight, "labels": arr(lab.astype(np.int32)), "count": int(n)})
manifest["label"] = cases

# ── cv2 Otsu on uint8 ─────────────────────────────────────────────────────────
cases = []
for k in range(20):
    n = int(rng.integers(1, 3000))
    u = np.concatenate([rng.normal(60 + k, 10, n // 2), rng.normal(170, 25, n - n // 2)]).clip(0, 255).astype(np.uint8)
    t, _ = cv2.threshold(u.reshape(-1, 1), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    cases.append({"input": arr(u), "threshold": int(t)})
manifest["otsu"] = cases

# ── Masks (find_largest_mask_xy) and multi-Otsu ───────────────────────────────
smooths = []
for k in range(3):
    img = blob_image(60, 70, 25 + 5 * k, 30 + 4 * k, 9 + k)
    img += blob_image(60, 70, 50, 10, 4, base=0, amp=500, noise=0)  # a second, smaller object
    smooths.append(gaussian_filter(img, 2))
flat = np.full((30, 30), 7.0, np.float32)

cases = []
for s in smooths + [flat]:
    for levels in (2, 3, 4, 5):
        th, cl = uf.multiotsu_thresholds_and_classes(s, levels)
        cases.append({"input": arr(s), "levels": levels, "thresholds": [float(x) for x in th],
                      "classes": arr(np.asarray(cl).astype(np.int32))})
manifest["multiotsu"] = cases

cases = []
variants = [
    dict(method="percentile", percentile=90.0),
    dict(method="percentile", percentile=75.0, invert=True),
    dict(method="multiotsu", percentile=90.0, levels=3, selected_levels=None),
    dict(method="multiotsu", percentile=90.0, levels=4, selected_levels=[1, 2]),
    dict(method="multiotsu", percentile=90.0, levels=3, selected_levels=[0, 2]),
    dict(method="multiotsu", percentile=90.0, levels=3, selected_levels=[]),
    dict(method="global_otsu", percentile=90.0),
    dict(method="percentile_otsu_roi", percentile=80.0),
    dict(method="percentile_otsu_roi", percentile=95.0, invert=True),
]
for s in smooths + [flat]:
    for v in variants:
        kw = dict(v)
        pct = kw.pop("percentile")
        mask, c = uf.find_largest_mask_xy(s, pct, **kw)
        py_th = [float(x) for x in uf.multiotsu_thresholds_and_classes(s, v.get("levels", 3))[0]] \
            if v["method"] == "multiotsu" else None
        cases.append({"input": arr(s), "percentile": pct, "method": v["method"], "invert": v.get("invert", False),
                      "multiotsu_thresholds": py_th,
                      "levels": v.get("levels", 3), "selected_levels": v.get("selected_levels"),
                      "mask": arr(mask.astype(np.uint8)), "centroid": [float(c[0]), float(c[1])]})
manifest["mask"] = cases

# ── compute_shift_xy on (C, Z, Y, X) frames ───────────────────────────────────
cases = []
for k in range(4):
    C, Z, H, W = 2, 3, 48, 56
    frame = np.zeros((C, Z, H, W), np.float32)
    for z in range(Z):
        frame[0, z] = np.round(blob_image(H, W, 20 + 3 * k, 25 - 2 * k, 6, amp=800 + 100 * z)).clip(0, 65535)
        frame[1, z] = np.round(blob_image(H, W, 30, 30, 5, amp=300)).clip(0, 65535)
    for params in [dict(sigma=2, percentile=90.0), dict(sigma=3, percentile=85.0, method="multiotsu", levels=3,
                                                         selected_levels=[2]),
                   dict(sigma=1, percentile=80.0, method="percentile_otsu_roi")]:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            dy, dx = uf.compute_shift_xy(frame, params["sigma"], params["percentile"], 0,
                                         method=params.get("method", "percentile"),
                                         levels=params.get("levels", 3),
                                         selected_levels=params.get("selected_levels"))
        cases.append({"frame": arr(frame.astype(np.uint16)), "params": params, "dy": float(dy), "dx": float(dx)})
manifest["compute_shift"] = cases

# ── Shift application ─────────────────────────────────────────────────────────
cases = []
for (dy, dx, pad) in [(2.3, -1.7, (0, 0, 0, 0)), (-0.5, 0.25, (0, 0, 0, 0)), (3.0, 0.0, (0, 3, 0, 0)),
                      (0.123456789, -4.987654321, (0, 1, 5, 0)), (-7.2, 6.9, (8, 0, 0, 7)), (2.5, -3.5, (0, 3, 4, 0))]:
    frame = np.round(rng.random((2, 2, 13, 11)) * 65535).astype(np.float32)
    pt, pb, pl, pr = pad
    padded = np.pad(frame, ((0, 0), (0, 0), (pt, pb), (pl, pr)))
    sub = shift(padded, (0, 0, dy, dx), order=1, mode="constant", cval=0).clip(0, 65535).astype(np.uint16)
    # Whole-pixel mode: apply_shift_xy_gpu (pad, then slice) written with numpy.
    idy, idx = int(round(dy)), int(round(dx))
    Y, X = padded.shape[2:]
    p2 = np.pad(padded, ((0, 0), (0, 0), (max(idy, 0), max(-idy, 0)), (max(idx, 0), max(-idx, 0))))
    whole = p2[:, :, max(-idy, 0):max(-idy, 0) + Y, max(-idx, 0):max(-idx, 0) + X].clip(0, 65535).astype(np.uint16)
    cases.append({"frame": arr(frame.astype(np.uint16)), "dy": dy, "dx": dx, "pad": list(pad),
                  "subpixel": arr(sub), "integer": arr(whole)})
manifest["shift"] = cases

# ── auto_contrast ─────────────────────────────────────────────────────────────
cases = []
for k in range(3):
    img = blob_image(30, 40, 15, 20, 6).clip(0, None)
    cases.append({"input": arr(img), "expected": arr(uf.auto_contrast(img))})
cases.append({"input": arr(np.zeros((5, 6), np.float32)), "expected": arr(uf.auto_contrast(np.zeros((5, 6), np.float32)))})
manifest["auto_contrast"] = cases

# ── TIFF files written by the Python code ─────────────────────────────────────
tif_dir = OUT / "tif"
tif_dir.mkdir()
cases = []
vox = SimpleNamespace(x=0.65, y=0.65, z=2.0)
for name, data, names, period, stream in [
    ("u16.ome.tif", rng.integers(0, 65535, (3, 2, 4, 9, 11), dtype=np.uint16), ["Venus", "mCherry"], 300.0, False),
    ("f32.ome.tif", (rng.random((2, 2, 3, 8, 10)) * 1000).astype(np.float32), ["A", "B"], None, False),
    ("c1.ome.tif", rng.integers(0, 4000, (4, 1, 2, 7, 6), dtype=np.uint16), ["GFP"], 60.0, False),
    ("stream.ome.tif", rng.integers(0, 65535, (2, 2, 3, 5, 7), dtype=np.uint16), ["X", "Y"], 1.5, True),
]:
    if stream:
        uf.save_ome_tiff(tif_dir / name, (f for f in data), names, vox, period, shape=data.shape, dtype=data.dtype)
    else:
        uf.save_ome_tiff(tif_dir / name, data, names, vox, period)
    cases.append({"file": f"tif/{name}", "data": arr(data), "channels": names, "period": period,
                  "vox": [vox.x, vox.y, vox.z]})
manifest["tiff"] = cases

# ── ND2 (synthetic, validated with the nd2 package) ───────────────────────────
import nd2  # noqa: E402

nd2_dir = OUT / "nd2"
nd2_dir.mkdir()
cases = []
write_nd2(nd2_dir / "synthetic_tpzc.nd2")
write_nd2(nd2_dir / "synthetic_compressed.nd2", T=2, P=1, Z=3, C=1, Y=16, X=24, pad=0, compress_frames=True,
          names=("GFP",), seed=1)
for name in ["synthetic_tpzc.nd2", "synthetic_compressed.nd2"]:
    with nd2.ND2File(nd2_dir / name) as f:
        sizes = dict(f.sizes)
        d = f.to_dask().compute()
        full = {k: sizes.get(k, 1) for k in "TPZCYX"}
        order = list(sizes)
        a = d
        for axis_name in "TPZCYX":
            if axis_name not in order:
                a = a[np.newaxis]
                order.insert(0, axis_name)
        a = np.transpose(a, [order.index(k) for k in "TPZCYX"])
        period = next((l.parameters.periodMs / 1000.0 for l in f.experiment if l.type == "TimeLoop"), None)
        cases.append({"file": f"nd2/{name}", "sizes": full, "channels": [c.channel.name for c in f.metadata.channels],
                      "vox": list(f.voxel_size()), "period": period, "data": arr(a)})
manifest["nd2"] = cases

# ── Convert (nd2_to_tif.py) end to end ────────────────────────────────────────
conv = OUT / "convert"
(conv / "in").mkdir(parents=True)
write_nd2(conv / "in" / "nd1188.nd2", T=2, P=2, Z=3, C=2, Y=12, X=14, pad=4, seed=21)
write_nd2(conv / "in" / "nd1189.nd2", T=3, P=2, Z=3, C=2, Y=12, X=14, pad=4, seed=22)
import nd2_to_tif  # noqa: E402

argv = sys.argv
sys.argv = ["nd2_to_tif.py", str(conv / "in"), "--output_dir", str(conv / "python_out")]
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    nd2_to_tif.main()
sys.argv = argv
manifest["convert"] = {"input": "convert/in",
                       "python_outputs": sorted(p.name for p in (conv / "python_out").glob("*.tif"))}

# ── YAML exactly as find_threshold.py writes it ───────────────────────────────
p_multi = {"channel": "Venus", "channel_index": 0, "sigma": 3, "percentile": 92.5, "method": "multiotsu",
           "invert": False, "levels": 4, "selected_levels": [2, 3]}
p_pct = {"channel": "Venus", "channel_index": 0, "sigma": 2, "percentile": 90.0, "method": "percentile", "invert": True}
doc = {
    "parameters": p_multi,
    "timepoint_parameters": [dict(p_multi), dict(p_pct), dict(p_multi)],
    "source": {"file": "/Users/me/data run/P0_concat.ome.tif", "image_shape": {"T": 3, "P": 1, "Y": 512, "X": 480}},
    "diagnostics": {"time_point": 1, "saved_at": "2026-09-26T10:11:12", "embryos": [
        {"id": 0, "mask_area_px": 12345, "mask_area_pct": 4.71, "mean_intensity": 812.35, "centroid": [240.12, 250.5]}]},
}
import copy  # noqa: E402

# find_threshold.py shares one selected_levels list between entries, so PyYAML writes
# anchors (&id001 / *id001). The Swift writer does not; compare with a deep copy.
manifest["yaml"] = {"text": yaml.dump(json.loads(json.dumps(doc)), default_flow_style=False, sort_keys=False),
                    "anchored_text": yaml.dump(doc, default_flow_style=False, sort_keys=False)}

# ── Alignment end to end ──────────────────────────────────────────────────────
adir = OUT / "align"
adir.mkdir()
T, C, Z, H, W = 6, 2, 3, 40, 48
movie = np.zeros((T, C, Z, H, W), np.uint16)
path = [(18, 22), (19, 24), (21, 23), (22, 27), (20, 30), (17, 29)]
for t, (cy, cx) in enumerate(path):
    for z in range(Z):
        movie[t, 0, z] = np.round(blob_image(H, W, cy, cx, 5, amp=900 + 50 * z)).clip(0, 65535)
        movie[t, 1, z] = np.round(blob_image(H, W, cy + 2, cx - 1, 4, amp=400)).clip(0, 65535)
tif = adir / "P0_concat.ome.tif"
uf.save_ome_tiff(tif, movie, ["Venus", "mCherry"], vox, 300.0)


def write_yaml(path, params, per_t=None):
    d = {"parameters": params, "source": {"file": str(tif), "image_shape": {"T": T, "P": 1, "Y": H, "X": W}}}
    if per_t is not None:
        d["timepoint_parameters"] = per_t
    path.write_text(yaml.dump(d, default_flow_style=False, sort_keys=False))


pct = {"channel": "Venus", "channel_index": 0, "sigma": 2, "percentile": 85.0, "method": "percentile", "invert": False}
write_yaml(adir / "percentile.yaml", pct)

# Run the unmodified worker for the percentile YAML (movies disabled: FFmpeg is not needed for the pixel data).
import centroid_align_xy  # noqa: E402

centroid_align_xy.tiff_to_mp4 = lambda *a, **k: None
# useful_functions.py uses scipy's `shift` without importing it (align_frame_xy raises NameError).
# Supply the intended function so the single-pass path can run.
uf.shift = shift
align_cases = []
for flag, tag in [([], "two_pass"), (["--no_enlarge_canvas"], "single_pass")]:
    out_dir = adir / "aligned_P0_concat"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    sys.argv = ["centroid_align_xy.py", str(adir / "percentile.yaml"), *flag]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        centroid_align_xy.main()
    sys.argv = argv
    result = tifffile.imread(out_dir / "P0_concat_xy.ome.tif")
    shifts = [[float(v) for v in line.replace("dy=", "").replace("dx=", "").split()]
              for line in buf.getvalue().splitlines() if line.startswith("dy=")]
    align_cases.append({"yaml": "align/percentile.yaml", "flags": flag, "shifts": shifts,
                        "expected": arr(result.reshape(T, C, Z, *result.shape[-2:]))})
    shutil.rmtree(out_dir)

# Intended behaviour for YAML settings the worker ignored (multi-Otsu, per-timepoint parameters):
# built from the same helper functions the worker uses.
multi = {"channel": "Venus", "channel_index": 0, "sigma": 3, "percentile": 90.0, "method": "multiotsu",
         "invert": False, "levels": 3, "selected_levels": [2]}
per_t = [dict(multi) if t % 2 == 0 else dict(pct) for t in range(T)]
write_yaml(adir / "multi.yaml", multi, per_t)
frames = movie.astype(np.float32)
sh = []
for t in range(T):
    p = uf.get_threshold_params_for_timepoint({"parameters": multi, "timepoint_parameters": per_t}, t)
    with contextlib.redirect_stdout(io.StringIO()):
        dy, dx = uf.compute_shift_xy(frames[t], p["sigma"], p["percentile"], p["channel_index"], method=p["method"],
                                     block_size=p["block_size"], invert=p["invert"], levels=p["levels"],
                                     selected_levels=p["selected_levels"])
    sh.append((dy, dx))
dys = np.array([s[0] for s in sh]); dxs = np.array([s[1] for s in sh])
pt, pb = int(np.ceil(max(0, -dys.min()))), int(np.ceil(max(0, dys.max())))
pl, pr = int(np.ceil(max(0, -dxs.min()))), int(np.ceil(max(0, dxs.max())))
out_sub = np.stack([shift(np.pad(frames[t], ((0, 0), (0, 0), (pt, pb), (pl, pr))), (0, 0, sh[t][0], sh[t][1]),
                          order=1, mode="constant", cval=0).clip(0, 65535).astype(np.uint16) for t in range(T)])
out_int = []
for t in range(T):
    padded = np.pad(frames[t], ((0, 0), (0, 0), (pt, pb), (pl, pr)))
    idy, idx = int(round(sh[t][0])), int(round(sh[t][1]))
    Y, X = padded.shape[2:]
    p2 = np.pad(padded, ((0, 0), (0, 0), (max(idy, 0), max(-idy, 0)), (max(idx, 0), max(-idx, 0))))
    out_int.append(p2[:, :, max(-idy, 0):max(-idy, 0) + Y, max(-idx, 0):max(-idx, 0) + X].astype(np.uint16))
align_cases.append({"yaml": "align/multi.yaml", "flags": [], "shifts": [list(s) for s in sh],
                    "expected": arr(out_sub), "expected_integer": arr(np.stack(out_int))})
manifest["align"] = align_cases

(OUT / "manifest.json").write_text(json.dumps(manifest, indent=1))
total = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file())
print(f"wrote {OUT} ({total / 1e6:.1f} MB)")
