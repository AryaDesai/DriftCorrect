"""Compare the pixel data and calibration of two TIFF stacks.

Use it to check the Swift output against the Python output for the same input:

    python scripts/compare_tiffs.py python_out/P0_concat.ome.tif swift_out/P0_concat.ome.tif

Sample types may differ (the Python concatenation wrote float32); values are compared.
"""

import sys
import xml.etree.ElementTree as ET

import numpy as np
import tifffile


def load(path):
    with tifffile.TiffFile(path) as t:
        s = t.series[0]
        data = s.asarray()
        shape = s.get_shape(False) if hasattr(s, "get_shape") else s.shape
        meta = {}
        if t.ome_metadata:
            root = ET.fromstring(t.ome_metadata)
            ns = root.tag.split("}")[0] + "}" if "}" in root.tag else ""
            px = root.find(f".//{ns}Pixels")
            if px is not None:
                for k in ("PhysicalSizeX", "PhysicalSizeY", "PhysicalSizeZ", "TimeIncrement"):
                    if px.get(k) is not None:
                        meta[k] = float(px.get(k))
                meta["Channels"] = [c.get("Name") for c in px.findall(f"{ns}Channel")]
    return data, shape, meta


a, sa, ma = load(sys.argv[1])
b, sb, mb = load(sys.argv[2])
ok = True
if a.size != b.size:
    print(f"Different number of samples: {a.shape} vs {b.shape}")
    sys.exit(1)
a = a.reshape(-1).astype(np.float64)
b = b.reshape(-1).astype(np.float64)
diff = np.abs(a - b)
n = int((diff > 0).sum())
print(f"Samples: {a.size}, different: {n}, max difference: {diff.max():g}")
if n:
    ok = False
    idx = np.flatnonzero(diff)[:10]
    print("First differences (flat index: first, second):", [(int(i), a[i], b[i]) for i in idx])
if ma != mb:
    print("Metadata differs:\n ", ma, "\n ", mb)
    ok = False
print("Identical values and metadata." if ok else "Differences found.")
sys.exit(0 if ok else 1)
