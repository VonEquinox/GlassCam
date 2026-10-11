#include "hncs_c.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <cstdint>
#include <cmath>
#include <limits>
#include <new>
#include <vector>
#include "hncs_assets.inc"

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
}

struct hncs_context {
    M incoming{}, outgoing{}, source_to_native{}, legacy_to_xyz{}, display_adaptation{};
    std::vector<double> lut;
    // 65536-entry display decode avoids pow() three times per pixel. This is
    // the original ICC gamma, not an approximate color correction / RGB LUT.
    std::array<double,65536> gamma_decode{};
    std::array<uint8_t,65536> srgb_encode{};
    double exposure=1., shadow_a=0., shadow_b=0., shadow_d=1.;
    int width=0,height=0;
    double cb0=0., cr0=0.;
    bool reproduction=false;
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
        double t=assets::shadow_desaturation[0];
        shadow_a=assets::shadow_desaturation[1]/(t*t);
        shadow_b=-2*shadow_a*t; shadow_d=shadow_a*t*t+1;
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
    inline std::array<uint16_t,3> render(const V& native) const {
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
        const double shadow=y<=assets::shadow_desaturation[0]?(shadow_a*y)*y+shadow_b*y+shadow_d:1.;
        if(!reproduction)weight=std::max(0.,std::min(weight,shadow));
        double cb=(y*weight)*mapped[0],cr=(y*weight)*mapped[1];
        std::array<uint16_t,3> result{};
        for(int c=0;c<3;++c) {
            // Native uses Y as baseline; not full inverse-matrix multiplication.
            double linear=y>0?y+(cb*outgoing[c*3+1]+cr*outgoing[c*3+2]):0;
            result[c]=curve[size_t(clamp(linear,0,65535))];
        }
        return result;
    }
    inline V display_linear(const std::array<uint16_t,3>& codes) const {
        V linear={gamma_decode[codes[0]],gamma_decode[codes[1]],gamma_decode[codes[2]]};
        // Keep the original stage order instead of folding matrices together.
        V rgb=transform(xyz_to_srgb,transform(display_adaptation,transform(legacy_to_xyz,linear)));
        for(double& v:rgb)v=clamp(v,0,1);
        return rgb;
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
extern "C" int hncs_render_native(const hncs_context *c,const double *input,uint16_t *output,size_t count) {
    if(!c||(!input&&count)||(!output&&count)||count>std::numeric_limits<size_t>::max()/sizeof(double)/3)return -1;
    for(size_t i=0;i<count;++i) {
        V p={input[i*3],input[i*3+1],input[i*3+2]}; if(!finite(p))return -1;
        auto codes=c->render(p);for(int j=0;j<3;++j)output[i*3+j]=codes[j];
    }return 0;
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
