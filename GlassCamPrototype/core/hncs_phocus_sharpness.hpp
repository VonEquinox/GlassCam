// Phocus 4.2.2 CPU sharpness equations, reconstructed from the original arm64
// functions and checked with direct native calls. Non-HDR, full-resolution
// scale, no local adjustment layers. This header does not load Phocus binaries.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace hncs_phocus_sharpness {

inline double effective_amount(int nominal, double baseline) {
    if (!std::isfinite(baseline) || baseline < 0.)
        throw std::invalid_argument("Invalid baseline sharpness");
    if (baseline == 0.) return double(nominal);
    const double gain = baseline * 1.8;
    if (nominal <= 100) return double(nominal) * gain;
    const double factor = (10. - gain) / 9.;
    const double first = std::fma(factor, double(nominal), 1000.);
    return std::fma(-factor, 1000., first);
}

struct Context {
    std::array<int32_t, 16384> amount_table{};
    std::array<uint8_t, 16384> noise_table{};
    std::array<uint32_t, 9> weights{};
    uint32_t weight_sum = 0;
    unsigned count = 0;
    int amount = 0;

    Context(int nominal, double radius, int noise, int dark, double baseline = 0.) {
        if (!std::isfinite(radius) || noise < 0 || noise > 255 || dark < -32768 || dark > 32767)
            throw std::invalid_argument("Invalid native sharpness parameters");
        const double resolved = effective_amount(nominal, baseline);
        if (!std::isfinite(resolved) || resolved < double(INT32_MIN) || resolved > double(INT32_MAX))
            throw std::invalid_argument("Effective sharpness amount overflow");
        amount = int(resolved); // Original call site uses fcvtzs, not round.
        const float a = float(amount);
        const float threshold = std::min(float(uint16_t(uint32_t(dark) << 6)), 16383.f);
        const float factor = float((double(a) + 100.) / 16384.);
        float knee = amount > 0 ? 1638400.f / (a + 100.f) : 0.f;
        knee = std::max(1000.f, std::min(knee, 10000.f));
        // These power-of-two operations appear explicitly in CalcAmountTab.
        knee = (knee * (1.f / 16384.f)) * 16384.f;
        for (unsigned i = 0; i < amount_table.size(); ++i) {
            const float x = float(i);
            float value = a;
            if (amount > 0) {
                if (x < threshold) {
                    float quadratic = std::fma(threshold, 3.f, -knee);
                    quadratic /= threshold * threshold;
                    float linear = std::fma(threshold, 6.f, knee * -2.f);
                    linear = 3.f - linear / threshold;
                    const float mapped = std::fma(quadratic * x, x, linear * x);
                    value = mapped > 0.f && mapped < 16384.f ? std::fma(mapped, factor, -100.f) : -100.f;
                } else if (x < 16384.f) {
                    const float span = 16384.f - threshold;
                    float quadratic = std::fma(span, -3.f, 16384.f - knee);
                    quadratic /= span * span;
                    const float distance = x - threshold;
                    float mapped = std::fma(distance * quadratic, distance, distance * 3.f);
                    mapped += knee;
                    if (mapped > 0.f && mapped < 16384.f) value = std::fma(mapped, factor, -100.f);
                }
            }
            amount_table[i] = int32_t(value);
            const unsigned limit = uint16_t(unsigned(noise) << 6);
            const unsigned transition = std::max(limit >> 2, 128u);
            float strength = (x - float(int(limit) - int(transition))) / float(transition);
            strength = std::max(0.f, std::min(strength, 1.f));
            noise_table[i] = uint8_t(strength * 255.f);
        }
        const double sigma = radius == 0. ? .1 : radius;
        auto coefficient = [sigma](int x) {
            if (sigma < 0.) return uint32_t(10000);
            const double position = double(x) / sigma;
            return uint32_t(10000. * std::exp(-position * position));
        };
        for (int x = -4; x <= 4; ++x) {
            const uint32_t value = coefficient(x);
            if (value > 1000 || x == 0) weights[count++] = value;
        }
        if (count < 3) {
            count = 3;
            for (int x = -1; x <= 1; ++x) weights[unsigned(x + 1)] = coefficient(x);
        }
        for (unsigned i = 0; i < count; ++i) weight_sum += weights[i];
        if (count > 9 || count % 2 != 1 || weight_sum == 0)
            throw std::invalid_argument("Invalid sharpness kernel");
    }

    unsigned radius() const { return count / 2; }
    static uint16_t luma(const uint16_t* rgb) {
        return uint16_t(((uint32_t(rgb[0]) >> 2) * 299 +
                         (uint32_t(rgb[1]) >> 2) * 587 +
                         (uint32_t(rgb[2]) >> 2) * 114) / 1000);
    }
    int correction(uint16_t original, uint16_t blurred) const {
        const int difference = int(original) - int(blurred);
        const int index = std::min(std::abs(difference), 16383);
        // Preserve native 32-bit multiplication without C++ signed overflow.
        const uint32_t bits = uint32_t(int64_t(difference) * amount_table[std::min(original, uint16_t(16383))] * noise_table[index]);
        const int64_t signed_product = bits < 0x80000000u ? int64_t(bits) : int64_t(bits) - 0x100000000LL;
        return int(signed_product / 25500);
    }
    void finish(const uint16_t* source, uint16_t blurred, uint16_t* output) const {
        const int change = amount == 0 ? 0 : correction(luma(source), blurred);
        for (unsigned ch = 0; ch < 3; ++ch)
            output[ch] = uint16_t(std::max(0, std::min(int(source[ch] >> 2) + change, 16383)) << 2);
    }

    // Packed, disjoint RGB16 buffers; replicated image edges. Horizontal and
    // vertical divisions are separate integer truncations, as in the original.
    void render(const uint16_t* source, uint16_t* output, size_t width, size_t height) const {
        if (!source || !output || source == output || !width || !height ||
            width > std::numeric_limits<size_t>::max() / height / 3 / sizeof(uint16_t))
            throw std::invalid_argument("Invalid sharpness image");
        const size_t r = radius();
        constexpr size_t band_rows = 32;
        for (size_t top = 0; top < height; top += band_rows) {
            const size_t end = top + std::min(band_rows, height - top);
            const size_t first = top > r ? top - r : 0;
            const size_t last = end + std::min(r, height - end);
            std::vector<uint16_t> horizontal((last - first) * width);
            for (size_t y = first; y < last; ++y) {
                const auto* row = source + y * width * 3;
                for (size_t x = 0; x < width; ++x) {
                    uint32_t sum = 0;
                    for (unsigned k = 0; k < count; ++k) {
                        const size_t sx = k < r ? (x < r-k ? 0 : x-(r-k)) : x + std::min(size_t(k)-r, width-1-x);
                        sum += weights[k] * luma(row + sx * 3);
                    }
                    horizontal[(y-first)*width+x] = uint16_t(sum / weight_sum);
                }
            }
            for (size_t y = top; y < end; ++y) {
                for (size_t x = 0; x < width; ++x) {
                    uint32_t sum = 0;
                    for (unsigned k = 0; k < count; ++k) {
                        const size_t sy = k < r ? (y < r-k ? 0 : y-(r-k)) : y + std::min(size_t(k)-r, height-1-y);
                        sum += weights[k] * horizontal[(sy-first)*width+x];
                    }
                    finish(source+(y*width+x)*3, uint16_t(sum/weight_sum), output+(y*width+x)*3);
                }
            }
        }
    }
};
} // namespace hncs_phocus_sharpness
