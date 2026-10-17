// Independent transcription of the original HDR film-curve construction.
// Phocus 4.2.2 ordinary film table -> native HDR color-stage table.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>
#include "hncs_assets.inc"

namespace hncs_phocus_hdr {
inline const std::array<float,65536>& linear_film() {
    static const auto values=[] {
        std::array<float,65536> result{};
        for (unsigned i=0;i<result.size();++i)
            result[i]=std::pow(float(assets::v1_gamma[i])/65535.f,2.19921875f);
        return result;
    }();
    return values;
}
inline std::vector<float> apply_gain(double gain,int& join) {
    const auto& film=linear_film();
    std::vector<float> result(65536);
    unsigned i=0;
    for (;i<65536 && double(i)*gain<20000.;++i)
        result[i]=film[std::min(unsigned(double(i)*gain),65535u)];
    if (i==65536) { join=int(i); return result; }
    double slope=0.,intercept=0.;
    unsigned x1=unsigned(double(i)*gain),x0=x1-20u;
    while (x0<65516u) {
        slope=(double(film[x1])-double(film[x0]))/double(x1-x0);
        intercept=double(film[x0])-double(x0)*slope;
        result[i]=film[x1];
        ++i;
        if (intercept+46340.24290506039*slope<1. || i==65536) break;
        x1=unsigned(double(i)*gain);x0=x1-20u;
    }
    join=int(i);
    for (unsigned k=i;k<65536;++k) {
        // The original vectorized tail evaluates lanes 0/1 and 2/3 in these
        // two distinct orders. Preserve them even when real-valued algebra agrees.
        result[k]=float(intercept+(((k-i)%4<2)?(gain*slope)*double(k):(gain*double(k))*slope));
    }
    return result;
}
inline std::vector<float> apply_highlight(std::vector<float> values,int join,double gain) {
    if (join>=10 && join<65526) {
        const double x=join;
        const double delta=65535./gain-x;
        const double slope=(double(values[join+10])-double(values[join-10]))/20.;
        const double a=((1.4142135623730951-double(values[join]))-delta*slope)/(delta*delta);
        const double b=slope+(x*a)*-2.;
        const double c=(double(values[join])+x*-(a*x))-x*b;
        for (unsigned i=unsigned(join);i<65536;++i) {
            const double p=i;
            values[i]=float((c+p*b)+(p*p)*a);
        }
        const double white=65535./gain;
        if (white<65535.) {
            const unsigned start=unsigned(white);
            const double slope2=double(values[start+1])-double(values[start]);
            const double intercept=std::fma(-slope2,double(start),double(values[start]));
            for (unsigned i=start+1;i<65536;++i)
                values[i]=float(std::fma(slope2,double(i),intercept));
        }
    }
    return values;
}
inline std::vector<float> curve(double gain,bool reproduction=false) {
    std::vector<float> result(65536);
    if (reproduction) {
        for (unsigned i=0;i<65536;++i) result[i]=(float(i)/65535.f)*float(gain);
    } else {
        int join=0;
        result=apply_gain(gain,join);
        result=apply_highlight(std::move(result),join,gain);
    }
    for (auto& value:result) value=(value/(10000.f/203.f))*65535.f;
    return result;
}
}
