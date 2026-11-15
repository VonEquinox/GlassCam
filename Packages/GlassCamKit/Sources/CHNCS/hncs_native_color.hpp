#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace hncs_native_color {
using V = std::array<double, 3>;
using M = std::array<double, 9>;

inline M multiply(const M& a, const M& b) {
    M result{};
    for (int row = 0; row < 3; ++row)
        for (int column = 0; column < 3; ++column)
            result[row * 3 + column] = std::fma(a[row * 3 + 2], b[6 + column],
                std::fma(a[row * 3], b[column], a[row * 3 + 1] * b[3 + column]));
    return result;
}

inline M inverse(const M& a) {
    double determinant = std::fma(a[0] * a[4], a[8], (a[1] * a[5]) * a[6]);
    determinant = std::fma(a[2] * a[3], a[7], determinant);
    determinant = std::fma(-(a[2] * a[4]), a[6], determinant);
    determinant = std::fma(-(a[1] * a[3]), a[8], determinant);
    determinant = std::fma(-(a[0] * a[5]), a[7], determinant);
    const M cofactors = {
        std::fma(a[4], a[8], -(a[5] * a[7])),
        std::fma(a[3], a[8], -(a[5] * a[6])),
        std::fma(a[3], a[7], -(a[4] * a[6])),
        std::fma(a[1], a[8], -(a[2] * a[7])),
        std::fma(a[0], a[8], -(a[2] * a[6])),
        std::fma(a[0], a[7], -(a[1] * a[6])),
        std::fma(a[1], a[5], -(a[2] * a[4])),
        std::fma(a[0], a[5], -(a[2] * a[3])),
        std::fma(a[0], a[4], -(a[1] * a[3])),
    };
    return {cofactors[0] / determinant, -cofactors[3] / determinant, cofactors[6] / determinant,
            -cofactors[1] / determinant, cofactors[4] / determinant, -cofactors[7] / determinant,
            cofactors[2] / determinant, -cofactors[5] / determinant, cofactors[8] / determinant};
}

inline V transform(const M& matrix, const V& input) {
    V output{};
    for (size_t row = 0; row < 3; ++row)
        output[row] = std::fma(matrix[row * 3 + 2], input[2],
            std::fma(matrix[row * 3], input[0], matrix[row * 3 + 1] * input[1]));
    return output;
}

inline void interpolate(double kelvin, const double* temperatures, int n,
                        const double* table, size_t count, double* output) {
    int interval = 0;
    while (interval < n && temperatures[interval] <= kelvin) ++interval;
    interval = std::clamp(interval - 1, 0, n - 2);
    const double lowTemperature = temperatures[interval];
    const double highTemperature = temperatures[interval + 1];
    for (size_t index = 0; index < count; ++index) {
        const double low = table[size_t(interval) * count + index];
        const double high = table[size_t(interval + 1) * count + index];
        const double slope = (high - low) / (highTemperature - lowTemperature);
        output[index] = std::fma(slope, kelvin, std::fma(-slope, highTemperature, high));
    }
}

inline M rgbToXYZ(const std::array<double, 6>& xy, const V& white) {
    M unscaled{};
    for (size_t column = 0; column < 3; ++column) {
        const double x = xy[column * 2], y = xy[column * 2 + 1];
        unscaled[column] = x / y;
        unscaled[3 + column] = 1.;
        unscaled[6 + column] = ((1. - x) - y) / y;
    }
    const V scale = transform(inverse(unscaled), white);
    M result{};
    for (size_t column = 0; column < 3; ++column) {
        result[column] = unscaled[column] * scale[column];
        result[3 + column] = scale[column];
        result[6 + column] = unscaled[6 + column] * scale[column];
    }
    return result;
}

// Phocus working-profile chromaticities and white points, stored without
// decimal re-rounding. The output is profile 10: extended linear sRGB.
inline M outputMatrix(bool lstar) {
    const std::array<double, 6> legacy = {
        0x1.5cacfea828d4cp-1, 0x1.4146a602afae5p-2,
        0x1.b366cd9b366cep-3, 0x1.7a627bd313deap-1,
        0x1.107d6e905ad47p-3, 0x1.7c9ef3d5d434fp-5};
    const std::array<double, 6> wide = {
        0x1.83382c67e8e8bp-1, 0x1.f31f4e605c5d5p-3,
        0x1.9127966ed869ap-4, 0x1.cddb0d3224f2dp-1,
        0x1.30d190130d190p-6, 0x1.69f8db169f8dbp-6};
    const std::array<double, 6> srgb = {.64, .33, .30, .60, .15, .06};
    const V sourceWhite = {0x1.eda9ab5ac3d70p-1, 1., 0x1.a67867e934fddp-1};
    const V targetWhite = {0x1.e6a228c5f3dc7p-1, 1., 0x1.16cc7d1ef8103p+0};
    const M bradford = {.8951, .2664, -.1614, -.7502, 1.7135, .0367, .0389, -.0685, 1.0296};
    const V first = transform(bradford, sourceWhite), second = transform(bradford, targetWhite);
    const M diagonal = {second[0] / first[0], 0., 0., 0., second[1] / first[1], 0.,
                        0., 0., second[2] / first[2]};
    const M adaptation = multiply(multiply(inverse(bradford), diagonal), bradford);
    return multiply(multiply(inverse(rgbToXYZ(srgb, targetWhite)), adaptation),
                    rgbToXYZ(lstar ? wide : legacy, sourceWhite));
}

inline float decode(float encoded, bool lstar) {
    const double x = encoded;
    if (!lstar) return float(std::pow(std::max(0., x), 0x1.1980000000000p+1));
    return float(x <= .08 ? (x * 100.) / 0x1.c3a5ed097b426p+9
                         : std::pow((x + .16) / 1.16, 3.));
}

inline double decodeCode(uint16_t code, double scale, bool lstar) {
    float encoded = float(code) / 65535.f;
    if (scale != 1.) encoded *= float(scale);
    return decode(encoded, lstar);
}
}
