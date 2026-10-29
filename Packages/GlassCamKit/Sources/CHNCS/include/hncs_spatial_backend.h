#ifndef GLASSCAM_HNCS_SPATIAL_BACKEND_H
#define GLASSCAM_HNCS_SPATIAL_BACKEND_H
#include "hncs_spatial.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Immutable tables built by the reference C++ kernel. All pointers are borrowed
 * for the duration of the call. The backend must preserve integer arithmetic,
 * replicated edges, Float32 work quantization and the final code/65535.f value. */
typedef struct hncs_sharpness_tables {
    const int32_t *amount; /* 16384 entries */
    const uint8_t *noise; /* 16384 entries */
    const uint32_t *weights;
    uint32_t count, weight_sum;
    int32_t enabled;
} hncs_sharpness_tables;

/* The seekable descriptor contains normalized, top-down packed Float32 RGB.
 * It is borrowed and flushed before this callback. Complete all asynchronous
 * access before returning. Return 0 on success, 1 to decline WITHOUT changing
 * the file, or the spatial API's negative error code. Partial errors must not
 * fall back to CPU processing. The caller discards failed temporary images. */
typedef int (*hncs_sharpness_backend_fn)(int descriptor, size_t width, size_t height,
    const hncs_sharpness_tables *tables, void *context);

int hncs_prepare_apple_hdr_spatial_file_with_backend(const char *path,
    size_t width, size_t height, const char *preset_key, int apply_grain,
    int apply_sharpness, double baseline_sharpness, double work_scale,
    const char *scratch_directory, hncs_spatial_cancel_fn cancelled,
    void *cancel_context, hncs_sharpness_backend_fn backend, void *backend_context);

#ifdef __cplusplus
}
#endif
#endif
