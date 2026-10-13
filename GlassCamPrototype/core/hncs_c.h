#ifndef GLASSCAM_HNCS_C_H
#define GLASSCAM_HNCS_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Immutable, reentrant settings context. Original legacy / standard / V1 gamma.
 * Kelvin is truncated then clamped to [2000, 10000], with table extrapolation.
 * Exposure must be finite and in [-20,20] EV.
 * NULL means invalid settings/allocation failure. No exceptions cross this ABI. */
typedef struct hncs_context hncs_context;
hncs_context *hncs_create(double exposure_ev, double illuminant_kelvin);
/* Optional reference modes: lstar=0 selects legacy, lstar=1 selects L*;
 * reproduction=0 selects standard/V1, reproduction=1 selects reproduction/pure.
 * Both mode flags must be exactly 0 or 1. */
hncs_context *hncs_create_mode(double exposure_ev, double illuminant_kelvin,
                               int lstar, int reproduction);
void hncs_destroy(hncs_context *context);
/* Packed linear sRGB RGB float triplets -> encoded sRGB RGBA8 (opaque).
 * Experimental D65-to-camera-white Bradford source adapter precedes true HNCS.
 * 0 success, -1 invalid argument/nonfinite input. Buffers must not overlap.
 * On failure output contents are unspecified. Reentrant on a shared context. */
int hncs_process_srgb(const hncs_context *context, const float *input_rgb,
                      uint8_t *output_rgba, size_t pixel_count);
/* Export path: packed linear sRGB RGB float triplets -> display-linear sRGB
 * RGBA float quads, clipped to [0,1], with alpha exactly 1. Reuses the original
 * UInt16 HNCS core and exact display matrices; no sRGB OETF or RGBA8 boundary.
 * The export encoder is responsible for its transfer function and bit depth.
 * Same errors/contracts as hncs_process_srgb; count is checked against both
 * input and output byte sizes. */
int hncs_process_linear_rgba(const hncs_context *context, const float *input_rgb,
                             float *output_rgba, size_t pixel_count);
/* Exact Float export in bounded contiguous tiles; no approximation or changed
 * arithmetic. workers=1..4; count<65536 uses the serial oracle. Thread launch
 * failure falls back safely after joining all started workers. Same buffer,
 * error and byte-size contracts as hncs_process_linear_rgba. */
int hncs_process_linear_rgba_parallel(const hncs_context *context,
    const float *input_rgb, float *output_rgba, size_t pixel_count, unsigned workers);
/* Optimized display path: same native core and display matrices, but the final
 * sRGB OETF uses a 65536-entry table at the nearest linear sample. The maximum
 * continuous 8-bit-code perturbation is <= 0.026; quantized output differs by
 * at most one byte level per RGB channel. Alpha remains 255. This API is
 * intentionally separate from the exact oracle above. Same errors/contracts. */
int hncs_process_srgb_fast(const hncs_context *context, const float *input_rgb,
                           uint8_t *output_rgba, size_t pixel_count);
/* Same fast output, split into bounded contiguous CPU tiles. workers must be
 * 1..4; smaller than 65536 pixels runs sequentially. Failure to create a worker
 * safely falls back to processing the remaining tiles on the calling thread.
 * No system-wide thread pool or hardware-concurrency assumption. */
int hncs_process_srgb_fast_parallel(const hncs_context *context,
                                    const float *input_rgb, uint8_t *output_rgba,
                                    size_t pixel_count, unsigned workers);
/* Original core only: white-balanced native X2D RGB double triplets -> uint16
 * RGB codes in the context's selected working space. No source adapter, exposure,
 * or display transform here. hncs_create selects legacy/standard/V1.
 * Input rounds ties to even; linear-code curve indices truncate (not round). */
int hncs_render_native(const hncs_context *context, const double *native_rgb,
                       uint16_t *output_rgb, size_t pixel_count);

/* Revision-8 additive API. Old constructors and their output are unchanged.
 * capture_kelvin chooses the experimental Apple-linear-RGB source bridge.
 * factory_kelvin_override=0 chooses preset CCT, or capture CCT when unspecified.
 * Other finite factory/capture CCTs are truncated and clamped to [2000,10000].
 * film_curve_type: 0 original, 1 high, 2 standard, 4 as-shot, 6 low, 7 linear.
 * As-shot resolves raw_film_curve_type once (Apple callers declare a fallback).
 * As in the source, raw 0 chooses original, raw 7 pure, every other int V1;
 * raw 4 is not recursively resolved. Unknown requested film types are rejected.
 * Reproduction always resolves type 7; original is distinct only in legacy RGB.
 * apply_tone_curve=0 disables point curves only, retaining gamma and contrast.
 * Optional WB pointers contain three positive finite gains, normalized to G=1.
 * NULL capture_target_wb uses interpolated factory_wb(capture CCT), clamped to
 * its original [3050,9100] table endpoints, a SYNTHETIC
 * virtual-X2D baseline, not measured Apple capture WB. NULL target_wb_override
 * uses preset absolute WB, or no WB replacement if that preset has none.
 * Applied virtual-native gain is desired/baseline; capture mapping and final
 * factory CCT remain distinct. Exposure EV is separate from XML EV multiplier.
 * Existing process APIs on this context apply POINTWISE stages only. Grain and
 * optional USM require the frame-aware spatial route and hooks below. */
hncs_context *hncs_create_preset(double exposure_ev, double capture_kelvin,
    double factory_kelvin_override, int lstar, int reproduction,
    int film_curve_type, int raw_film_curve_type, const char *preset_key,
    int apply_tone_curve, const double *capture_target_wb,
    const double *target_wb_override);

/* Immutable, generated catalog: 43 unique XML payloads; aliases accepted by all
 * key-based calls. Strings remain valid for the lifetime of the process.
 * Flags: 1 pointwise/WB effect, 2 square crop, 4 grain needs spatial route,
 * 8 sharpness-only needs optional spatial route, 16 optional sharpness values,
 * 32 source-defined pointwise no-op. Unknown key returns NULL or UINT_MAX.
 * Settings JSON includes exact original payload, WB and spatial parameters. */
size_t hncs_preset_count(void);
const char *hncs_preset_key(size_t index);
const char *hncs_preset_name(size_t index);
unsigned hncs_preset_flags(const char *preset_key);
const char *hncs_preset_settings_json(const char *preset_key);

/* Independent numerical oracles. Postcurves exclude saturation and grayscale;
 * pointwise includes saturation, postcurves, grayscale and final UInt16 round.
 * Neither applies WB, film curve, crop, grain or USM. Packed RGB; disjoint
 * buffers. Return 0 success or -1 invalid argument/overflow. */
int hncs_apply_post_curves(const char *preset_key, int apply_tone_curve,
    const uint16_t *input_rgb, uint16_t *output_rgb, size_t pixel_count);
int hncs_apply_preset_pointwise(const char *preset_key, int apply_tone_curve,
    const uint16_t *input_rgb, uint16_t *output_rgb, size_t pixel_count);
/* Core film curve + pointwise preset; input already white-balanced native RGB.
 * No source bridge, target WB replacement or EV is applied to native input. */
int hncs_render_native_preset(const hncs_context *context,
    const double *input_rgb, uint16_t *output_rgb, size_t pixel_count);

/* Frame-aware spatial handoff. Float32 working RGB is AFTER saturation,
 * postcurves and grayscale but BEFORE grain, optional USM, final clip/rint.
 * Crop before calling a spatial route: its seed/variance use cropped shape.
 * Finish performs exactly one final UInt16 quantization then exact display
 * decoding. Never feed already-finished display-linear pixels to finish. */
int hncs_apply_preset_work_float(const char *preset_key, int apply_tone_curve,
    const uint16_t *input_rgb, float *work_rgb, size_t pixel_count);
int hncs_process_preset_work_float(const hncs_context *context,
    const float *linear_srgb_rgb, float *work_rgb, size_t pixel_count);
int hncs_finish_preset_work_linear(const hncs_context *context,
    const float *work_rgb, float *linear_rgba, size_t pixel_count);
/* Diagnostics for explicit synthetic-bridge verification. Row-major 3x3;
 * exposure is separate. Returns 0/-1. No capture metadata is inferred. */
int hncs_source_to_native_matrix(const hncs_context *context, double *matrix9);
int hncs_preset_white_balance(const hncs_context *context,
    double *capture_target_wb3, double *target_wb3, double *factory_kelvin);
#ifdef __cplusplus
}
#endif
#endif
