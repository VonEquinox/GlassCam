// Original vector-return ABIs and a separately implemented HDR math candidate.
#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <stdexcept>
#include <vector>
#include "../core/hncs_phocus_hdr.hpp"
template<class F> F native(void* library,const char* name) {
    auto* result=dlsym(library,name);
    if(!result)throw std::runtime_error(name);
    return reinterpret_cast<F>(result);
}
extern "C" int hdr_original_stages(void* library,void* manager,double gain,
                                   float* gain_values,float* highlight_values,float* final_values,int* join) {
    try {
        using Gain=std::vector<float>(*)(void*,double,int&);
        using Highlight=std::vector<float>(*)(void*,std::vector<float>,double,double);
        using Curve=std::vector<float>(*)(void*,double);
        auto base=native<Gain>(library,"_ZN17CGradationManager18GradationApplyGainEdRi")(manager,gain,*join);
        auto high=native<Highlight>(library,"_ZN17CGradationManager23GradationApplyHighlightENSt3__16vectorIfNS0_9allocatorIfEEEEdd")(manager,base,double(*join),gain);
        auto final=native<Curve>(library,"_ZN17CGradationManager20GetGradationCurveHDREd")(manager,gain);
        if(base.size()!=65536 || high.size()!=65536 || final.size()!=65536)return -2;
        std::copy(base.begin(),base.end(),gain_values);std::copy(high.begin(),high.end(),highlight_values);
        for(unsigned i=0;i<65536;++i)final_values[i]=final[i]*65535.f;
        return 0;
    } catch (...) {return -1;}
}
extern "C" void hdr_candidate_stages(double gain,float* base,float* high,float* final,int* join) {
    auto a=hncs_phocus_hdr::apply_gain(gain,*join);
    auto b=hncs_phocus_hdr::apply_highlight(a,*join,gain);
    auto c=hncs_phocus_hdr::curve(gain);
    std::copy(a.begin(),a.end(),base);std::copy(b.begin(),b.end(),high);std::copy(c.begin(),c.end(),final);
}
extern "C" void hdr_candidate_linear_film(float* output) {
    const auto& values=hncs_phocus_hdr::linear_film();std::copy(values.begin(),values.end(),output);
}
