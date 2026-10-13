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
#ifdef __cplusplus
}
#endif
#endif
