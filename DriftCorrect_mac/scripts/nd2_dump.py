"""Print ND2 metadata and per-frame checksums with the `nd2` package.

The output has the same form as `dc nd2-info FILE --checksums`, so the two
can be compared line by line on a real file:

    python scripts/nd2_dump.py FILE.nd2 > python.json
    swift run -c release dc nd2-info FILE.nd2 --checksums > swift.json
    diff python.json swift.json
"""

import hashlib
import json
import sys

import nd2
import numpy as np


def main(path):
    with nd2.ND2File(path) as f:
        sizes = dict(f.sizes)
        full = {k: sizes.get(k, 1) for k in "TPZCYX"}
        order = list(sizes)
        data = f.to_dask()
        loops = [k for k in order if k not in "CYXS"]
        sums = []
        for t in range(full["T"]):
            for p in range(full["P"]):
                for z in range(full["Z"]):
                    idx = []
                    for k in order:
                        if k == "T":
                            idx.append(t)
                        elif k == "P":
                            idx.append(p)
                        elif k == "Z":
                            idx.append(z)
                        else:
                            idx.append(slice(None))
                    frame = np.asarray(data[tuple(idx)].compute())
                    if "C" not in order:
                        frame = frame[np.newaxis]
                    frame = np.ascontiguousarray(frame.astype(frame.dtype.newbyteorder("<")))
                    sums.append(hashlib.sha256(frame.tobytes()).hexdigest()[:16])
        period = next((l.parameters.periodMs / 1000.0 for l in f.experiment if l.type == "TimeLoop"), None)
        out = {
            "channels": [c.channel.name for c in f.metadata.channels],
            "dtype": {"uint8": "uint8", "uint16": "uint16", "float32": "float32"}[str(f.dtype)],
            "frame_sha256_16": sums,
            "loops": loops,
            "period_s": period,
            "sizes": full,
            "voxel": list(f.voxel_size()),
        }
    print(json.dumps(out, indent=2, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1])
