#include "hncs_c.h"
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>
int main() {
    const auto max=std::numeric_limits<size_t>::max();
    assert(hncs_preset_count()==43);
    assert(!hncs_preset_key(max));assert(!hncs_preset_name(max));
    assert(!hncs_preset_settings_json("invalid"));
    assert(hncs_preset_flags("invalid")==std::numeric_limits<unsigned>::max());
    auto create=[](const char *key="standard",const double *b=nullptr,const double *d=nullptr){return hncs_create_preset(0,6500,0,0,0,4,2,key,1,b,d);};
    for(double bad:{0.,-1.,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
        const double wb[3]={bad,1,1};assert(!create("nature",wb));assert(!create("nature",nullptr,wb));
    }
    const double underflow[3]={1e-308,1e308,1.};assert(!create("nature",underflow));
    assert(!hncs_create_preset(0,6500,0,2,0,4,2,"standard",1,nullptr,nullptr));
    assert(!hncs_create_preset(0,6500,0,0,0,3,2,"standard",1,nullptr,nullptr));
    assert(!create("not-a-preset"));
    const size_t n=65539;
    std::vector<float> pixels(n*3),work(n*3),out(n*4),parallel(n*4);
    std::vector<double> native(n*3);
    std::vector<uint16_t> codes(n*3),corrected(n*3);
    for(size_t i=0;i<n*3;++i){pixels[i]=float(i%65536)/65535.f;native[i]=pixels[i];codes[i]=uint16_t(i%65536);}
    for(size_t i=0;i<hncs_preset_count();++i) {
        const char *key=hncs_preset_key(i);assert(key&&hncs_preset_name(i));assert(hncs_preset_settings_json(key));
        hncs_context *ctx=create(key);assert(ctx);
        assert(hncs_apply_post_curves(key,1,codes.data(),corrected.data(),n)==0);
        assert(hncs_apply_preset_pointwise(key,0,codes.data(),corrected.data(),n)==0);
        assert(hncs_render_native_preset(ctx,native.data(),corrected.data(),n)==0);
        assert(hncs_apply_preset_work_float(key,1,codes.data(),work.data(),n)==0);
        assert(hncs_process_preset_work_float(ctx,pixels.data(),work.data(),n)==0);
        assert(hncs_finish_preset_work_linear(ctx,work.data(),out.data(),n)==0);
        assert(hncs_process_linear_rgba(ctx,pixels.data(),parallel.data(),n)==0);
        assert(std::memcmp(out.data(),parallel.data(),out.size()*sizeof(float))==0);
        assert(hncs_process_linear_rgba_parallel(ctx,pixels.data(),parallel.data(),n,4)==0);
        assert(std::memcmp(out.data(),parallel.data(),out.size()*sizeof(float))==0);
        double m[9],base[3],desired[3],k;
        assert(hncs_source_to_native_matrix(ctx,m)==0);
        assert(hncs_preset_white_balance(ctx,base,desired,&k)==0);
        for(double value:m)assert(std::isfinite(value));
        assert(hncs_process_preset_work_float(ctx,nullptr,nullptr,0)==0);
        assert(hncs_finish_preset_work_linear(ctx,nullptr,nullptr,0)==0);
        assert(hncs_process_preset_work_float(ctx,pixels.data(),work.data(),max)==-1);
        assert(hncs_finish_preset_work_linear(ctx,work.data(),out.data(),max)==-1);
        assert(hncs_render_native_preset(ctx,native.data(),corrected.data(),max)==-1);
        hncs_destroy(ctx);
    }
    assert(hncs_apply_post_curves("nature",1,codes.data(),corrected.data(),max)==-1);
    assert(hncs_apply_preset_pointwise("nature",1,codes.data(),corrected.data(),max)==-1);
    assert(hncs_apply_preset_work_float("nature",1,codes.data(),work.data(),max)==-1);
    assert(hncs_apply_preset_work_float("nature",-1,codes.data(),work.data(),1)==-1);
    assert(hncs_process_preset_work_float(nullptr,pixels.data(),work.data(),1)==-1);
    assert(hncs_finish_preset_work_linear(nullptr,work.data(),out.data(),1)==-1);
    hncs_context *ctx=create();assert(ctx);
    for(float bad:{std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity()}) {
        pixels[0]=bad;work[0]=bad;
        assert(hncs_process_preset_work_float(ctx,pixels.data(),work.data(),1)==-1);
        assert(hncs_finish_preset_work_linear(ctx,work.data(),out.data(),1)==-1);
    }
    hncs_destroy(ctx);
}
