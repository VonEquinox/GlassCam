#include "ffcs_c.h"
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <vector>
#define CHECK(x) do { if (!(x)) { std::cerr << "FFCS check failed line " << __LINE__ << ": " << #x << " (" << error.data() << ")\n"; return 1; } } while(false)
int main(int argc, char **argv) {
    if (argc != 2) { std::cerr << "Usage: ffcs_smoke /path/to/xh2s\n"; return 2; }
    std::array<char,1024> error{};
    CHECK(ffcs_simulation_count() == 20);
    CHECK(ffcs_simulation_name(20) == nullptr);
    CHECK(ffcs_simulation_asset(20) == nullptr);
    CHECK(ffcs_create(argv[1],19,error.data(),error.size()) == nullptr);
    CHECK(ffcs_create(nullptr,0,error.data(),error.size()) == nullptr);
    const std::array<std::array<size_t,2>,5> shapes{{{{1,1}},{{1,9}},{{9,1}},{{7,3}},{{131,9}}}};
    size_t cases = 0;
    for (size_t look=0; look<19; ++look) {
        CHECK(ffcs_simulation_name(look) != nullptr && ffcs_simulation_asset(look) != nullptr);
        std::unique_ptr<FFCSContext, decltype(&ffcs_destroy)> ctx(
            ffcs_create(argv[1],look,error.data(),error.size()),ffcs_destroy);
        CHECK(ctx != nullptr);
        for (auto shape : shapes) {
            const size_t w=shape[0],h=shape[1],n=w*h*3;
            std::vector<float> input(n),expected(n),actual(n);
            std::vector<uint8_t> rgba(w*h*4),preview(w*h*4);
            for(size_t i=0;i<n;++i) input[i]=float((i*7919)%10007)/8000.f-.1f;
            CHECK(ffcs_process_linear_rgb(ctx.get(),input.data(),n,w,h,.7f,0xffffffffu,
                expected.data(),n,rgba.data(),rgba.size(),error.data(),error.size()) == 1);
            for(unsigned workers : {1u,4u}) {
                auto run=[&](float *out,size_t count,uint8_t *bytes,size_t byte_count,unsigned threads) {
                    return ffcs_process_linear_rgb_optimized(ctx.get(),input.data(),n,w,h,.7f,0xffffffffu,
                        out,count,bytes,byte_count,threads,error.data(),error.size());
                };
                CHECK(run(actual.data(),n,preview.data(),preview.size(),workers)==1);
                CHECK(std::memcmp(expected.data(),actual.data(),n*sizeof(float))==0);
                CHECK(rgba==preview);
                for(float v:actual) CHECK(std::isfinite(v) && v>=0.f && v<=1.f);
                for(size_t i=3;i<preview.size();i+=4) CHECK(preview[i]==255);
                CHECK(run(nullptr,0,preview.data(),preview.size(),workers)==1 && rgba==preview);
                CHECK(run(actual.data(),n,nullptr,0,workers)==1);
                CHECK(std::memcmp(expected.data(),actual.data(),n*sizeof(float))==0);
                ++cases;
            }
            auto invalid=[&](const float *in,size_t count,size_t width,size_t height,float ev,
                              float *out,size_t out_count,uint8_t *bytes,size_t byte_count,unsigned threads) {
                return ffcs_process_linear_rgb_optimized(ctx.get(),in,count,width,height,ev,0,
                    out,out_count,bytes,byte_count,threads,error.data(),error.size());
            };
            CHECK(invalid(input.data(),n,w,h,0,actual.data(),n,nullptr,0,0)==0);
            CHECK(invalid(input.data(),n,w,h,0,actual.data(),n,nullptr,0,5)==0);
            CHECK(invalid(input.data(),n,w,h,0,nullptr,0,nullptr,0,1)==0);
            CHECK(invalid(nullptr,n,w,h,0,actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n-1,w,h,0,actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,w,h,0,actual.data(),n-1,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,w,h,0,actual.data(),n,preview.data(),preview.size()-1,1)==0);
            CHECK(invalid(input.data(),n,0,h,0,actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,std::numeric_limits<size_t>::max(),h,0,actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,w,h,33,actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,w,h,std::numeric_limits<float>::quiet_NaN(),actual.data(),n,nullptr,0,1)==0);
            CHECK(invalid(input.data(),n,w,h,0,input.data(),n,nullptr,0,1)==0);
            input[0]=std::numeric_limits<float>::infinity();
            CHECK(invalid(input.data(),n,w,h,0,actual.data(),n,nullptr,0,1)==0);
        }
    }
    std::cout << "FFCS smoke passed: 19 looks, " << cases
              << " shape/worker pairs, both + single outputs, bit-exact float/preview, invalid arguments.\n";
    return 0;
}
