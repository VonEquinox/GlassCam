#include "../../Sources/CMetalImage/float_raster.cpp"
#include <array>
#include <cstring>
#include <iostream>
#include <vector>

static int failures = 0;
static void check(bool valid, const char *name) {
    if (!valid) { ++failures; std::cerr << "Failed: " << name << '\n'; }
}

int main() {
    std::array<float,8> pixels{-0.25f, 2, 4, 8, 0, 3, 1, 16};
    float peak = -99;
    check(gc_float_rgba_peak(pixels.data(), 2, &peak) == 1, "accept finite signed HDR");
    check(peak == 4, "headroom excludes alpha");
    const auto original = pixels;
    check(gc_float_rgba_peak(pixels.data(), 2, pixels.data()+1) == 0, "reject aliased peak output");
    check(pixels == original, "aliased request preserves pixels");

    for (size_t channel = 0; channel < 4; ++channel) {
        for (float invalid : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                              -std::numeric_limits<float>::infinity()}) {
            auto input = pixels; input[4+channel] = invalid; peak = -99;
            check(gc_float_rgba_peak(input.data(), 2, &peak) == 0, "reject nonfinite RGBA");
            check(peak == -99, "failed scan preserves peak output");
        }
    }
    for (size_t count : {size_t(1), size_t(31), size_t(1025)}) {
        std::vector<float> image(count*4, -1);
        image[(count-1)*4+2] = 12;
        check(gc_float_rgba_peak(image.data(), count, &peak) == 1, "accept tail pixel");
        check(peak == 12, "include last pixel");
    }
    check(gc_float_rgba_peak(pixels.data(), 0, &peak) == 0, "reject empty image");
    check(gc_float_rgba_peak(pixels.data(), std::numeric_limits<size_t>::max(), &peak) == 0, "reject overflow");
    check(gc_float_rgba_peak(nullptr, 2, &peak) == 0, "reject absent pixels");
    check(gc_float_rgba_peak(pixels.data(), 2, nullptr) == 0, "reject absent peak");

    std::array<float,6> rgb{};
    check(gc_float_rgba_to_rgb(pixels.data(), 2, rgb.data()) == 1, "pack RGB");
    check(rgb == std::array<float,6>{-.25f, 2, 4, 0, 3, 1}, "packing preserves signed HDR");
    std::array<float,8> rgba{};
    check(gc_float_rgb_to_rgba(rgb.data(), 2, rgba.data()) == 1, "expand RGBA");
    check(rgba == std::array<float,8>{-.25f, 2, 4, 1, 0, 3, 1, 1}, "expansion is opaque");
    const auto unchanged=rgba;
    check(gc_float_rgba_to_rgb(rgba.data(), 2, rgba.data()+1) == 0, "reject overlapping packing");
    check(rgba == unchanged, "failed packing preserves storage");
    std::array<float,2> gains{};
    check(gc_float_normalize_rgb(rgb.data(), 2, 2, gains.data()) == 1, "normalize exposed HDR");
    check(gains == std::array<float,2>{8, 6}, "magnitude includes exposure once");
    check(rgb == std::array<float,6>{-.0625f, .5f, 1, 0, 1, 1.f/3}, "normalize with signed channels");
    check(gc_float_rgb_to_rgba(rgb.data(), 2, rgba.data()) == 1, "prepare restored image");
    check(gc_float_restore_rgba(rgba.data(), gains.data(), 2, 4, &peak) == 1, "restore HDR with ceiling");
    check(rgba == std::array<float,8>{0, 4, 4, 1, 0, 4, 2, 1}, "restore RGB and retain alpha");
    check(peak == 4, "restore reports capped headroom");
    std::array<float,4> signedZero{-0.f,0,0,1};
    const float unity = 1;
    check(gc_float_restore_rgba(signedZero.data(), &unity, 1, 4, &peak) == 1, "restore zero pixel");
    check(std::signbit(signedZero[0]), "retain negative-zero sign");
    for (size_t count : {size_t(1), size_t(4), size_t(7), size_t(16)}) {
        std::vector<float> input(count*4, 0.5f), expected(count*4, 1), gains(count, 2);
        for (size_t p = 0; p < count; ++p) input[p*4+3] = 1;
        input[0] = expected[0] = -0.f;
        input[(count-1)*4+2] = expected[(count-1)*4+2] = 4;
        check(gc_float_restore_rgba(input.data(), gains.data(), count, 4, &peak) == 1, "restore vector and scalar tails");
        check(std::memcmp(input.data(), expected.data(), input.size()*sizeof(float)) == 0, "preserve exact vector pixel bits");
    }
    std::array<float,3> nodes{0, .25f, 1};
    std::array<float,27> slab{};
    check(gc_float_cube_rgb_slab(nodes.data(), 3, 1, slab.data()) == 1, "prepare cube slab");
    check(slab == std::array<float,27>{0,0,.25f, .25f,0,.25f, 1,0,.25f,
        0,.25f,.25f, .25f,.25f,.25f, 1,.25f,.25f, 0,1,.25f, .25f,1,.25f, 1,1,.25f}, "cube axis order");
    check(gc_float_cube_rgb_slab(nodes.data(), 3, 3, slab.data()) == 0, "reject invalid slab");
    std::array<float,4> unit{0, .25f, 1, 1};
    check(gc_float_unit_rgba_valid(unit.data(), 1) == 1, "accept unit opaque output");
    unit[3] = .5f;
    check(gc_float_unit_rgba_valid(unit.data(), 1) == 0, "reject translucent cube output");
    check(gc_float_range_valid(unit.data(), unit.size(), 0, 1) == 1, "range validation allows fractional alpha");
    check(gc_float_range_valid(nullptr, 0, 0, 1) == 1, "empty range validation succeeds");
    check(gc_float_range_valid(nullptr, 1, 0, 1) == 0, "reject absent nonempty range");
    check(gc_float_range_valid(unit.data(), std::numeric_limits<size_t>::max(), 0, 1) == 0, "reject range size overflow");
    check(gc_float_range_valid(unit.data(), unit.size(), 1, 0) == 0, "reject reversed limits");
    for (size_t position : {size_t(0), size_t(3), size_t(8)}) {
        for (float value : {-0.01f, 1.01f, std::numeric_limits<float>::quiet_NaN(),
                            std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()}) {
            std::array<float,9> samples{0, 1, 0.5f, -0.f, 1, 0.5f, 0, 1, 0.5f};
            samples[position] = value;
            const auto before = samples;
            check(gc_float_range_valid(samples.data(), samples.size(), 0, 1) == 0, "reject invalid vector or tail sample");
            check(std::memcmp(samples.data(), before.data(), sizeof(samples)) == 0, "range scan never mutates input");
        }
    }
    std::array<float,5> signedHDR{-std::numeric_limits<float>::max(), -0.f, 0, 8, std::numeric_limits<float>::max()};
    check(gc_float_range_valid(signedHDR.data(), signedHDR.size(),
        -std::numeric_limits<float>::max(), std::numeric_limits<float>::max()) == 1, "finite validation preserves full signed range");
    return failures ? 1 : 0;
}
