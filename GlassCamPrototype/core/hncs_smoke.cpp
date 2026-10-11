#include "hncs_c.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>
#define CHECK(x) do { if (!(x)) { std::cerr << "check failed at line " << __LINE__ << ": " << #x << '\n'; return 1; } } while(false)
int main() {
    CHECK(hncs_create(0,std::numeric_limits<double>::quiet_NaN())==nullptr);
    CHECK(hncs_create(21,5500)==nullptr);
    CHECK(hncs_create_mode(0,5500,2,0)==nullptr);
    CHECK(hncs_render_native(nullptr,nullptr,nullptr,0)==-1);
    constexpr size_t count=100003;
    std::vector<float> source(count*3);
    for(size_t i=0;i<source.size();++i)source[i]=float((i*7919)%10007)/10006.f;
    std::vector<uint8_t> exact(count*4),fast(count*4),parallel(count*4);
    for(int lstar=0;lstar<2;++lstar)for(int repro=0;repro<2;++repro) {
        auto ctx=hncs_create_mode(0,5500,lstar,repro);CHECK(ctx);
        CHECK(hncs_render_native(ctx,nullptr,nullptr,0)==0);
        CHECK(hncs_render_native(ctx,nullptr,nullptr,1)==-1);
        CHECK(hncs_process_srgb(ctx,source.data(),exact.data(),std::numeric_limits<size_t>::max())==-1);
        CHECK(hncs_process_srgb(ctx,source.data(),exact.data(),count)==0);
        CHECK(hncs_process_srgb_fast(ctx,source.data(),fast.data(),count)==0);
        for(size_t i=0;i<fast.size();++i)CHECK(std::abs(int(fast[i])-int(exact[i]))<=1);
        for(unsigned workers=1;workers<=4;++workers) {
            CHECK(hncs_process_srgb_fast_parallel(ctx,source.data(),parallel.data(),count,workers)==0);
            CHECK(parallel==fast);
        }
        CHECK(hncs_process_srgb_fast_parallel(ctx,source.data(),parallel.data(),count,0)==-1);
        CHECK(hncs_process_srgb_fast_parallel(ctx,source.data(),parallel.data(),count,5)==-1);
        float saved=source[31];source[31]=std::numeric_limits<float>::infinity();
        CHECK(hncs_process_srgb_fast_parallel(ctx,source.data(),parallel.data(),count,4)==-1);
        source[31]=saved;
        std::array<double,3> bad={0,std::numeric_limits<double>::quiet_NaN(),0};
        std::array<uint16_t,3> output{};
        CHECK(hncs_render_native(ctx,bad.data(),output.data(),1)==-1);
        hncs_destroy(ctx);
    }
    std::cout<<"C ABI smoke checks passed (4 modes, 1..4 workers, invalid settings/buffers).\n";
    return 0;
}
