// The source of the compute kernels in the Metal Shading Language.
//
// scipy accumulates in float64. Apple GPUs have no float64, so the Gaussian uses arithmetic on pairs of floats.
// Each value is the unevaluated sum hi + lo of two floats, which holds about 48 significant bits. Rounding that sum to float32 gives the same result as the float64 accumulation of
// scipy, except in the rare case where the exact value lies very close to the midpoint between two float32
// values. The kernels must be compiled with fast math off, as MetalBackend does, or the error terms vanish.

let metalSource = #"""
#include <metal_stdlib>
using namespace metal;

// Arithmetic on pairs of floats
inline float2 two_sum(float a, float b) {
    float s = a + b;
    float bb = s - a;
    float e = (a - (s - bb)) + (b - bb);
    return float2(s, e);
}
inline float2 quick_two_sum(float a, float b) {
    float s = a + b;
    float e = b - (s - a);
    return float2(s, e);
}
inline float2 two_prod(float a, float b) {
    float p = a * b;
    float e = fma(a, b, -p);
    return float2(p, e);
}
inline float2 ff_add(float2 a, float2 b) {
    float2 s = two_sum(a.x, b.x);
    float2 t = two_sum(a.y, b.y);
    s.y += t.x;
    s = quick_two_sum(s.x, s.y);
    s.y += t.y;
    return quick_two_sum(s.x, s.y);
}
inline float2 ff_mul(float2 a, float2 b) {
    float2 p = two_prod(a.x, b.x);
    p.y = fma(a.x, b.y, p.y);
    p.y = fma(a.y, b.x, p.y);
    return quick_two_sum(p.x, p.y);
}
// Return the exact sum of two floats as a pair of floats.
inline float2 ff_from_sum(float a, float b) { return two_sum(a, b); }
// Round a pair of floats to the nearest float.
inline float ff_round(float2 a) { return a.x + a.y; }

// Extend a line as the "reflect" mode of scipy does, which is d c b a | a b c d | d c b a.
inline int reflect_index(int i, int n) {
    if (i >= 0 && i < n) return i;
    int period = 2 * n;
    int m = i % period;
    if (m < 0) m += period;
    return m >= n ? period - 1 - m : m;
}

// Maximum projection along z
struct ProjParams { uint planeElements; uint zCount; uint firstPlane; };

kernel void max_project_u16(device const ushort* src [[buffer(0)]],
                            device float* dst [[buffer(1)]],
                            constant ProjParams& p [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
    if (i >= p.planeElements) return;
    device const ushort* s = src + (ulong)p.firstPlane * p.planeElements + i;
    ushort m = s[0];
    for (uint z = 1; z < p.zCount; ++z) m = max(m, s[(ulong)z * p.planeElements]);
    dst[i] = float(m);
}

kernel void max_project_u8(device const uchar* src [[buffer(0)]],
                           device float* dst [[buffer(1)]],
                           constant ProjParams& p [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
    if (i >= p.planeElements) return;
    device const uchar* s = src + (ulong)p.firstPlane * p.planeElements + i;
    uchar m = s[0];
    for (uint z = 1; z < p.zCount; ++z) m = max(m, s[(ulong)z * p.planeElements]);
    dst[i] = float(m);
}

kernel void max_project_f32(device const float* src [[buffer(0)]],
                            device float* dst [[buffer(1)]],
                            constant ProjParams& p [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
    if (i >= p.planeElements) return;
    device const float* s = src + (ulong)p.firstPlane * p.planeElements + i;
    float m = s[0];
    for (uint z = 1; z < p.zCount; ++z) { float v = s[(ulong)z * p.planeElements]; m = v > m ? v : m; }
    dst[i] = m;
}

// Gaussian
// Run one correlate1d pass of scipy. `alongY` selects axis 0, along the columns, or axis 1, along the rows.
struct GaussParams { uint width; uint height; int radius; uint alongY; };

kernel void gaussian_pass(device const float* src [[buffer(0)]],
                          device float* dst [[buffer(1)]],
                          constant float2* w [[buffer(2)]],
                          constant GaussParams& p [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    const uint x = gid.x, y = gid.y;
    if (x >= p.width || y >= p.height) return;
    const int r = p.radius;
    const bool alongY = p.alongY != 0;
    const int n = alongY ? int(p.height) : int(p.width);
    const int i = alongY ? int(y) : int(x);
    const int stride = alongY ? int(p.width) : 1;
    device const float* line = alongY ? (src + x) : (src + (ulong)y * p.width);

    float2 acc = ff_mul(float2(line[i * stride], 0.0f), w[r]);
    const bool interior = (i - r >= 0) && (i + r < n);
    for (int jj = -r; jj < 0; ++jj) {
        int ia = i + jj, ib = i - jj;
        if (!interior) { ia = reflect_index(ia, n); ib = reflect_index(ib, n); }
        float2 pair = ff_from_sum(line[ia * stride], line[ib * stride]);
        acc = ff_add(acc, ff_mul(pair, w[r + jj]));
    }
    dst[(ulong)y * p.width + x] = ff_round(acc);
}

// Convert as clip(0, 65535).astype(np.uint16) does.
inline ushort to_u16(float v) {
    if (!(v > 0.0f)) return 0;
    if (v >= 65535.0f) return 65535;
    return ushort(v);
}

// Shift and rotation
// The CPU prepares one table entry for every output pixel. It holds the upper left of the four source pixels and
// the fractions toward the next pixel. An entry with x0 at the smallest int reads nothing. The kernel only reads
// the four pixels of each plane and combines them. Each sum of two products is one product plus a fused multiply
// and add, as in the CPU code, so that both round in the same places.
struct WarpEntry { int x0; int y0; float fx; float fy; };
struct WarpParams { uint outW; uint outH; uint srcW; uint srcH; uint planes; };

#define WARP_KERNEL(SUFFIX, TYPE) \
inline float warp_sample_##SUFFIX(device const TYPE* s, constant WarpParams& p, uint plane, int sy, int sx) { \
    if (sy < 0 || sy >= int(p.srcH) || sx < 0 || sx >= int(p.srcW)) return 0.0f; \
    return float(s[(ulong)plane * p.srcW * p.srcH + (ulong)sy * p.srcW + sx]); \
} \
kernel void warp_##SUFFIX(device const TYPE* src [[buffer(0)]], \
                          device ushort* dst [[buffer(1)]], \
                          device const WarpEntry* table [[buffer(2)]], \
                          constant WarpParams& p [[buffer(3)]], \
                          uint3 gid [[thread_position_in_grid]]) { \
    const uint x = gid.x, y = gid.y, plane = gid.z; \
    if (x >= p.outW || y >= p.outH || plane >= p.planes) return; \
    const ulong k = (ulong)y * p.outW + x; \
    const ulong o = (ulong)plane * p.outW * p.outH + k; \
    WarpEntry e = table[k]; \
    if (e.x0 == (-2147483647 - 1)) { dst[o] = 0; return; } \
    float top = fma(warp_sample_##SUFFIX(src, p, plane, e.y0, e.x0 + 1), e.fx, \
                    warp_sample_##SUFFIX(src, p, plane, e.y0, e.x0) * (1.0f - e.fx)); \
    float bottom = fma(warp_sample_##SUFFIX(src, p, plane, e.y0 + 1, e.x0 + 1), e.fx, \
                       warp_sample_##SUFFIX(src, p, plane, e.y0 + 1, e.x0) * (1.0f - e.fx)); \
    dst[o] = to_u16(round(fma(bottom, e.fy, top * (1.0f - e.fy)))); \
}

WARP_KERNEL(u16, ushort)
WARP_KERNEL(f32, float)
WARP_KERNEL(u8, uchar)
"""#
