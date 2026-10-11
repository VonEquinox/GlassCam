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
#ifdef __cplusplus
}
#endif
#endif
