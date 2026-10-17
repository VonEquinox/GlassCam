// Phocus 4.2.2 CPU global saturation and grayscale, without selective points,
// vibrance or local layers. The native pipeline runs these AFTER sharpness.
// Float/double boundaries, explicit FMA and truncation follow the arm64 code.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace hncs_phocus_post {
using Codes = std::array<uint16_t, 3>;

inline Codes saturation(const Codes& input, double amount) {
    if (amount == 0.) return input; // Original caller does not add an idle filter.
    const float r = float(input[0]) / 65536.f;
    const float g = float(input[1]) / 65536.f;
    const float b = float(input[2]) / 65536.f;
    const double low = std::min({double(r), double(g), double(b)});
    const double high = std::max({double(r), double(g), double(b)});
    const double difference = high - low;
    const float lightness = float((high + low) * .5);
    float sat = 0.f, hue = 0.f;
    if (lightness < .5f) {
        if (double(lightness) > 1. / 65535.) sat = float((difference * .5) / double(lightness));
    } else if (double(lightness) < 65534. / 65535.) {
        sat = float(difference / std::fma(double(lightness), -2., 2.));
    }
    if (high != low) {
        if (high == r) {
            double value = double((g - b) * 60.f) / difference;
            if (g < b) value += 360.;
            hue = float(value);
        } else if (high == g) {
            hue = float(double((b - r) * 60.f) / difference + 120.);
        } else {
            hue = float(double((r - g) * 60.f) / difference + 240.);
        }
    }
    // The original empty selective-curve tables contain 0 / 1 / 0.
    if (hue >= 360.f) hue -= 360.f;
    if (hue < 0.f) hue += 360.f;
    sat = std::max(0.f, std::min(sat * (float(amount + 100.) / 100.f), 1.f));
    const float high2 = lightness >= .5f
        ? std::fma(-lightness, sat, sat + lightness) : (sat + 1.f) * lightness;
    const double low2 = double(lightness + lightness) - double(high2);
    const double unit_hue = double(hue / 360.f);
    const double slope = (double(high2) - low2) * 6.;
    const std::array<double, 3> positions = {unit_hue + 1./3., unit_hue, unit_hue - 1./3.};
    Codes output{};
    for (unsigned channel = 0; channel < 3; ++channel) {
        double t = positions[channel];
        if (t < 0.) t += 1.;
        if (t > 1.) t -= 1.;
        const double value = t < 1./6. ? std::fma(slope, t, low2)
            : t < .5 ? double(high2)
            : t < 2./3. ? std::fma(slope, 2./3. - t, low2) : low2;
        output[channel] = uint16_t(float(value) * 65535.f);
    }
    return output;
}

inline Codes grayscale(const Codes& input, const std::array<double, 3>& weights) {
    const double rg = std::fma(double(input[0]), weights[0], double(input[1]) * weights[1]);
    const double value = std::floor(std::fma(double(input[2]), weights[2], rg));
    const uint16_t gray = uint16_t(std::max(0., std::min(value, 65535.)));
    return {gray, gray, gray};
}
} // namespace hncs_phocus_post
