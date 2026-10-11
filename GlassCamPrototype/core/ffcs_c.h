#ifndef GLASSCAM_FFCS_C_H
#define GLASSCAM_FFCS_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FFCSContext FFCSContext;
/* Immutable, thread-safe context. asset_directory contains original XH2S .lutz
 * files. Missing/corrupt resources fail explicitly; never analytic fallback. */
size_t ffcs_simulation_count(void);
const char *ffcs_simulation_name(size_t index);
const char *ffcs_simulation_asset(size_t index);
FFCSContext *ffcs_create(const char *asset_directory, size_t simulation_index,
                        char *error, size_t error_size);
void ffcs_destroy(FFCSContext *context);
/* Experimental preview / runtime LUT baking only. This is the genuine FFCS
 * pointwise color transform, retaining the original matrix, LUT, Lab/OKLab,
 * tone curve and clipping, while omitting spatial grain and sharpening.
 * It does not replace any full-photo API below. No blur stage is present.
 * Input: dense interleaved RGB Float32, finite linear-sRGB in [0,1].
 * Output: dense DISPLAY-LINEAR sRGB RGBA Float32, alpha exactly 1.
 * Exposure is not applied here; the caller applies it before cube lookup.
 * pixel_count must be nonzero; counts are float elements, not bytes.
 * Caller owns nonoverlapping buffers. Context is immutable/thread-safe.
 * Returns 1 on success, 0 with error on failure; no exceptions cross the ABI.
 * Invalid arguments/input are rejected before writing any output.
 * For an sRGB-shaped N^3 cube, evaluate RGB = sRGB_EOTF(node/(N-1)).
 * Sampling coordinates must use sRGB_OETF(clamp(linear_RGB,0,1)); a shaped
 * cube must NOT be sampled with plain linear RGB coordinates. Node ordering
 * is caller-controlled; this API preserves input order exactly. */
int ffcs_process_linear_rgb_color_only(const FFCSContext *context,
    const float *input, size_t input_float_count, size_t pixel_count,
    float *output_rgba, size_t output_float_count, char *error, size_t error_size);
/* Dense interleaved RGB float input in linear-sRGB primaries. EV applied in
 * linear light before original FFCS stages. Output is DISPLAY-LINEAR sRGB,
 * suitable for tagged extended-linear-sRGB Core Image / 10-bit HEIF encoding.
 * Optional RGBA8 preview is the same final result with sRGB encoding.
 * Counts are elements/bytes, not pixels; no row padding. Returns 1 or 0.
 * Input/output must not overlap. No exceptions cross the C ABI. */
int ffcs_process_linear_rgb(const FFCSContext *context, const float *input,
    size_t input_float_count, size_t width, size_t height, float exposure_ev,
    uint32_t seed, float *output_linear, size_t output_float_count,
    uint8_t *preview_rgba, size_t preview_byte_count, char *error, size_t error_size);
/* Exact fused/row-ring mobile path. workers must be 1..4; each worker uses
 * three RGB-double rows plus one halo on each side of its output tile. Grain
 * always uses global image coordinates/width. Either output may be NULL, but
 * not both; its corresponding count is ignored when NULL. Buffers must not
 * overlap. Context is immutable and shared safely. No full-image temporaries.
 * On any error discard outputs (a worker may already have written a tile). */
int ffcs_process_linear_rgb_optimized(const FFCSContext *context, const float *input,
    size_t input_float_count, size_t width, size_t height, float exposure_ev,
    uint32_t seed, float *output_linear, size_t output_float_count,
    uint8_t *preview_rgba, size_t preview_byte_count, unsigned workers,
    char *error, size_t error_size);
/* Bounded-memory full-resolution strip export. Inputs/outputs are dense RGB
 * floats, in the same domains as ffcs_process_linear_rgb_optimized. All row
 * coordinates are GLOBAL and zero-based, in the same row order as the full
 * input bitmap (no implicit orientation flip). input covers input_rows
 * starting at input_origin_y; output stores only output_rows starting at
 * output_origin_y. Width is always the full image width (no horizontal crop).
 * The input strip must contain the output rows plus one original-image row
 * above/below, except at the full image edges. Extra input rows are accepted.
 * Grain uses global coordinates and full image width; sharpening truncates
 * only at full image edges, never at strip/tile boundaries. Output equals the
 * full-frame optimized result without allocating a full-frame intermediate.
 * workers is 1..4. Caller owns nonoverlapping buffers; counts are float counts.
 * Returns 1 on success; 0 with error on failure. Discard output on failure.
 * Each worker allocates just three full-width RGB-double rows. */
int ffcs_process_linear_rgb_strip(const FFCSContext *context, const float *input,
    size_t input_float_count, size_t full_width, size_t full_height,
    size_t input_origin_y, size_t input_rows, size_t output_origin_y,
    size_t output_rows, float exposure_ev, uint32_t seed,
    float *output_linear, size_t output_float_count, unsigned workers,
    char *error, size_t error_size);
/* Original double-precision encoded sRGB pipeline, EV=0, for validation.
 * Callback snapshots are valid only for callback duration; copy if retaining.
 * Names/domains match supplied pipeline.py's nine stages. */
typedef void (*FFCSStageCallback)(const char *stage_name, const double *rgb,
                                 size_t width, size_t height, void *user);
int ffcs_process_encoded_double(const FFCSContext *context, const double *input,
    size_t input_double_count, size_t width, size_t height, uint32_t seed,
    double *output_encoded, size_t output_double_count,
    FFCSStageCallback callback, void *user, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
#endif
