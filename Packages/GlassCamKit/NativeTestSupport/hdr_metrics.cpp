// ITU-R BT.2124: PQ RGB -> BT.2100 LMS -> ITP, scale 720.
#include "native_test_support.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>
namespace {
double clip(double value){return std::max(0.,std::min(value,1.));}
double eotf(double value) {
    const double p=std::pow(clip(value),32./2523.);
    return std::pow(std::max(p-3424./4096.,0.)/(2413./128.-2392./128.*p),16384./2610.);
}
double pq(double value) {
    const double p=std::pow(clip(value),2610./16384.);
    return std::pow((3424./4096.+2413./128.*p)/(1.+2392./128.*p),2523./32.);
}
std::array<double,3> itp(const float* rgb) {
    const double r=eotf(rgb[0]),g=eotf(rgb[1]),b=eotf(rgb[2]);
    const double l=pq((1688*r+2146*g+262*b)/4096.),m=pq((683*r+2951*g+462*b)/4096.),s=pq((99*r+309*g+3688*b)/4096.);
    return {(l+m)*.5,((6610*l-13613*m+7003*s)/4096.)*.5,(17933*l-17390*m-543*s)/4096.};
}
struct State {
    size_t count=0,different=0,black=0,white=0,outside=0,worst=0;
    double sum=0,maximum=0,peakA=0,peakB=0;
    std::vector<double> nonzero;
};
double quantile(const State& s,double q) {
    if(!s.count)return 0;
    const size_t zeros=s.count-s.nonzero.size();
    const double position=q*double(s.count-1);
    const size_t lower=size_t(position),upper=std::min(lower+1,s.count-1);
    auto value=[&](size_t i){return i<zeros?0.:s.nonzero[i-zeros];};
    return value(lower)+(value(upper)-value(lower))*(position-double(lower));
}
}
extern "C" void* hdr_metric_create(){try{return new State;}catch(...){return nullptr;}}
extern "C" int hdr_metric_add(void* opaque,const float* a,const float* b,size_t count) {
    if(!opaque||!a||!b)return -1;
    auto& state=*static_cast<State*>(opaque);
    try {
        for(size_t i=0;i<count;++i,a+=4,b+=4) {
            bool different=false;
            for(unsigned c=0;c<3;++c) {
                if(!std::isfinite(a[c])||!std::isfinite(b[c]))return -1;
                state.peakA=std::max(state.peakA,double(a[c]));state.peakB=std::max(state.peakB,double(b[c]));
                state.black+=(a[c]>0 && b[c]<=0);state.white+=(a[c]<1 && b[c]>=1);
                state.outside+=(a[c]<0||a[c]>1||b[c]<0||b[c]>1);different|=a[c]!=b[c];
            }
            if(!different)continue;
            ++state.different;
            const auto x=itp(a),y=itp(b);
            const double d=720.*std::sqrt((x[0]-y[0])*(x[0]-y[0])+(x[1]-y[1])*(x[1]-y[1])+(x[2]-y[2])*(x[2]-y[2]));
            state.sum+=d;if(d>0)state.nonzero.push_back(d);
            if(d>state.maximum){state.maximum=d;state.worst=state.count+i;}
        }
        state.count+=count;return 0;
    }catch(...){return -1;}
}
extern "C" int hdr_metric_finish(void* opaque,double* output,size_t count) {
    if(!opaque||!output||count<12)return -1;
    auto& s=*static_cast<State*>(opaque);std::sort(s.nonzero.begin(),s.nonzero.end());
    const double values[]={double(s.count),double(s.different),s.count?s.sum/double(s.count):0.,quantile(s,.95),quantile(s,.99),s.maximum,
                           eotf(s.peakA)*10000.,eotf(s.peakB)*10000.,double(s.black),double(s.white),double(s.worst),double(s.outside)};
    std::copy(std::begin(values),std::end(values),output);return 0;
}
extern "C" void hdr_metric_destroy(void* state){delete static_cast<State*>(state);}
