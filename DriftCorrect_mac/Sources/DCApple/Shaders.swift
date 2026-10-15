// Metal Shading Language source for the compute kernels.
//
// scipy accumulates in float64. Apple GPUs have no float64, so the
// Gaussian and the bilinear shift use "float-float" arithmetic: each value
// is an unevaluated sum hi + lo of two floats (about 48 significant bits).
// Rounding that sum to float32 gives the same result as scipy's float64
// accumulation except in the rare case where the exact value lies within
// ~2^-44 (relative) of a float32 rounding midpoint. The kernels must be
// compiled with fast math off (see MetalBackend), or the error terms vanish.

let metalSource = #"""
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- float-float
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
// Sum of two floats as float-float (exact).
inline float2 ff_from_sum(float a, float b) { return two_sum(a, b); }
// Round float-float to the nearest float.
inline float ff_round(float2 a) { return a.x + a.y; }

// scipy "reflect" extension: d c b a | a b c d | d c b a
inline int reflect_index(int i, int n) {
    if (i >= 0 && i < n) return i;
    int period = 2 * n;
    int m = i % period;
    if (m < 0) m += period;
    return m >= n ? period - 1 - m : m;
}

// ---------------------------------------------------------------- Z projection
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

// ---------------------------------------------------------------- Gaussian
// One scipy correlate1d pass. `alongY` selects axis 0 (columns) or axis 1 (rows).
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

// ---------------------------------------------------------------- Shift
// Per-row / per-column tables prepared on the CPU in float64:
//   idx.x = first source index on the padded canvas, idx.y = second (clamped),
//   w = (w0, w1) as float-float pairs; valid = 0 when the coordinate is outside the canvas.
struct AxisEntry { int i0; int i1; int valid; int pad0; float2 w0; float2 w1; };
struct ShiftParams {
    uint outW; uint outH;         // canvas size
    uint srcW; uint srcH;         // source frame size
    int padTop; int padLeft;      // source placement on the canvas
    int iy; int ix;               // whole-pixel shift
    uint planes;
};

inline float sample_u16(device const ushort* s, constant ShiftParams& p, uint plane, int cy, int cx) {
    int sy = cy - p.padTop, sx = cx - p.padLeft;
    if (sy < 0 || sy >= int(p.srcH) || sx < 0 || sx >= int(p.srcW)) return 0.0f;
    return float(s[(ulong)plane * p.srcW * p.srcH + (ulong)sy * p.srcW + sx]);
}
inline float sample_f32(device const float* s, constant ShiftParams& p, uint plane, int cy, int cx) {
    int sy = cy - p.padTop, sx = cx - p.padLeft;
    if (sy < 0 || sy >= int(p.srcH) || sx < 0 || sx >= int(p.srcW)) return 0.0f;
    return s[(ulong)plane * p.srcW * p.srcH + (ulong)sy * p.srcW + sx];
}
inline float sample_u8(device const uchar* s, constant ShiftParams& p, uint plane, int cy, int cx) {
    int sy = cy - p.padTop, sx = cx - p.padLeft;
    if (sy < 0 || sy >= int(p.srcH) || sx < 0 || sx >= int(p.srcW)) return 0.0f;
    return float(s[(ulong)plane * p.srcW * p.srcH + (ulong)sy * p.srcW + sx]);
}

// clip(0, 65535).astype(np.uint16)
inline ushort to_u16(float v) {
    if (!(v > 0.0f)) return 0;
    if (v >= 65535.0f) return 65535;
    return ushort(v);
}

#define SHIFT_KERNELS(SUFFIX, TYPE, SAMPLE) \
kernel void shift_bilinear_##SUFFIX(device const TYPE* src [[buffer(0)]], \
                                    device ushort* dst [[buffer(1)]], \
                                    device const AxisEntry* rows [[buffer(2)]], \
                                    device const AxisEntry* cols [[buffer(3)]], \
                                    constant ShiftParams& p [[buffer(4)]], \
                                    uint3 gid [[thread_position_in_grid]]) { \
    const uint x = gid.x, y = gid.y, plane = gid.z; \
    if (x >= p.outW || y >= p.outH || plane >= p.planes) return; \
    const ulong o = (ulong)plane * p.outW * p.outH + (ulong)y * p.outW + x; \
    AxisEntry ry = rows[y]; AxisEntry cx = cols[x]; \
    if (ry.valid == 0 || cx.valid == 0) { dst[o] = 0; return; } \
    float v00 = SAMPLE(src, p, plane, ry.i0, cx.i0); \
    float v01 = SAMPLE(src, p, plane, ry.i0, cx.i1); \
    float v10 = SAMPLE(src, p, plane, ry.i1, cx.i0); \
    float v11 = SAMPLE(src, p, plane, ry.i1, cx.i1); \
    float2 acc = ff_mul(ff_mul(float2(v00, 0.0f), ry.w0), cx.w0); \
    acc = ff_add(acc, ff_mul(ff_mul(float2(v01, 0.0f), ry.w0), cx.w1)); \
    acc = ff_add(acc, ff_mul(ff_mul(float2(v10, 0.0f), ry.w1), cx.w0)); \
    acc = ff_add(acc, ff_mul(ff_mul(float2(v11, 0.0f), ry.w1), cx.w1)); \
    dst[o] = to_u16(ff_round(acc)); \
} \
kernel void shift_integer_##SUFFIX(device const TYPE* src [[buffer(0)]], \
                                   device ushort* dst [[buffer(1)]], \
                                   constant ShiftParams& p [[buffer(4)]], \
                                   uint3 gid [[thread_position_in_grid]]) { \
    const uint x = gid.x, y = gid.y, plane = gid.z; \
    if (x >= p.outW || y >= p.outH || plane >= p.planes) return; \
    const ulong o = (ulong)plane * p.outW * p.outH + (ulong)y * p.outW + x; \
    int yy = int(y) - p.iy, xx = int(x) - p.ix; \
    if (yy < 0 || yy >= int(p.outH) || xx < 0 || xx >= int(p.outW)) { dst[o] = 0; return; } \
    dst[o] = to_u16(SAMPLE(src, p, plane, yy, xx)); \
}

SHIFT_KERNELS(u16, ushort, sample_u16)
SHIFT_KERNELS(f32, float, sample_f32)
SHIFT_KERNELS(u8, uchar, sample_u8)
"""#
