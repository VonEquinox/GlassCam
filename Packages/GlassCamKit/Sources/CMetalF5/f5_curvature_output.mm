#include "f5_curvature.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace {
struct OutputFailure { int status; const char *message; int code = 0; };
void require(bool ok, int status, const char *message) { if (!ok) throw OutputFailure{status, message}; }
void record(gc_f5_curve_error *error, const OutputFailure &e) {
    if (error) { error->status = e.status; error->system_error = e.code; std::snprintf(error->message, sizeof(error->message), "%s", e.message); }
}
struct OutputParameters { simd_uint4 shape, output, tile; simd_float4 crop; simd_int4 region; simd_float4 color[3]; };
static_assert(sizeof(OutputParameters) == 128);
constexpr unsigned stripRows = 16, tileWidth = 512;
void writeAll(int fd, const void *data, size_t bytes) {
    auto cursor = static_cast<const uint8_t *>(data);
    while (bytes) {
        ssize_t n = write(fd, cursor, bytes); if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw OutputFailure{5, "Cannot write curvature color output.", n < 0 ? errno : EIO};
        cursor += n; bytes -= size_t(n);
    }
}
void readAll(int fd, void *data, size_t bytes, off_t offset) {
    auto cursor = static_cast<uint8_t *>(data);
    while (bytes) {
        ssize_t n = pread(fd, cursor, bytes, offset); if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw OutputFailure{5, "Curvature source raster is incomplete.", n < 0 ? errno : EIO};
        cursor += n; bytes -= size_t(n); offset += n;
    }
}
}

struct gc_f5_curve_output {
    gc_f5_curve_output_config config;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> boundsPipeline, outputPipeline;
    id<MTLBuffer> operations, input, camera, linear, bounds, failure;
    uint64_t allocated = 0;
    bool warped = false;
    id<MTLBuffer> allocate(size_t bytes, NSString *label) {
        require(bytes && bytes <= device.maxBufferLength && bytes <= config.maximum_bytes - allocated, 2, "Curvature color output exceeds the working-set budget.");
        auto value = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        require(value != nil, 2, "Cannot allocate curvature color output.");
        value.label = label; allocated += value.length; return value;
    }
    gc_f5_curve_output(const gc_f5_curve_output_config &c, void *d, void *l, void *o) : config(c) {
        require(c.width && c.height && c.width <= 16384 && c.height <= 16384 && (c.scale == 1 || c.scale == 2) &&
                c.output_width && c.output_height && c.output_width <= 32768 && c.output_height <= 32768 && c.operations <= 8 &&
                std::isfinite(c.crop_x) && std::isfinite(c.crop_y) && c.crop_x >= 0 && c.crop_y >= 0 &&
                c.crop_x + double(c.output_width) / c.scale <= c.width && c.crop_y + double(c.output_height) / c.scale <= c.height,
                1, "Invalid curvature color output dimensions.");
        for (float value : c.camera_to_linear) require(std::isfinite(value), 1, "Invalid curvature camera color matrix.");
        device = (__bridge id<MTLDevice>)d; id<MTLLibrary> library = (__bridge id<MTLLibrary>)l; operations = (__bridge id<MTLBuffer>)o;
        require(device && library && operations && operations.device == device && operations.length >= size_t(c.operations) * 128,
                1, "Curvature post-operation buffer is incomplete.");
        require(operations.storageMode == MTLStorageModeShared, 1, "Curvature post operations must be CPU-readable.");
        const auto records = static_cast<const uint32_t *>(operations.contents);
        for (unsigned i = 0; i < c.operations; ++i) {
            const uint32_t kind = records[i * 32 + 28];
            require(kind == 1 || kind == 9, 1, "Unsupported curvature post operation."); warped |= kind == 1;
        }
        queue = [device newCommandQueue]; require(queue != nil, 2, "Cannot create curvature output queue.");
        NSError *error = nil;
        auto boundsFunction = [library newFunctionWithName:@"f5_curve_output_bounds"], outputFunction = [library newFunctionWithName:@"f5_curve_output_tile"];
        require(boundsFunction && outputFunction, 2, "A curvature output Metal function is missing.");
        boundsPipeline = [device newComputePipelineStateWithFunction:boundsFunction error:&error];
        outputPipeline = [device newComputePipelineStateWithFunction:outputFunction error:&error];
        require(boundsPipeline && outputPipeline && boundsPipeline.maxTotalThreadsPerThreadgroup >= 128 && outputPipeline.maxTotalThreadsPerThreadgroup >= 128,
                2, "Cannot create curvature output pipelines.");
        input = allocate(16 * 1024 * 1024, @"F5 bounded post-warp source rectangle");
        camera = allocate(size_t(c.output_width) * stripRows * 16, @"F5 post-warp camera rows");
        linear = allocate(camera.length, @"F5 post-color linear rows");
        bounds = allocate(16, @"F5 post-warp source bounds"); failure = allocate(16, @"F5 post-color validation");
    }
    void run(int source, int cameraFD, int linearFD, const gc_f5_curve_callbacks *callbacks) {
        require(source >= 0 && cameraFD >= 0 && linearFD >= 0 && source != cameraFD && source != linearFD && cameraFD != linearFD,
                1, "Invalid curvature output descriptors.");
        struct stat status{};
        if (fstat(source, &status) != 0) throw OutputFailure{5, "Cannot inspect curvature source raster.", errno};
        require(status.st_size >= off_t(config.width) * config.height * config.scale * config.scale * 16,
                1, "Curvature source raster has incorrect dimensions.");
        const auto cancelled = [&] { if (callbacks && callbacks->cancelled && callbacks->cancelled(callbacks->context)) throw OutputFailure{4, "Curvature color output cancelled."}; };
        cancelled();
        OutputParameters p{{config.width * config.scale, config.height * config.scale, config.scale, config.operations},
            {config.output_width, config.output_height, 0, 0}, {}, {config.crop_x, config.crop_y, 0, 0}, {}, {}};
        for (unsigned c = 0; c < 3; ++c) p.color[c] = {config.camera_to_linear[c * 3], config.camera_to_linear[c * 3 + 1], config.camera_to_linear[c * 3 + 2], 0};
        for (unsigned top = 0; top < config.output_height; top += stripRows) {
            const unsigned rows = std::min(stripRows, config.output_height - top);
            const unsigned span = warped ? tileWidth : config.output_width;
            for (unsigned left = 0; left < config.output_width; left += span) {
                @autoreleasepool {
                    cancelled(); p.output.z = left; p.output.w = top; p.tile = {std::min(span, config.output_width - left), rows, top, 0};
                    auto *rect = static_cast<int32_t *>(bounds.contents); rect[0] = rect[1] = INT32_MAX; rect[2] = rect[3] = INT32_MIN;
                    *static_cast<uint32_t *>(failure.contents) = 0;
                    id<MTLCommandBuffer> command;
                    id<MTLComputeCommandEncoder> encoder;
                    if (warped) {
                        command = [queue commandBuffer]; require(command != nil, 2, "Cannot allocate curvature output-bounds command.");
                        encoder = [command computeCommandEncoder]; require(encoder != nil, 2, "Cannot encode curvature output bounds.");
                        [encoder setComputePipelineState:boundsPipeline]; [encoder setBuffer:operations offset:0 atIndex:0];
                        [encoder setBuffer:bounds offset:0 atIndex:1]; [encoder setBuffer:failure offset:0 atIndex:2]; [encoder setBytes:&p length:sizeof(p) atIndex:3];
                        [encoder dispatchThreadgroups:MTLSizeMake((size_t(p.tile.x) * rows + 127) / 128, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
                        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
                        require(command.status == MTLCommandBufferStatusCompleted && *static_cast<uint32_t *>(failure.contents) == 0,
                                3, "Curvature post-warp sampling left valid support.");
                    } else {
                        const auto coordinate = [&](float crop, unsigned pixel, unsigned length) {
                            const float point = crop + (float(pixel) + 0.5f) / config.scale;
                            return int(std::floor(std::clamp(point * config.scale - 0.5f, 0.0f, float(length - 1))));
                        };
                        rect[0] = coordinate(config.crop_x, left, p.shape.x); rect[1] = coordinate(config.crop_y, top, p.shape.y);
                        rect[2] = std::min(int(p.shape.x) - 1, coordinate(config.crop_x, left + p.tile.x - 1, p.shape.x) + 1);
                        rect[3] = std::min(int(p.shape.y) - 1, coordinate(config.crop_y, top + rows - 1, p.shape.y) + 1);
                    }
                    p.region = {rect[0], rect[1], rect[2] - rect[0] + 1, rect[3] - rect[1] + 1};
                    const size_t rowBytes = size_t(p.region.z) * 16, bytes = rowBytes * p.region.w;
                    require(p.region.x >= 0 && p.region.y >= 0 && p.region.z > 0 && p.region.w > 0 &&
                            p.region.x + p.region.z <= int(p.shape.x) && p.region.y + p.region.w <= int(p.shape.y), 3, "Invalid curvature output source rectangle.");
                    require(bytes <= input.length, 2, "Curvature warp exceeds the bounded source rectangle.");
                    for (int y = 0; y < p.region.w; ++y) {
                        cancelled(); readAll(source, static_cast<uint8_t *>(input.contents) + y * rowBytes, rowBytes,
                            (off_t(p.region.y + y) * p.shape.x + p.region.x) * 16);
                    }
                    command = [queue commandBuffer]; require(command != nil, 2, "Cannot allocate curvature color command.");
                    encoder = [command computeCommandEncoder]; require(encoder != nil, 2, "Cannot encode curvature color output.");
                    [encoder setComputePipelineState:outputPipeline];
                    [encoder setBuffer:input offset:0 atIndex:0]; [encoder setBuffer:operations offset:0 atIndex:1];
                    [encoder setBuffer:camera offset:0 atIndex:2]; [encoder setBuffer:linear offset:0 atIndex:3];
                    [encoder setBuffer:failure offset:0 atIndex:4]; [encoder setBytes:&p length:sizeof(p) atIndex:5];
                    [encoder dispatchThreadgroups:MTLSizeMake((size_t(p.tile.x) * rows + 127) / 128, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
                    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
                    require(command.status == MTLCommandBufferStatusCompleted && *static_cast<uint32_t *>(failure.contents) == 0,
                            3, "Nonfinite curvature camera or linear color output.");
                }
            }
            cancelled(); writeAll(cameraFD, camera.contents, size_t(config.output_width) * rows * 16);
            writeAll(linearFD, linear.contents, size_t(config.output_width) * rows * 16);
            if (callbacks && callbacks->progress) callbacks->progress(callbacks->context, double(top + rows) / config.output_height);
        }
        cancelled();
    }
};
extern "C" gc_f5_curve_output *gc_f5_curve_output_create(const gc_f5_curve_output_config *c, void *d, void *l, void *o, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(c != nullptr, 1, "Missing curvature output configuration."); return new gc_f5_curve_output(*c, d, l, o); } }
    catch (const OutputFailure &e) { record(error, e); }
    catch (const std::bad_alloc &) { record(error, {2, "Cannot allocate curvature output context."}); }
    catch (const std::exception &e) { record(error, {1, e.what()}); }
    return nullptr;
}
extern "C" void gc_f5_curve_output_destroy(gc_f5_curve_output *context) { delete context; }
extern "C" uint64_t gc_f5_curve_output_allocated_bytes(const gc_f5_curve_output *context) { return context ? context->allocated : 0; }
extern "C" int32_t gc_f5_curve_output_write(gc_f5_curve_output *context, int source, int camera, int linear, const gc_f5_curve_callbacks *callbacks, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(context != nullptr, 1, "Missing curvature output context."); context->run(source, camera, linear, callbacks); return 0; } }
    catch (const OutputFailure &e) { record(error, e); return e.status; }
    catch (const std::bad_alloc &) { record(error, {2, "Cannot allocate curvature output metadata."}); return 2; }
    catch (const std::exception &e) { record(error, {1, e.what()}); return 1; }
}
