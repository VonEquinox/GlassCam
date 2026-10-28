#ifndef GLASSCAM_HNCS_SPATIAL_H
#define GLASSCAM_HNCS_SPATIAL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Portable revision-8 phocus_presets.py spatial model, not the proprietary
 * native Phocus grain/sharpening kernels. Run after grayscale Float32 work,
 * before final clip/rint/UInt16 and display conversion. Input is packed RGB
 * IEEE Float32 in canonical TOP-LEFT row order, with post-crop width/height.
 * The exact shape participates in the deterministic SHA256/PCG64 noise seed.
 * Standard/default outer render bypass is the caller's responsibility.
 *
 * Return 0 success, -1 invalid key/flags/shape/input, -2 allocation or I/O
 * failure, -3 canceled. On failure input may be partially modified; discard
 * the temporary result. No C++ exception crosses this ABI. Calls are reentrant
 * with separate buffers/files. Do not use the same path concurrently.
 */
typedef int (*hncs_spatial_cancel_fn)(void *context);
int hncs_apply_spatial_preset(float *work_rgb, size_t width, size_t height,
    const char *preset_key, int apply_grain, int apply_sharpness);
/* The existing, seekable file must contain exactly width*height*3*sizeof(float)
 * native-endian bytes, without a header. scratch_directory can name the app's
 * temporary directory or be NULL for the system default. Temporary files are
 * unlinked immediately and always closed on success, error, or cancellation.
 * Extra scratch storage is <=16 bytes/pixel; extra RAM is bounded independently
 * of image dimensions (<4MiB for this catalog), excluding caller buffers.
 * Cancellation is checked between chunks/rows/passes; nonzero means stop.
 */
int hncs_apply_spatial_preset_file(const char *work_rgb_path,
    size_t width, size_t height, const char *preset_key,
    int apply_grain, int apply_sharpness, const char *scratch_directory,
    hncs_spatial_cancel_fn cancelled, void *cancel_context);
/* Original Phocus CPU sharpness equations followed by the portable grain model.
 * Non-HDR work codes, full-resolution pixel scale, replicated image edges;
 * no Phocus local adjustment layers or lens sharpness compensation.
 * baseline_sharpness is the RAW's DNG BaselineSharpness, or 0 if absent.
 * The original filter internally shifts UInt16 work to 14 bits and back.
 * apply_sharpness=0 bypasses that entire operation. Apple RAW sharpening must
 * be disabled before using it to avoid applying both decoder and native USM.
 * Return/error/cancellation/ownership rules match the portable API above.
 * Native sharpness scratch is 4 bytes/pixel and <1MiB working RAM; portable
 * grain retains its existing <=16 bytes/pixel / <4MiB bounds.
 */
int hncs_apply_spatial_native_sharpness(float *work_rgb, size_t width, size_t height,
    const char *preset_key, int apply_grain, int apply_sharpness, double baseline_sharpness);
int hncs_apply_spatial_native_sharpness_file(const char *work_rgb_path,
    size_t width, size_t height, const char *preset_key, int apply_grain,
    int apply_sharpness, double baseline_sharpness, const char *scratch_directory,
    hncs_spatial_cancel_fn cancelled, void *cancel_context);
/* Factory native USM gate after the Standard/tool overlay: 1 active, 0 bypass,
 * -1 unknown key. Independent of the legacy portable catalog's optional flags. */
int hncs_native_sharpness_enabled(const char *preset_key);
/* Revision-12 Apple HDR work image: unscaled encoded Float RGB -> normalized
 * Float RGB in [0,1], in place. work_scale is chosen by hncs_apple_hdr_work_scale
 * from the complete frame. It must be finite in [1,64] and cover every component;
 * never use per-strip scales.
 * Packs once by this shared scale even when both effects are disabled. Original
 * CPU sharpness receives the matching work-domain factor, so HDR differences
 * participate in luma/blur/thresholds. Portable grain keeps its reference-white
 * amplitude. Finish with hncs_finish_apple_hdr_work_linear and the same scale.
 * No extra source gain may be restored afterward. Existing APIs unchanged.
 * Same full-resolution, edge, cancellation and partial-error rules as above. */
int hncs_prepare_apple_hdr_spatial(float *unscaled_work_rgb,
    size_t width, size_t height, const char *preset_key, int apply_grain,
    int apply_sharpness, double baseline_sharpness, double work_scale);
int hncs_prepare_apple_hdr_spatial_file(const char *unscaled_work_rgb_path,
    size_t width, size_t height, const char *preset_key, int apply_grain,
    int apply_sharpness, double baseline_sharpness, double work_scale,
    const char *scratch_directory, hncs_spatial_cancel_fn cancelled,
    void *cancel_context);
/* Prepared X2D II HDR gamma/gradation RGB16 -> original full-resolution USM.
 * Standard/Nature factory controls and the RAW BaselineSharpness; HDR amount
 * and noise tables use the original 5.8829245141 work-domain factor.
 * No pixel exposure multiplier, grain, local layers, lens compensation,
 * preview radius scaling or output ICC. Image edges are replicated.
 * Source and output must be disjoint packed RGB16 frames. 0 success, -1 invalid
 * input, -2 allocation failure (discard the output on any failure).
 */
int hncs_render_x2d_hdr_sharpness(const uint16_t *input_rgb, uint16_t *output_rgb,
    size_t width, size_t height, const char *preset_key, double baseline_sharpness);
#ifdef __cplusplus
}
#endif
#endif
