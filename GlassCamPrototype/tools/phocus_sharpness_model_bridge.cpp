// C ABI for independently probing the reconstructed equations; not an app API.
#include "../core/hncs_phocus_sharpness.hpp"
#include <cstring>
using hncs_phocus_sharpness::Context;
extern "C" void* sharpness_model_create(int nominal, double radius, int noise, int dark, double baseline) {
    try { return new Context(nominal, radius, noise, dark, baseline); } catch (...) { return nullptr; }
}
extern "C" void sharpness_model_destroy(void* value) { delete static_cast<Context*>(value); }
extern "C" int sharpness_model_tables(void* value, int32_t* amount, uint8_t* noise, uint32_t* weights) {
    if (!value || !amount || !noise || !weights) return -1;
    auto& c = *static_cast<Context*>(value);
    std::memcpy(amount, c.amount_table.data(), c.amount_table.size()*sizeof(int32_t));
    std::memcpy(noise, c.noise_table.data(), c.noise_table.size());
    std::memcpy(weights, c.weights.data(), c.count*sizeof(uint32_t));
    return int(c.count);
}
extern "C" int sharpness_model_render(void* value, const uint16_t* source, uint16_t* output, size_t width, size_t height) {
    try { if (!value) return -1; static_cast<Context*>(value)->render(source, output, width, height); return 0; }
    catch (...) { return -1; }
}
extern "C" double sharpness_model_amount(int nominal, double baseline) {
    return hncs_phocus_sharpness::effective_amount(nominal, baseline);
}
