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
/* Clone an immutable context for prepared X2D II native RGB input at a known
 * Phocus processing gain. This is the effective gain passed to the original
 * color filter after RAW normalization/WB/lens stages, NOT just ISO gain or EV.
 * Only the native dark-chroma weighting changes; pixels are not multiplied.
 * Preset, work-space, curve and output settings are preserved. The caller owns
 * the returned context; NULL means invalid/nonrepresentable gain or allocation
 * failure. Original constructors retain unit gain for their existing input
 * contract. Do not infer this gain from an Apple-decoded RGB image. This API
 * does not add a RAW decoder or imply equivalence of Phocus's HDR branches. */
hncs_context *hncs_clone_with_native_gain(const hncs_context *context,
                                        double native_processing_gain);
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
 * arithmetic. workers=1..4; count<65536 uses the serial oracle. Apple platforms
 * reuse bounded libdispatch workers; other platforms retain the safe thread
 * launch fallback after joining all started workers. Same buffer,
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
/* Prepared X2D II HDR input -> linear HDR RGB16 color-stage working codes.
 * Includes the original gain-aware HDR film curve; no HighlightStrength,
 * gamma, gradation, spatial stage or output ICC is applied here. This is NOT
 * display-linear sRGB; do not pass it through the SDR display decoder.
 * Gain must come from the original input contract. Supported range [0.25,32];
 * Standard/Nature color model only, not reproduction. Working primaries come
 * from context. No Apple adaptation or second exposure gain is applied.
 * Call cost includes HDR table creation. 0 success, -1 invalid/unsupported
 * input or OOM. Finite input, caller-owned nonoverlapping buffers required. */
int hncs_render_x2d_hdr_color(const hncs_context *context,
    double native_processing_gain, const double *native_rgb,
    uint16_t *hdr_working_rgb, size_t pixel_count);
/* Original HDR color-stage codes -> HighlightStrength -> HDR gamma work codes.
 * The two strength controls are finite values in [0,100], native defaults 50/50.
 * lstar=0 selects legacy gamma, 1 selects L*; it is NOT an inverse-gamma flag.
 * This must match the working primaries selected for the HDR color stage.
 * Preserves native FMA, Float32 HSL boundaries and round-away-from-zero codes.
 * No gradation, spatial, output ICC or Apple source adaptation is applied.
 * Exact in-place operation is supported; partial overlap is rejected.
 * Returns 0 on success, -1 on invalid parameters, with no writes on error. */
int hncs_render_x2d_hdr_post(const uint16_t *hdr_working_rgb,
    uint16_t *gamma_working_rgb, size_t pixel_count,
    double highlight_amount, double highlight_saturation, int lstar);
/* Original Standard/Nature HDR gradation, after HDR gamma and before USM.
 * Exact original UInt16 tables for ExpToolVersion 4, default factory tone,
 * gamma/highlight/shadow controls, and RecoverHue enabled. No user curve edits.
 * Valid keys are "standard" / "nature"; working codes are not display sRGB.
 * Source/output may be disjoint or exactly in-place; partial overlap is invalid.
 * 0 success, -1 invalid/unsupported input, with no writes on argument error. */
int hncs_apply_x2d_hdr_gradation(const char *preset_key,
    const uint16_t *gamma_working_rgb, uint16_t *gradation_working_rgb,
    size_t pixel_count);

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
 * Like native Phocus, every preset context still runs gradation/RecoverHue.
 * Even Standard has small UInt16 rounding changes; it is not the bare core.
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

/* Additive automatic-whitepoint adapter for already white-balanced linear sRGB.
 * xy is the RAW decoder's scene neutral, not camera RGB gains. The reference
 * virtual response estimates X2D capture gains (G=1) and Robertson kernel CCT.
 * Bradford reintroduces the scene white before virtual normalization; no second
 * camera WB is multiplied into the decoded image. Fixed-WB presets replace the
 * estimated virtual gains. This is a model, not paired iPhone/X2D calibration.
 * Existing constructors and numerical contracts remain unchanged. */
int hncs_whitepoint_parameters(double white_x, double white_y,
                              double *capture_target_wb, double *kelvin);
hncs_context *hncs_create_preset_whitepoint(double exposure_ev,
    double white_x, double white_y, double factory_kelvin_override,
    int lstar_working_space, int reproduction, int film_curve_type,
    int raw_film_curve_type, const char *preset_key, int apply_tone_curve);

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
/* Parallel pointwise boundaries around the unchanged whole-frame spatial pass.
 * Same arithmetic and errors as the serial functions; workers=1..4. */
int hncs_process_preset_work_float_parallel(const hncs_context *context,
    const float *linear_srgb_rgb, float *work_rgb, size_t pixel_count, unsigned workers);
int hncs_finish_preset_work_linear_parallel(const hncs_context *context,
    const float *work_rgb, float *linear_rgba, size_t pixel_count, unsigned workers);
/* Revision-10 production boundaries: core -> native gradation -> work RGB;
 * caller runs native sharpness, then optional portable grain on the whole frame;
 * finish quantizes, applies native global saturation/grayscale, then display.
 * No selective control points, vibrance, lens or local-layer corrections.
 * The no-spatial combined call uses the same pointwise arithmetic. Contracts,
 * finite-input validation and worker limits match the older Float APIs above.
 * Older preset APIs retain their pinned portable-reference behavior. */
int hncs_apply_phocus_post_spatial(const char *preset_key,
    const uint16_t *input_rgb, uint16_t *output_rgb, size_t pixel_count);
int hncs_process_phocus_work_float(const hncs_context *context,
    const float *linear_srgb_rgb, float *work_rgb, size_t pixel_count);
int hncs_finish_phocus_work_linear(const hncs_context *context,
    const float *work_rgb, float *linear_rgba, size_t pixel_count);
int hncs_process_phocus_linear_rgba(const hncs_context *context,
    const float *linear_srgb_rgb, float *linear_rgba, size_t pixel_count);
int hncs_process_phocus_work_float_parallel(const hncs_context *context,
    const float *linear_srgb_rgb, float *work_rgb, size_t pixel_count, unsigned workers);
int hncs_finish_phocus_work_linear_parallel(const hncs_context *context,
    const float *work_rgb, float *linear_rgba, size_t pixel_count, unsigned workers);
int hncs_process_phocus_linear_rgba_parallel(const hncs_context *context,
    const float *linear_srgb_rgb, float *linear_rgba, size_t pixel_count, unsigned workers);
/* Diagnostics for explicit synthetic-bridge verification. Row-major 3x3;
 * exposure is separate. Returns 0/-1. No capture metadata is inferred. */
int hncs_source_to_native_matrix(const hncs_context *context, double *matrix9);
int hncs_preset_white_balance(const hncs_context *context,
    double *capture_target_wb3, double *target_wb3, double *factory_kelvin);
#ifdef __cplusplus
}
#endif
#endif
