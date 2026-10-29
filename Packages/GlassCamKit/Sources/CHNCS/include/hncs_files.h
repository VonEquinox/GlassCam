#ifndef GLASSCAM_HNCS_FILES_H
#define GLASSCAM_HNCS_FILES_H
#include "hncs_c.h"
#include "hncs_spatial.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*hncs_file_progress_fn)(double fraction, void *context);
/* Complete normalized top-down RGB work -> top-down linear RGBA. The output
 * must be a distinct existing temporary file. Bounded native buffers invoke
 * the unchanged reference finish API. The maximum includes opaque alpha (1).
 * 0 success, -1 invalid input, -2 I/O/allocation failure, -3 cancellation.
 * On any error, discard the partial destination. No exception crosses C ABI. */
int hncs_finish_apple_hdr_work_file(const hncs_context *context,
    const char *work_path, const char *output_path, size_t pixels,
    double work_scale, unsigned workers, float *maximum,
    hncs_spatial_cancel_fn cancelled, hncs_file_progress_fn progress, void *callback_context);
#ifdef __cplusplus
}
#endif
#endif
