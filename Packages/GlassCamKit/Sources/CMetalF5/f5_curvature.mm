#include "f5_curvature.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
struct Failure {
    int status;
    std::string message;
    int systemError = 0;
};
void record(gc_f5_curve_error *error, const Failure &failure) {
    if (!error) return;
    error->status = failure.status;
    error->system_error = failure.systemError;
    std::snprintf(error->message, sizeof(error->message), "%s", failure.message.c_str());
}
void check(bool condition, int status, const char *message) {
    if (!condition) throw Failure{status, message};
}
struct Parameters { simd_uint4 shape; simd_float4 policy; };
static_assert(sizeof(Parameters) == 32);
enum Kernel { forward, phases, normals, lowBand, colorPrior, solve, inversePatch32, inversePatch64, accumulate, normalize, kernelCount };
constexpr const char *kernelNames[] = {"f5_curve_forward", "f5_curve_phases", "f5_curve_normals", "f5_curve_low_band", "f5_curve_color_prior", "f5_curve_solve",
    "f5_curve_inverse_patch_32", "f5_curve_inverse_patch_64", "f5_curve_accumulate", "f5_curve_normalize"};

struct Workspace {
    id<MTLBuffer> samples, models, channels, means, precision, statistics, low, observations, phases, normals, spectrum, output, failure;
    id<MTLCommandBuffer> command;
    ~Workspace() { if (command && command.status != MTLCommandBufferStatusNotEnqueued) [command waitUntilCompleted]; }
};
}

struct gc_f5_curvature {
    gc_f5_curve_config config;
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLCommandQueue> queue;
    std::array<id<MTLComputePipelineState>, kernelCount> pipelines;
    std::vector<std::unique_ptr<Workspace>> work;
    id<MTLBuffer> ring, strip, outputFailure;
    uint64_t allocated = 0;

    id<MTLBuffer> allocate(size_t bytes, NSString *label, bool shared = false) {
        check(bytes && bytes <= device.maxBufferLength && bytes <= config.maximum_bytes - allocated,
              2, "Curvature allocation exceeds the declared working-set budget.");
        MTLResourceOptions options = shared ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate;
        id<MTLBuffer> value = [device newBufferWithLength:bytes options:options];
        check(value != nil, 2, "Cannot allocate a curvature GPU buffer.");
        value.label = label;
        allocated += value.length;
        return value;
    }

    gc_f5_curvature(const gc_f5_curve_config &c, void *metalDevice, void *metalLibrary) : config(c) {
        check((c.scale == 1 || c.scale == 2) && c.batch_capacity > 0 && c.batch_capacity <= 256 &&
              c.plane_capacity >= 4 && c.plane_capacity <= 28 && c.plane_capacity % 4 == 0 &&
              (c.slots == 1 || c.slots == 2) && c.automatic_color_prior <= 1 && c.width <= 16384 && c.height <= 16384 &&
              ((c.width == 0) == (c.height == 0)), 1, "Invalid curvature context dimensions.");
        device = (__bridge id<MTLDevice>)metalDevice;
        library = (__bridge id<MTLLibrary>)metalLibrary;
        check(device && library, 2, "Curvature Metal device or library is unavailable.");
        queue = [device newCommandQueue];
        check(queue != nil, 2, "Cannot create the curvature command queue.");
        queue.label = @"F5 C++ curvature";
        for (unsigned i = 0; i < kernelCount; ++i) {
            if (!c.width && i >= accumulate) break;
            if (!c.automatic_color_prior && (i == lowBand || i == colorPrior)) continue;
            if ((i == inversePatch32 && c.scale != 1) || (i == inversePatch64 && c.scale != 2)) continue;
            NSError *error = nil;
            id<MTLFunction> function = [library newFunctionWithName:[NSString stringWithUTF8String:kernelNames[i]]];
            check(function != nil, 2, "A curvature Metal function is missing.");
            pipelines[i] = [device newComputePipelineStateWithFunction:function error:&error];
            if (!pipelines[i]) throw Failure{2, error.localizedDescription.UTF8String ?: "Cannot create a curvature pipeline."};
        }
        const size_t b = c.batch_capacity, rows = b * c.plane_capacity, side = 32 * c.scale;
        for (unsigned i = 0; i < c.slots; ++i) {
            auto slot = std::make_unique<Workspace>();
            slot->samples = allocate(rows * 256 * sizeof(float), @"F5 CFA input", true);
            slot->models = allocate(rows * 16, @"F5 CFA observation models", true);
            slot->channels = allocate(rows * 4, @"F5 CFA channels", true);
            slot->means = allocate(b * 16, @"F5 camera means", true);
            slot->precision = allocate(b * 9 * 4, @"F5 colour precision", true);
            if (c.automatic_color_prior) {
                slot->statistics = allocate(b * 8 * 4, @"F5 guide signal and noise statistics", true);
                slot->low = allocate(b * 64 * 16, @"F5 aligned low-band colour samples");
            }
            slot->observations = allocate(rows * 256 * 8, @"F5 observed spectra");
            slot->phases = allocate(rows * 48 * 8, @"F5 phase factors");
            slot->normals = allocate(b * 4 * 48 * 8, @"F5 data normal blocks");
            slot->spectrum = allocate(b * 3 * 1024 * 8, @"F5 reconstructed spectra");
            slot->output = allocate(b * side * side * 16, @"F5 windowed RGB blocks", !c.width);
            slot->failure = allocate(16, @"F5 batch validation", true);
            work.push_back(std::move(slot));
        }
        if (c.width) {
            ring = allocate(size_t(c.width * c.scale) * (64 * c.scale) * 16, @"F5 curvature overlap rows");
            strip = allocate(size_t(c.width * c.scale) * (16 * c.scale) * 16, @"F5 curvature output strip", true);
            outputFailure = allocate(16, @"F5 overlap validation", true);
        }
    }

    gc_f5_curve_input input(uint32_t index) {
        auto &s = *work.at(index);
        return {static_cast<float *>(s.samples.contents), static_cast<float *>(s.models.contents),
                static_cast<float *>(s.means.contents), static_cast<float *>(s.precision.contents),
                config.automatic_color_prior ? static_cast<float *>(s.statistics.contents) : nullptr,
                static_cast<uint32_t *>(s.channels.contents), config.batch_capacity, config.plane_capacity, 0,
                (__bridge void *)s.samples, (__bridge void *)s.models, (__bridge void *)s.means,
                (__bridge void *)s.statistics, (__bridge void *)s.channels};
    }

    void validate(uint32_t index, uint32_t patches, uint32_t planes) {
        check(patches && patches <= config.batch_capacity && planes >= 4 && planes <= config.plane_capacity && planes % 4 == 0,
              1, "Invalid curvature batch dimensions.");
        const auto in = input(index);
        for (unsigned b = 0; b < patches; ++b) {
            for (unsigned c = 0; c < 3; ++c) check(std::isfinite(in.means[b * 4 + c]), 1, "Invalid curvature camera mean.");
            if (config.automatic_color_prior) {
                for (unsigned c = 0; c < 3; ++c) {
                    const float variance = in.statistics[b * 8 + c], noise = in.statistics[b * 8 + 4 + c];
                    check(std::isfinite(variance) && variance >= 0 && std::isfinite(noise) && noise > 0,
                          1, "Invalid curvature guide signal/noise statistics.");
                }
            } else {
                const float *a = in.precision + b * 9;
                double d[9], scale = 1;
                for (unsigned j = 0; j < 9; ++j) {
                    check(std::isfinite(a[j]), 1, "Non-finite curvature colour prior.");
                    d[j] = a[j]; scale = std::max(scale, std::abs(d[j]));
                }
                const double determinant = d[0] * (d[4] * d[8] - d[5] * d[7]) - d[1] * (d[3] * d[8] - d[5] * d[6])
                    + d[2] * (d[3] * d[7] - d[4] * d[6]);
                check(std::abs(d[1] - d[3]) <= scale * 1e-6 && std::abs(d[2] - d[6]) <= scale * 1e-6 &&
                      std::abs(d[5] - d[7]) <= scale * 1e-6 && d[0] > 0 && d[0] * d[4] - d[1] * d[3] > 0 && determinant > 0,
                      1, "Curvature colour precision must be symmetric positive definite.");
            }
            unsigned supported = 0;
            for (unsigned r = 0; r < planes; ++r) {
                const unsigned row = b * planes + r, channel = in.channels[row];
                const float *model = in.models + row * 4;
                check(channel < 3 && std::isfinite(model[0]) && std::isfinite(model[1]) && std::isfinite(model[2]) && model[2] > 0 &&
                      std::isfinite(model[3]) && model[3] >= 0 && model[3] <= 1, 1, "Invalid curvature CFA observation model.");
                if (model[3] > 0) supported |= 1u << channel;
            }
            check(supported == 7, 3, "Curvature observations do not support all colour channels.");
        }
    }

    void dispatch(id<MTLCommandBuffer> command, Kernel kernel, size_t groups, size_t threads,
                  std::initializer_list<id<MTLBuffer>> buffers, const void *parameters, size_t bytes) {
        auto pipeline = pipelines[kernel];
        check(threads <= pipeline.maxTotalThreadsPerThreadgroup, 2, "Invalid curvature GPU dispatch dimensions.");
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        check(encoder != nil, 2, "Cannot allocate a curvature compute encoder.");
        encoder.label = [NSString stringWithUTF8String:kernelNames[kernel]];
        [encoder setComputePipelineState:pipeline];
        unsigned index = 0;
        for (auto buffer : buffers) [encoder setBuffer:buffer offset:0 atIndex:index++];
        [encoder setBytes:parameters length:bytes atIndex:index];
        [encoder dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        [encoder endEncoding];
    }

    void retire(Workspace &s) {
        if (!s.command) return;
        check(s.command.status != MTLCommandBufferStatusNotEnqueued, 2, "Curvature command encoding did not complete.");
        [s.command waitUntilCompleted];
        check(s.command.status == MTLCommandBufferStatusCompleted, 3, s.command.error.localizedDescription.UTF8String ?: "Curvature GPU command failed.");
        const uint32_t failure = *static_cast<uint32_t *>(s.failure.contents);
        check(!(failure & 4), 1, "Non-finite curvature CFA observation.");
        check(failure == 0, 3, "Curvature Fourier reconstruction failed finite or positive-pivot checks.");
        s.command = nil;
    }

    void submit(uint32_t index, uint32_t patches, uint32_t planes, const gc_f5_curve_origin *origin = nullptr) {
        auto &s = *work.at(index);
        validate(index, patches, planes);
        *static_cast<uint32_t *>(s.failure.contents) = 0;
        const Parameters p{{patches, planes, config.scale, 0}, {3, 1e-5f, .1f, 4}};
        const size_t side = 32 * config.scale;
        s.command = [queue commandBuffer];
        check(s.command != nil, 2, "Cannot allocate a curvature command buffer.");
        s.command.label = @"F5 C++ Fourier reconstruction";
        dispatch(s.command, forward, patches * planes / 2, 128, {s.samples, s.models, s.observations, s.failure}, &p, sizeof(p));
        dispatch(s.command, phases, (patches * planes * 48 + 255) / 256, 256, {s.models, s.phases}, &p, sizeof(p));
        if (config.automatic_color_prior) {
            dispatch(s.command, lowBand, patches * 3, 128, {s.observations, s.models, s.channels, s.phases, s.low}, &p, sizeof(p));
            dispatch(s.command, colorPrior, (patches + 127) / 128, 128,
                     {s.low, s.statistics, s.models, s.channels, s.precision, s.failure}, &p, sizeof(p));
        }
        dispatch(s.command, normals, (patches * 4 * 48 + 255) / 256, 256, {s.models, s.channels, s.phases, s.normals}, &p, sizeof(p));
        dispatch(s.command, solve, patches, 256, {s.observations, s.models, s.channels, s.phases, s.normals,
            s.means, s.precision, s.spectrum, s.failure}, &p, sizeof(p));
        dispatch(s.command, config.scale == 1 ? inversePatch32 : inversePatch64, patches * 3, side * 4,
                 {s.spectrum, s.output, s.failure}, &p, sizeof(p));
        if (origin) {
            const simd_uint4 shape{config.width * config.scale, config.height * config.scale, config.scale, 64 * config.scale};
            const simd_int4 placement{origin->x, origin->y, int32_t(patches), 0};
            id<MTLComputeCommandEncoder> e = [s.command computeCommandEncoder];
            check(e != nil, 2, "Cannot encode curvature overlap-add.");
            [e setComputePipelineState:pipelines[accumulate]];
            [e setBuffer:s.output offset:0 atIndex:0]; [e setBuffer:ring offset:0 atIndex:1]; [e setBuffer:s.failure offset:0 atIndex:2];
            [e setBytes:&shape length:sizeof(shape) atIndex:3]; [e setBytes:&placement length:sizeof(placement) atIndex:4];
            [e dispatchThreadgroups:MTLSizeMake((size_t(shape.x) * side + 255) / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [e endEncoding];
        }
        [s.command commit];
    }

    void raster(int fd, const gc_f5_curve_callbacks &callbacks) {
        check(config.width && config.height && fd >= 0 && callbacks.prepare, 1, "Invalid curvature raster destination or provider.");
        const auto cancelled = [&] { if (callbacks.cancelled && callbacks.cancelled(callbacks.context)) throw Failure{4, "Curvature reconstruction cancelled."}; };
        cancelled();
        id<MTLCommandBuffer> clear = [queue commandBuffer];
        check(clear != nil, 2, "Cannot clear curvature overlap rows.");
        id<MTLBlitCommandEncoder> blit = [clear blitCommandEncoder];
        check(blit != nil, 2, "Cannot clear curvature overlap rows.");
        [blit fillBuffer:ring range:NSMakeRange(0, ring.length) value:0]; [blit endEncoding]; [clear commit];
        [clear waitUntilCompleted];
        check(clear.status == MTLCommandBufferStatusCompleted, 3, "Curvature overlap initialization failed.");
        *static_cast<uint32_t *>(outputFailure.contents) = 0;
        const simd_uint4 shape{config.width * config.scale, config.height * config.scale, config.scale, 64 * config.scale};
        uint32_t scheduled = 0, written = 0, pendingRows = 0, slotIndex = 0;
        struct PendingStrip {
            id<MTLCommandBuffer> command = nil;
            ~PendingStrip() { if (command && command.status != MTLCommandBufferStatusNotEnqueued) [command waitUntilCompleted]; }
        } pendingStrip;
        const auto retireStrip = [&] {
            if (!pendingStrip.command) return;
            [pendingStrip.command waitUntilCompleted];
            check(pendingStrip.command.status == MTLCommandBufferStatusCompleted, 3, "Curvature output normalization failed.");
            pendingStrip.command = nil;
            check(*static_cast<uint32_t *>(outputFailure.contents) == 0, 3, "Curvature overlap-add has missing or non-finite support.");
            cancelled();
            auto *cursor = static_cast<const uint8_t *>(strip.contents);
            size_t remaining = size_t(shape.x) * pendingRows * 16;
            while (remaining) {
                const ssize_t n = write(fd, cursor, remaining);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) throw Failure{5, "Cannot write curvature output strip.", n < 0 ? errno : EIO};
                cursor += n; remaining -= size_t(n);
            }
            written += pendingRows;
            pendingRows = 0;
        };
        const auto flush = [&](uint32_t end) {
            while (scheduled < end) {
                @autoreleasepool {
                    cancelled();
                    retireStrip();
                    const simd_uint2 rows{scheduled, std::min(16 * config.scale, end - scheduled)};
                    id<MTLCommandBuffer> command = [queue commandBuffer];
                    check(command != nil, 2, "Cannot normalize curvature output.");
                    id<MTLComputeCommandEncoder> e = [command computeCommandEncoder];
                    check(e != nil, 2, "Cannot normalize curvature output.");
                    [e setComputePipelineState:pipelines[normalize]];
                    [e setBuffer:ring offset:0 atIndex:0]; [e setBuffer:strip offset:0 atIndex:1]; [e setBuffer:outputFailure offset:0 atIndex:2];
                    [e setBytes:&shape length:sizeof(shape) atIndex:3]; [e setBytes:&rows length:sizeof(rows) atIndex:4];
                    [e dispatchThreadgroups:MTLSizeMake((size_t(shape.x) * rows.y + 255) / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                    [e endEncoding]; [command commit];
                    pendingStrip.command = command;
                    pendingRows = rows.y;
                    scheduled += rows.y;
                }
            }
        };
        std::vector<gc_f5_curve_origin> origins;
        origins.reserve(config.batch_capacity);
        for (int32_t top = -16; top <= int32_t(config.height) - 16; top += 16) {
            for (int32_t left = -16; left <= int32_t(config.width) - 16;) {
                @autoreleasepool {
                    cancelled();
                    auto &slot = *work[slotIndex]; retire(slot);
                    origins.clear();
                    while (origins.size() < config.batch_capacity && left <= int32_t(config.width) - 16) {
                        origins.push_back({left, top}); left += 16;
                    }
                    auto view = input(slotIndex);
                    const int result = callbacks.prepare(callbacks.context, origins.data(), uint32_t(origins.size()), &view);
                    if (result != 0) throw Failure{result == 4 ? 4 : 1, "Curvature observation provider failed."};
                    cancelled();
                    submit(slotIndex, uint32_t(origins.size()), view.plane_count, &origins.front());
                    slotIndex = (slotIndex + 1) % config.slots;
                }
            }
            flush(std::min(shape.y, uint32_t(std::max(0, top + 16)) * config.scale));
            if (callbacks.progress && scheduled < shape.y) callbacks.progress(callbacks.context, double(scheduled) / shape.y);
        }
        flush(shape.y);
        for (auto &slot : work) retire(*slot);
        retireStrip();
        cancelled();
        if (callbacks.progress) callbacks.progress(callbacks.context, 1);
    }
};

extern "C" gc_f5_curvature *gc_f5_curvature_create(const gc_f5_curve_config *config, void *device, void *library, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { check(config != nullptr, 1, "Missing curvature configuration."); return new gc_f5_curvature(*config, device, library); } }
    catch (const Failure &failure) { record(error, failure); }
    catch (const std::exception &failure) { record(error, {2, failure.what()}); }
    return nullptr;
}
extern "C" void gc_f5_curvature_destroy(gc_f5_curvature *context) { delete context; }
extern "C" uint64_t gc_f5_curvature_allocated_bytes(const gc_f5_curvature *context) { return context ? context->allocated : 0; }
extern "C" gc_f5_curve_input gc_f5_curvature_input(gc_f5_curvature *context, uint32_t slot) {
    return context && slot < context->work.size() ? context->input(slot) : gc_f5_curve_input{};
}
extern "C" int32_t gc_f5_curvature_solve(gc_f5_curvature *context, uint32_t patches, uint32_t planes, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { check(context && !context->config.width, 1, "A standalone curvature batch context is required."); context->retire(*context->work[0]);
        context->submit(0, patches, planes); context->retire(*context->work[0]); return 0; } }
    catch (const Failure &failure) { record(error, failure); return failure.status; }
    catch (const std::exception &failure) { record(error, {2, failure.what()}); return 2; }
}
extern "C" void *gc_f5_curvature_output(gc_f5_curvature *context) {
    return context && !context->config.width ? (__bridge void *)context->work[0]->output : nullptr;
}
extern "C" int32_t gc_f5_curvature_raster(gc_f5_curvature *context, int descriptor, const gc_f5_curve_callbacks *callbacks, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { check(context && callbacks, 1, "Missing curvature raster context."); context->raster(descriptor, *callbacks); return 0; } }
    catch (const Failure &failure) { record(error, failure); return failure.status; }
    catch (const std::exception &failure) { record(error, {2, failure.what()}); return 2; }
}
