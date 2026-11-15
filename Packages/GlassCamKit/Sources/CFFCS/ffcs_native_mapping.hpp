#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

struct FFCSNativeMapping {
    uint32_t maximum = 20000;
    uint32_t fixed = 1;
    double gamma = 1.;
    std::vector<uint32_t> gammaIn;
    std::vector<uint16_t> gammaOut;
    std::array<int32_t, 1536> gaussian{};
    std::array<int32_t, 1024> distances{};

    void prepare(uint32_t nodes) {
        gammaIn.resize(size_t(maximum) + 1);
        gammaOut.resize(20001);
        const double inverse = 1. / gamma;
        for (uint32_t code = 0; code <= maximum; ++code)
            gammaIn[code] = uint32_t(std::floor(
                std::pow(double(code) / maximum, inverse) * double(nodes - 2) * 256. + .5));
        for (uint32_t code = 0; code <= 20000; ++code)
            gammaOut[code] = uint16_t(std::min(65535., std::floor(
                std::pow(double(code) / 20000., gamma) * double(maximum) + .5)));
        constexpr double sigma = .5055;
        const double variance = 1. / ((sigma + sigma) * sigma);
        for (int i = 0; i < 1536; ++i)
            gaussian[i] = int32_t(std::floor(std::exp(double(i) * (-1. / 256.) * variance) * 1024. + .5));
        for (int fraction = 0; fraction < 256; ++fraction) {
            distances[fraction * 4] = (fraction + 256) * (fraction + 256);
            distances[fraction * 4 + 1] = fraction * fraction;
            distances[fraction * 4 + 2] = (256 - fraction) * (256 - fraction);
            distances[fraction * 4 + 3] = (512 - fraction) * (512 - fraction);
        }
    }

    std::array<uint16_t, 3> map(const uint16_t* lut, uint32_t nodes,
                              const std::array<uint16_t, 3>& input) const {
        int lo[3], fraction[3];
        for (unsigned c = 0; c < 3; ++c) {
            const uint32_t value = gammaIn[std::min(uint32_t(input[c]), maximum)];
            lo[c] = int(value >> 8); fraction[c] = int(value & 255);
        }
        int64_t sums[3]{};
        int32_t weights[3]{};
        for (int r = -1; r <= 2; ++r) for (int g = -1; g <= 2; ++g) for (int b = -1; b <= 2; ++b) {
            if ((r < 0 || r > 1) + (g < 0 || g > 1) + (b < 0 || b > 1) > 1) continue;
            const int offsets[3] = {b, g, r};
            int coordinate[3], sign[3] = {1, 1, 1}, squared = 0;
            for (unsigned c = 0; c < 3; ++c) {
                squared += distances[fraction[c] * 4 + offsets[c] + 1];
                coordinate[c] = lo[c] + offsets[c];
                if (lo[c] == 0 && offsets[c] == -1) {
                    coordinate[c] = 1; sign[c] = -1;
                } else if (lo[c] >= int(nodes) - (fixed ? 2 : 3) && offsets[c] == 2) {
                    coordinate[c] = lo[c]; sign[c] = -1;
                }
            }
            // Both original modes use this asymmetric neighbour.
            if (b == -1 && g == 0 && r == 1 && lo[0] > 0) coordinate[0] = lo[0];
            if (squared >= 0x60000) continue;
            const int32_t weight = gaussian[squared >> 8];
            const size_t index = ((size_t(coordinate[2]) * nodes + coordinate[1]) * nodes + coordinate[0]) * 3;
            for (unsigned c = 0; c < 3; ++c) {
                weights[c] += sign[c] * weight;
                sums[c] += int64_t(lut[index + c]) * sign[c] * weight;
            }
        }
        std::array<uint16_t, 3> output{};
        for (unsigned c = 0; c < 3; ++c) {
            if (!weights[c]) throw std::runtime_error("Invalid FFCS mapping weights");
            const int64_t value = (sums[c] + (weights[c] + 1) / 2) / weights[c];
            output[c] = gammaOut[size_t(std::clamp<int64_t>(value, 0, 20000))];
        }
        return output;
    }
};
