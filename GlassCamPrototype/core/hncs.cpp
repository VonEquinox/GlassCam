#include "hncs_c.h"
#include "hncs_phocus_post.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <cstdint>
#include <cmath>
#include <limits>
#include <new>
#include <cstring>
#include <string>
#include <vector>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif
#include "hncs_phocus_hdr.hpp"
#include "hncs_phocus_hdr_post.hpp"
#include "hncs_x2d_hdr_gradation.inc"
#include "hncs_preset_assets.inc"
#include "hncs_whitepoint_assets.inc"

namespace {
using V = std::array<double,3>;
using M = std::array<double,9>;
inline double clamp(double x,double lo,double hi) {return std::max(lo,std::min(x,hi));}
M matrix(const double *a) {M m{}; std::copy(a,a+9,m.begin()); return m;}
M mul(const M& a,const M& b) {
    M c{};
    for(int r=0;r<3;++r) for(int k=0;k<3;++k)
        c[r*3+k]=(a[r*3]*b[k]+a[r*3+1]*b[3+k])+a[r*3+2]*b[6+k];
    return c;
}
V transform(const M& a,const V& v) {
    return {(a[0]*v[0]+a[1]*v[1])+a[2]*v[2],
            (a[3]*v[0]+a[4]*v[1])+a[5]*v[2],
            (a[6]*v[0]+a[7]*v[1])+a[8]*v[2]};
}
M inverse(const M& a) {
    const double d=a[0]*(a[4]*a[8]-a[5]*a[7])-a[1]*(a[3]*a[8]-a[5]*a[6])+a[2]*(a[3]*a[7]-a[4]*a[6]);
    return {(a[4]*a[8]-a[5]*a[7])/d,(a[2]*a[7]-a[1]*a[8])/d,(a[1]*a[5]-a[2]*a[4])/d,
            (a[5]*a[6]-a[3]*a[8])/d,(a[0]*a[8]-a[2]*a[6])/d,(a[2]*a[3]-a[0]*a[5])/d,
            (a[3]*a[7]-a[4]*a[6])/d,(a[1]*a[6]-a[0]*a[7])/d,(a[0]*a[4]-a[1]*a[3])/d};
}
void interpolate(double k,const double *temps,int n,const double *table,size_t count,double *out) {
    // Equivalent to searchsorted(side=left)-1 and interval-index clamping.
    int i=0; while(i<n && temps[i]<k) ++i; i=std::max(0,std::min(i-1,n-2));
    const double f=(k-temps[i])/(temps[i+1]-temps[i]);
    for(size_t j=0;j<count;++j)out[j]=table[size_t(i)*count+j]*(1-f)+table[size_t(i+1)*count+j]*f;
}
const M bradford={.8951,.2664,-.1614,-.7502,1.7135,.0367,.0389,-.0685,1.0296};
const V d65={.95047,1.,1.08883};
const M srgb_to_xyz={.4124564,.3575761,.1804375,.2126729,.7151522,.0721750,.0193339,.1191920,.9503041};
const M xyz_to_srgb={3.2404542,-1.5371385,-.4985314,-.969266,1.8760108,.041556,.0556434,-.2040259,1.0572252};
M adaptation(const V& source,const V& target) {
    V a=transform(bradford,source), b=transform(bradford,target);
    M scale={b[0]/a[0],0,0,0,b[1]/a[1],0,0,0,b[2]/a[2]};
    return mul(mul(inverse(bradford),scale),bradford);
}
// Independent of the host rounding mode, and identical to np.rint for [0,65535].
inline double round_even(double x) {
    const double f=std::floor(x), d=x-f;
    return f + ((d>.5 || (d==.5 && std::fmod(f,2.)!=0.)) ? 1. : 0.);
}
inline bool finite(const V& v) {return std::isfinite(v[0])&&std::isfinite(v[1])&&std::isfinite(v[2]);}
using Codes = std::array<uint16_t,3>;
using F = std::array<float,3>;
const preset_assets::Preset *find_preset(const char *key) {
    if(!key) key="standard";
    // Match the reference's ordinary ASCII case/outer-whitespace normalization.
    std::string normalized(key);
    const auto first=normalized.find_first_not_of(" \t\r\n");
    if(first==std::string::npos)return nullptr;
    normalized=normalized.substr(first,normalized.find_last_not_of(" \t\r\n")-first+1);
    for(char& c:normalized)if(c>='A'&&c<='Z')c=char(c-'A'+'a');
    for(const char *dash:{"\xe2\x80\x93","\xe2\x80\x94"}) {
        size_t position=0;
        while((position=normalized.find(dash,position))!=std::string::npos)normalized.replace(position,3,"-");
    }
    for(const auto& alias:preset_assets::aliases)
        if(normalized==alias.key)return preset_assets::catalog[alias.index];
    return nullptr;
}
// RecoverHue intentionally mixes Float32 arithmetic and double constants.
// Do not simplify the divide/multiply or hue reconstruction boundaries.
F recover_hue(const Codes& original,const Codes& adjusted) {
    F rgb{},mapped{};
    for(int i=0;i<3;++i) {rgb[i]=float(original[i])/65535.f;mapped[i]=float(adjusted[i])/65535.f;}
    const float lo=std::min({rgb[0],rgb[1],rgb[2]}),hi=std::max({rgb[0],rgb[1],rgb[2]}),span=hi-lo;
    const float divisor=span!=0.f?span:1.f;
    float hue=hi==rgb[0]?((rgb[1]-rgb[2])*60.f)/divisor:
        hi==rgb[1]?((rgb[2]-rgb[0])*60.f)/divisor+120.f:((rgb[0]-rgb[1])*60.f)/divisor+240.f;
    if(hi==rgb[0]&&rgb[1]<rgb[2])hue=hue+360.f;
    if(span==0.f)hue=0.f;
    const float bottom=std::min({mapped[0],mapped[1],mapped[2]}),top=std::max({mapped[0],mapped[1],mapped[2]});
    const float light=(bottom+top)*.5f,delta=top-bottom;
    const float low_s=light>float(1./65535.)?(delta*.5f)/light:0.f;
    const float low_p=light*(1.f+low_s);
    const float denominator=float(2.-2.*double(light));
    const float high_s=double(light)<1.-1./65535.?delta/denominator:0.f;
    const float high_p=float(double(light+high_s)-double(light)*double(high_s));
    const double p=light<.5f?double(low_p):double(high_p);
    const double q=double(light+light)-p,normalized_hue=double(hue/360.f),amplitude=(p-q)*6.;
    constexpr double offsets[3]={.3333333432674408,0.,-.3333333432674408};
    F color{};
    for(int i=0;i<3;++i) {
        double t=normalized_hue+offsets[i];if(t<0.)t+=1.;else if(t>1.)t-=1.;
        const double v=t<.1666666716337204?amplitude*t+q:
            t<.5?p:t<.6666666865348816?amplitude*(.6666666865348816-t)+q:q;
        color[i]=float(v)*65535.f;
    }
    return color;
}
Codes post_curves(const preset_assets::Preset& preset,bool tone,const Codes& input) {
    const auto& mode=preset.mode[tone?1:0];
    // Phocus 4.2.2 runs CGradationFilter even with no user curve adjustments.
    // Its channel tables and RecoverHue have observable UInt16 rounding.
    // mode.active describes tool settings, not whether this stage can be skipped.
    Codes base{};
    for(int i=0;i<3;++i)base[i]=preset_assets::tables[mode.table[i]][input[i]];
    F ratio[2]={{1.f,1.f,1.f},{1.f,1.f,1.f}};
    for(int stage=0;stage<2;++stage) {
        if(stage==1&&!mode.luma)continue;
        Codes mapped{};
        for(int i=0;i<3;++i)mapped[i]=preset_assets::tables[mode.table[3+stage]][base[i]];
        const F recovered=recover_hue(base,mapped);
        for(int i=0;i<3;++i)ratio[stage][i]=base[i]?recovered[i]/float(base[i]):recovered[i];
    }
    Codes out{};
    for(int i=0;i<3;++i) {
        const float value=(float(base[i])*ratio[0][i])*ratio[1][i];
        out[i]=uint16_t(std::max(0.f,std::min(value,65535.f))); // truncate, never rint
    }
    return out;
}
Codes hdr_post_curves(const x2d_hdr_gradation_assets::Preset& preset,const Codes& input) {
    // Same native gradation arithmetic, with tables generated in the distinct
    // HDR work domain. The existing SDR assets and entry points stay separate.
    Codes base{};
    for(int i=0;i<3;++i)base[i]=x2d_hdr_gradation_assets::tables[preset.table[i]][input[i]];
    F ratio[2]={{1.f,1.f,1.f},{1.f,1.f,1.f}};
    for(int stage=0;stage<2;++stage) {
        if(stage==1&&!preset.luma)continue;
        Codes mapped{};
        for(int i=0;i<3;++i)mapped[i]=x2d_hdr_gradation_assets::tables[preset.table[3+stage]][base[i]];
        const F recovered=recover_hue(base,mapped);
        for(int i=0;i<3;++i)ratio[stage][i]=base[i]?recovered[i]/float(base[i]):recovered[i];
    }
    Codes output{};
    for(int i=0;i<3;++i) {
        const float value=(float(base[i])*ratio[0][i])*ratio[1][i];
        output[i]=uint16_t(std::max(0.f,std::min(value,65535.f)));
    }
    return output;
}
F preset_work(const preset_assets::Preset *preset,bool tone,const Codes& input) {
    Codes saturation_codes=input;
    if(preset&&preset->saturation!=0.) {
        F work{};for(int i=0;i<3;++i)work[i]=float(input[i])/65535.f;
        const float mean=((work[0]+work[1])+work[2])/3.f;
        const float scale=float(1.+preset->saturation/100.);
        for(int i=0;i<3;++i) {
            const float value=mean+(work[i]-mean)*scale;
            saturation_codes[i]=uint16_t(round_even(double(std::max(0.f,std::min(value,1.f))*65535.f)));
        }
    }
    const Codes adjusted=preset?post_curves(*preset,tone,saturation_codes):saturation_codes;
    F work{};for(int i=0;i<3;++i)work[i]=float(adjusted[i])/65535.f;
    if(preset&&preset->grayscale) {
        F gray{};for(int i=0;i<3;++i)gray[i]=work[i]*(float(preset->gray[i])/100.f);
        const float value=(gray[0]+gray[1])+gray[2];work={value,value,value};
    }
    return work;
}
Codes finish_work(const F& work) {
    Codes out{};
    for(int i=0;i<3;++i)out[i]=uint16_t(round_even(double(std::max(0.f,std::min(work[i],1.f))*65535.f)));
    return out;
}
F phocus_work(const preset_assets::Preset *preset,bool tone,const Codes& input) {
    const Codes adjusted=preset?post_curves(*preset,tone,input):input;
    return {float(adjusted[0])/65535.f,float(adjusted[1])/65535.f,float(adjusted[2])/65535.f};
}
Codes phocus_post_spatial(const preset_assets::Preset *preset,const Codes& input) {
    if(!preset)return input;
    Codes output=hncs_phocus_post::saturation(input,preset->saturation);
    if(preset->grayscale)
        output=hncs_phocus_post::grayscale(output,{preset->gray[0]/100.,preset->gray[1]/100.,preset->gray[2]/100.});
    return output;
}
}

struct hncs_context {
    M incoming{}, outgoing{}, source_to_native{}, legacy_to_xyz{}, display_adaptation{};
    std::vector<double> lut;
    // 65536-entry display decode avoids pow() three times per pixel. This is
    // the original ICC gamma, not an approximate color correction / RGB LUT.
    std::array<double,65536> gamma_decode{};
    std::array<uint8_t,65536> srgb_encode{};
    double exposure=1., shadow_threshold=0., shadow_a=0., shadow_b=0., shadow_d=1.;
    int width=0,height=0;
    double cb0=0., cr0=0.;
    bool reproduction=false;
    const preset_assets::Preset *preset=nullptr;
    bool preset_tone=true;
    bool preset_pointwise_active=false;
    V capture_target_wb={1.,1.,1.},target_wb={1.,1.,1.};
    double factory_kelvin=0.;
    const uint16_t *curve=assets::v1_gamma;
    explicit hncs_context(double ev,double kelvin,bool lstar=false,bool repro=false) {
        reproduction=repro;
        curve=lstar?(repro?assets::pure_lstar:assets::v1_lstar):(repro?assets::pure_gamma:assets::v1_gamma);
        double k=clamp(std::trunc(kelvin),2000,10000);
        M camera{};
        interpolate(k,assets::matrix_temperatures,4,assets::camera_to_xyz,9,camera.data());
        const M yuv=matrix(assets::rgb_to_ycbcr);
        legacy_to_xyz=matrix(lstar?assets::working_rgb_to_xyz:assets::legacy_rgb_to_xyz);
        incoming=mul(mul(yuv,matrix(assets::xyz_to_legacy_rgb)),camera);
        // Preserve the original expression, including inverse(W) @ W.
        outgoing=mul(mul(inverse(legacy_to_xyz),matrix(assets::legacy_rgb_to_xyz)),inverse(yuv));
        if(repro) for(double& v:incoming)v*=1.7;
        width=int(assets::grid[1]-assets::grid[0])+1;
        height=int(assets::grid[3]-assets::grid[2])+1;
        lut.resize(size_t(width)*height*2);
        interpolate(k,assets::wb_temperatures,3,repro?assets::lut_repro:assets::lut_std,lut.size(),lut.data());
        cb0=assets::grid[0];cr0=assets::grid[2];
        if(lstar) {
            int left=int(assets::lut_expansion[0]),top=int(assets::lut_expansion[1]);
            int right=int(assets::lut_expansion[2]),bottom=int(assets::lut_expansion[3]);
            int ew=width+left+right,eh=height+top+bottom;
            std::vector<double> expanded(size_t(ew)*eh*2);
            // Unit-slope extension, horizontal first then vertical. The other
            // mapped coordinate remains at the nearest boundary.
            for(int y=0;y<eh;++y) for(int x=0;x<ew;++x) {
                int sx=std::max(0,std::min(x-left,width-1));
                int sy=std::max(0,std::min(y-top,height-1));
                size_t dest=size_t(y*ew+x)*2,src=size_t(sy*width+sx)*2;
                double u=lut[src],v=lut[src+1];
                if(x<left)u=(u+x)-left;
                else if(x>=left+width)u=((u+x)-(left+width))+1;
                if(y<top)v=(v+y)-top;
                else if(y>=top+height)v=((v+y)-(top+height))+1;
                expanded[dest]=u;expanded[dest+1]=v;
            }
            lut.swap(expanded);width=ew;height=eh;cb0-=left;cr0-=top;
        }
        set_native_processing_gain(1.);
        exposure=std::exp2(ev);
        source_to_native=mul(mul(inverse(camera),adaptation(d65,transform(camera,{1.,1.,1.}))),srgb_to_xyz);
        display_adaptation=adaptation(transform(legacy_to_xyz,{1.,1.,1.}),d65);
        for(size_t i=0;i<gamma_decode.size();++i)
            {
                double encoded=double(i)/65535.;
                double srgb=encoded<=.0031308?12.92*encoded:1.055*std::pow(encoded,1./2.4)-.055;
                srgb_encode[i]=uint8_t(round_even(clamp(srgb*255.,0,255)));
                gamma_decode[i]=lstar?(encoded<=.08?encoded/(24389./2700.):std::pow((encoded+.16)/1.16,3.))
                                      :std::pow(encoded,assets::legacy_icc_gamma[0]);
            }
    }
    bool set_native_processing_gain(double gain) {
        if(!std::isfinite(gain)||gain<=0.)return false;
        const double threshold=assets::shadow_desaturation[0]/gain;
        const double a=assets::shadow_desaturation[1]/(threshold*threshold);
        // CRawColorCorrection::CalculateDesatValues (Phocus 4.2.2, 0x15304).
        // Preserve the native products. Gain describes already prepared input;
        // it changes the dark-chroma threshold, not the RGB exposure again.
        const double b=(threshold*a)*-2.;
        const double d=(threshold*threshold)*a+1.;
        if(!std::isfinite(threshold)||threshold<=0.||!std::isfinite(a)||
           !std::isfinite(b)||!std::isfinite(d))return false;
        shadow_threshold=threshold;shadow_a=a;shadow_b=b;shadow_d=d;
        return true;
    }
    inline std::array<uint16_t,3> render(const V& native,const uint16_t* native_curve=nullptr) const {
        V p={round_even(clamp(native[0],0,1)*65535.),round_even(clamp(native[1],0,1)*65535.),round_even(clamp(native[2],0,1)*65535.)};
        V yuv=transform(incoming,p); const double y=yuv[0];
        double x=clamp((y>0?yuv[1]/y:0)*assets::grid[4]-cb0,0,width-1);
        double z=clamp((y>0?yuv[2]/y:0)*assets::grid[4]-cr0,0,height-1);
        int x0=int(std::floor(x)),z0=int(std::floor(z)),x1=std::min(x0+1,width-1),z1=std::min(z0+1,height-1);
        double fx=x-x0,fy=z-z0;
        size_t i00=size_t(z0*width+x0)*2,i01=size_t(z1*width+x0)*2;
        size_t i10=size_t(z0*width+x1)*2,i11=size_t(z1*width+x1)*2;
        double mapped[2];
        for(int c=0;c<2;++c)
            mapped[c]=((lut[i00+c]*(1-fy)+lut[i01+c]*fy)*(1-fx)+(lut[i10+c]*(1-fy)+lut[i11+c]*fy)*fx)/assets::grid[4];
        double weight=1.;
        if(assets::gray_thresholds[0]>assets::gray_thresholds[1]) {
            double mean=(p[0]+p[1]+p[2])/3.;
            double saturation=mean>0?std::max({std::abs(p[0]-mean),std::abs(p[1]-mean),std::abs(p[2]-mean)})/mean:0;
            weight=clamp((saturation-assets::gray_thresholds[1])/(assets::gray_thresholds[0]-assets::gray_thresholds[1]),0,1);
        }
        const double shadow=y<=shadow_threshold?(shadow_a*y)*y+shadow_b*y+shadow_d:1.;
        if(!reproduction)weight=std::max(0.,std::min(weight,shadow));
        double cb=(y*weight)*mapped[0],cr=(y*weight)*mapped[1];
        std::array<uint16_t,3> result{};
        for(int c=0;c<3;++c) {
            // Native uses Y as baseline; not full inverse-matrix multiplication.
            double linear=y>0?y+(cb*outgoing[c*3+1]+cr*outgoing[c*3+2]):0;
            result[c]=(native_curve?native_curve:curve)[size_t(clamp(linear,0,65535))];
        }
        return result;
    }
    inline V display_linear_core(const std::array<uint16_t,3>& codes) const {
        V linear={gamma_decode[codes[0]],gamma_decode[codes[1]],gamma_decode[codes[2]]};
        // Keep the original stage order instead of folding matrices together.
        V rgb=transform(xyz_to_srgb,transform(display_adaptation,transform(legacy_to_xyz,linear)));
        for(double& v:rgb)v=clamp(v,0,1);
        return rgb;
    }
    inline V display_linear(const std::array<uint16_t,3>& codes) const {
        return display_linear_core(preset_pointwise_active?finish_work(preset_work(preset,preset_tone,codes)):codes);
    }
    inline V display(const std::array<uint16_t,3>& codes) const {
        V rgb=display_linear(codes);
        for(double& v:rgb)v=v<=.0031308?12.92*v:1.055*std::pow(v,1./2.4)-.055;
        return rgb;
    }
};
extern "C" hncs_context *hncs_create(double ev,double kelvin) {
    if(!std::isfinite(ev)||ev < -20.||ev > 20.||!std::isfinite(kelvin))return nullptr;
    try {return new hncs_context(ev,kelvin);} catch(...) {return nullptr;}
}
extern "C" hncs_context *hncs_create_mode(double ev,double kelvin,int lstar,int reproduction) {
    if(!std::isfinite(ev)||ev < -20.||ev > 20.||!std::isfinite(kelvin) || (lstar!=0&&lstar!=1) || (reproduction!=0&&reproduction!=1))return nullptr;
    try {return new hncs_context(ev,kelvin,lstar!=0,reproduction!=0);} catch(...) {return nullptr;}
}
extern "C" void hncs_destroy(hncs_context *c) {delete c;}
extern "C" hncs_context *hncs_clone_with_native_gain(const hncs_context *source,double gain) {
    if(!source||!std::isfinite(gain)||gain<=0.)return nullptr;
    try {
        auto context=std::make_unique<hncs_context>(*source);
        if(!context->set_native_processing_gain(gain))return nullptr;
        return context.release();
    } catch(...) {return nullptr;}
}
extern "C" int hncs_render_native(const hncs_context *c,const double *input,uint16_t *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(double)/3)return -1;
    for(size_t i=0;i<count;++i) {
        V p={input[i*3],input[i*3+1],input[i*3+2]}; if(!finite(p))return -1;
        auto codes=c->render(p);for(int j=0;j<3;++j)output[i*3+j]=codes[j];
    }return 0;
}
extern "C" int hncs_render_x2d_hdr_color(const hncs_context *source,double gain,const double *input,
                                         uint16_t *output,size_t count) {
    if(!source||source->reproduction||
       (source->curve!=assets::v1_gamma&&source->curve!=assets::v1_lstar)||
       !std::isfinite(gain)||gain<.25||gain>32.||
       (!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(double)/3)return -1;
    for(size_t i=0;i<count*3;++i)if(!std::isfinite(input[i]))return -1;
    try {
        auto context=std::make_unique<hncs_context>(*source);
        if(!context->set_native_processing_gain(gain))return -1;
        const auto floating=hncs_phocus_hdr::curve(gain);
        std::vector<uint16_t> curve(floating.size());
        for(size_t i=0;i<curve.size();++i) {
            if(!std::isfinite(floating[i])||floating[i]<0.f||floating[i]>65535.f)return -1;
            curve[i]=uint16_t(floating[i]);
        }
        for(size_t i=0;i<count;++i) {
            const auto result=context->render({input[i*3],input[i*3+1],input[i*3+2]},curve.data());
            std::copy(result.begin(),result.end(),output+i*3);
        }
        return 0;
    }catch(...) {return -1;}
}
extern "C" int hncs_render_x2d_hdr_post(const uint16_t *input,uint16_t *output,size_t count,
                                        double amount,double saturation,int lstar) {
    if(!std::isfinite(amount)||amount<0.||amount>100.||
       !std::isfinite(saturation)||saturation<0.||saturation>100.||
       (lstar!=0&&lstar!=1)||(!input&&count)||(!output&&count)||
       count>std::numeric_limits<size_t>::max()/sizeof(uint16_t)/3)return -1;
    const auto a=reinterpret_cast<uintptr_t>(input),b=reinterpret_cast<uintptr_t>(output);
    if(a!=b&&(a<b?b-a:a-b)<count*3*sizeof(uint16_t))return -1;
    for(size_t i=0;i<count;++i) {
        const hncs_phocus_hdr_post::Codes p={input[i*3],input[i*3+1],input[i*3+2]};
        const auto q=hncs_phocus_hdr_post::gamma(hncs_phocus_hdr_post::highlight(p,amount,saturation),lstar!=0);
        std::copy(q.begin(),q.end(),output+i*3);
    }
    return 0;
}
extern "C" int hncs_apply_x2d_hdr_gradation(const char *key,const uint16_t *input,uint16_t *output,size_t count) {
    if(!key||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(uint16_t)/3)return -1;
    const auto a=reinterpret_cast<uintptr_t>(input),b=reinterpret_cast<uintptr_t>(output);
    if(a!=b&&(a<b?b-a:a-b)<count*3*sizeof(uint16_t))return -1;
    for(const auto &preset:x2d_hdr_gradation_assets::presets)if(std::strcmp(preset.key,key)==0) {
        for(size_t i=0;i<count;++i) {
            const auto result=hdr_post_curves(preset,{input[i*3],input[i*3+1],input[i*3+2]});
            std::copy(result.begin(),result.end(),output+i*3);
        }
        return 0;
    }
    return -1;
}
extern "C" int hncs_process_srgb(const hncs_context *c,const float *input,uint8_t *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3)return -1;
    // Fused pixel loop: O(1) scratch; caller may parallelize nonoverlapping rows.
    for(size_t i=0;i<count;++i) {
        V p={double(input[i*3])*c->exposure,double(input[i*3+1])*c->exposure,double(input[i*3+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);if(!finite(p))return -1;
        V rgb=c->display(c->render(p));
        for(int j=0;j<3;++j)output[i*4+j]=uint8_t(round_even(clamp(rgb[j]*255.,0,255)));
        output[i*4+3]=255;
    }return 0;
}

extern "C" int hncs_process_srgb_fast(const hncs_context *c,const float *input,uint8_t *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3)return -1;
    // Only final display encoding is approximated. All original HNCS arithmetic,
    // uint16 boundaries and Bradford conversion are identical to the exact API.
    for(size_t i=0;i<count;++i) {
        V p={double(input[i*3])*c->exposure,double(input[i*3+1])*c->exposure,double(input[i*3+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);if(!finite(p))return -1;
        V linear=c->display_linear(c->render(p));
        for(int j=0;j<3;++j)output[i*4+j]=c->srgb_encode[size_t(round_even(linear[j]*65535.))];
        output[i*4+3]=255;
    }return 0;
}

extern "C" int hncs_process_linear_rgba(const hncs_context *c,const float *input,float *output,size_t count) {
    // RGBA float output is larger than RGB float input; this bound protects
    // both byte sizes and all component-index multiplications below.
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/4)return -1;
    for(size_t i=0;i<count;++i) {
        V p={double(input[i*3])*c->exposure,double(input[i*3+1])*c->exposure,double(input[i*3+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);if(!finite(p))return -1;
        // Preserve render's original UInt16 quantization and exact stage order.
        // Only the final double-to-float storage conversion occurs here.
        V linear=c->display_linear(c->render(p));
        for(int j=0;j<3;++j)output[i*4+j]=float(linear[j]);
        output[i*4+3]=1.f;
    }return 0;
}

extern "C" int hncs_process_srgb_fast_parallel(const hncs_context *c,const float *input,uint8_t *output,size_t count,unsigned workers) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3||workers<1||workers>4)return -1;
    // Avoid launch overhead for small buffers. Context is immutable and each
    // worker writes a disjoint contiguous pixel range with constant scratch.
    if(workers==1||count<65536)return hncs_process_srgb_fast(c,input,output,count);
    std::atomic<int> status{0};
    const size_t base=count/workers,remainder=count%workers;
    auto run=[&](unsigned index) {
        size_t start=base*index+std::min(size_t(index),remainder);
        size_t length=base+(index<remainder?1:0);
        if(hncs_process_srgb_fast(c,input+start*3,output+start*4,length)!=0)
            status.store(-1,std::memory_order_relaxed);
    };
    // Fixed-size thread storage needs no allocation. If thread creation fails,
    // already-started ranges continue and the unlaunched ranges run here.
    std::array<std::thread,3> threads;
    unsigned launched=0;
    try {
        for(;launched+1<workers;++launched)threads[launched]=std::thread(run,launched);
    } catch(...) { /* Bounded, safe sequential fallback for remaining tiles. */ }
    for(unsigned i=launched;i<workers;++i)run(i);
    for(unsigned i=0;i<launched;++i)if(threads[i].joinable())threads[i].join();
    return status.load(std::memory_order_relaxed);
}

namespace {
using FloatOperation = int (*)(const hncs_context*,const float*,float*,size_t);
// Every operation is pointwise. Work scheduling never changes a pixel's
// expression order, precision, table lookup, or rounding boundaries.
int parallel_float(const hncs_context *c,const float *input,float *output,size_t count,
                   unsigned workers,size_t output_channels,FloatOperation operation) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/output_channels||workers<1||workers>4)return -1;
    // Avoid launch overhead for small buffers. Context is immutable and each
    // worker writes a disjoint contiguous pixel range with constant scratch.
    if(workers==1||count<65536)return operation(c,input,output,count);
#if defined(__APPLE__)
    struct Work {
        const hncs_context *context;
        const float *input;
        float *output;
        size_t count,channels;
        FloatOperation operation;
        std::atomic<size_t> next{0};
        std::atomic<int> status{0};
    } work{c,input,output,count,output_channels,operation};
    // Reuse libdispatch threads instead of creating three pthreads per strip.
    // Small claims let faster cores take more pixels without exceeding the
    // caller's low-power/thermal worker budget. dispatch_apply_f is synchronous.
    dispatch_apply_f(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&work,
        [](void *opaque,size_t) {
            auto& w=*static_cast<Work*>(opaque);
            constexpr size_t chunk=32768;
            for(;;) {
                const size_t start=w.next.fetch_add(chunk,std::memory_order_relaxed);
                if(start>=w.count)break;
                const size_t length=std::min(chunk,w.count-start);
                if(w.operation(w.context,w.input+start*3,w.output+start*w.channels,length)!=0)
                    w.status.store(-1,std::memory_order_relaxed);
            }
        });
    return work.status.load(std::memory_order_relaxed);
#else
    std::atomic<int> status{0};
    const size_t base=count/workers,remainder=count%workers;
    auto run=[&](unsigned index) {
        size_t start=base*index+std::min(size_t(index),remainder);
        size_t length=base+(index<remainder?1:0);
        if(operation(c,input+start*3,output+start*output_channels,length)!=0)
            status.store(-1,std::memory_order_relaxed);
    };
    // Fixed-size thread storage needs no allocation. If thread creation fails,
    // already-started ranges continue and the unlaunched ranges run here.
    std::array<std::thread,3> threads;
    unsigned launched=0;
    try {
        for(;launched+1<workers;++launched)threads[launched]=std::thread(run,launched);
    } catch(...) { /* Bounded, safe sequential fallback for remaining tiles. */ }
    for(unsigned i=launched;i<workers;++i)run(i);
    for(unsigned i=0;i<launched;++i)if(threads[i].joinable())threads[i].join();
    return status.load(std::memory_order_relaxed);
#endif
}
}

// Exact Float export parallelism: identical per-pixel math, disjoint output.
extern "C" int hncs_process_linear_rgba_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,4,hncs_process_linear_rgba);
}

extern "C" size_t hncs_preset_count(void) {
    return sizeof(preset_assets::catalog)/sizeof(preset_assets::catalog[0]);
}
extern "C" const char *hncs_preset_key(size_t index) {
    return index<hncs_preset_count()?preset_assets::catalog[index]->key:nullptr;
}
extern "C" const char *hncs_preset_name(size_t index) {
    return index<hncs_preset_count()?preset_assets::catalog[index]->name:nullptr;
}
extern "C" unsigned hncs_preset_flags(const char *key) {
    try { const auto *p=find_preset(key);return p?p->flags:std::numeric_limits<unsigned>::max(); }
    catch(...) {return std::numeric_limits<unsigned>::max();}
}
extern "C" const char *hncs_preset_settings_json(const char *key) {
    try {const auto *p=find_preset(key);return p?p->json:nullptr;} catch(...) {return nullptr;}
}
extern "C" int hncs_whitepoint_parameters(double x,double y,double *capture_wb,double *kelvin) {
    if(!capture_wb||!kelvin||!std::isfinite(x)||!std::isfinite(y)||x<=0.||y<=0.||x+y>=1.)return -1;
    const V white={x/y,1.,(1.-x-y)/y};
    // The same virtual sensor response used by the reference GainToTempAndTint.
    M response=matrix(assets::camera_to_xyz+18);
    for(int row=0;row<3;++row)for(int col=0;col<3;++col)
        response[row*3+col]*=preset_assets::factory_wb[3+col];
    const V neutral=transform(inverse(response),white);
    if(!finite(neutral)||neutral[0]<=0.||neutral[1]<=0.||neutral[2]<=0.)return -1;
    for(int i=0;i<3;++i)capture_wb[i]=neutral[1]/neutral[i];
    const double denominator=1.5-x+6.*y,u=2.*x/denominator,v=3.*y/denominator;
    double previous=0.;
    for(int i=1;i<31;++i) {
        const auto& r=whitepoint_assets::robertson[i];
        const double distance=((v-r[2])-(u-r[1])*r[3])/std::sqrt(1.+r[3]*r[3]);
        if(distance<=0.||i==30) {
            double temperature=50000.;
            if(i>1) {
                const double d=std::min(distance,0.),fraction=-d/(previous-d);
                const double mired=whitepoint_assets::robertson[i-1][0]*fraction+r[0]*(1.-fraction);
                if(!std::isfinite(mired)||mired<=0.)return -1;
                temperature=std::floor(1e6/mired+.5);
            }
            *kelvin=clamp(temperature,2000.,10000.);return 0;
        }
        previous=distance;
    }
    return -1;
}

extern "C" hncs_context *hncs_create_preset_whitepoint(double ev,double x,double y,double factory_override,
    int lstar,int repro,int film_type,int raw_type,const char *key,int tone) {
    V baseline{};double kelvin=0.;
    if(hncs_whitepoint_parameters(x,y,baseline.data(),&kelvin)!=0)return nullptr;
    hncs_context *context=hncs_create_preset(ev,kelvin,factory_override,lstar,repro,film_type,raw_type,key,tone,baseline.data(),nullptr);
    if(!context)return nullptr;
    const V white={x/y,1.,(1.-x-y)/y};
    M response=matrix(assets::camera_to_xyz+18);
    for(int row=0;row<3;++row)for(int col=0;col<3;++col)
        response[row*3+col]*=preset_assets::factory_wb[3+col];
    const M unbalanced=mul(mul(inverse(response),adaptation(d65,white)),srgb_to_xyz);
    const V neutral=transform(inverse(response),white);
    M adapter=unbalanced;
    for(int row=0;row<3;++row)for(int col=0;col<3;++col)
        adapter[row*3+col]*=context->target_wb[row]/neutral[1];
    for(double value:adapter)if(!std::isfinite(value)){delete context;return nullptr;}
    context->source_to_native=adapter;
    return context;
}
extern "C" hncs_context *hncs_create_preset(double ev,double capture_kelvin,double factory_override,
    int lstar,int repro,int film_type,int raw_type,const char *key,int tone,
    const double *capture_wb,const double *desired_wb) {
    if(!std::isfinite(ev)||ev < -20.||ev > 20.||!std::isfinite(capture_kelvin)||
       !std::isfinite(factory_override)||(lstar!=0&&lstar!=1)||(repro!=0&&repro!=1)||
       (tone!=0&&tone!=1)||(film_type!=0&&film_type!=1&&film_type!=2&&film_type!=4&&film_type!=6&&film_type!=7))return nullptr;
    try {
        const auto *preset=find_preset(key);if(!preset)return nullptr;
        const double capture=clamp(std::trunc(capture_kelvin),2000,10000);
        const double factory=clamp(std::trunc(factory_override!=0.?factory_override:
            preset->cct!=0.?preset->cct:capture_kelvin),2000,10000);
        V baseline{},desired{};
        if(capture_wb)std::copy(capture_wb,capture_wb+3,baseline.begin());
        else interpolate(clamp(capture,assets::wb_temperatures[0],assets::wb_temperatures[2]),
            assets::wb_temperatures,3,preset_assets::factory_wb,3,baseline.data());
        const bool replace=desired_wb||preset->wb[0]>0.;
        if(desired_wb)std::copy(desired_wb,desired_wb+3,desired.begin());
        else if(replace)std::copy(preset->wb,preset->wb+3,desired.begin());
        else desired=baseline;
        for(const auto& wb:{baseline,desired})if(!finite(wb)||wb[0]<=0.||wb[1]<=0.||wb[2]<=0.)return nullptr;
        const double bg=baseline[1],dg=desired[1];
        for(int i=0;i<3;++i){baseline[i]/=bg;desired[i]/=dg;}
        if(!finite(baseline)||!finite(desired))return nullptr;
        for(int i=0;i<3;++i)if(baseline[i]<=0.||desired[i]<=0.)return nullptr;
        M camera{};
        interpolate(capture,assets::matrix_temperatures,4,assets::camera_to_xyz,9,camera.data());
        M adapter=mul(mul(inverse(camera),adaptation(d65,transform(camera,{1.,1.,1.}))),srgb_to_xyz);
        if(replace)for(int row=0;row<3;++row)for(int col=0;col<3;++col)adapter[row*3+col]*=desired[row]/baseline[row];
        for(double v:adapter)if(!std::isfinite(v))return nullptr;
        auto *context=new hncs_context(ev,factory,lstar!=0,repro!=0);
        context->preset=preset;context->preset_tone=tone!=0;
        context->preset_pointwise_active=true;
        context->source_to_native=adapter;
        context->capture_target_wb=baseline;context->target_wb=desired;context->factory_kelvin=factory;
        const int resolved=repro?7:film_type==4?raw_type:film_type;
        context->curve=resolved==7?(lstar?assets::pure_lstar:assets::pure_gamma):
            resolved==0&&!lstar?preset_assets::original_gamma:(lstar?assets::v1_lstar:assets::v1_gamma);
        return context;
    } catch(...) {return nullptr;}
}
extern "C" int hncs_apply_post_curves(const char *key,int tone,const uint16_t *input,uint16_t *output,size_t count) {
    if((tone!=0&&tone!=1)||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(uint16_t)/3)return -1;
    try {
        const auto *preset=find_preset(key);if(!preset)return -1;
        for(size_t i=0;i<count;++i){Codes v={input[3*i],input[3*i+1],input[3*i+2]};v=post_curves(*preset,tone!=0,v);for(int j=0;j<3;++j)output[3*i+j]=v[j];}
        return 0;
    } catch(...) {return -1;}
}
extern "C" int hncs_apply_preset_pointwise(const char *key,int tone,const uint16_t *input,uint16_t *output,size_t count) {
    if((tone!=0&&tone!=1)||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(uint16_t)/3)return -1;
    try {
        const auto *preset=find_preset(key);if(!preset)return -1;
        for(size_t i=0;i<count;++i){Codes v={input[3*i],input[3*i+1],input[3*i+2]};v=finish_work(preset_work(preset,tone!=0,v));for(int j=0;j<3;++j)output[3*i+j]=v[j];}
        return 0;
    } catch(...) {return -1;}
}
extern "C" int hncs_render_native_preset(const hncs_context *c,const double *input,uint16_t *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(double)/3)return -1;
    for(size_t i=0;i<count;++i) {
        V p={input[i*3],input[i*3+1],input[i*3+2]};if(!finite(p))return -1;
        const Codes codes=c->preset_pointwise_active?finish_work(preset_work(c->preset,c->preset_tone,c->render(p))):c->render(p);
        for(int j=0;j<3;++j)output[3*i+j]=codes[j];
    }
    return 0;
}
extern "C" int hncs_apply_preset_work_float(const char *key,int tone,const uint16_t *input,float *output,size_t count) {
    if((tone!=0&&tone!=1)||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3)return -1;
    try {
        const auto *preset=find_preset(key);if(!preset)return -1;
        for(size_t i=0;i<count;++i){const F v=preset_work(preset,tone!=0,{input[3*i],input[3*i+1],input[3*i+2]});for(int j=0;j<3;++j)output[3*i+j]=v[j];}
        return 0;
    } catch(...) {return -1;}
}
extern "C" int hncs_process_preset_work_float(const hncs_context *c,const float *input,float *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3)return -1;
    for(size_t i=0;i<count;++i) {
        V p={double(input[i*3])*c->exposure,double(input[i*3+1])*c->exposure,double(input[i*3+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);
        if(!finite(p))return -1;
        const F work=preset_work(c->preset,c->preset_tone,c->render(p));
        for(int j=0;j<3;++j)output[3*i+j]=work[j];
    }
    return 0;
}
extern "C" int hncs_finish_preset_work_linear(const hncs_context *c,const float *input,float *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/4)return -1;
    for(size_t i=0;i<count;++i) {
        const F work={input[3*i],input[3*i+1],input[3*i+2]};
        if(!std::isfinite(work[0])||!std::isfinite(work[1])||!std::isfinite(work[2]))return -1;
        const V linear=c->display_linear_core(finish_work(work));
        for(int j=0;j<3;++j)output[4*i+j]=float(linear[j]);
        output[4*i+3]=1.f;
    }
    return 0;
}
extern "C" int hncs_process_preset_work_float_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,3,hncs_process_preset_work_float);
}
extern "C" int hncs_finish_preset_work_linear_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,4,hncs_finish_preset_work_linear);
}
extern "C" int hncs_apply_phocus_post_spatial(const char *key,const uint16_t *input,uint16_t *output,size_t count) {
    if((!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(uint16_t)/3)return -1;
    const auto *preset=find_preset(key);if(!preset)return -1;
    for(size_t i=0;i<count;++i) {
        const Codes value=phocus_post_spatial(preset,{input[3*i],input[3*i+1],input[3*i+2]});
        for(int ch=0;ch<3;++ch)output[3*i+ch]=value[ch];
    }
    return 0;
}
extern "C" int hncs_process_phocus_work_float(const hncs_context *c,const float *input,float *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/3)return -1;
    for(size_t i=0;i<count;++i) {
        V p={double(input[3*i])*c->exposure,double(input[3*i+1])*c->exposure,double(input[3*i+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);if(!finite(p))return -1;
        const F work=phocus_work(c->preset,c->preset_tone,c->render(p));
        for(int ch=0;ch<3;++ch)output[3*i+ch]=work[ch];
    }
    return 0;
}
extern "C" int hncs_finish_phocus_work_linear(const hncs_context *c,const float *input,float *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/4)return -1;
    for(size_t i=0;i<count;++i) {
        const F work={input[3*i],input[3*i+1],input[3*i+2]};
        if(!std::isfinite(work[0])||!std::isfinite(work[1])||!std::isfinite(work[2]))return -1;
        const V linear=c->display_linear_core(phocus_post_spatial(c->preset,finish_work(work)));
        for(int ch=0;ch<3;++ch)output[4*i+ch]=float(linear[ch]);
        output[4*i+3]=1.f;
    }
    return 0;
}
extern "C" int hncs_process_phocus_linear_rgba(const hncs_context *c,const float *input,float *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(float)/4)return -1;
    for(size_t i=0;i<count;++i) {
        V p={double(input[3*i])*c->exposure,double(input[3*i+1])*c->exposure,double(input[3*i+2])*c->exposure};
        if(!finite(p))return -1;
        p=transform(c->source_to_native,p);if(!finite(p))return -1;
        const V linear=c->display_linear_core(phocus_post_spatial(c->preset,finish_work(phocus_work(c->preset,c->preset_tone,c->render(p)))));
        for(int ch=0;ch<3;++ch)output[4*i+ch]=float(linear[ch]);
        output[4*i+3]=1.f;
    }
    return 0;
}
extern "C" int hncs_process_phocus_work_float_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,3,hncs_process_phocus_work_float);
}
extern "C" int hncs_finish_phocus_work_linear_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,4,hncs_finish_phocus_work_linear);
}
extern "C" int hncs_process_phocus_linear_rgba_parallel(const hncs_context *c,const float *input,float *output,size_t count,unsigned workers) {
    return parallel_float(c,input,output,count,workers,4,hncs_process_phocus_linear_rgba);
}
extern "C" int hncs_source_to_native_matrix(const hncs_context *c,double *out) {
    if(!c||!out)return -1;
    std::copy(c->source_to_native.begin(),c->source_to_native.end(),out);
    return 0;
}
extern "C" int hncs_preset_white_balance(const hncs_context *c,double *capture,double *target,double *kelvin) {
    if(!c||!c->preset||!capture||!target||!kelvin)return -1;
    std::copy(c->capture_target_wb.begin(),c->capture_target_wb.end(),capture);
    std::copy(c->target_wb.begin(),c->target_wb.end(),target);*kelvin=c->factory_kelvin;return 0;
}
