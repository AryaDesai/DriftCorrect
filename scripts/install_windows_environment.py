"""Select locked CUDA dependencies, verify the GPU, or install the CPU environment."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def cuda_choices(output):
    match = re.search(r"CUDA Version:\s*(\d+)\.(\d+)", output)
    if not match:
        return []
    major = int(match[1])
    if major >= 13:
        return ["cuda13", "cuda12"]
    return ["cuda12"] if major == 12 else []


def detect_cuda():
    smi = shutil.which("nvidia-smi")
    if not smi:
        candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "NVIDIA Corporation/NVSMI/nvidia-smi.exe"
        if candidate.is_file():
            smi = str(candidate)
    if not smi:
        return []
    try:
        result = subprocess.run([smi], capture_output=True, text=True, timeout=20)
        return cuda_choices(result.stdout) if result.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        return []


# Exercise both the CUDA runtime and NVRTC, which the alignment kernels require.
GPU_CHECK = """
import cupy as cp
x = cp.arange(4, dtype=cp.float64)
kernel = cp.RawKernel('extern "C" __global__ void twice(double* x) { x[threadIdx.x] *= 2; }', 'twice')
kernel((1,), (4,), (x,))
cp.cuda.Stream.null.synchronize()
assert x.get().tolist() == [0, 2, 4, 6]
"""


def main():
    root = Path(__file__).resolve().parent.parent
    python = root / ".venv/Scripts/python.exe"
    sync = [sys.executable, "-m", "uv", "sync", "--project", str(root),
            "--python", "3.12", "--locked"]
    for extra in detect_cuda():
        print(f"Installing NVIDIA acceleration ({extra})...", flush=True)
        if subprocess.run(sync + ["--extra", extra]).returncode:
            continue
        try:
            check = subprocess.run([str(python), "-c", GPU_CHECK], capture_output=True,
                                   text=True, timeout=120)
            if check.returncode == 0:
                print(f"NVIDIA acceleration ready ({extra}).")
                return 0
        except (OSError, subprocess.TimeoutExpired):
            pass
        print(f"GPU check did not pass with {extra}; trying the next option.", flush=True)
    print("Installing CPU mode.", flush=True)
    # Exact sync removes a previous or unsuccessful CUDA installation.
    return subprocess.run(sync).returncode


if __name__ == "__main__":
    sys.exit(main())
