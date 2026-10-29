#ifndef GLASSCAM_METAL_SPATIAL_H
#define GLASSCAM_METAL_SPATIAL_H
#include <stddef.h>
#include "hncs_spatial.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct gc_metal_spatial gc_metal_spatial;
/* Loads the precompiled app library, or the packaged source for SwiftPM hosts.
 * Returns NULL if Metal is unavailable or initialization fails; error is an
 * optional, NUL-terminated diagnostic. The context is safe for concurrent jobs. */
gc_metal_spatial *gc_metal_spatial_create(const char *shader_path, char *error, size_t error_capacity);
void gc_metal_spatial_destroy(gc_metal_spatial *context);
/* Same input, result, cancellation and partial-failure contract as the native
 * HDR spatial API. Only native sharpness runs on Metal; normalization and grain
 * retain the exact C++ implementation. NULL context selects the CPU backend. */
int gc_metal_spatial_prepare_file(gc_metal_spatial *context, const char *path,
    size_t width, size_t height, const char *preset_key, int apply_grain,
    int apply_sharpness, double baseline_sharpness, double work_scale,
    const char *scratch_directory, hncs_spatial_cancel_fn cancelled, void *cancel_context);
#ifdef __cplusplus
}
#endif
#endif
