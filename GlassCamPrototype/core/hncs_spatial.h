#ifndef GLASSCAM_HNCS_SPATIAL_H
#define GLASSCAM_HNCS_SPATIAL_H
#include <stddef.h>
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
#ifdef __cplusplus
}
#endif
#endif
