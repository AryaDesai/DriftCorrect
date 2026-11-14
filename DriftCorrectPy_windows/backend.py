"""CPU (NumPy/SciPy) and CUDA (CuPy).

Both backends give the same results. The CUDA Gaussian calculates in float64, in the same order of operations as
scipy, so it is identical to `scipy.ndimage.gaussian_filter`.

The GPU is used automatically when CuPy and an NVIDIA GPU are available.
Set the environment variable DRIFT_CORRECT_CPU=1 (or pass --cpu to a worker)
to force the CPU backend.

Only the heavy operations on every frame run here, which are the maximum projection, the blur and the move.
Percentiles, labelling and Otsu stay on the CPU in useful_functions.py, where their NumPy/SciPy results are the
reference.
"""

import math
import os
import threading

import numpy as np
from scipy.ndimage import affine_transform, gaussian_filter


def gaussian_kernel(sigma, truncate=4.0):
    """scipy's gaussian_kernel1d(sigma, 0, int(truncate * sigma + 0.5))."""
    sd = float(sigma)
    radius = int(truncate * sd + 0.5)
    x = np.arange(-radius, radius + 1)
    phi = np.exp(-0.5 / (sd * sd) * x ** 2)
    phi = phi / phi.sum()
    return phi, radius


class CPUBackend:
    """CPU backend using NumPy and SciPy."""

    name = "CPU (NumPy/SciPy)"
    is_gpu = False

    def gaussian(self, image, sigma):
        return gaussian_filter(np.asarray(image, dtype=np.float32), sigma)

    def max_project(self, frame, channel):
        return np.asarray(frame[channel]).max(axis=0).astype(np.float32)

    def max_project_all(self, frame):
        return np.asarray(frame).max(axis=1).astype(np.float32)

    def warp(self, frame, pad, transform):
        """Move all (C, Z) planes by a rotation and a shift onto the frame padded by pad=(top, bottom, left, right).

        Values between pixels are interpolated from the four nearest pixels, and a pixel outside the frame counts
        as 0. Returns uint16 (C, Z, Y + top + bottom, X + left + right).
        """
        top, bottom, left, right = pad
        C, Z, Y, X = frame.shape
        shape = (Y + top + bottom, X + left + right)
        matrix, offset = _warp_arguments(pad, transform)
        out = np.empty((C, Z) + shape, dtype=np.uint16)
        for c in range(C):
            for z in range(Z):
                plane = affine_transform(np.asarray(frame[c, z], dtype=np.float32), matrix, offset=offset, output_shape=shape,
                                         order=1, mode="grid-constant", cval=0)
                out[c, z] = np.rint(plane).clip(0, 65535).astype(np.uint16)
        return out


def _warp_arguments(pad, transform):
    """Return the matrix and offset that ndimage needs to move a plane by `transform` onto the padded canvas.

    `transform` is a 3 by 3 matrix in (x, y) pixels of the frame. Each output pixel reads the source at the
    position that the opposite transform gives, and ndimage works in (row, column) order.
    """
    top, _, left, _ = pad
    placed = np.array([[1, 0, left], [0, 1, top], [0, 0, 1.0]]) @ np.asarray(transform, dtype=float)
    back = np.linalg.inv(placed)
    return [[back[1, 1], back[1, 0]], [back[0, 1], back[0, 0]]], (back[1, 2], back[0, 2])


CUDA_SOURCE = r"""
extern "C" {

__device__ __forceinline__ int reflect_index(int i, int n) {
    if (i >= 0 && i < n) return i;
    int period = 2 * n;
    int m = i % period;
    if (m < 0) m += period;
    return m >= n ? period - 1 - m : m;
}

// One scipy correlate1d pass (mode "reflect") in float64; alongY selects axis 0 or axis 1.
__global__ void gaussian_pass(const float* __restrict__ src, float* __restrict__ dst,
                              const double* __restrict__ w, int width, int height, int r, int alongY) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;
    int n = alongY ? height : width;
    int i = alongY ? y : x;
    long long stride = alongY ? width : 1;
    const float* line = alongY ? (src + x) : (src + (long long)y * width);
    double acc = (double)line[i * stride] * w[r];
    bool interior = (i - r >= 0) && (i + r < n);
    for (int jj = -r; jj < 0; ++jj) {
        int ia = i + jj, ib = i - jj;
        if (!interior) { ia = reflect_index(ia, n); ib = reflect_index(ib, n); }
        acc += ((double)line[ia * stride] + (double)line[ib * stride]) * w[r + jj];
    }
    dst[(long long)y * width + x] = (float)acc;
}

}
"""


class CudaBackend:
    """CuPy implementation. Each thread uses its own CUDA stream."""

    is_gpu = True

    def __init__(self):
        import cupy as cp

        self.cp = cp
        cp.cuda.runtime.getDeviceCount()  # raises when no device
        props = cp.cuda.runtime.getDeviceProperties(cp.cuda.Device().id)
        name = props["name"].decode() if isinstance(props["name"], bytes) else props["name"]
        self.name = f"CUDA ({name})"

        module = cp.RawModule(code=CUDA_SOURCE, options=("--fmad=false", "-std=c++11")) # Disable FMA  to stay idential to scipy
        self._gauss = module.get_function("gaussian_pass")
        self._local = threading.local()
        # test so a broken driver falls back to the CPU at start-up.
        self.gaussian(np.ones((4, 4), np.float32), 1.0)

    def _stream(self):
        s = getattr(self._local, "stream", None)
        if s is None:
            s = self.cp.cuda.Stream(non_blocking=True)
            self._local.stream = s
        return s

    def gaussian(self, image, sigma):
        cp = self.cp
        img = np.asarray(image, dtype=np.float32)
        if sigma <= 1e-15:
            return img.copy()
        weights, radius = gaussian_kernel(sigma)
        h, w = img.shape
        block = (32, 8, 1)
        grid = ((w + 31) // 32, (h + 7) // 8, 1)
        with self._stream() as stream:
            a = cp.asarray(img)
            b = cp.empty_like(a)
            c = cp.empty_like(a)
            wd = cp.asarray(weights, dtype=cp.float64)
            self._gauss(grid, block, (a, b, wd, np.int32(w), np.int32(h), np.int32(radius), np.int32(1)))
            self._gauss(grid, block, (b, c, wd, np.int32(w), np.int32(h), np.int32(radius), np.int32(0)))
            out = cp.asnumpy(c, stream=stream)
            stream.synchronize()
        return out

    def max_project(self, frame, channel):
        cp = self.cp
        with self._stream() as stream:
            out = cp.asnumpy(cp.asarray(frame[channel]).max(axis=0).astype(cp.float32), stream=stream)
            stream.synchronize()
        return out

    def max_project_all(self, frame):
        cp = self.cp
        with self._stream() as stream:
            out = cp.asnumpy(cp.asarray(frame).max(axis=1).astype(cp.float32), stream=stream)
            stream.synchronize()
        return out

    def warp(self, frame, pad, transform):
        """Move all planes by a rotation and a shift on the GPU. The result is the same as on the CPU up to
        float32 rounding."""
        cp = self.cp
        from cupyx.scipy.ndimage import affine_transform as gpu_affine_transform
        top, bottom, left, right = pad
        C, Z, Y, X = frame.shape
        shape = (Y + top + bottom, X + left + right)
        matrix, offset = _warp_arguments(pad, transform)
        with self._stream() as stream:
            f = cp.asarray(frame).astype(cp.float32, copy=False)
            out = cp.empty((C, Z) + shape, dtype=cp.uint16)
            m = cp.asarray(matrix)
            for c in range(C):
                for z in range(Z):
                    plane = gpu_affine_transform(f[c, z], m, offset=offset, output_shape=shape, order=1,
                                                 mode="grid-constant", cval=0)
                    out[c, z] = cp.rint(plane).clip(0, 65535).astype(cp.uint16)
            result = cp.asnumpy(out, stream=stream)
            stream.synchronize()
        return result


_backends = {}
_backend_lock = threading.Lock()


def get_backend(prefer_gpu=True):
    """CUDA when available (and not disabled), else the CPU"""
    want_gpu = bool(prefer_gpu) and os.environ.get("DRIFT_CORRECT_CPU", "").lower() not in ("1", "true", "yes")
    with _backend_lock:
        if want_gpu not in _backends:
            backend = None
            if want_gpu:
                try:
                    backend = CudaBackend()
                except Exception as e:  # CuPy missing, no NVIDIA GPU, or driver problem
                    if os.environ.get("DRIFT_CORRECT_DEBUG"):
                        print(f"CUDA not used: {e}", flush=True)
            _backends[want_gpu] = backend or CPUBackend()
        return _backends[want_gpu]
