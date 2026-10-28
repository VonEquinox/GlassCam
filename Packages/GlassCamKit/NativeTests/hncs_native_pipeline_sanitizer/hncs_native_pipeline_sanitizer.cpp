#include "hncs_c.h"
#include "hncs_spatial.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
#include <unistd.h>

using Serial = int (*)(const hncs_context*, const float*, float*, size_t);
using Parallel = int (*)(const hncs_context*, const float*, float*, size_t, unsigned);
struct Stage { Serial serial; Parallel parallel; size_t channels; };

int main() {
    const Stage stages[] = {
        {hncs_process_phocus_work_float, hncs_process_phocus_work_float_parallel, 3},
        {hncs_finish_phocus_work_linear, hncs_finish_phocus_work_linear_parallel, 4},
        {hncs_process_phocus_linear_rgba, hncs_process_phocus_linear_rgba_parallel, 4}
    };
    size_t calls = 0;
    for (const char* key : {"standard", "nature", "saturated", "grayscale-red-filter"}) {
        auto* context = hncs_create_preset_whitepoint(-.3, .33943, .35259, 0, 1, 0, 4, 2, key, 1);
        assert(context);
        const size_t count = 65539;
        std::vector<float> source(count * 3);
        for (size_t i = 0; i < source.size(); ++i) source[i] = float(i % 1031) / 1000.f - .02f;
        for (const auto& stage : stages) {
            std::vector<float> expected(count * stage.channels), actual(expected.size());
            assert(stage.serial(context, source.data(), expected.data(), count) == 0);
            for (unsigned workers : {1u, 2u, 4u}) {
                assert(stage.parallel(context, source.data(), actual.data(), count, workers) == 0);
                assert(std::memcmp(actual.data(), expected.data(), actual.size() * sizeof(float)) == 0);
                assert(stage.parallel(context, nullptr, nullptr, 0, workers) == 0);
                assert(stage.parallel(context, source.data(), actual.data(), std::numeric_limits<size_t>::max(), workers) == -1);
                ++calls;
            }
            const float saved = source.back(); source.back() = std::numeric_limits<float>::quiet_NaN();
            assert(stage.parallel(context, source.data(), actual.data(), count, 4) == -1);
            source.back() = saved;
        }
        hncs_destroy(context);
    }
    for (const auto shape : {std::array<size_t, 2>{1, 1}, {1, 17}, {19, 1}, {7, 131}, {8203, 5}}) {
        const size_t width = shape[0], height = shape[1], samples = width * height * 3;
        std::vector<float> source(samples);
        for (size_t i = 0; i < samples; ++i) source[i] = float((i * 99991) % 65536) / 65535.f;
        for (const char* key : {"standard", "nature", "high"}) {
            for (double baseline : {0., .5, 1.5, 2.}) {
                auto memory = source;
                assert(hncs_apply_spatial_native_sharpness(memory.data(), width, height, key, 0, 1, baseline) == 0);
                char path[] = "/tmp/glasscam-native-sanitizer-XXXXXX";
                const int descriptor = mkstemp(path); assert(descriptor >= 0);
                FILE* file = fdopen(descriptor, "w+b"); assert(file);
                assert(fwrite(source.data(), sizeof(float), samples, file) == samples); assert(fclose(file) == 0);
                assert(hncs_apply_spatial_native_sharpness_file(path, width, height, key, 0, 1, baseline, nullptr, nullptr, nullptr) == 0);
                file = fopen(path, "rb"); assert(file); std::vector<float> disk(samples);
                assert(fread(disk.data(), sizeof(float), samples, file) == samples); assert(fclose(file) == 0);
                assert(std::memcmp(memory.data(), disk.data(), samples * sizeof(float)) == 0);
                int cancelled = 0;
                assert(hncs_apply_spatial_native_sharpness_file(path, width, height, key, 0, 1, baseline, nullptr,
                    [](void* state) { ++*static_cast<int*>(state); return 1; }, &cancelled) == -3);
                assert(cancelled > 0); assert(unlink(path) == 0); ++calls;
            }
        }
        source.back() = std::numeric_limits<float>::infinity();
        assert(hncs_apply_spatial_native_sharpness(source.data(), width, height, "standard", 0, 1, 1.5) == -1);
    }
    for(const auto shape : {std::array<size_t,2>{1,1},{1,17},{19,1},{7,131},{8203,5}}) {
        const size_t width=shape[0],height=shape[1],count=width*height;
        std::vector<double> source(count*3);
        std::vector<uint16_t> color(count*3),post(count*3),graded(count*3),sharp(count*3);
        for(size_t i=0;i<source.size();++i)source[i]=double((i*991)%65536)/65535.;
        auto* context=hncs_create_mode(0.,5500.,0,0);assert(context);
        assert(hncs_render_x2d_hdr_color(context,4.643616364582644,source.data(),color.data(),count)==0);
        hncs_destroy(context);
        assert(hncs_render_x2d_hdr_post(color.data(),post.data(),count,50.,50.,0)==0);
        auto inplace=color;
        assert(hncs_render_x2d_hdr_post(inplace.data(),inplace.data(),count,50.,50.,0)==0);
        assert(inplace==post);
        for(const char* key : {"standard","nature"}) {
            assert(hncs_apply_x2d_hdr_gradation(key,post.data(),graded.data(),count)==0);
            assert(hncs_render_x2d_hdr_sharpness(graded.data(),sharp.data(),width,height,key,1.5)==0);
            assert(hncs_render_x2d_hdr_sharpness(graded.data(),graded.data(),width,height,key,1.5)==-1);
            assert(hncs_render_x2d_hdr_sharpness(graded.data(),sharp.data(),0,height,key,1.5)==-1);
            ++calls;
        }
        assert(hncs_apply_x2d_hdr_gradation("missing",post.data(),graded.data(),count)==-1);
        assert(hncs_render_x2d_hdr_post(color.data(),post.data(),count,50.,50.,2)==-1);
        assert(hncs_render_x2d_hdr_post(color.data(),post.data(),std::numeric_limits<size_t>::max(),50.,50.,0)==-1);
    }
    std::printf("PASS: %zu native stage/spatial comparisons, HDR stages, invalid sizes, NaN/Inf and cancellation under ASan/UBSan\n", calls);
}
