"""Compare two JSON files by value (floats within 1e-9). Prints the first differences.

    python scripts/compare_json.py python.json swift.json
"""

import json
import math
import sys


def diff(a, b, path="$", out=None):
    out = [] if out is None else out
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}.{k}: only in {'second' if k not in a else 'first'}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: length {len(a)} != {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        if not math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12):
            out.append(f"{path}: {a} != {b}")
    elif a != b:
        out.append(f"{path}: {a!r} != {b!r}")
    return out


if __name__ == "__main__":
    first = json.load(open(sys.argv[1]))
    second = json.load(open(sys.argv[2]))
    problems = diff(first, second)
    if problems:
        print(f"{len(problems)} difference(s):")
        for p in problems[:50]:
            print("  " + p)
        sys.exit(1)
    print("Identical.")
