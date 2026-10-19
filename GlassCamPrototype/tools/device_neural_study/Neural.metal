#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp::tensor_ops;
#pragma clang fp contract(off)

struct Dimensions { uint m, n, k; };

// Interleaved RGB is an M-by-3 matrix. The 3-by-3 source matrix is
// transposed by the CPU into conventional row-major B before dispatch.
kernel void source_scalar(const device float *a [[buffer(0)]],
                          const device float *b [[buffer(1)]],
                          device float *c [[buffer(2)]],
                          constant Dimensions &d [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
    if (i >= d.m * d.n) return;
    uint row = i / d.n, column = i % d.n;
    float value = 0;
    for (uint k = 0; k < d.k; ++k) value = value + a[row * d.k + k] * b[k * d.n + column];
    c[i] = value;
}

template <typename T, int N = 32, int Groups = 4>
inline void tensor_product(device T *a, device T *b, device float *c,
                           constant Dimensions &d, uint2 group) {
    tensor<device T, dextents<int, 2>, tensor_inline> A(a, dextents<int, 2>(int(d.k), int(d.m)));
    tensor<device T, dextents<int, 2>, tensor_inline> B(b, dextents<int, 2>(int(d.n), int(d.k)));
    tensor<device float, dextents<int, 2>, tensor_inline> C(c, dextents<int, 2>(int(d.n), int(d.m)));
    constexpr auto descriptor = matmul2d_descriptor(64, N, int(dynamic_extent), false, false, false);
    matmul2d<descriptor, execution_simdgroups<Groups>> operation;
    auto localA = A.slice(0, int(group.y * 64));
    auto localB = B.slice(int(group.x * N), 0);
    auto localC = C.slice(int(group.x * N), int(group.y * 64));
    // Caller zeroes C. run implements C += A * B, with edge checking.
    operation.run(localA, localB, localC);
}

kernel void source_tensor_fp32(device float *a [[buffer(0)]], device float *b [[buffer(1)]],
                               device float *c [[buffer(2)]], constant Dimensions &d [[buffer(3)]],
                               uint2 group [[threadgroup_position_in_grid]]) {
    tensor_product(a, b, c, d, group);
}

kernel void source_tensor_fp16(device half *a [[buffer(0)]], device half *b [[buffer(1)]],
                               device float *c [[buffer(2)]], constant Dimensions &d [[buffer(3)]],
                               uint2 group [[threadgroup_position_in_grid]]) {
    tensor_product(a, b, c, d, group);
}

kernel void source_tensor8_fp32(device float *a [[buffer(0)]], device float *b [[buffer(1)]],
                                device float *c [[buffer(2)]], constant Dimensions &d [[buffer(3)]],
                                uint2 group [[threadgroup_position_in_grid]]) {
    tensor_product<float, 8, 1>(a, b, c, d, group);
}

kernel void source_tensor8_fp16(device half *a [[buffer(0)]], device half *b [[buffer(1)]],
                                device float *c [[buffer(2)]], constant Dimensions &d [[buffer(3)]],
                                uint2 group [[threadgroup_position_in_grid]]) {
    tensor_product<half, 8, 1>(a, b, c, d, group);
}
