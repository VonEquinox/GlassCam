// ABI adapter for original Phocus 4.2.2 arm64 crop processing with explicit backend.
// The native library owns algorithms. This file only marshals C++ arguments.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <exception>
#include <fstream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Shared = std::shared_ptr<void>;
struct Rect { alignas(8) unsigned char bytes[32]{}; ~Rect() {} };
struct Processor { alignas(8) unsigned char bytes[32]{}; ~Processor() {} };
struct Pointer { void* value = nullptr; ~Pointer() {} };
struct Profile { alignas(8) unsigned char bytes[256]{}; ~Profile() {} };
struct Parameters { alignas(8) unsigned char bytes[512]{}; ~Parameters() {} };
struct ByteSpan { const unsigned char* data; std::size_t size; };
struct Size { int width, height; };
static_assert(sizeof(Shared) == 16 && sizeof(Rect) == 32 && sizeof(Processor) == 32);

template <class Function> Function function(void* library, const char* name) {
    void* address = dlsym(library, name);
    if (!address) throw std::runtime_error(std::string("Missing original symbol: ") + name);
    return reinterpret_cast<Function>(address);
}

Shared borrowed(void* address) { return Shared(address, [](void*) {}); }

void dump_filters(const Processor& processor, const char* stage) {
    void* current = nullptr;
    std::memcpy(&current, processor.bytes + 8, sizeof current);
    std::fprintf(stderr, "filters[%s] last-to-first:\n", stage);
    for (unsigned n = 0; current && n < 128; ++n) {
        const auto* bytes = static_cast<const unsigned char*>(current);
        const auto& id = *reinterpret_cast<const std::string*>(bytes + 0x20);
        std::fprintf(stderr, "  %s\n", id.c_str());
        std::memcpy(&current, bytes + 8, sizeof current);
    }
}
}

extern "C" int configure_x2d_backend(void* image_library, void* util_library, bool cpu) {
    try {
        if (cpu) {
            auto** manager = static_cast<void**>(dlsym(util_library, "gDebugManager"));
            if (!manager || !*manager) return -1;
            function<void (*)(void*, std::string, double, bool)>(util_library,
                "_ZN13CDebugManager11SetDebugKeyENSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEdb")(
                    *manager, "disableGPU", 1., false);
        }
        return function<bool (*)()>(image_library, "_ZN19CGpuPipelineManager12IsGpuEnabledEv")() ? 1 : 0;
    } catch (...) { return -1; }
}

extern "C" void* cached_x2d_description(void* storage_library, void* raw) {
    if (!raw) return nullptr;
    try {
        // This is the shared native description also used by FromCorrection.
        // Keep its owner for the diagnostic child process's lifetime.
        auto* owner = new Shared(function<Shared (*)(void*)>(storage_library,
            "_ZN13CRawImageFile17GetRawDescriptionEv")(raw));
        return owner->get();
    } catch (...) { return nullptr; }
}

extern "C" int render_x2d_crop(
    void* image_library, void* util_library, void* raw, void* description,
    void* correction, void* curves, void* parameters, void* image_description,
    void* output_preset, int stage, bool export_parameters,
    const char* stop_filter, bool before_filter,
    const char* output_profile,
    int left, int top, int width, int height, int source_width, int source_height,
    std::uint16_t* output, unsigned* metadata, double* color_contract) {
    if (!raw || !description || !correction || !curves || !parameters || !output || !metadata ||
        width <= 0 || height <= 0 || width > 4096 || height > 4096 || stage < 0 || stage > 1) return -1;
    try {
        using Update = void (*)(Shared, void*, void*, void*, const void*, Shared);
        auto update = function<Update>(image_library,
            "_ZN12CCameraImage19UpdateProcessParamsENSt3__110shared_ptrIK15sRawDescriptionEEP14sProcessParamsP13CRawImageFileP16CImageCorrectionPK17CImageDescriptionNS1_I11CClarifyMapEE");
        auto raw_ptr = borrowed(raw), desc_ptr = borrowed(description), curve_ptr = borrowed(curves);
        if (export_parameters) {
            using Build = Parameters (*)(Shared, const void*, const void*, const void*);
            std::fprintf(stderr, "native export FromCorrection\n"); std::fflush(stderr);
            Parameters built = function<Build>(image_library,
                "_ZN12CSaveHandler14FromCorrectionENSt3__110shared_ptrI13CRawImageFileEEPK16CImageCorrectionPK17CImageDescriptionRK13COutputPreset")(
                    raw_ptr, correction, image_description, output_preset);
            if (!built.bytes[0x1c0]) throw std::runtime_error("Original export parameter factory returned no value");
            // Native sProcessParams is 0x1c0 bytes; the optional engagement flag
            // is immediately after it. Opaque container ownership is retained
            // in this diagnostic process, with no synthetic field defaults.
            std::memcpy(parameters, built.bytes, 0x1c0);
        } else {
            std::fprintf(stderr, "native viewer UpdateProcessParams\n"); std::fflush(stderr);
            update(desc_ptr, parameters, raw, correction, image_description, {});
        }
        Rect rect;
        function<void (*)(void*, int, int, int, int)>(util_library, "_ZN6CXRectC1Eiiii")(
            rect.bytes, left, top, left + width, top + height);
        using General = Processor (*)(const Rect&, Shared, Shared, void*, const void*, bool, Shared, double);
        auto general = function<General>(image_library,
            "_ZN12CCameraImage18ProcessCropGeneralERK6CXRectNSt3__110shared_ptrI13CRawImageFileEENS4_IK15sRawDescriptionEEP14sProcessParamsPK16CImageCorrectionbNS4_I12CImageFilterEEd");
        std::fprintf(stderr, "native ProcessCropGeneral\n"); std::fflush(stderr);
        Processor processor = general(rect, raw_ptr, desc_ptr, parameters, correction, false, {}, 1.0);
        dump_filters(processor, "general");
        if (stage >= 1) {
            using Specific = void (*)(Processor*, Shared, Shared, void*, const void*, Shared, bool, double);
            std::fprintf(stderr, "native ProcessCropSpecific\n"); std::fflush(stderr);
            function<Specific>(image_library,
                "_ZN12CCameraImage19ProcessCropSpecificEP15CImageProcessorNSt3__110shared_ptrI13CRawImageFileEENS3_IK15sRawDescriptionEEP14sProcessParamsPK16CImageCorrectionNS3_IK17CCalculatedCurvesEEbd")(
                    &processor, raw_ptr, desc_ptr, parameters, correction, curve_ptr, false, 1.0);
            dump_filters(processor, "specific");
            if (color_contract) {
                auto selected = *reinterpret_cast<Shared*>(processor.bytes + 8);
                while (selected) {
                    auto* bytes = static_cast<unsigned char*>(selected.get());
                    const auto& id = *reinterpret_cast<const std::string*>(bytes + 0x20);
                    if (id == "colorCorrect") {
                        unsigned char* outer = nullptr;
                        std::memcpy(&outer, bytes + 0x48, sizeof outer);
                        unsigned char* inner = nullptr;
                        std::memcpy(&inner, outer + 0xb0, sizeof inner);
                        color_contract[0] = function<double (*)(void*)>(image_library,
                            "_ZNK19CRawColorCorrection19GetColorTemperatureEv")(outer);
                        color_contract[1] = function<int (*)(void*)>(image_library,
                            "_ZNK19CRawColorCorrection12GetICMMethodEv")(outer);
                        std::memcpy(color_contract + 2, bytes + 0x50, sizeof(double));
                        std::memcpy(color_contract + 3, outer + 0x1f8, sizeof(double));
                        std::memcpy(color_contract + 4, outer + 0x248, sizeof(double));
                        std::memcpy(color_contract + 5, inner + 0x1b8, 4 * sizeof(double));
                        std::memcpy(color_contract + 9, inner + 8, 9 * sizeof(double));
                        std::memcpy(color_contract + 18, inner + 0x50, 9 * sizeof(double));
                        for (unsigned k = 0; k < 6; ++k) {
                            const unsigned char *begin = nullptr, *end = nullptr;
                            auto offset = (k < 3 ? 0x1e0 : 0x240) + (k % 3) * 24;
                            std::memcpy(&begin, inner + offset, sizeof begin);
                            std::memcpy(&end, inner + offset + 8, sizeof end);
                            color_contract[27 + k] = begin ? double((end - begin) / 2) : 0;
                        }
                        break;
                    }
                    selected = *reinterpret_cast<Shared*>(bytes + 8);
                }
            }
        }
        if (output_profile && *output_profile) {
            // Original macOS ColorSync manager/cache factory. Opaque state is
            // process-local and retained until this diagnostic process exits.
            void* manager = ::operator new(4096);
            std::memset(manager, 0, 4096);
            std::fprintf(stderr, "native ColorSync manager constructor\n"); std::fflush(stderr);
            function<void (*)(void*)>(image_library, "_ZN19CColorSyncManagerNGC1Ev")(manager);
            std::fprintf(stderr, "native SetSharedInstance\n"); std::fflush(stderr);
            function<void (*)(Shared)>(image_library,
                "_ZN13CColorManager17SetSharedInstanceENSt3__110shared_ptrIS_EE")(borrowed(manager));
            std::ifstream profile_file(output_profile, std::ios::binary);
            std::vector<unsigned char> profile_data((std::istreambuf_iterator<char>(profile_file)), {});
            if (profile_data.empty()) throw std::runtime_error("Empty original output ICC profile");
            // File lookup only sees registered ColorSync profiles. Parse these
            // exact retained ICC bytes through the original native importer.
            std::fprintf(stderr, "native output profile from ICC bytes\n"); std::fflush(stderr);
            // The exported member thunk drops `this` before the static helper
            // (0x7bc70: x0=x1, x1=x2, x2=x3). Preserve that ABI argument.
            Profile profile = function<Profile (*)(void*, ByteSpan, int)>(image_library,
                "_ZN19CColorSyncManagerNG18ProfileFromIccDataENSt3__14spanIKhLm18446744073709551615EEE12eProfileType")(
                    manager, {profile_data.data(), profile_data.size()}, 1);
            if (!profile.bytes[0x78]) throw std::runtime_error("Original ICC importer returned no profile");
            std::fprintf(stderr, "native AddOutputFiltersExport\n"); std::fflush(stderr);
            function<void (*)(Processor*, const void*, void*, Profile)>(image_library,
                "_ZN12CCameraImage22AddOutputFiltersExportEP15CImageProcessorRK16CImageCorrectionP13CColorManager13CColorProfile")(
                    &processor, correction, manager, profile);
            dump_filters(processor, "output-profile");
        }
        if (stop_filter && *stop_filter) {
            auto tail = *reinterpret_cast<Shared*>(processor.bytes + 8);
            while (tail) {
                auto* bytes = static_cast<unsigned char*>(tail.get());
                const auto& id = *reinterpret_cast<const std::string*>(bytes + 0x20);
                if (id == stop_filter) break;
                tail = *reinterpret_cast<Shared*>(bytes + 8);
            }
            if (!tail) throw std::runtime_error(std::string("Original filter not found: ") + stop_filter);
            if (before_filter) tail = *reinterpret_cast<Shared*>(static_cast<unsigned char*>(tail.get()) + 8);
            if (!tail) throw std::runtime_error("No input filter before selected stage");
            *reinterpret_cast<Shared*>(processor.bytes + 8) = tail;
            dump_filters(processor, "selected");
        }
        alignas(16) unsigned char context[4096]{};
        using ContextCtor = void (*)(void*, Size, Shared);
        function<ContextCtor>(image_library,
            "_ZN14CFilterContextC1E6CArrayIiLi2EiENSt3__110shared_ptrI20CAdjustmentLayerListEE")(
                context, {source_width, source_height}, {});
        using Output = Pointer (*)(Processor*, Rect, void*, Shared, void*, std::string);
        std::fprintf(stderr, "native OutputImage, backend configured separately\n"); std::fflush(stderr);
        Pointer result = function<Output>(image_library,
            "_ZN15CImageProcessor11OutputImageE6CXRectP14CFilterContextNSt3__110shared_ptrI13CGpuTileCacheEEP9CProgressNS3_12basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEE")(
                &processor, rect, context, {}, nullptr, "GlassCam X2D original CPU audit");
        function<void (*)(void*)>(image_library, "_ZN15CImageProcessorD1Ev")(&processor);
        if (!result.value) return -2;
        std::memcpy(metadata, static_cast<unsigned char*>(result.value) + 8, 4 * sizeof(unsigned));
        auto remove = function<void (*)(void*)>(util_library, "_ZN14CBufferedImageD0Ev");
        if (metadata[0] != unsigned(width) || metadata[1] != unsigned(height) ||
            metadata[2] == 0 || metadata[2] > 4) { remove(result.value); return -3; }
        auto pixel = function<std::uint16_t* (*)(void*, unsigned, unsigned)>(util_library,
            "_ZN14CBufferedImage11GetPixelPtrEjj");
        for (int y = 0; y < height; ++y) {
            auto* row = pixel(result.value, 0, unsigned(y));
            if (!row) { remove(result.value); return -4; }
            std::memcpy(output + std::size_t(y) * width * metadata[2], row,
                        std::size_t(width) * metadata[2] * sizeof(std::uint16_t));
        }
        remove(result.value);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "Native exception: %s\n", error.what()); return -5;
    } catch (...) {
        std::fprintf(stderr, "Unknown native exception\n"); return -6;
    }
}
