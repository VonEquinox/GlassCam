#include "lumix_c.h"
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <vector>
#include <cstdlib>

static int failures = 0;
static void check(bool valid, const char *name) {
    if (!valid) { ++failures; std::cerr << "Failed: " << name << '\n'; }
}
using Context = std::unique_ptr<LUMIXContext, decltype(&lumix_destroy)>;

int main(int argc, char **argv) {
    if (argc != 2) { std::cerr << "Supply the prepared LUMIX resource directory\n"; return 2; }
    std::array<char,1024> error{};
    constexpr size_t pixels = 31;
    std::vector<float> input(pixels*3), output(pixels*4);
    for (size_t i = 0; i < input.size(); ++i) input[i] = float(i % 17)/8 - 0.25f;
    for (size_t look = 0; look < lumix_look_count(); ++look) {
        Context context(lumix_create_pipeline(argv[1], look, 4000, 10, 10, 100, error.data(), error.size()), lumix_destroy);
        check(bool(context), "load Photo Style");
        if (!context) continue;
        check(lumix_process_iphone_rgba(context.get(), input.data(), input.size(), pixels, 0,
            output.data(), output.size(), error.data(), error.size()) == 1, "render signed iPhone RGB");
        check(std::all_of(output.begin(), output.end(), [](float x) { return std::isfinite(x) && x >= 0 && x <= 1; }),
              "finite bounded Photo Style output");

        auto aliased = output;
        const auto before = aliased;
        check(lumix_process_iphone_rgba(context.get(), aliased.data(), pixels*3, pixels, 0,
            aliased.data(), pixels*4, error.data(), error.size()) == 0, "reject overlapping RGBA");
        check(aliased == before, "overlapping RGBA preserves source");
        std::fill(output.begin(), output.end(), -99);
        auto invalid = input; invalid.back() = std::numeric_limits<float>::quiet_NaN();
        check(lumix_process_iphone_rgba(context.get(), invalid.data(), invalid.size(), pixels, 0,
            output.data(), output.size(), error.data(), error.size()) == 0, "reject nonfinite iPhone input");
        check(std::all_of(output.begin(), output.end(), [](float x) { return x == -99; }), "nonfinite input preserves output");

        std::vector<uint16_t> rgb(pixels*3), expected(rgb.size());
        for (size_t i = 0; i < rgb.size(); ++i) rgb[i] = uint16_t(i*3919%4096);
        check(lumix_process_rgb12(context.get(), rgb.data(), pixels, expected.data(), error.data(), error.size()) == 1,
              "render RGB12");
        auto inplace = rgb;
        check(lumix_process_rgb12(context.get(), inplace.data(), pixels, inplace.data(), error.data(), error.size()) == 1,
              "render RGB12 in place");
        check(inplace == expected, "in-place RGB12 is exact");
        for (auto &value : rgb) value *= 16;
        check(lumix_process_rgb16(context.get(), rgb.data(), pixels, 65535, 0, 0,
              expected.data(), error.data(), error.size()) == 1, "render RGB16");
        inplace = rgb;
        check(lumix_process_rgb16(context.get(), inplace.data(), pixels, 65535, 0, 0,
              inplace.data(), error.data(), error.size()) == 1, "render RGB16 in place");
        check(inplace == expected, "in-place RGB16 is exact");
    }

    namespace fs = std::filesystem;
    auto pattern = (fs::temp_directory_path()/"glasscam-lumix-XXXXXX").string();
    std::vector<char> path(pattern.begin(), pattern.end()); path.push_back(0);
    char *created = mkdtemp(path.data());
    check(created != nullptr, "create malformed-resource fixture");
    if (created) {
        const fs::path directory(created);
        try {
            for (const auto &entry : fs::directory_iterator(argv[1]))
                if (entry.path().extension() == ".lmx") fs::create_symlink(fs::absolute(entry.path()), directory/entry.path().filename());
            std::ifstream source(fs::path(argv[1])/"pipeline.lmp", std::ios::binary);
            std::vector<unsigned char> registers((std::istreambuf_iterator<char>(source)), {});
            check(registers.size() >= 88, "read pipeline register fixture");
            if (registers.size() >= 88) {
                const double nan = std::numeric_limits<double>::quiet_NaN();
                for (size_t i = 0; i < 4; ++i) std::memcpy(registers.data()+registers.size()-64+i*16+8, &nan, 8);
                const uint32_t crc = uint32_t(crc32(0, registers.data()+24, uInt(registers.size()-24)));
                for (size_t i = 0; i < 4; ++i) registers[16+i] = uint8_t(crc >> (i*8));
                std::ofstream invalid(directory/"pipeline.lmp", std::ios::binary);
                invalid.write(reinterpret_cast<const char *>(registers.data()), registers.size()); invalid.close();
                Context context(lumix_create_pipeline(created, 0, 6500, 10, 10, 100, error.data(), error.size()), lumix_destroy);
                check(!context, "reject NaN curve despite matching CRC");
            }
        } catch (const std::exception &exception) {
            check(false, exception.what());
        }
        fs::remove_all(directory);
    }
    return failures ? 1 : 0;
}
