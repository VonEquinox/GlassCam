#include "metal_spatial.h"
#include "hncs_spatial_backend.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace {
struct Failure { int code; };
struct Tile {
    uint32_t width, inputRows, outputOffset, outputRows;
    uint32_t count, weightSum, enabled;
    uint32_t weights[9];
};
static_assert(sizeof(Tile) == 64);

struct Tables {
    id<MTLBuffer> amount, noise;
    Tables(id<MTLDevice> device, const hncs_sharpness_tables &source) {
        amount = [device newBufferWithBytes:source.amount length:16384 * sizeof(int32_t)
                                   options:MTLResourceStorageModeShared];
        noise = [device newBufferWithBytes:source.noise length:16384
                                  options:MTLResourceStorageModeShared];
        if (!amount || !noise) throw Failure{-2};
    }
    bool matches(const hncs_sharpness_tables &source) const {
        return std::memcmp(amount.contents, source.amount, amount.length) == 0
            && std::memcmp(noise.contents, source.noise, noise.length) == 0;
    }
};

struct Slot {
    id<MTLBuffer> work, horizontal;
    id<MTLCommandBuffer> command;
    size_t outputRow = 0, outputOffset = 0, outputRows = 0;
    Slot(id<MTLDevice> device, size_t pixels) {
        work = [device newBufferWithLength:pixels * 3 * sizeof(float) options:MTLResourceStorageModeShared];
        horizontal = [device newBufferWithLength:pixels * sizeof(uint16_t) options:MTLResourceStorageModePrivate];
        if (!work || !horizontal) throw Failure{-2};
    }
    ~Slot() { if (command) [command waitUntilCompleted]; }
};

// Positional I/O leaves the reference C++ stream's offset untouched. Retry
// interruptions and short transfers; never expose an incomplete work image.
void transfer(int fd, void *bytes, size_t count, off_t offset, bool write) {
    auto *cursor = static_cast<unsigned char *>(bytes);
    while (count) {
        const ssize_t n = write ? pwrite(fd, cursor, count, offset) : pread(fd, cursor, count, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw Failure{-2};
        cursor += n; count -= size_t(n); offset += n;
    }
}
}

struct gc_metal_spatial {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> horizontal, finish;
    id<MTLBuffer> decode;
    std::mutex tableMutex;
    std::shared_ptr<Tables> cachedTables;

    explicit gc_metal_spatial(const char *shaderPath) {
        device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        NSError *error = nil;
        id<MTLLibrary> library = [device newDefaultLibrary];
        if (![library newFunctionWithName:@"gc_sharpness_horizontal"] ||
            ![library newFunctionWithName:@"gc_sharpness_finish"]) {
            NSString *path = shaderPath ? [NSString stringWithUTF8String:shaderPath] : nil;
            NSString *source = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error] : nil;
            if (!source) throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal shader resource missing");
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.mathMode = MTLMathModeSafe;
            options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
            library = [device newLibraryWithSource:source options:options error:&error];
        }
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal library unavailable");
        horizontal = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_sharpness_horizontal"] error:&error];
        finish = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_sharpness_finish"] error:&error];
        queue = [device newCommandQueue];
        decode = [device newBufferWithLength:65536 * sizeof(float) options:MTLResourceStorageModeShared];
        if (!horizontal || !finish || !queue || !decode)
            throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal pipeline allocation failed");
        auto *values = static_cast<float *>(decode.contents);
        for (uint32_t i = 0; i < 65536; ++i) values[i] = float(i) / 65535.f;
        queue.label = @"GlassCam native spatial";
    }

    std::shared_ptr<Tables> tables(const hncs_sharpness_tables &source) {
        std::lock_guard<std::mutex> lock(tableMutex);
        if (!cachedTables || !cachedTables->matches(source))
            cachedTables = std::make_shared<Tables>(device, source);
        return cachedTables;
    }

    void encode(Slot &slot, const Tile &tile, const Tables &tables) {
        slot.command = [queue commandBuffer];
        if (!slot.command) throw Failure{-2};
        slot.command.label = @"HNCS exact native sharpness";
        id<MTLComputeCommandEncoder> encoder = [slot.command computeCommandEncoder];
        if (!encoder) { slot.command = nil; throw Failure{-2}; }
        [encoder setComputePipelineState:horizontal];
        [encoder setBuffer:slot.work offset:0 atIndex:0];
        [encoder setBuffer:slot.horizontal offset:0 atIndex:1];
        [encoder setBytes:&tile length:sizeof(tile) atIndex:2];
        const NSUInteger lane = horizontal.threadExecutionWidth;
        [encoder dispatchThreads:MTLSizeMake(tile.width, tile.inputRows, 1)
            threadsPerThreadgroup:MTLSizeMake(lane, std::min(NSUInteger(4), horizontal.maxTotalThreadsPerThreadgroup / lane), 1)];
        [encoder endEncoding];
        // Separate encoders establish the tracked-buffer dependency between
        // horizontal convolution and in-place vertical/finish output.
        encoder = [slot.command computeCommandEncoder];
        if (!encoder) { slot.command = nil; throw Failure{-2}; }
        [encoder setComputePipelineState:finish];
        [encoder setBuffer:slot.work offset:0 atIndex:0];
        [encoder setBuffer:slot.horizontal offset:0 atIndex:1];
        [encoder setBytes:&tile length:sizeof(tile) atIndex:2];
        [encoder setBuffer:tables.amount offset:0 atIndex:3];
        [encoder setBuffer:tables.noise offset:0 atIndex:4];
        [encoder setBuffer:decode offset:0 atIndex:5];
        const NSUInteger finishLane = finish.threadExecutionWidth;
        [encoder dispatchThreads:MTLSizeMake(tile.width, tile.outputRows, 1)
            threadsPerThreadgroup:MTLSizeMake(finishLane, std::min(NSUInteger(4), finish.maxTotalThreadsPerThreadgroup / finishLane), 1)];
        [encoder endEncoding];
        [slot.command commit];
    }
};

namespace {
struct Job {
    gc_metal_spatial &runtime;
    hncs_spatial_cancel_fn cancelled;
    void *cancelContext;
    void check() const { if (cancelled && cancelled(cancelContext)) throw Failure{-3}; }

    void retire(Slot &slot, int descriptor, size_t rowBytes) {
        if (!slot.command) return;
        [slot.command waitUntilCompleted];
        if (slot.command.status != MTLCommandBufferStatusCompleted) throw Failure{-2};
        check();
        transfer(descriptor, static_cast<unsigned char *>(slot.work.contents) + slot.outputOffset * rowBytes,
                 slot.outputRows * rowBytes, off_t(slot.outputRow * rowBytes), true);
        slot.command = nil;
    }

    int render(int descriptor, size_t width, size_t height, const hncs_sharpness_tables &source) {
        check();
        if (width > INT_MAX || height > INT_MAX) return 1;
        const size_t rowBytes = width * 3 * sizeof(float), radius = source.count / 2;
        // Two reusable slots, each with <=32 MiB RGB plus a 16-bit luma plane.
        // At least one future halo is read before the preceding output is
        // written, so in-place processing never sharpens a neighbor twice.
        const size_t capacityRows = std::min(size_t(32 * 1024 * 1024), size_t(runtime.device.maxBufferLength)) / rowBytes;
        if (capacityRows < 32 + 2 * radius) return 1;
        const size_t rows = std::min(height, std::min(size_t(1024), ((capacityRows - 2 * radius) / 32) * 32));
        const size_t pixels = width * std::min(height, rows + 2 * radius);
        const auto parameters = runtime.tables(source);
        std::array<std::unique_ptr<Slot>, 2> slots;
        slots[0] = std::make_unique<Slot>(runtime.device, pixels);
        const size_t bands = (height + rows - 1) / rows;
        if (bands > 1) slots[1] = std::make_unique<Slot>(runtime.device, pixels);
        for (size_t band = 0; band < bands; ++band) {
            check();
            auto &slot = *slots[band % 2];
            retire(slot, descriptor, rowBytes);
            const size_t top = band * rows, count = std::min(rows, height - top);
            const size_t first = top > radius ? top - radius : 0;
            const size_t end = top + count + std::min(radius, height - top - count);
            transfer(descriptor, slot.work.contents, (end - first) * rowBytes, off_t(first * rowBytes), false);
            slot.outputRow = top; slot.outputRows = count; slot.outputOffset = top - first;
            Tile tile{uint32_t(width), uint32_t(end - first), uint32_t(top - first), uint32_t(count),
                      source.count, source.weight_sum, uint32_t(source.enabled), {}};
            std::copy_n(source.weights, source.count, tile.weights);
            runtime.encode(slot, tile, *parameters);
        }
        for (size_t band = bands > 2 ? bands - 2 : 0; band < bands; ++band)
            retire(*slots[band % 2], descriptor, rowBytes);
        return 0;
    }
};

int runBackend(int descriptor, size_t width, size_t height, const hncs_sharpness_tables *tables, void *context) {
    @autoreleasepool {
        try { return static_cast<Job *>(context)->render(descriptor, width, height, *tables); }
        catch (const Failure &error) { return error.code; }
        catch (...) { return -2; }
    }
}
}

extern "C" gc_metal_spatial *gc_metal_spatial_create(const char *shaderPath, char *error, size_t capacity) {
    @autoreleasepool {
        if (error && capacity) error[0] = '\0';
        try { return new gc_metal_spatial(shaderPath); }
        catch (const std::exception &failure) {
            if (error && capacity) { std::strncpy(error, failure.what(), capacity - 1); error[capacity - 1] = '\0'; }
        } catch (...) {
            if (error && capacity) { std::strncpy(error, "Metal initialization failed", capacity - 1); error[capacity - 1] = '\0'; }
        }
        return nullptr;
    }
}
extern "C" void gc_metal_spatial_destroy(gc_metal_spatial *context) { delete context; }
extern "C" int gc_metal_spatial_prepare_file(gc_metal_spatial *context, const char *path, size_t width, size_t height,
    const char *key, int grain, int sharp, double baseline, double scale, const char *scratch,
    hncs_spatial_cancel_fn cancelled, void *cancelContext) {
    if (!context) return hncs_prepare_apple_hdr_spatial_file(path, width, height, key, grain, sharp, baseline,
                                                          scale, scratch, cancelled, cancelContext);
    Job job{*context, cancelled, cancelContext};
    return hncs_prepare_apple_hdr_spatial_file_with_backend(path, width, height, key, grain, sharp, baseline,
                                                          scale, scratch, cancelled, cancelContext, runBackend, &job);
}
