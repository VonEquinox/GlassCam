#include <metal_stdlib>
using namespace metal;

struct SharpnessTile {
    uint width, inputRows, outputOffset, outputRows;
    uint count, weightSum, enabled;
    uint weights[9];
};

// Multiplication rounds to Float32 before ties-to-even integer quantization,
// exactly as native_work_code. All work values were validated by C++.
static ushort3 workCodes(device const float *rgb, uint pixel) {
    const uint at = pixel * 3;
    const float3 value = clamp(float3(rgb[at], rgb[at + 1], rgb[at + 2]), 0.0f, 1.0f);
    return ushort3(rint(value * 65535.0f));
}

static uint nativeLuma(ushort3 value) {
    const uint3 reduced = uint3(value) >> 2;
    return (reduced.x * 299u + reduced.y * 587u + reduced.z * 114u) / 1000u;
}

kernel void gc_sharpness_horizontal(device const float *rgb [[buffer(0)]],
    device ushort *horizontal [[buffer(1)]], constant SharpnessTile &tile [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= tile.width || position.y >= tile.inputRows) return;
    uint sum = 0;
    const int radius = int(tile.count / 2);
    for (uint k = 0; k < tile.count; ++k) {
        const uint x = uint(clamp(int(position.x) + int(k) - radius, 0, int(tile.width) - 1));
        sum += tile.weights[k] * nativeLuma(workCodes(rgb, position.y * tile.width + x));
    }
    horizontal[position.y * tile.width + position.x] = ushort(sum / tile.weightSum);
}

kernel void gc_sharpness_finish(device float *rgb [[buffer(0)]],
    device const ushort *horizontal [[buffer(1)]], constant SharpnessTile &tile [[buffer(2)]],
    device const int *amount [[buffer(3)]], device const uchar *noise [[buffer(4)]],
    device const float *decode [[buffer(5)]], uint2 position [[thread_position_in_grid]]) {
    if (position.x >= tile.width || position.y >= tile.outputRows) return;
    const uint row = position.y + tile.outputOffset;
    const uint pixel = row * tile.width + position.x;
    const ushort3 source = workCodes(rgb, pixel);
    uint sum = 0;
    const int radius = int(tile.count / 2);
    for (uint k = 0; k < tile.count; ++k) {
        const uint y = uint(clamp(int(row) + int(k) - radius, 0, int(tile.inputRows) - 1));
        sum += tile.weights[k] * uint(horizontal[y * tile.width + position.x]);
    }
    const uint original = nativeLuma(source);
    const int difference = int(original) - int(sum / tile.weightSum);
    // Native multiplication wraps at 32 bits, followed by signed division
    // toward zero. Unsigned operations make that wrap explicit on both CPUs
    // and GPUs, including negative corrections.
    const uint product = as_type<uint>(difference) * as_type<uint>(amount[original])
        * uint(noise[min(uint(abs(difference)), 16383u)]);
    const int change = tile.enabled ? as_type<int>(product) / 25500 : 0;
    const uint3 codes = uint3(clamp(int3(uint3(source) >> 2) + change, 0, 16383)) << 2;
    // The CPU builds this exact Float32 decode table. No approximate GPU
    // division is introduced at the boundary with the exact color core.
    rgb[pixel * 3] = decode[codes.x];
    rgb[pixel * 3 + 1] = decode[codes.y];
    rgb[pixel * 3 + 2] = decode[codes.z];
}
