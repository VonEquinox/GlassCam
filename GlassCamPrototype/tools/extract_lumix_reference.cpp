// Offline x86_64 oracle for the supplied SILKYPIX 8.0.31.1 framework.
// Never linked into GlassCam. Offsets belong only to the pinned SHA-256 in ORIGIN.md.
#include <dlfcn.h>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

static uintptr_t base;
template<class F> F fn(uintptr_t address) { return reinterpret_cast<F>(base + address); }
struct alignas(16) Object { std::array<unsigned char, 4096> bytes{}; void *get() { return bytes.data(); } };

int main(int argc, char **argv) {
    try {
        if (argc < 3) throw std::runtime_error("framework map | framework decode input.s3d output.rgb16");
        void *handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
        if (!handle) throw std::runtime_error(dlerror());
        void *known = dlsym(handle, "_ZNK14IslZColor3DLut10GetLutSizeEv");
        if (!known) throw std::runtime_error("Pinned SILKYPIX symbol not found");
        base = reinterpret_cast<uintptr_t>(known) - 0x7a292a;
        if (std::string(argv[2]) == "enum") {
            auto table = reinterpret_cast<uint64_t *>(base + 0x154a220);
            for (int i = 0; i < 60 && table[i]; i += 2) {
                std::printf("%d\t%s\n", static_cast<int32_t>(table[i+1]), reinterpret_cast<const char *>(table[i]));
            }
            return 0;
        }
        if (std::string(argv[2]) == "map") {
            for (int camera = 98; camera <= 108; ++camera) {
                for (int style = 1; style <= 25; ++style) {
                    Object strings[4];
                    auto stringConstructor = fn<void(*)(void *, int)>(0xed10);
                    auto stringDestructor = fn<void(*)(void *)>(0xc9f0);
                    for (auto &s : strings) stringConstructor(s.get(), -3);
                    unsigned char flag = 0; int a = -1, b = -1;
                    auto call = fn<void(*)(void *, int, int, unsigned char *, void *, void *, void *, void *, int *, int *)>(0x5b48c0);
                    call(nullptr, camera, style, &flag, strings[0].get(), strings[1].get(), strings[2].get(), strings[3].get(), &a, &b);
                    std::printf("%d\t%d\t%u\t%d\t%d", camera, style, flag, a, b);
                    for (auto &s : strings) std::printf("\t%s", fn<const char *(*)(void *)>(0x2d640)(s.get()));
                    std::printf("\n");
                    for (auto &s : strings) stringDestructor(s.get());
                }
            }
            return 0;
        }
        if (std::string(argv[2]) != "decode" || (argc != 5 && argc != 6)) throw std::runtime_error("Invalid arguments");
        std::ifstream input(argv[3], std::ios::binary);
        std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
        if (bytes.size() < 156 || std::memcmp(bytes.data(), "ISL_PANA_3DMAP", 13)) throw std::runtime_error("Invalid PANA resource");
        int grid = static_cast<unsigned char>(bytes[0x42]) | (static_cast<unsigned char>(bytes[0x43]) << 8);
        if (grid != 17 && grid != 129 && grid != 257) throw std::runtime_error("Unexpected grid");
        Object storage, lut;
        fn<void(*)(void *, void *, int)>(0x6b9e00)(storage.get(), bytes.data() + 0x34, static_cast<int>(bytes.size() - 0x34));
        fn<void(*)(void *, int)>(0x7a2840)(lut.get(), grid);
        double gain = 0, matrix[9]{}; uint16_t white = 0;
        short header = fn<short(*)(void *, void *, double *, uint16_t *, double *)>(0x7ab172)(lut.get(), storage.get(), &gain, &white, matrix);
        short data = header ? header : fn<short(*)(void *, void *)>(0x7ab5b8)(lut.get(), storage.get());
        if (data) throw std::runtime_error("Native LUT decoder failed: " + std::to_string(data));
        std::ofstream output(argv[4], std::ios::binary);
        auto point = fn<const uint16_t *(*)(void *, int, int, int)>(0x7a29a2);
        // Canonical file order: R fastest, then G, then B; RGB components.
        for (int b = 0; b < grid; ++b) for (int g = 0; g < grid; ++g) for (int r = 0; r < grid; ++r) {
            const uint16_t *p = point(lut.get(), r, g, b);
            const uint16_t rgb[3] = {p[2], p[1], p[0]};
            output.write(reinterpret_cast<const char *>(rgb), sizeof(rgb));
        }
        if (!output) throw std::runtime_error("Could not write decoded LUT");
        if (argc == 6) {
            // Independently populate the native Pana_LUT layout exactly as DecompressLUT does.
            std::vector<uint16_t> native(static_cast<size_t>(grid) * grid * grid * 3);
            size_t index = 0;
            for (int r = 0; r < grid; ++r) for (int g = 0; g < grid; ++g) for (int b = 0; b < grid; ++b) {
                const uint16_t *p = point(lut.get(), r, g, b);
                native[index++] = p[2]; native[index++] = p[1]; native[index++] = p[0];
            }
            Object pana;
            fn<void(*)(void *)>(0x707a10)(pana.get());
            *reinterpret_cast<uint16_t **>(pana.bytes.data() + 8) = native.data();
            *reinterpret_cast<int *>(pana.bytes.data() + 0x148) = grid == 129 ? 32 : grid == 257 ? 16 : 256;
            *reinterpret_cast<int *>(pana.bytes.data() + 0x14c) = grid;
            std::ofstream golden(argv[5], std::ios::binary);
            uint32_t random = 0x4c554d49;
            for (int i = 0; i < 12304; ++i) {
                uint16_t rgb[3];
                for (auto &c : rgb) { random = random * 1664525U + 1013904223U; c = (random >> 12) & 4095; }
                if (i < 4096) rgb[0] = rgb[1] = rgb[2] = static_cast<uint16_t>(i);
                if (i >= 12288) for (int c = 0; c < 3; ++c) rgb[c] = (i & (1 << c)) ? 4095 : (i & 8) ? 32 : 0;
                uint16_t bgr[3] = {rgb[2], rgb[1], rgb[0]}, result[3]{};
                fn<void(*)(void *, const uint16_t *, uint16_t *)>(0x82bfb8)(pana.get(), bgr, result);
                uint16_t row[6] = {rgb[0], rgb[1], rgb[2], result[2], result[1], result[0]};
                golden.write(reinterpret_cast<const char *>(row), sizeof(row));
            }
            if (!golden) throw std::runtime_error("Could not save native vectors");
        }
        std::printf("{\"grid\":%d,\"gain\":%.17g,\"white\":%u,\"matrix\":[", grid, gain, white);
        for (int i = 0; i < 9; ++i) std::printf("%s%.17g", i ? "," : "", matrix[i]);
        std::printf("]}\n");
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
