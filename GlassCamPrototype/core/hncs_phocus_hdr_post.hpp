// Phocus 4.2.2 CPU HDR HighlightStrength and gamma, checked against original
// filters. These use a distinct HDR domain, not the ordinary display decoder.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
namespace hncs_phocus_hdr_post {
using Codes=std::array<uint16_t,3>;
using F=std::array<float,3>;
inline F to_hsl(F rgb) {
    const float r=rgb[0],g=rgb[1],b=rgb[2];
    const double low=std::min({double(r),double(g),double(b)}),high=std::max({double(r),double(g),double(b)}),difference=high-low;
    const float light=float((high+low)*.5);float saturation=0,hue=0;
    if(light<.5f){if(double(light)>1./65535.)saturation=float((difference*.5)/double(light));}
    else if(double(light)<65534./65535.)saturation=float(difference/std::fma(double(light),-2.,2.));
    if(high!=low) {
        if(high==r){double h=double((g-b)*60.f)/difference;if(g<b)h+=360.;hue=float(h);}
        else if(high==g)hue=float(double((b-r)*60.f)/difference+120.);
        else hue=float(double((r-g)*60.f)/difference+240.);
    }
    return {hue,saturation,light};
}
inline F from_hsl(F hsl) {
    const float hue=hsl[0],saturation=hsl[1],light=hsl[2];
    const float upper=light>=.5f?std::fma(-light,saturation,saturation+light):(saturation+1.f)*light;
    const double lower=double(light+light)-double(upper),unit=double(hue/360.f),slope=(double(upper)-lower)*6.;
    const double offsets[3]={1./3.,0.,-1./3.};F result{};
    for(unsigned c=0;c<3;++c) {
        double t=unit+offsets[c];if(t<0)t+=1.;if(t>1)t-=1.;
        const double value=t<1./6.?std::fma(slope,t,lower):t<.5?double(upper):t<2./3.?std::fma(slope,2./3.-t,lower):lower;
        result[c]=float(value);
    }
    return result;
}
inline Codes highlight(Codes codes,double amount,double saturation) {
    const double strength=std::fma(amount*4.5e-5,amount,amount*.01);
    auto curve=[&](double x) {
        if(x<.008346684977492943)return x;
        if(x<.020300000000000002)return .005104561436606606+std::fma(x*x,73.27070833656774,x*-.22313504112619367);
        if(strength<=0)return std::fma(x,2.7505376609351897,-.025066868216823274);
        return std::min(-.02580768953630813+std::fma(x*x,-1.7977172935156156,x*2.823524983051924),1.);
    };
    F source{},mapped{};
    for(unsigned c=0;c<3;++c){const double x=double(codes[c])/65535.;source[c]=float(x);mapped[c]=float(curve(x));}
    const auto a=to_hsl(source),b=to_hsl(mapped);
    const float delta=b[1]-a[1];
    const float sat=float(std::fma(double(delta),saturation/100.,
                                  std::fma(double(delta)*-.5,1.-strength,double(a[1]))));
    const float weight=float(strength);
    const float light=std::fma(1.f-weight,a[2],b[2]*weight);
    const auto rgb=from_hsl({a[0],std::max(0.f,sat),light});
    Codes output{};
    // Original arm64 uses FRINTA before clamping and integer conversion.
    for(unsigned c=0;c<3;++c)output[c]=uint16_t(std::max(0.,std::min(std::round(double(rgb[c])*65535.),65535.)));
    return output;
}
inline Codes gamma(Codes codes,bool lstar) {
    constexpr double input_scale=49.26108374384236,output_scale=5.8829245141;
    Codes output{};
    for(unsigned c=0;c<3;++c) {
        const double x=(double(codes[c])/65535.)*input_scale;
        const double mapped=lstar?(x<=216./24389.?x*(24389./2700.):1.16*std::pow(x,1./3.)-.16):std::pow(x,.4547069271758437);
        output[c]=uint16_t(std::max(0.,std::min(std::round((mapped/output_scale)*65535.),65535.)));
    }
    return output;
}
}
