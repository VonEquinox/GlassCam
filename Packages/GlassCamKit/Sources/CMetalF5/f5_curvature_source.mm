#include "f5_curvature.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>

namespace {
struct SourceFailure { int status; const char *message; };
void require(bool condition, int status, const char *message) { if (!condition) throw SourceFailure{status, message}; }
void fail(gc_f5_curve_error *error, int status, const char *message) {
    if (error) { error->status = status; error->system_error = 0; std::snprintf(error->message, sizeof(error->message), "%s", message); }
}
int mirror(int p, int n) { const int period = 2 * n - 2; p %= period; if (p < 0) p += period; return std::min(p, period - p); }
struct SourceParameters {
    simd_uint4 shape, grid, cfa;
    simd_float4 alpha, beta;
    simd_int4 rows;
};
static_assert(sizeof(SourceParameters) == 96);
constexpr const char *names[] = {"f5_curve_temporal_rows", "f5_curve_guide_rows", "f5_curve_gradient_horizontal",
    "f5_curve_gradient_rows", "f5_curve_patch_statistics", "f5_curve_gather_planes"};
}

struct gc_f5_curve_source {
    gc_f5_curve_source_config config;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLBuffer> raw, flow, reliability, mosaic, guide, horizontal, gradient, origins, offsets, failure;
    std::array<id<MTLComputePipelineState>, 6> pipelines;
    uint64_t allocated = 0;
    int cachedTop = std::numeric_limits<int>::min();
    int mosaicTop = 0, mosaicCount = 0;

    id<MTLBuffer> allocate(size_t bytes, bool shared, NSString *label) {
        require(bytes && bytes <= device.maxBufferLength && bytes <= config.maximum_bytes - allocated,
                2, "Curvature guide allocation exceeds the working-set budget.");
        auto value = [device newBufferWithLength:bytes options:shared ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];
        require(value != nil, 2, "Cannot allocate curvature guide rows.");
        value.label = label; allocated += value.length; return value;
    }

    gc_f5_curve_source(const gc_f5_curve_source_config &c, void *d, void *l, void *r, void *f, void *w) : config(c) {
        require(c.width >= 4 && c.height >= 4 && c.width <= 16384 && c.height <= 16384 &&
                !(c.width % 2) && !(c.height % 2) && c.frames >= 1 && c.frames <= 7 &&
                c.tile_size >= 2 && c.tile_size <= 256 && c.flow_width == (c.width + c.tile_size - 1) / c.tile_size &&
                c.flow_height == (c.height + c.tile_size - 1) / c.tile_size, 1, "Invalid curvature Bayer source dimensions.");
        unsigned counts[3] = {};
        for (unsigned p = 0; p < 4; ++p) {
            require(c.cfa[p] < 3 && std::isfinite(c.alpha[p]) && c.alpha[p] >= 0 && std::isfinite(c.beta[p]) && c.beta[p] > 0,
                    1, "Invalid curvature Bayer noise model.");
            ++counts[c.cfa[p]];
        }
        require(counts[0] == 1 && counts[1] == 2 && counts[2] == 1 && c.cfa[0] != c.cfa[1] && c.cfa[0] != c.cfa[2] &&
                c.cfa[1] != c.cfa[3] && c.cfa[2] != c.cfa[3], 1, "Curvature source requires a Bayer CFA.");
        device = (__bridge id<MTLDevice>)d;
        id<MTLLibrary> library = (__bridge id<MTLLibrary>)l;
        raw = (__bridge id<MTLBuffer>)r; flow = (__bridge id<MTLBuffer>)f; reliability = (__bridge id<MTLBuffer>)w;
        require(device && library && raw && flow && reliability && raw.device == device && flow.device == device && reliability.device == device,
                1, "Curvature source buffers belong to a different Metal device.");
        require(raw.length >= size_t(c.frames) * c.width * c.height * 4 &&
                flow.length >= size_t(c.frames) * c.flow_width * c.flow_height * 8 &&
                reliability.length >= size_t(c.frames) * (c.width / 2) * (c.height / 2) * 4,
                1, "Curvature source buffers are incomplete.");
        queue = [device newCommandQueue]; require(queue != nil, 2, "Cannot create curvature guide queue.");
        queue.label = @"F5 C++ Bayer preparation";
        for (unsigned i = 0; i < pipelines.size(); ++i) {
            auto function = [library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
            require(function != nil, 2, "A curvature guide Metal function is missing.");
            NSError *error = nil; pipelines[i] = [device newComputePipelineStateWithFunction:function error:&error];
            require(pipelines[i] != nil && pipelines[i].maxTotalThreadsPerThreadgroup >= 128, 2, "Cannot create curvature guide pipeline.");
        }
        mosaic = allocate(size_t(c.width) * 48 * 4, false, @"F5 temporal mosaic rows");
        guide = allocate(size_t(c.width) * 40 * 16, false, @"F5 temporal MHC guide rows");
        horizontal = allocate(size_t(c.width) * 40 * 8, false, @"F5 Gaussian gradient rows");
        gradient = allocate(size_t(c.width) * 32 * 4, false, @"F5 guide gradient energy");
        origins = allocate(256 * 8, true, @"F5 Bayer patch origins");
        offsets = allocate(size_t(256) * c.frames * 8, false, @"F5 even CFA source offsets");
        failure = allocate(16, true, @"F5 Bayer preparation validation");
    }

    void encode(id<MTLCommandBuffer> command, unsigned kernel, size_t groups, size_t threads,
                std::initializer_list<id<MTLBuffer>> buffers, const SourceParameters &p) {
        auto encoder = [command computeCommandEncoder]; require(encoder != nil, 2, "Cannot encode curvature guide rows.");
        encoder.label = [NSString stringWithUTF8String:names[kernel]];
        [encoder setComputePipelineState:pipelines[kernel]];
        unsigned index = 0; for (auto buffer : buffers) [encoder setBuffer:buffer offset:0 atIndex:index++];
        [encoder setBytes:&p length:sizeof(p) atIndex:index];
        [encoder dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        [encoder endEncoding];
    }

    void prepare(const gc_f5_curve_origin *positions, uint32_t count, gc_f5_curve_input &input) {
        require(positions && count && count <= 256 && count <= input.patch_capacity && config.frames * 4 <= input.plane_capacity,
                1, "Invalid curvature Bayer patch batch.");
        const int top = positions[0].y;
        for (unsigned i = 0; i < count; ++i)
            require(positions[i].y == top && positions[i].x >= -16 && positions[i].x <= int(config.width) - 16 &&
                    !(positions[i].x % 16) && top >= -16 && top <= int(config.height) - 16 && !(top % 16),
                    1, "Curvature Bayer patches must share one valid row.");
        id<MTLBuffer> samples = (__bridge id<MTLBuffer>)input.sample_buffer, models = (__bridge id<MTLBuffer>)input.model_buffer;
        id<MTLBuffer> means = (__bridge id<MTLBuffer>)input.mean_buffer, statistics = (__bridge id<MTLBuffer>)input.statistics_buffer;
        id<MTLBuffer> channels = (__bridge id<MTLBuffer>)input.channel_buffer;
        const size_t rows = size_t(count) * config.frames * 4;
        require(samples && models && means && statistics && channels && samples.device == device && models.device == device &&
                means.device == device && statistics.device == device && channels.device == device &&
                samples.length >= rows * 256 * 4 && models.length >= rows * 16 && means.length >= count * 16 &&
                statistics.length >= count * 32 && channels.length >= rows * 4, 1, "Curvature Bayer output buffers are incomplete.");
        std::memcpy(origins.contents, positions, count * sizeof(*positions));
        *static_cast<uint32_t *>(failure.contents) = 0;
        if (top != cachedTop) {
            int low = int(config.height), high = 0;
            for (int y = top - 4; y < top + 36; ++y) { const int physical = mirror(y, config.height); low = std::min(low, physical); high = std::max(high, physical); }
            mosaicTop = std::max(0, low - 2); mosaicCount = std::min(int(config.height), high + 3) - mosaicTop;
            require(mosaicCount <= 48, 1, "Curvature guide row range is too large.");
        }
        SourceParameters p{{config.width, config.height, config.frames, config.tile_size},
            {config.flow_width, config.flow_height, count, 0}, {}, {}, {}, {mosaicTop, mosaicCount, top, int(count)}};
        std::memcpy(&p.cfa, config.cfa, 16); std::memcpy(&p.alpha, config.alpha, 16); std::memcpy(&p.beta, config.beta, 16);
        auto command = [queue commandBuffer]; require(command != nil, 2, "Cannot allocate curvature Bayer command.");
        if (top != cachedTop) {
            encode(command, 0, (size_t(config.width) * mosaicCount + 127) / 128, 128, {raw, flow, reliability, mosaic, failure}, p);
            encode(command, 1, (size_t(config.width) * 40 + 127) / 128, 128, {mosaic, guide}, p);
            encode(command, 2, (size_t(config.width) * 40 + 127) / 128, 128, {guide, horizontal}, p);
            encode(command, 3, (size_t(config.width) * 32 + 127) / 128, 128, {horizontal, gradient}, p);
        }
        encode(command, 4, count, 128, {guide, gradient, flow, reliability, origins, means, statistics, models, channels, offsets, failure}, p);
        encode(command, 5, (rows * 256 + 127) / 128, 128, {raw, origins, offsets, samples, failure}, p);
        [command commit]; [command waitUntilCompleted];
        require(command.status == MTLCommandBufferStatusCompleted, 3, "Curvature Bayer preparation GPU command failed.");
        require(*static_cast<uint32_t *>(failure.contents) == 0, 1, "Invalid or unsupported curvature Bayer observations.");
        cachedTop = top; input.plane_count = config.frames * 4;
    }
};

extern "C" gc_f5_curve_source *gc_f5_curve_source_create(const gc_f5_curve_source_config *c, void *d, void *l, void *r, void *f, void *w, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(c != nullptr, 1, "Missing curvature Bayer source configuration."); return new gc_f5_curve_source(*c, d, l, r, f, w); } }
    catch (const SourceFailure &e) { fail(error, e.status, e.message); }
    catch (const std::bad_alloc &) { fail(error, 2, "Cannot allocate curvature Bayer source."); }
    catch (const std::exception &e) { fail(error, 1, e.what()); }
    return nullptr;
}
extern "C" void gc_f5_curve_source_destroy(gc_f5_curve_source *source) { delete source; }
extern "C" uint64_t gc_f5_curve_source_allocated_bytes(const gc_f5_curve_source *source) { return source ? source->allocated : 0; }
extern "C" int32_t gc_f5_curve_source_prepare(gc_f5_curve_source *source, const gc_f5_curve_origin *origins, uint32_t count, gc_f5_curve_input *input, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(source && input, 1, "Missing curvature Bayer preparation context."); source->prepare(origins, count, *input); return 0; } }
    catch (const SourceFailure &e) { fail(error, e.status, e.message); return e.status; }
    catch (const std::bad_alloc &) { fail(error, 2, "Cannot allocate curvature Bayer patch metadata."); return 2; }
    catch (const std::exception &e) { fail(error, 1, e.what()); return 1; }
}

namespace {
struct RawFrame {
    simd_uint4 shape, active, cfa;
    simd_float4 scale, kappa, readSigma, low, high, gain, blackResidual;
    simd_uint4 censorLow, censorHigh, black, tables, extras, extra2;
};
static_assert(sizeof(RawFrame) == 256);
}
struct gc_f5_curve_raw {
    gc_f5_curve_raw_config config;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline, repairPipeline;
    id<MTLBuffer> values, kinds, failure, repairScratch;
    uint64_t allocated = 0;
    gc_f5_curve_raw(const gc_f5_curve_raw_config &c, void *d, void *l) : config(c) {
        require(c.width >= 4 && c.height >= 4 && c.width <= 16384 && c.height <= 16384 && c.frames >= 1 && c.frames <= 7,
                1, "Invalid curvature RAW dimensions.");
        device = (__bridge id<MTLDevice>)d; id<MTLLibrary> library = (__bridge id<MTLLibrary>)l;
        require(device && library, 2, "Curvature RAW Metal device or library is missing.");
        const size_t pixels = size_t(c.width) * c.height * c.frames;
        require(pixels * 4 <= device.maxBufferLength && pixels * 5 + size_t(c.width) * c.height * 4 + 16 <= c.maximum_bytes, 2, "Curvature RAW exceeds the working-set budget.");
        values = [device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
        kinds = [device newBufferWithLength:pixels options:MTLResourceStorageModeShared];
        failure = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        repairScratch = [device newBufferWithLength:size_t(c.width) * c.height * 4 options:MTLResourceStorageModePrivate];
        require(values && kinds && failure && repairScratch, 2, "Cannot allocate curvature RAW observations.");
        allocated = values.length + kinds.length + failure.length + repairScratch.length;
        values.label = @"F5 normalized Bayer values"; kinds.label = @"F5 preserved RAW event kinds";
        queue = [device newCommandQueue]; require(queue != nil, 2, "Cannot create curvature RAW queue.");
        auto function = [library newFunctionWithName:@"f5_curve_decode_raw"];
        require(function != nil, 2, "Curvature RAW decode Metal function is missing.");
        NSError *error = nil; pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        require(pipeline != nil, 2, "Cannot create curvature RAW decode pipeline.");
        function = [library newFunctionWithName:@"f5_curve_repair_raw"];
        require(function != nil, 2, "Bayer bad-pixel repair Metal function is missing.");
        repairPipeline = [device newComputePipelineStateWithFunction:function error:&error];
        require(repairPipeline != nil, 2, "Cannot create Bayer bad-pixel repair pipeline.");
    }
    void decode(uint32_t index, void *r, void *t, const void *u, uint32_t bytes) {
        require(index < config.frames && u && bytes == sizeof(RawFrame), 1, "Invalid curvature RAW frame layout.");
        RawFrame f; std::memcpy(&f, u, sizeof(f));
        id<MTLBuffer> raw = (__bridge id<MTLBuffer>)r, table = (__bridge id<MTLBuffer>)t;
        require(raw && table && raw.device == device && table.device == device && f.active.z == config.width && f.active.w == config.height &&
                f.shape.x > 0 && f.shape.y > 0 && f.shape.z >= f.shape.x && f.active.x <= f.shape.x && f.active.y <= f.shape.y &&
                f.active.z <= f.shape.x - f.active.x && f.active.w <= f.shape.y - f.active.y &&
                raw.length >= size_t(f.shape.z) * f.shape.y * 2 && f.black.x && f.black.y && f.extra2.w &&
                std::isfinite(f.scale.x) && f.scale.x > 0 && std::isfinite(f.scale.y) && f.scale.y > 0,
                1, "Invalid curvature integer RAW buffers or scale.");
        require(std::isfinite(f.scale.z) && std::isfinite(f.scale.w) && f.scale.w >= f.scale.z, 1, "Invalid curvature RAW code range.");
        for (unsigned phase = 0; phase < 4; ++phase)
            require(f.cfa[phase] < 4 && std::isfinite(f.gain[phase]) && f.gain[phase] > 0 && std::isfinite(f.kappa[phase]) && f.kappa[phase] >= 0 &&
                    std::isfinite(f.readSigma[phase]) && f.readSigma[phase] > 0 && std::isfinite(f.low[phase]) && std::isfinite(f.high[phase]) &&
                    std::isfinite(f.blackResidual[phase]), 1, "Invalid curvature RAW phase calibration.");
        const size_t n = table.length / 4;
        const auto range = [n](uint32_t offset, size_t count) { return offset <= n && count <= n - offset; };
        require(range(f.black.z, size_t(f.black.x) * f.black.y) &&
                (f.black.w == UINT32_MAX || range(f.black.w, config.width)) && (f.tables.x == UINT32_MAX || range(f.tables.x, config.height)) &&
                range(f.tables.y, f.tables.z) && range(f.extras.x, size_t(f.tables.w) * 16) && range(f.extras.y, f.extras.z) &&
                range(f.extras.w, f.extra2.x) && range(f.extra2.y, size_t(f.extra2.z) * 4), 1, "Curvature RAW metadata tables are incomplete.");
        // Gain-map payload offsets are integer bit patterns in validated tables.
        require(table.storageMode == MTLStorageModeShared, 1, "Curvature RAW metadata must be CPU-readable.");
        const float *data = static_cast<const float *>(table.contents);
        for (unsigned j = 0; j < f.tables.w; ++j) {
            const float *gain = data + f.extras.x + j * 16; uint32_t offset; std::memcpy(&offset, gain + 12, 4);
            require(std::isfinite(gain[6]) && std::isfinite(gain[7]) && gain[6] >= 1 && gain[6] <= 1024 && gain[7] >= 1 && gain[7] <= 1024 &&
                    range(offset, size_t(gain[6]) * size_t(gain[7])), 1, "Curvature RAW gain-map payload is incomplete.");
        }
        *static_cast<uint32_t *>(failure.contents) = 0;
        auto command = [queue commandBuffer]; require(command != nil, 2, "Cannot allocate curvature RAW command.");
        auto encoder = [command computeCommandEncoder]; require(encoder != nil, 2, "Cannot encode curvature RAW decode.");
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:raw offset:0 atIndex:0]; [encoder setBuffer:table offset:0 atIndex:1];
        [encoder setBuffer:values offset:size_t(index) * config.width * config.height * 4 atIndex:2];
        [encoder setBuffer:kinds offset:0 atIndex:3]; [encoder setBuffer:failure offset:0 atIndex:4];
        [encoder setBytes:&f length:sizeof(f) atIndex:5];
        const uint32_t kindOffset = index * config.width * config.height;
        [encoder setBytes:&kindOffset length:4 atIndex:6];
        const size_t threads = std::min<size_t>(256, pipeline.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreadgroups:MTLSizeMake((size_t(config.width) * config.height + threads - 1) / threads, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        require(command.status == MTLCommandBufferStatusCompleted, 3, "Curvature RAW GPU decode failed.");
        require(*static_cast<uint32_t *>(failure.contents) == 0, 1, "Nonfinite curvature RAW normalization.");
    }
    void repair() {
        require(repairScratch != nil, 1, "Bayer bad-pixel repair has already completed.");
        *static_cast<uint32_t *>(failure.contents) = 0;
        auto command = [queue commandBuffer]; require(command != nil, 2, "Cannot allocate Bayer repair command.");
        for (unsigned frame = 0; frame < config.frames; ++frame) {
            auto encoder = [command computeCommandEncoder]; require(encoder != nil, 2, "Cannot encode Bayer repair.");
            const simd_uint4 shape{config.width, config.height, frame, config.frames};
            [encoder setComputePipelineState:repairPipeline]; [encoder setBuffer:values offset:0 atIndex:0];
            [encoder setBuffer:kinds offset:0 atIndex:1]; [encoder setBuffer:repairScratch offset:0 atIndex:2];
            [encoder setBuffer:failure offset:0 atIndex:3]; [encoder setBytes:&shape length:sizeof(shape) atIndex:4];
            [encoder dispatchThreadgroups:MTLSizeMake((size_t(config.width) * config.height + 255) / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
            [encoder endEncoding];
            auto blit = [command blitCommandEncoder]; require(blit != nil, 2, "Cannot retain repaired Bayer values.");
            [blit copyFromBuffer:repairScratch sourceOffset:0 toBuffer:values destinationOffset:size_t(frame)*config.width*config.height*4 size:repairScratch.length];
            [blit endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        require(command.status == MTLCommandBufferStatusCompleted, 3, "Bayer bad-pixel repair GPU command failed.");
        require(*static_cast<uint32_t *>(failure.contents) == 0, 1, "A damaged sensor area has no valid same-color neighbors.");
        allocated -= repairScratch.length; repairScratch = nil;
    }
};
extern "C" gc_f5_curve_raw *gc_f5_curve_raw_create(const gc_f5_curve_raw_config *c, void *d, void *l, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(c != nullptr, 1, "Missing curvature RAW configuration."); return new gc_f5_curve_raw(*c, d, l); } }
    catch (const SourceFailure &e) { fail(error, e.status, e.message); }
    catch (const std::bad_alloc &) { fail(error, 2, "Cannot allocate curvature RAW context."); }
    catch (const std::exception &e) { fail(error, 1, e.what()); }
    return nullptr;
}
extern "C" void gc_f5_curve_raw_destroy(gc_f5_curve_raw *raw) { delete raw; }
extern "C" uint64_t gc_f5_curve_raw_allocated_bytes(const gc_f5_curve_raw *raw) { return raw ? raw->allocated : 0; }
extern "C" int32_t gc_f5_curve_raw_decode(gc_f5_curve_raw *raw, uint32_t index, void *r, void *t, const void *u, uint32_t bytes, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(raw != nullptr, 1, "Missing curvature RAW context."); raw->decode(index, r, t, u, bytes); return 0; } }
    catch (const SourceFailure &e) { fail(error, e.status, e.message); return e.status; }
    catch (const std::bad_alloc &) { fail(error, 2, "Cannot allocate curvature RAW decode metadata."); return 2; }
    catch (const std::exception &e) { fail(error, 1, e.what()); return 1; }
}
extern "C" void *gc_f5_curve_raw_values(gc_f5_curve_raw *raw) { return raw ? (__bridge void *)raw->values : nullptr; }
extern "C" void *gc_f5_curve_raw_kinds(gc_f5_curve_raw *raw) { return raw ? (__bridge void *)raw->kinds : nullptr; }
extern "C" int32_t gc_f5_curve_raw_repair(gc_f5_curve_raw *raw, gc_f5_curve_error *error) {
    if (error) *error = {};
    try { @autoreleasepool { require(raw != nullptr, 1, "Missing Bayer repair context."); raw->repair(); return 0; } }
    catch (const SourceFailure &e) { fail(error, e.status, e.message); return e.status; }
    catch (const std::exception &e) { fail(error, 2, e.what()); return 2; }
}
