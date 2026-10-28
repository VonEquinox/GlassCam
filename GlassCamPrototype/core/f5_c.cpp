#include "f5_c.h"
#include "f5_math.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
extern "C" int f5_reference_limit_direction(const double *coefficients,const double *direction,double *output,
    int width,int height,int scale,const F5InformationSample *points,size_t count) {
    if(!coefficients||!direction||!output||width<2||height<2||width>64||height>64||scale<1||scale>2||count>128||(!points&&count))return -1;
    try {
        std::vector<f5::Event> events;
        for(size_t i=0;i<count;++i){const auto&p=points[i];if(p.color>2||!std::isfinite(p.x)||!std::isfinite(p.y))return -1;f5::Event e;e.x=p.x;e.y=p.y;e.color=p.color;e.frame=0;e.kind=f5::EventKind(p.kind);events.push_back(e);}
        auto state=f5::initialize(width,height,scale,0,events);const size_t n=size_t(width)*height*scale*scale*3;
        state.coefficients.assign(coefficients,coefficients+n);const auto result=f5::limit_physical_direction(state,events,std::vector<double>(direction,direction+n));
        std::copy(result.begin(),result.end(),output);return 0;
    }catch(...){return -2;}
}
extern "C" int f5_pg_event(F5LikelihoodEvent input,double mean,F5LikelihoodValue *out) {
    if(!out||input.kind>2||!std::isfinite(mean)||mean<0||input.kappa<=0||input.read_sigma<=0)return -1;
    try{f5::Event event;event.lower=input.lower;event.upper=input.upper;event.kappa=input.kappa;event.read_sigma=input.read_sigma;event.kind=f5::EventKind(input.kind);event.uniform_probability=input.uniform_probability;
        const auto l=f5::poisson_gaussian(event,mean);*out={l.nll,l.score,l.curvature,l.probability};return 0;}catch(...){return -2;}
}
extern "C" int f5_align(const F5GuideInput *input,const double *timestamps,double minimum,int *reference,F5AlignmentValue *output) {
    if(!input||!timestamps||!reference||!output)return -1;
    try{std::array<f5::Guide,5>guides;std::array<double,5>times;
        for(int f=0;f<5;++f){const auto &in=input[f];if(!in.rgba||in.width<2||in.height<2||in.width>2048||in.height>2048||!std::isfinite(in.pixel_size)||in.pixel_size<=0)return -1;
            auto &g=guides[f];g.width=in.width;g.height=in.height;g.pixel_size=in.pixel_size;size_t n=size_t(in.width)*in.height;g.values.resize(n);g.validity.resize(n);g.variance.resize(n);
            for(size_t i=0;i<n;++i){g.values[i]=in.rgba[i*4];g.variance[i]=in.rgba[i*4+1];g.validity[i]=in.rgba[i*4+2];}times[f]=timestamps[f];}
        int r=*reference>=0&&*reference<5?*reference:f5::choose_reference(guides,times,minimum);if(r<0)return -3;*reference=r;
        for(int f=0;f<5;++f){f5::Alignment a;if(f!=r)a=f5::align_guides(guides[f],guides[r]);else a.ambiguity=1;
            std::copy(a.affine.begin(),a.affine.end(),output[f].affine);output[f].ambiguity=a.ambiguity;output[f].cycle_error=a.cycle_error;
            for(int j=0;j<6;++j)output[f].hypotheses[j]=j/2<int(a.hypotheses.size())?a.hypotheses[j/2][j%2]:0;}
        return 0;
    }catch(...){return -2;}
}
extern "C" int f5_reference_sample(const double *coeff,int width,int height,int scale,double x,double y,int channel,double *value,double *dx,double *dy) {
    if(!coeff||!value||!dx||!dy||width<=0||height<=0||width>512||height>512||scale<1||scale>2||channel<0||channel>2)return -1;
    try{std::vector<double>c(coeff,coeff+size_t(width)*height*3);auto b=f5::stencil(width,height,scale,x,y,channel);auto d=b.derivative(c);*value=b.evaluate(c);*dx=d[0];*dy=d[1];return 0;}catch(...){return -2;}
}
extern "C" int f5_align_local(F5GuideInput input,F5GuideInput reference,double maximum_shift,double maximum_std,F5LocalTranslation *out) {
    if(!out||!input.rgba||!reference.rgba||input.width>256||input.height>256||reference.width>256||reference.height>256)return -1;
    try {
        auto guide=[](F5GuideInput in){f5::Guide g;g.width=in.width;g.height=in.height;g.pixel_size=in.pixel_size;
            const size_t count=size_t(in.width)*in.height;g.values.resize(count);g.variance.resize(count);g.validity.resize(count);
            for(size_t i=0;i<count;++i){g.values[i]=in.rgba[i*4];g.variance[i]=in.rgba[i*4+1];g.validity[i]=in.rgba[i*4+2];}return g;};
        const auto value=f5::align_local_translation(guide(input),guide(reference),maximum_shift,maximum_std);
        *out={{value.shift[0],value.shift[1]},value.cycle_error,value.maximum_std,value.residual,value.normalized_correlation,uint64_t(value.samples),value.reliable?1:0};return 0;
    }catch(...){return -2;}
}
extern "C" int f5_reference_evaluate(const F5Observation *input,size_t event_count,const double *coefficients,const double *direction,
    const double *translations,int width,int height,int scale,int reference,double sigma,double lambda_y,double lambda_c,double pi0,
    double tau,double *objective,double *gradient,double *diagonal,double *normal) {
    return f5_reference_evaluate_guided(input,event_count,coefficients,direction,translations,width,height,scale,reference,
        sigma,lambda_y,lambda_c,pi0,tau,nullptr,nullptr,nullptr,objective,gradient,diagonal,normal);
}
extern "C" int f5_reference_evaluate_guided(const F5Observation *input,size_t event_count,const double *coefficients,const double *direction,
    const double *translations,int width,int height,int scale,int reference,double sigma,double lambda_y,double lambda_c,double pi0,
    double tau,const double *rgb_axes,const double *color_confidence,const double *luminance_scale,
    double *objective,double *gradient,double *diagonal,double *normal) {
    if(!input||!coefficients||!direction||!translations||!objective||!gradient||!diagonal||!normal||width<2||height<2||width>64||height>64||scale<1||scale>2||reference<0||reference>4)return -1;
    try{std::vector<f5::Event>events;events.reserve(event_count);for(size_t i=0;i<event_count;++i){auto &v=input[i];if(v.color>2||v.phase>3||v.frame>4||v.kind>6)return -1;f5::Event e;e.x=v.x;e.y=v.y;e.lower=v.lower;e.upper=v.upper;e.exposure=v.exposure;e.eta=v.eta;e.kappa=v.kappa;e.read_sigma=v.read_sigma;e.uniform_probability=v.uniform_probability;e.color=v.color;e.phase=v.phase;e.frame=v.frame;e.kind=f5::EventKind(v.kind);events.push_back(e);}
        auto state=f5::initialize(width,height,scale,reference,events);size_t n=size_t(width)*height*scale*scale*3;state.coefficients.assign(coefficients,coefficients+n);state.noise_scale.assign(n/3,sigma);
        if(rgb_axes){state.color_axis.resize(n/3);for(size_t i=0;i<n/3;++i)state.color_axis[i]={rgb_axes[i*3],rgb_axes[i*3+1],rgb_axes[i*3+2]};}
        if(color_confidence)state.color_confidence.assign(color_confidence,color_confidence+n/3);
        if(luminance_scale)state.luminance_prior_scale.assign(luminance_scale,luminance_scale+n/3);
        for(int f=0;f<5;++f)for(size_t i=0;i<state.geometry.motion[f].nodes.size();i+=2){state.geometry.motion[f].nodes[i]=translations[f*2];state.geometry.motion[f].nodes[i+1]=translations[f*2+1];}
        f5::Policy policy;policy.lambda_y=lambda_y;policy.lambda_c=lambda_c;policy.pi0=pi0;auto value=f5::evaluate(state,events,policy,tau);
        if(!value.feasible)return -3;*objective=value.value;std::copy(value.gradient.begin(),value.gradient.end(),gradient);std::copy(value.diagonal.begin(),value.diagonal.end(),diagonal);
        std::vector<double>d(direction,direction+n),q;value.q(d,q);std::copy(q.begin(),q.end(),normal);return 0;
    }catch(...){return -2;}
}

extern "C" int f5_reference_reconstruct(const F5Observation *input,size_t event_count,const double *translations,
    F5ReferenceOptions o,double *rgb,size_t capacity,F5ReferenceReport *report) {
    if(!input||!rgb||!report||o.width<4||o.height<4||o.width>64||o.height>64||o.reference<0||o.reference>=5||o.reference==2||
       (o.baseline!=1&&o.baseline!=5)||o.max_cycles<1||o.max_cycles>50||o.block_size<2||o.geometry_rounds<0||o.geometry_rounds>3||
       event_count!=size_t(o.width)*o.height*5||capacity<size_t(o.width)*o.height*12)return -1;
    try {
        *report={};std::vector<f5::Event>events;events.reserve(event_count);
        for(size_t i=0;i<event_count;++i){const auto&v=input[i];if(v.color>2||v.phase>3||v.frame>4||v.kind>6||v.kappa<=0||v.read_sigma<=0||v.exposure<=0||v.eta<=0)return -1;
            f5::Event e;e.x=v.x;e.y=v.y;e.lower=v.lower;e.upper=v.upper;e.exposure=v.exposure;e.eta=v.eta;e.kappa=v.kappa;e.read_sigma=v.read_sigma;e.uniform_probability=v.uniform_probability;e.color=v.color;e.phase=v.phase;e.frame=v.frame;e.kind=f5::EventKind(v.kind);events.push_back(e);}
        f5::Policy p;p.max_cycles=o.max_cycles;p.block_size=o.block_size;p.geometry_rounds=o.geometry_rounds;
        p.lambda_y=o.lambda_y;p.lambda_c=o.lambda_c;p.lambda_motion=o.lambda_motion;p.pi0=o.pi0;p.objective_tolerance=o.objective_tolerance;p.gradient_tolerance=o.gradient_tolerance;
        auto native=f5::initialize(o.width,o.height,1,o.reference,events);
        if(translations){for(int f=0;f<5;++f)for(size_t i=0;i<native.geometry.motion[f].nodes.size();i+=2){native.geometry.motion[f].nodes[i]=translations[f*2];native.geometry.motion[f].nodes[i+1]=translations[f*2+1];}}
        else {std::array<f5::Guide,5>guides;std::array<f5::Alignment,5>alignments;
            for(int f=0;f<5;++f)guides[f]=f5::make_guide(o.width,o.height,f,events);
            f5::initialize_motion(native,guides,alignments);}
        auto trace=f5::solve(native,events,p);report->native_cycles=trace.cycles;std::strncpy(report->native_stop,trace.stop.c_str(),31);
        if(trace.cycles==0||trace.stop=="NONFINITE"||trace.stop=="NUMERICAL_STALL")return -3;
        f5::freeze_noise_scale(native,events);std::vector<double>out;
        if(o.baseline==5){auto high=f5::lift(native,2);trace=f5::solve(high,events,p);out=f5::sample_rgb(high.geometry,high.coefficients,2);}
        else {auto base=f5::sample_rgb(native.geometry,native.coefficients,1);out.resize(size_t(o.width)*o.height*12);
            for(int y=0;y<o.height*2;++y)for(int x=0;x<o.width*2;++x){double px=std::clamp((x+0.5)/2-0.5,0.0,double(o.width-1)),py=std::clamp((y+0.5)/2-0.5,0.0,double(o.height-1));int ix=int(px),iy=int(py);double ax=px-ix,ay=py-iy;
                for(int c=0;c<3;++c){auto at=[&](int xx,int yy){return base[(size_t(std::min(yy,o.height-1))*o.width+std::min(xx,o.width-1))*3+c];};out[(size_t(y)*o.width*2+x)*3+c]=((1-ax)*at(ix,iy)+ax*at(ix+1,iy))*(1-ay)+((1-ax)*at(ix,iy+1)+ax*at(ix+1,iy+1))*ay;}}
        }
        report->cycles=trace.cycles;report->gradient=trace.standardized_gradient;report->motion_gradient=trace.standardized_motion_gradient;
        report->objective_count=int(trace.objective.size());std::copy(trace.objective.begin(),trace.objective.end(),report->objectives);std::strncpy(report->stop,trace.stop.c_str(),31);
        for(double v:out)if(!std::isfinite(v)||v<0)return -4;
        std::copy(out.begin(),out.end(),rgb);return 0;
    }catch(...){return -2;}
}
