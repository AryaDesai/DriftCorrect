"""CPU (NumPy/SciPy) and CUDA (CuPy).

Both backends give the same results. The CUDA kernels calculate in float64,
in the same order of operations as scipy so the gaussian bl;ur and the bilinear intrepolation shift are bit-identical to
`scipy.ndimage.gaussian_filter` and `scipy.ndimage.shift(order=1)`.

The GPU is used automatically when CuPy and an NVIDIA GPU are available.
Set the environment variable DRIFT_CORRECT_CPU=1 (or pass --cpu to a worker)
to force the CPU backend.

Only the heavy per-frame operations run here like max projection,
blur and the shift. Percentiles, labelling and Otsu stay on the CPU in
useful_functions.py, where their NumPy/SciPy results are the reference.
"""

import math
import os
import threading

import numpy as np
from scipy.ndimage import gaussian_filter, shift as nd_shift

SHIFT_MODES = ("subpixel", "integer")



def gaussian_kernel(sigma, truncate=4.0):
    """scipy's gaussian_kernel1d(sigma, 0, int(truncate * sigma + 0.5))."""
    sd = float(sigma)
    radius = int(truncate * sd + 0.5)
    x = np.arange(-radius, radius + 1)
    phi = np.exp(-0.5 / (sd * sd) * x ** 2)
    phi = phi / phi.sum()
    return phi, radius


def axis_table(n, s):
    """Per-row or per-column bilinear table in float64

    Returns int32 (i0, i1, valid) and float64 (w0, w1) arrays of length n.
    """
    c = np.arange(n, dtype=np.float64) - float(s)
    valid = (c >= 0) & (c <= n - 1)
    i0 = np.floor(np.where(valid, c, 0)).astype(np.int64)
    t = np.where(valid, c - i0, 0.0)
    i1 = np.minimum(i0 + 1, n - 1)
    return i0.astype(np.int32), i1.astype(np.int32), valid.astype(np.int32), 1.0 - t, t


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

    def shift(self, frame, pad, dy, dx, mode):
        """Shift all (C, Z) planes on the frame padded by pad=(top, bottom, left, right).

        Returns uint16 (C, Z, Y + top + bottom, X + left + right).
        """
        top, bottom, left, right = pad
        f = np.asarray(frame, dtype=np.float32)
        if any(pad):
            f = np.pad(f, ((0, 0), (0, 0), (top, bottom), (left, right)))
        if mode == "integer":
            return _integer_shift(np, f, dy, dx).clip(0, 65535).astype(np.uint16)
        out = nd_shift(f, (0, 0, float(dy), float(dx)), order=1, mode="constant", cval=0)
        return out.clip(0, 65535).astype(np.uint16)


def _integer_shift(xp, f, dy, dx):
    """apply_shift_xy_gpu: pad with zeros on the side content moves away from, then slice."""
    iy, ix = int(round(float(dy))), int(round(float(dx)))
    Y, X = f.shape[-2:]
    p = xp.pad(f, ((0, 0), (0, 0), (max(iy, 0), max(-iy, 0)), (max(ix, 0), max(-ix, 0))))
    return p[:, :, max(-iy, 0):max(-iy, 0) + Y, max(-ix, 0):max(-ix, 0) + X]


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

// scipy.ndimage.shift(order=1, mode="constant") of float32 planes on a padded canvas,
// then clip(0, 65535).astype(uint16). Tables come from axis_table() on the host.
__global__ void shift_bilinear(const float* __restrict__ src, unsigned short* __restrict__ dst,
                               const int* __restrict__ ry0, const int* __restrict__ ry1, const int* __restrict__ rv,
                               const double* __restrict__ rw0, const double* __restrict__ rw1,
                               const int* __restrict__ cx0, const int* __restrict__ cx1, const int* __restrict__ cv,
                               const double* __restrict__ cw0, const double* __restrict__ cw1,
                               int outW, int outH, int srcW, int srcH, int padTop, int padLeft, int planes) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int plane = blockIdx.z;
    if (x >= outW || y >= outH || plane >= planes) return;
    long long o = ((long long)plane * outH + y) * outW + x;
    if (!rv[y] || !cv[x]) { dst[o] = 0; return; }
    const float* s = src + (long long)plane * srcW * srcH;
    int ys[2] = {ry0[y], ry1[y]};
    int xs[2] = {cx0[x], cx1[x]};
    double wy[2] = {rw0[y], rw1[y]};
    double wx[2] = {cw0[x], cw1[x]};
    double acc = 0.0;
    for (int a = 0; a < 2; ++a) {
        for (int b = 0; b < 2; ++b) {
            int sy = ys[a] - padTop, sx = xs[b] - padLeft;
            double v = (sy < 0 || sy >= srcH || sx < 0 || sx >= srcW) ? 0.0 : (double)s[(long long)sy * srcW + sx];
            double c = v * wy[a];
            c = c * wx[b];
            acc += c;
        }
    }
    float f = (float)acc;
    unsigned short u;
    if (!(f > 0.0f)) u = 0;
    else if (f >= 65535.0f) u = 65535;
    else u = (unsigned short)f;
    dst[o] = u;
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
        self._shift = module.get_function("shift_bilinear")
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

    def shift(self, frame, pad, dy, dx, mode):
        cp = self.cp
        top, bottom, left, right = pad
        C, Z, Y, X = frame.shape
        H, W = Y + top + bottom, X + left + right
        with self._stream() as stream:
            f = cp.asarray(frame).astype(cp.float32, copy=False)
            if mode == "integer":
                if any(pad):
                    f = cp.pad(f, ((0, 0), (0, 0), (top, bottom), (left, right)))
                out = _integer_shift(cp, f, dy, dx).clip(0, 65535).astype(cp.uint16)
            else:
                f = cp.ascontiguousarray(f)
                out = cp.empty((C, Z, H, W), dtype=cp.uint16)
                rows = [cp.asarray(a) for a in axis_table(H, dy)]
                cols = [cp.asarray(a) for a in axis_table(W, dx)]
                block = (32, 8, 1)
                grid = ((W + 31) // 32, (H + 7) // 8, C * Z)
                self._shift(grid, block, (f, out, *rows, *cols, np.int32(W), np.int32(H), np.int32(X), np.int32(Y),
                                          np.int32(top), np.int32(left), np.int32(C * Z)))
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
