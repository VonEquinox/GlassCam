#ifndef GLASSCAM_FLOAT_RASTER_H
#define GLASSCAM_FLOAT_RASTER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Validates all RGBA components and returns max(1, R, G, B), excluding alpha.
/// On failure, neither the source nor the peak output is changed.
int gc_float_rgba_peak(const float *pixels, size_t count, float *peak);

/// Pointwise storage operations. Zero samples are accepted; nonempty ranges
/// must be caller-owned and correctly sized. Packing preserves RGB bits.
/// All multi-buffer operations require disjoint complete ranges.
int gc_float_rgba_to_rgb(const float *rgba, size_t count, float *rgb);
int gc_float_rgb_to_rgba(const float *rgb, size_t count, float *rgba);
/// Read-only validation over a closed finite range. Empty input is valid.
int gc_float_range_valid(const float *values, size_t samples, float minimum, float maximum);
/// Scale/normalize/restore return 0 for invalid or nonfinite input. A pixel
/// error may leave partial output; discard it. Peak is written only on success.
int gc_float_scale(float *values, size_t samples, float scale);
int gc_float_normalize_rgb(float *rgb, size_t count, float scale, float *gains);
int gc_float_restore_rgba(float *rgba, const float *gains, size_t count,
                          float ceiling, float *peak);
/// CIColorCube order: R varies fastest, G next; blue selects one complete slab.
int gc_float_cube_rgb_slab(const float *nodes, size_t dimension, size_t blue, float *rgb);
int gc_float_unit_rgba_valid(const float *rgba, size_t count);

#ifdef __cplusplus
}
#endif
#endif
