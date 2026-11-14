#include "float_raster.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace {
bool valid(const float *values, size_t samples) {
    return samples <= std::numeric_limits<size_t>::max() / sizeof(float) && (!samples || values);
}
bool overlap(const float *a, size_t an, const float *b, size_t bn) {
    if (!an || !bn) return false;
    const auto x = reinterpret_cast<uintptr_t>(a), y = reinterpret_cast<uintptr_t>(b);
    return x <= y ? y - x < an * sizeof(float) : x - y < bn * sizeof(float);
}
bool packed(const float *input, float *output, size_t count, size_t from, size_t to) {
    if (count > std::numeric_limits<size_t>::max() / (4 * sizeof(float))) return false;
    return valid(input, count * from) && valid(output, count * to) &&
        !overlap(input, count * from, output, count * to);
}
}

extern "C" int gc_float_rgba_to_rgb(const float *rgba, size_t count, float *rgb) {
    if (!packed(rgba, rgb, count, 4, 3)) return 0;
    for (size_t i = 0; i < count; ++i)
        for (size_t c = 0; c < 3; ++c) rgb[i * 3 + c] = rgba[i * 4 + c];
    return 1;
}

extern "C" int gc_float_rgb_to_rgba(const float *rgb, size_t count, float *rgba) {
    if (!packed(rgb, rgba, count, 3, 4)) return 0;
    for (size_t i = 0; i < count; ++i) {
        for (size_t c = 0; c < 3; ++c) rgba[i * 4 + c] = rgb[i * 3 + c];
        rgba[i * 4 + 3] = 1;
    }
    return 1;
}

extern "C" int gc_float_range_valid(const float *values, size_t samples, float minimum, float maximum) {
    if (!valid(values, samples) || !std::isfinite(minimum) || !std::isfinite(maximum) || minimum > maximum) return 0;
    size_t i = 0;
#if defined(__aarch64__)
    const auto lower = vdupq_n_f32(minimum), upper = vdupq_n_f32(maximum);
    for (; i + 4 <= samples; i += 4) {
        const auto value = vld1q_f32(values + i);
        if (!vminvq_u32(vandq_u32(vcgeq_f32(value, lower), vcleq_f32(value, upper)))) return 0;
    }
#endif
    for (; i < samples; ++i)
        if (!(values[i] >= minimum && values[i] <= maximum)) return 0;
    return 1;
}

extern "C" int gc_float_scale(float *values, size_t samples, float scale) {
    if (!valid(values, samples) || !std::isfinite(scale) || scale <= 0) return 0;
    size_t i = 0;
#if defined(__aarch64__)
    const auto multiplier = vdupq_n_f32(scale), limit = vdupq_n_f32(std::numeric_limits<float>::max());
    for (; i + 4 <= samples; i += 4) {
        const auto source = vld1q_f32(values + i);
        const auto value = scale == 1 ? source : vmulq_f32(source, multiplier);
        if (!vminvq_u32(vcleq_f32(vabsq_f32(value), limit))) return 0;
        vst1q_f32(values + i, value);
    }
#endif
    for (; i < samples; ++i) {
        const float value = scale == 1 ? values[i] : values[i] * scale;
        if (!std::isfinite(value)) return 0;
        values[i] = value;
    }
    return 1;
}

extern "C" int gc_float_normalize_rgb(float *rgb, size_t count, float scale, float *gains) {
    if (count > std::numeric_limits<size_t>::max() / (3 * sizeof(float)) ||
        !valid(rgb, count * 3) || !valid(gains, count) || overlap(rgb, count * 3, gains, count) ||
        !std::isfinite(scale) || scale <= 0) return 0;
    for (size_t i = 0; i < count; ++i) {
        float *pixel = rgb + i * 3;
        for (size_t c = 0; c < 3; ++c) {
            if (scale != 1) pixel[c] *= scale;
            if (!std::isfinite(pixel[c])) return 0;
        }
        const float gain = std::max({1.f, pixel[0], pixel[1], pixel[2]});
        gains[i] = gain;
        if (gain > 1) for (size_t c = 0; c < 3; ++c) pixel[c] /= gain;
    }
    return 1;
}

extern "C" int gc_float_restore_rgba(float *rgba, const float *gains, size_t count,
                                     float ceiling, float *peak) {
    if (!peak || !std::isfinite(ceiling) || ceiling < 1 ||
        count > std::numeric_limits<size_t>::max() / (4 * sizeof(float)) ||
        !valid(rgba, count * 4) || !valid(gains, count) ||
        overlap(rgba, count * 4, gains, count) || overlap(rgba, count * 4, peak, 1) ||
        overlap(gains, count, peak, 1)) return 0;
    float maximum = 1;
    size_t i = 0;
#if defined(__aarch64__)
    const auto zero = vdupq_n_f32(0), one = vdupq_n_f32(1), upper = vdupq_n_f32(ceiling);
    const auto finiteLimit = vdupq_n_f32(std::numeric_limits<float>::max());
    auto peaks = one;
    for (; i + 4 <= count; i += 4) {
        auto pixels = vld4q_f32(rgba + i * 4);
        const auto gain = vld1q_f32(gains + i);
        auto accepted = vandq_u32(vcgeq_f32(gain, one), vcleq_f32(gain, finiteLimit));
        for (size_t c = 0; c < 4; ++c)
            accepted = vandq_u32(accepted, vcleq_f32(vabsq_f32(pixels.val[c]), finiteLimit));
        if (!vminvq_u32(accepted)) return 0;
        for (size_t c = 0; c < 3; ++c) {
            const auto product = vmulq_f32(pixels.val[c], gain);
            // A comparison/select preserves -0, unlike an IEEE maximum with +0.
            pixels.val[c] = vminq_f32(upper, vbslq_f32(vcltq_f32(product, zero), zero, product));
            peaks = vmaxq_f32(peaks, pixels.val[c]);
        }
        vst4q_f32(rgba + i * 4, pixels);
    }
    maximum = vmaxvq_f32(peaks);
#endif
    for (; i < count; ++i) {
        if (!std::isfinite(gains[i]) || gains[i] < 1 || !std::isfinite(rgba[i * 4 + 3])) return 0;
        for (size_t c = 0; c < 3; ++c) {
            const float source = rgba[i * 4 + c];
            if (!std::isfinite(source)) return 0;
            const float product = source * gains[i];
            // Swift max(0, value) retains the second operand on an equality,
            // including -0. Keep that bit at the original HDR handoff.
            const float value = std::min(ceiling, product < 0 ? 0.f : product);
            rgba[i * 4 + c] = value;
            maximum = std::max(maximum, value);
        }
    }
    *peak = maximum;
    return 1;
}

extern "C" int gc_float_cube_rgb_slab(const float *nodes, size_t dimension, size_t blue, float *rgb) {
    if (dimension < 2 || dimension > 256 || blue >= dimension ||
        !nodes || !rgb || overlap(nodes, dimension, rgb, dimension * dimension * 3)) return 0;
    for (size_t i = 0; i < dimension; ++i)
        if (!std::isfinite(nodes[i]) || nodes[i] < 0 || nodes[i] > 1) return 0;
    for (size_t green = 0; green < dimension; ++green)
        for (size_t red = 0; red < dimension; ++red) {
            const size_t i = (green * dimension + red) * 3;
            rgb[i] = nodes[red]; rgb[i + 1] = nodes[green]; rgb[i + 2] = nodes[blue];
        }
    return 1;
}

extern "C" int gc_float_unit_rgba_valid(const float *rgba, size_t count) {
    if (count > std::numeric_limits<size_t>::max() / (4 * sizeof(float)) ||
        !gc_float_range_valid(rgba, count * 4, 0, 1)) return 0;
    for (size_t i = 0; i < count; ++i) if (rgba[i * 4 + 3] != 1) return 0;
    return 1;
}

extern "C" int gc_float_rgba_peak(const float *pixels, size_t count, float *peak) {
    if (!pixels || !peak || !count || count > std::numeric_limits<size_t>::max() / (4 * sizeof(float))) return 0;
    const auto source = reinterpret_cast<uintptr_t>(pixels), destination = reinterpret_cast<uintptr_t>(peak);
    const size_t bytes = count * 4 * sizeof(float);
    const auto addressLimit = std::numeric_limits<uintptr_t>::max();
    if (source > addressLimit - bytes || destination > addressLimit - sizeof(float) ||
        (source < destination + sizeof(float) && destination < source + bytes)) return 0;
#if defined(__aarch64__)
    float32x4_t maximum = vdupq_n_f32(1);
    uint32x4_t finite = vdupq_n_u32(~0U);
    const auto limit = vdupq_n_f32(std::numeric_limits<float>::max());
    for (size_t i = 0; i < count; ++i) {
        const float32x4_t pixel = vld1q_f32(pixels + 4 * i);
        finite = vandq_u32(finite, vcleq_f32(vabsq_f32(pixel), limit));
        maximum = vmaxq_f32(maximum, vsetq_lane_f32(1, pixel, 3));
    }
    if (!vminvq_u32(finite)) return 0;
    const float result = vmaxvq_f32(maximum);
#else
    float result = 1;
    for (size_t i = 0; i < count; ++i) {
        const auto *pixel = pixels + 4 * i;
        for (size_t c = 0; c < 4; ++c) if (!std::isfinite(pixel[c])) return 0;
        result = std::max(result, std::max(pixel[0], std::max(pixel[1], pixel[2])));
    }
#endif
    *peak = result;
    return 1;
}
