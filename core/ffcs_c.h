#ifndef GLASSCAM_FFCS_C_H
#define GLASSCAM_FFCS_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FFCSContext FFCSContext;
/* Immutable, thread-safe FFCS 0.2.0 context. Missing/corrupt native LUTs
 * fail explicitly; there is no implicit analytic fallback. Stable legacy look
 * indices 0..18; REALA ACE is appended at index 19. */
size_t ffcs_simulation_count(void);
const char *ffcs_simulation_name(size_t index);
const char *ffcs_simulation_asset(size_t index);
/* Direct family directory (contains .lutz files). Default is native LUT with
 * neutral postprocessing, exactly the 0.2.0 reference default. */
FFCSContext *ffcs_create(const char *asset_directory, size_t simulation_index,
                        char *error, size_t error_size);
/* Flags remain independent gates. Enabled never invents an absent coefficient.
 * Old constructors default to analytic_overlay=0, sharpen_radius=1.0, so both
 * spatial gates are inert until an explicit overlay is selected. */
FFCSContext *ffcs_create_options(const char *asset_directory, size_t simulation_index,
    int grain_enabled, int sharpen_enabled, char *error, size_t error_size);
/* Explicit analytic overlay matches Python apply_reference_adjustments=True:
 * Lab/OKLab + tone + selected look's grain/sharpen coefficients. Every flag
 * is exactly 0 or 1. Radius is finite (0,64], evaluated as max(0.1,radius).
 * This resource limit is a portable API bound, not a reference-model change.
 * Grain/sharpen gates never disable the overlay's pointwise color stages. */
FFCSContext *ffcs_create_config(const char *asset_directory, size_t simulation_index,
    int grain_enabled, int sharpen_enabled, int analytic_overlay,
    double sharpen_radius, char *error, size_t error_size);
/* data_root contains xh2s/, xa3/, gfx100/, gfx100s/, gfx100ii/. Camera names
 * are case-insensitive. Dedicated GFX100S/II assets take priority; remaining
 * looks resolve to GFX100 exactly as the reference. No other substitutions.
 * Availability only checks a resolved file exists; creation validates it. */
FFCSContext *ffcs_create_family_config(const char *data_root, const char *camera,
    size_t simulation_index, int grain_enabled, int sharpen_enabled,
    int analytic_overlay, double sharpen_radius, char *error, size_t error_size);
int ffcs_simulation_available(const char *data_root, const char *camera,
    size_t simulation_index);
/* Existence-only resolver; static string lifetime, NULL when unavailable. */
const char *ffcs_resolved_asset_family(const char *data_root, const char *camera,
    size_t simulation_index);
/* Actual lower-case asset family for family constructors; empty for the legacy
 * direct-directory constructor. Pointer lifetime is the context lifetime. */
const char *ffcs_asset_family(const FFCSContext *context);
/* Required strip halo rows; 0 for native default/sharpen disabled, otherwise
 * ceil(3*max(0.1,radius)). NULL yields 0; processing still rejects NULL. */
size_t ffcs_required_halo(const FFCSContext *context);
void ffcs_destroy(FFCSContext *context);
/* Experimental preview / runtime LUT baking only. This is the genuine FFCS
 * pointwise color transform, retaining the original matrix, LUT, Lab/OKLab,
 * tone curve and clipping when the overlay is enabled, while omitting spatial
 * grain and sharpening. Native default preserves LUT values without analytic
 * adjustments. It does not replace any full-photo API below.
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
 * at most min(height, 2*ffcs_required_halo(context)+1) RGB-double rows. Grain
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
 * The input strip must contain the output rows plus ffcs_required_halo(context)
 * original-image rows above/below, except at full image edges. Extra rows accepted.
 * Grain uses global coordinates and full image width; sharpening truncates
 * only at full image edges, never at strip/tile boundaries. Output equals the
 * full-frame optimized result without allocating a full-frame intermediate.
 * workers is 1..4. Caller owns nonoverlapping buffers; counts are float counts.
 * Returns 1 on success; 0 with error on failure. Discard output on failure.
 * Each worker allocates min(full_height,2*halo+1) full-width RGB-double rows. */
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
