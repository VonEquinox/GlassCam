// Diagnostic ABI adapter for hash-locked Phocus 4.2.2 arm64 functions.
// No Phocus code or binary is linked into the application.
#include <cstdint>
#include <cstring>
#include <new>

namespace {
struct Rect {
    alignas(8) unsigned char bytes[32]{};
    ~Rect() {} // Nontrivial native CXRect arguments are passed indirectly.
};
struct Pointer {
    void* value = nullptr;
    ~Pointer() {} // Native unique_ptr return uses the indirect result register.
};
struct EmptyVector {
    void* values[3]{};
    ~EmptyVector() {}
};
struct BorrowedShared {
    void* value = nullptr;
    void* owner = nullptr;
    ~BorrowedShared() {}
};
}

extern "C" int apply_phocus_filter(
    void* filter_object, std::uint16_t* source, unsigned source_width,
    unsigned source_height, int crop_left, int crop_top, unsigned width,
    unsigned height, std::uint16_t* output,
    void* image_ctor_address, void* image_delete_address, void* pixel_address,
    void* rect_ctor_address, void* filter_address) {
    using ImageCtor = void (*)(void*, unsigned, unsigned, unsigned, unsigned,
                              std::uint16_t*, bool, unsigned);
    using Delete = void (*)(void*);
    using Pixel = std::uint16_t* (*)(void*, unsigned, unsigned);
    using RectCtor = void (*)(void*, int, int, int, int);
    using Filter = Pointer (*)(void*, Rect, Rect, Pointer, Pointer);
    // Margin filters intentionally request a destination beyond the source.
    // The caller must obey the selected original filter's neighborhood contract.
    if (!filter_object || !source || !output || !width || !height ||
        !source_width || !source_height) return -1;
    auto image_ctor = reinterpret_cast<ImageCtor>(image_ctor_address);
    auto image_delete = reinterpret_cast<Delete>(image_delete_address);
    auto get_pixel = reinterpret_cast<Pixel>(pixel_address);
    auto rect_ctor = reinterpret_cast<RectCtor>(rect_ctor_address);
    auto filter = reinterpret_cast<Filter>(filter_address);
    try {
        void* image_object = ::operator new(0x40);
        image_ctor(image_object, source_width, source_height, 3, 0, source, false, 0);
        Rect a, b;
        rect_ctor(a.bytes, 0, 0, int(source_width), int(source_height));
        rect_ctor(b.bytes, crop_left, crop_top, crop_left + int(width), crop_top + int(height));
        Pointer input, destination;
        input.value = image_object;
        Pointer result = filter(filter_object, a, b, input, destination);
        if (!result.value) return -2;
        unsigned actual_width, actual_height;
        std::memcpy(&actual_width, static_cast<unsigned char*>(result.value) + 8, 4);
        std::memcpy(&actual_height, static_cast<unsigned char*>(result.value) + 12, 4);
        if (actual_width != width || actual_height != height) {
            image_delete(result.value);
            return -3;
        }
        for (unsigned y = 0; y < height; ++y) {
            auto* row = get_pixel(result.value, 0, y);
            if (!row) { image_delete(result.value); return -4; }
            std::memcpy(output + y * width * 3, row, width * 3 * sizeof(std::uint16_t));
        }
        image_delete(result.value);
        return 0;
    } catch (...) {
        return -5;
    }
}

extern "C" int construct_phocus_margin(void* filter, int width, int height,
                                       int period, void* rect_ctor_address,
                                       void* filter_ctor_address) {
    using RectCtor = void (*)(void*, int, int, int, int);
    using FilterCtor = void (*)(void*, Rect, int);
    if (!filter || width <= 0 || height <= 0 || period <= 0) return -1;
    try {
        Rect rectangle;
        reinterpret_cast<RectCtor>(rect_ctor_address)(rectangle.bytes, 0, 0, width, height);
        reinterpret_cast<FilterCtor>(filter_ctor_address)(filter, rectangle, period);
        return 0;
    } catch (...) {
        return -2;
    }
}

extern "C" int construct_phocus_saturation(void* filter, int saturation,
                                           void* filter_ctor_address) {
    using FilterCtor = void (*)(void*, EmptyVector, int, int);
    if (!filter || !filter_ctor_address) return -1;
    try {
        EmptyVector points;
        reinterpret_cast<FilterCtor>(filter_ctor_address)(filter, points, saturation, 0);
        return 0;
    } catch (...) {
        return -2;
    }
}

extern "C" int construct_phocus_gradation(void* filter,void* curves,bool recover_hue,void* address) {
    if(!filter||!curves||!address)return -1;
    try {
        BorrowedShared shared;shared.value=curves;
        reinterpret_cast<void(*)(void*,BorrowedShared,bool)>(address)(filter,shared,recover_hue);
        return 0;
    }catch(...){return -2;}
}
