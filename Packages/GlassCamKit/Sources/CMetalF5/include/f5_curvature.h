#ifndef GLASSCAM_F5_CURVATURE_H
#define GLASSCAM_F5_CURVATURE_H

#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct gc_f5_curvature gc_f5_curvature;
typedef struct {
    uint32_t width, height, scale, batch_capacity, plane_capacity, slots;
    uint64_t maximum_bytes;
    uint32_t automatic_color_prior;
} gc_f5_curve_config;

typedef struct {
    // 0 success, 1 invalid input, 2 memory, 3 numerical, 4 cancellation, 5 I/O.
    int32_t status, system_error;
    char message[256];
} gc_f5_curve_error;

typedef struct { int32_t x, y; } gc_f5_curve_origin;
typedef struct {
    // CPU-writable shared inputs, packed at the actual returned plane_count.
    // A plane has 256 unwindowed samples and a four-float model x,y,var,weight.
    float *samples, *models, *means, *precision, *statistics;
    uint32_t *channels;
    uint32_t patch_capacity, plane_capacity, plane_count;
    // Borrowed MTLBuffer objects for a GPU producer. Valid until the owning
    // workspace is reused or destroyed; CPU and GPU access must not overlap.
    void *sample_buffer, *model_buffer, *mean_buffer, *statistics_buffer, *channel_buffer;
} gc_f5_curve_input;

typedef int32_t (*gc_f5_curve_prepare_fn)(void *, const gc_f5_curve_origin *, uint32_t, gc_f5_curve_input *);
typedef int32_t (*gc_f5_curve_cancel_fn)(void *);
typedef void (*gc_f5_curve_progress_fn)(void *, double);
typedef struct {
    void *context;
    gc_f5_curve_prepare_fn prepare;
    gc_f5_curve_cancel_fn cancelled;
    gc_f5_curve_progress_fn progress;
} gc_f5_curve_callbacks;

// The caller supplies borrowed Objective-C MTLDevice/MTLLibrary objects. The
// context retains them and owns all GPU workspaces until destroy returns.
gc_f5_curvature *gc_f5_curvature_create(const gc_f5_curve_config *, void *device, void *library, gc_f5_curve_error *);
void gc_f5_curvature_destroy(gc_f5_curvature *);
uint64_t gc_f5_curvature_allocated_bytes(const gc_f5_curvature *);
gc_f5_curve_input gc_f5_curvature_input(gc_f5_curvature *, uint32_t slot);

// One-batch output is a borrowed MTLBuffer retained by the context.
int32_t gc_f5_curvature_solve(gc_f5_curvature *, uint32_t patches, uint32_t planes, gc_f5_curve_error *);
void *gc_f5_curvature_output(gc_f5_curvature *);

// Owns patch iteration, two reusable workspaces, GPU overlap-add and bounded
// POSIX strip writes. The descriptor remains owned by the caller.
int32_t gc_f5_curvature_raster(gc_f5_curvature *, int descriptor, const gc_f5_curve_callbacks *, gc_f5_curve_error *);

typedef struct gc_f5_curve_source gc_f5_curve_source;
typedef struct {
    uint32_t width, height, frames, tile_size, flow_width, flow_height;
    uint32_t cfa[4]; // Camera RGB channels in physical Bayer order.
    float alpha[4], beta[4]; // Variance = alpha * max(camera mean, 0) + beta.
    uint64_t maximum_bytes;
} gc_f5_curve_source_config;

// Borrowed buffers contain frame-major normalized Bayer float32, reference-to-
// source float2 tile translations and half-density float32 reliability [0,1].
// Frame zero is the reference. The source retains these buffers. Only bounded
// guide rows and patch metadata are allocated; no full RGB guide is retained.
gc_f5_curve_source *gc_f5_curve_source_create(const gc_f5_curve_source_config *, void *device, void *library,
                                             void *raw, void *flow, void *reliability, gc_f5_curve_error *);
void gc_f5_curve_source_destroy(gc_f5_curve_source *);
uint64_t gc_f5_curve_source_allocated_bytes(const gc_f5_curve_source *);
int32_t gc_f5_curve_source_prepare(gc_f5_curve_source *, const gc_f5_curve_origin *, uint32_t,
                                  gc_f5_curve_input *, gc_f5_curve_error *);

typedef struct gc_f5_curve_raw gc_f5_curve_raw;
typedef struct { uint32_t width, height, frames; uint64_t maximum_bytes; } gc_f5_curve_raw_config;
gc_f5_curve_raw *gc_f5_curve_raw_create(const gc_f5_curve_raw_config *, void *device, void *library, gc_f5_curve_error *);
void gc_f5_curve_raw_destroy(gc_f5_curve_raw *);
uint64_t gc_f5_curve_raw_allocated_bytes(const gc_f5_curve_raw *);
// Uniforms use the validated 256-byte F5Frame layout shared with the event
// decoder. Integer codes remain untouched. Kind bytes preserve interval (0),
// upper/lower censoring (1/2) and invalid observations (3 or more).
int32_t gc_f5_curve_raw_decode(gc_f5_curve_raw *, uint32_t frame, void *raw, void *table,
                              const void *uniforms, uint32_t uniform_bytes, gc_f5_curve_error *);
void *gc_f5_curve_raw_values(gc_f5_curve_raw *);
void *gc_f5_curve_raw_kinds(gc_f5_curve_raw *);
int32_t gc_f5_curve_raw_repair(gc_f5_curve_raw *, gc_f5_curve_error *);

typedef struct gc_f5_curve_registration gc_f5_curve_registration;
typedef struct {
    uint32_t width, height, frames, cfa[4];
    float alpha[4], beta[4];
    uint64_t maximum_bytes;
} gc_f5_curve_registration_config;
gc_f5_curve_registration *gc_f5_curve_registration_create(const gc_f5_curve_registration_config *, void *device,
    void *library, void *raw, void *kinds, gc_f5_curve_error *);
void gc_f5_curve_registration_destroy(gc_f5_curve_registration *);
uint64_t gc_f5_curve_registration_allocated_bytes(const gc_f5_curve_registration *);
int32_t gc_f5_curve_registration_run(gc_f5_curve_registration *, const gc_f5_curve_callbacks *, gc_f5_curve_error *);
void *gc_f5_curve_registration_flow(gc_f5_curve_registration *);
void *gc_f5_curve_registration_reliability(gc_f5_curve_registration *);
void *gc_f5_curve_registration_summary(gc_f5_curve_registration *);

typedef struct gc_f5_curve_output gc_f5_curve_output;
typedef struct {
    uint32_t width, height, scale, output_width, output_height, operations;
    float crop_x, crop_y, camera_to_linear[9];
    uint64_t maximum_bytes;
} gc_f5_curve_output_config;
gc_f5_curve_output *gc_f5_curve_output_create(const gc_f5_curve_output_config *, void *device, void *library,
                                             void *operations, gc_f5_curve_error *);
void gc_f5_curve_output_destroy(gc_f5_curve_output *);
uint64_t gc_f5_curve_output_allocated_bytes(const gc_f5_curve_output *);
// Input is interleaved camera RGBAf at config.scale, before Stage3/WB. GPU
// pullback evaluates ordered post operations and the color matrix once. C++
// reads bounded source rectangles and writes top-to-bottom camera/linear rows.
int32_t gc_f5_curve_output_write(gc_f5_curve_output *, int input, int camera, int linear,
                                 const gc_f5_curve_callbacks *, gc_f5_curve_error *);

// Pack existing camera RGBAf into unchanged RGB float32 strips for LinearRaw
// DNG archival. No color, exposure, white balance or range operation is applied.
int32_t gc_f5_curve_write_rgb(int input, int output, uint32_t width, uint32_t height,
                             uint64_t output_offset, const gc_f5_curve_callbacks *, gc_f5_curve_error *);

#ifdef __cplusplus
}
#endif
#endif
