"""Write small synthetic ND2 files that the `nd2` package reads correctly.

The files exercise the parts of the format that the Swift reader implements:
chunk map, CLX Lite metadata (with a zlib-compressed block), nested
experiment loops (T > P > Z), several channels, row padding, and
zlib-compressed frames.

Usage: python make_synthetic_nd2.py OUT_DIR
"""

import struct
import sys
import zlib
from pathlib import Path

import numpy as np

MAGIC = 0x0ABECEDA
# CLX Lite types
BOOL, INT32, UINT32, INT64, UINT64, DOUBLE, VOIDP, STRING, BYTES, LEVEL = 1, 2, 3, 4, 5, 6, 7, 8, 9, 11


def _name(n):
    raw = (n + "\x00").encode("utf-16-le")
    return struct.pack("BB", 0, len(raw) // 2), raw


def rec(t, name, value):
    """Encode one CLX Lite record."""
    _, raw = _name(name)
    head = struct.pack("BB", t, len(raw) // 2) + raw
    if t == BOOL:
        return head + struct.pack("B", 1 if value else 0)
    if t == INT32:
        return head + struct.pack("<i", value)
    if t == UINT32:
        return head + struct.pack("<I", value)
    if t == INT64:
        return head + struct.pack("<q", value)
    if t in (UINT64, VOIDP):
        return head + struct.pack("<Q", value)
    if t == DOUBLE:
        return head + struct.pack("<d", value)
    if t == STRING:
        return head + (value + "\x00").encode("utf-16-le")
    if t == BYTES:
        return head + struct.pack("<Q", len(value)) + bytes(value)
    if t == LEVEL:
        items = value  # list of encoded records
        body = b"".join(items)
        length = len(head) + 12 + len(body)
        return head + struct.pack("<IQ", len(items), length) + body + b"\x00" * (8 * len(items))
    raise ValueError(t)


def level(name, *items):
    return rec(LEVEL, name, list(items))


def compressed(payload):
    """Type-76 record: 2-byte header, 10 skipped bytes, zlib stream."""
    return struct.pack("BB", 76, 0) + b"\x00" * 10 + zlib.compress(payload)


def chunk(name, data, name_len=None):
    nb = name.encode()
    if name_len is not None:
        nb = nb + b"\x00" * (name_len - len(nb))
    return struct.pack("<IIQ", MAGIC, len(nb), len(data)) + nb + data


def write_nd2(path, *, T=3, P=2, Z=4, C=2, Y=32, X=40, pad=8, compress_frames=False,
              names=("Venus", "mCherry"), calib=0.65, zstep=2.0, period_ms=300000.0, seed=0):
    rng = np.random.default_rng(seed)
    width_bytes = X * C * 2 + pad
    attrs = level(
        "SLxImageAttributes",
        rec(UINT32, "uiWidth", X),
        rec(UINT32, "uiWidthBytes", width_bytes),
        rec(UINT32, "uiHeight", Y),
        rec(UINT32, "uiComp", C),
        rec(UINT32, "uiBpcInMemory", 16),
        rec(UINT32, "uiBpcSignificant", 12),
        rec(UINT32, "uiSequenceCount", T * P * Z),
        rec(UINT32, "uiTileWidth", X),
        rec(UINT32, "uiTileHeight", Y),
        rec(INT32, "eCompression", 0 if compress_frames else 2),
        rec(DOUBLE, "dCompressionParam", 0.0),
        rec(UINT32, "uiVirtualComponents", C),
    )
    planes = [
        level(f"a{i}", rec(STRING, "sDescription", nm), rec(UINT32, "uiCompCount", 1),
              rec(UINT32, "uiSampleIndex", i), rec(UINT32, "uiColor", 0xFF00FF),
              level("pFluorescentProbe", rec(STRING, "m_sName", nm)))
        for i, nm in enumerate(names[:C])
    ]
    picture = level(
        "SLxPictureMetadata",
        rec(DOUBLE, "dCalibration", calib),
        rec(BOOL, "bCalibrated", True),
        rec(DOUBLE, "dObjectiveMag", 20.0),
        level("sPicturePlanes", rec(UINT32, "uiCount", C), level("sPlaneNew", *planes)),
    )
    zloop = level(
        "",
        rec(UINT32, "eType", 4),
        level("uLoopPars", rec(UINT32, "uiCount", Z), rec(DOUBLE, "dZStep", zstep),
              rec(DOUBLE, "dZLow", 0.0), rec(DOUBLE, "dZHigh", zstep * (Z - 1)),
              rec(DOUBLE, "dZHome", 0.0), rec(INT32, "iType", 0), rec(BOOL, "bZInverted", False)),
    )
    points = [level("", rec(DOUBLE, "dPosX", 10.0 * i), rec(DOUBLE, "dPosY", 5.0 * i),
                    rec(DOUBLE, "dPosZ", 0.0), rec(STRING, "dPosName", f"pos{i}")) for i in range(P + 1)]
    # One extra point marked invalid: tests pItemValid filtering.
    valid = [1] * P + [0]
    ploop = level(
        "",
        rec(UINT32, "eType", 2),
        level("uLoopPars", rec(BOOL, "bUseZ", False), level("Points", *points)),
        rec(BYTES, "pItemValid", valid),
        level("ppNextLevelEx", zloop),
    )
    experiment = level(
        "SLxExperiment",
        rec(UINT32, "eType", 1),
        level("uLoopPars", rec(UINT32, "uiCount", T), rec(DOUBLE, "dStart", 0.0),
              rec(DOUBLE, "dPeriod", period_ms), rec(DOUBLE, "dDuration", period_ms * T)),
        level("ppNextLevelEx", ploop),
    )

    out = bytearray()
    out += chunk("ND2 FILE SIGNATURE CHUNK NAME01!", b"Ver3.0".ljust(64, b"\x00"))
    cmap = {}

    def add(name, data, name_len=None):
        cmap[name] = (len(out), len(data))
        out.extend(chunk(name, data, name_len))

    add("ImageAttributesLV!", attrs)
    add("ImageMetadataSeqLV|0!", compressed(picture))
    add("ImageMetadataLV!", experiment)

    frames = {}
    seq = 0
    for t in range(T):
        for p in range(P):
            for z in range(Z):
                img = rng.integers(0, 4096, (Y, X, C), dtype=np.uint16)
                frames[(t, p, z)] = img
                rows = np.zeros((Y, width_bytes), np.uint8)
                rows[:, : X * C * 2] = img.view(np.uint8).reshape(Y, X * C * 2)
                payload = rows.tobytes()
                if compress_frames:
                    payload = zlib.compress(payload)
                add(f"ImageDataSeq|{seq}!", struct.pack("<d", float(seq)) + payload, name_len=4072)
                seq += 1

    map_pos = len(out)
    body = bytearray()
    for k, (off, size) in cmap.items():
        body += k.encode() + struct.pack("<QQ", off, size)
    body += b"ND2 CHUNK MAP SIGNATURE 0000001!" + struct.pack("<Q", map_pos)
    out += struct.pack("<IIQ", MAGIC, 32, len(body)) + b"ND2 FILEMAP SIGNATURE NAME 0001!" + body
    Path(path).write_bytes(bytes(out))
    return frames


def main():
    out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out_dir.mkdir(parents=True, exist_ok=True)
    write_nd2(out_dir / "synthetic_tpzc.nd2")
    write_nd2(out_dir / "synthetic_compressed.nd2", T=2, P=1, Z=3, C=1, Y=16, X=24, pad=0,
              compress_frames=True, names=("GFP",), seed=1)


if __name__ == "__main__":
    main()
