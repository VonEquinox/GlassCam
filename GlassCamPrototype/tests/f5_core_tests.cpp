#include "f5_math.hpp"
#include "f5_c.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <random>
#include <stdexcept>

namespace {
void require(bool value,const char *message) { if(!value) throw std::runtime_error(message); }
double dot(const std::vector<double>&a,const std::vector<double>&b) { double out=0; for(size_t i=0;i<a.size();++i) out+=a[i]*b[i]; return out; }
std::vector<double> random(size_t n,std::mt19937 &rng,double offset=0) {
    std::uniform_real_distribution<double> d(-1,1); std::vector<double>x(n); for(double&v:x)v=d(rng)+offset; return x;
}
std::vector<f5::Event> observations(int w,int h) {
    std::vector<f5::Event> events;
    for(int frame=0;frame<5;++frame) for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        f5::Event e; e.x=x+0.5;e.y=y+0.5;e.frame=frame;e.phase=(y%2)*2+x%2;e.color=e.phase==0?0:e.phase==3?2:1;
        e.exposure=frame==2?0.125:1;e.eta=0.8+0.1*x/w;e.lower=0.2*e.exposure-0.002;e.upper=e.lower+0.004;
        e.kappa=0.01;e.read_sigma=0.02;events.push_back(e);
    } return events;
}
void operators() {
    std::mt19937 rng(20261027);auto events=observations(7,5);auto s=f5::initialize(7,5,2,1,events);
    for(int f=0;f<5;++f) if(f!=1) for(size_t i=0;i<s.geometry.motion[f].nodes.size();i+=2) {
        s.geometry.motion[f].nodes[i]=0.13*(f-2);s.geometry.motion[f].nodes[i+1]=-0.11*(f-2);
    }
    auto x=random(s.coefficients.size(),rng),z=random(events.size(),rng);
    const auto a=f5::apply_a(s.geometry,events,x),at=f5::apply_at(s.geometry,events,z);
    double error=std::abs(dot(a,z)-dot(x,at))/std::max(1.0,std::abs(dot(a,z)));
    require(error<1e-10,"CFA forward/adjoint mismatch");
    auto p=f5::predict(s.geometry,events[10],x);const auto &e=events[10];
    const double step=1e-6;
    auto plus=s.geometry,minus=s.geometry;
    for(size_t i=0;i<plus.motion[e.frame].nodes.size();i+=2) {plus.motion[e.frame].nodes[i]+=step;minus.motion[e.frame].nodes[i]-=step;}
    const double fd=(f5::predict(plus,e,x).mean-f5::predict(minus,e,x).mean)/(2*step);
    require(std::abs(fd-p.fx*p.gain)<1e-7,"Motion derivative misses input-pixel scale");
    std::fill(x.begin(),x.end(),3.25);
    for(const auto &event:events) {auto q=f5::predict(s.geometry,event,x);if(q.valid)require(std::abs(q.mean-3.25*event.exposure*event.eta)<1e-12,"Constant field/exposure not preserved");}
    f5::Prolongation prolong(19,13,3,8);auto coarse=random(size_t(prolong.cw)*prolong.ch*3,rng),fine=random(19*13*3,rng);
    require(std::abs(dot(prolong.apply(coarse),fine)-dot(coarse,prolong.transpose(fine)))<1e-11,"P transpose is not an adjoint");
    // A legal positive image needs signed controls; sampling is not identity.
    auto basis=f5::stencil(12,8,2,2.25,1.75,0);auto controls=random(12*8*3,rng,1.1);
    controls[basis.index[5]]=-0.2;double sample=basis.evaluate(controls);
    require(sample>0 && std::abs(sample-controls[basis.index[5]])>0.1,"Signed coefficients confused with output RGB");
    std::cout<<"operator_adjoint_relative_error="<<error<<"\n";
}
void likelihoods() {
    double worst=0;
    for(double mu:{0.00001,0.001,0.03,0.2,0.5}) for(auto kind:{f5::EventKind::interval,f5::EventKind::upper,f5::EventKind::lower}) {
        f5::Event e;e.kappa=0.01;e.read_sigma=0.015;e.kind=kind;e.lower=kind==f5::EventKind::interval?mu-0.004:0.2;e.upper=kind==f5::EventKind::interval?mu+0.004:0.02;
        const double h=std::max(mu*1e-5,1e-10);auto a=f5::poisson_gaussian(e,mu);
        double fd=(f5::poisson_gaussian(e,mu+h).nll-f5::poisson_gaussian(e,mu-h).nll)/(2*h);
        const double error=std::abs(fd-a.score)*std::sqrt(e.kappa*mu+e.read_sigma*e.read_sigma);
        if(error>1e-4) std::cerr<<"PG fd mu="<<mu<<" kind="<<int(kind)<<" analytic="<<a.score<<" fd="<<fd<<" error="<<error<<"\n";
        worst=std::max(worst,error);
        require(a.curvature>0 && std::isfinite(a.nll),"Invalid censored likelihood");
    }
    require(worst<1e-4,"PG quantized/censored score differs from independent finite difference");
    f5::Event tail;tail.kind=f5::EventKind::upper;tail.lower=4;tail.kappa=0.01;tail.read_sigma=0.005;
    auto rare=f5::poisson_gaussian(tail,0.002);require(std::isfinite(rare.nll)&&rare.nll>1000&&rare.score<0,"Log-tail underflow or wrong censor score");
    f5::Event negative;negative.lower=-0.015;negative.upper=-0.005;negative.kappa=0.01;negative.read_sigma=0.015;
    require(std::isfinite(f5::poisson_gaussian(negative,0).nll),"Negative black-subtracted observation discarded");
    f5::Event high;high.kind=f5::EventKind::upper;high.lower=1;high.kappa=0.01;high.read_sigma=0.02;
    require(f5::poisson_gaussian(high,2).nll<f5::poisson_gaussian(high,1).nll,"Saturation incorrectly pulls radiance to white");
    auto m=f5::poisson_gaussian(negative,0.5,0.001);require(m.responsibility<0.1,"Mixture code mass not used");
    std::cout<<"pg_score_standardized_fd_error="<<worst<<"\n";
}
void objective_derivative() {
    auto events=observations(4,4);auto s=f5::initialize(4,4,1,1,events);std::mt19937 rng(13);
    for(double &v:s.coefficients)v+=std::uniform_real_distribution<double>(-0.1,0.1)(rng);
    f5::Policy policy;policy.pi0=0.001;auto eval=f5::evaluate(s,events,policy,1e-6);
    double maximum=0;
    for(size_t i=0;i<s.coefficients.size();i+=5) {
        auto plus=s,minus=s;plus.coefficients[i]+=1e-6;minus.coefficients[i]-=1e-6;
        double fd=(f5::evaluate(plus,events,policy,1e-6,false).value-f5::evaluate(minus,events,policy,1e-6,false).value)/2e-6;
        maximum=std::max(maximum,std::abs(fd-eval.gradient[i])/std::max(1.0,std::abs(fd)));
    }
    require(maximum<1e-5,"Full data/curvature/barrier gradient mismatch");
    auto x=random(s.coefficients.size(),rng),y=random(s.coefficients.size(),rng);std::vector<double>qx,qy;eval.q(x,qx);eval.q(y,qy);
    require(dot(x,qx)>0 && std::abs(dot(x,qy)-dot(y,qx))<1e-8,"Frozen normal operator is not SPD/self-adjoint");
    std::cout<<"objective_gradient_relative_fd_error="<<maximum<<"\n";
    s.color_axis.resize(16);
    for(size_t i=0;i<16;++i)s.color_axis[i]={0.4+0.1*std::sin(double(i)),0.8,0.3+0.2*std::cos(double(i))};
    s.color_confidence.resize(16);
    for(size_t i=0;i<16;++i)s.color_confidence[i]=double(i)/15;
    s.luminance_prior_scale.resize(16);
    for(size_t i=0;i<16;++i)s.luminance_prior_scale[i]=1+double(i)/2;
    eval=f5::evaluate(s,events,policy,1e-6);maximum=0;
    for(size_t i=0;i<s.coefficients.size();i+=5){
        auto plus=s,minus=s;plus.coefficients[i]+=1e-6;minus.coefficients[i]-=1e-6;
        double fd=(f5::evaluate(plus,events,policy,1e-6,false).value-f5::evaluate(minus,events,policy,1e-6,false).value)/2e-6;
        maximum=std::max(maximum,std::abs(fd-eval.gradient[i])/std::max(1.0,std::abs(fd)));
    }
    require(maximum<1e-5,"Frozen local-color prior gradient misses the varying row basis");
    eval.q(x,qx);eval.q(y,qy);
    require(dot(x,qx)>0&&std::abs(dot(x,qy)-dot(y,qx))<1e-8,"Frozen local-color prior is not symmetric positive");
    std::cout<<"guided_color_gradient_relative_fd_error="<<maximum<<"\n";
}
void initialization() {
    auto events=observations(9,9);
    for(auto &e:events){double signal=0.1+0.01*(e.x-0.5)+0.02*(e.y-0.5);if(e.frame!=1)signal+=1;
        const double value=signal*e.exposure*e.eta;e.lower=value-0.002;e.upper=value+0.002;}
    const auto state=f5::initialize(9,9,1,1,events);
    for(int c=0;c<3;++c){require(std::abs(state.coefficients[c*81+4*9+4]-0.22)<1e-12,"Initializer lost reference-frame radiometry");
        require(state.coefficients[c*81+4*9+5]>state.coefficients[c*81+4*9+3]+0.019,"Reference texture was replaced by a flat color seed");}
    require(std::abs(state.noise_scale[4*9+4]-0.02/(0.8+0.1*2/9))<1e-12,"Initializer lost the local radiometric read-noise floor");
}
void chromatic_edge_prior() {
    const int w=8,h=8;auto events=observations(w,h);auto s=f5::initialize(w,h,1,1,events);
    const std::array<double,3> color{0.35,0.8,0.45};
    s.color_axis.assign(w*h,color);
    for(int c=0;c<3;++c)for(int y=0;y<h;++y)for(int x=0;x<w;++x)
        s.coefficients[(c*h+y)*w+x]=color[c]*(0.45+0.2*std::sin(x*1.4)+0.1*std::cos(y*1.1));
    f5::Policy weak,strong;weak.lambda_y=weak.lambda_c=0.001;strong=weak;strong.lambda_c=0.1;
    auto penalty=[&](const f5::State &state){return f5::evaluate(state,events,strong,0,false).value-f5::evaluate(state,events,weak,0,false).value;};
    require(std::abs(penalty(s))<1e-9,"Color prior suppresses common edges of constant chromaticity");
    auto fixed=s;fixed.color_axis.clear();const double original=penalty(fixed);
    require(original>0.01,"Edge test lacks color-dependent structure");
    s.coefficients[3*w+3]+=0.1;
    require(penalty(s)>0.01,"Guided color prior ignores unsupported chromatic variation");
    std::cout<<"common_chromatic_edge_penalty="<<original<<" -> 0; isolated color residual penalized\n";
}
void solver() {
    auto events=observations(4,4);auto state=f5::initialize(4,4,1,1,events);f5::Policy p;p.max_cycles=7;p.block_size=8;p.geometry_rounds=0;
    auto before=f5::evaluate(state,events,p,1e-8,false).value;auto trace=f5::solve(state,events,p);
    auto after=f5::evaluate(state,events,p,1e-8,false).value;require(after<before,"True objective did not decrease");
    for(double value:f5::sample_rgb(state.geometry,state.coefficients,2))require(value>f5::epsilon_f&&std::isfinite(value),"Solver violates physical positivity");
    require(trace.stop=="BUDGET_STOP"||trace.stop=="CONVERGED","Unexpected solve termination");
    auto stopped=f5::solve(state,events,p,0,[]{return true;});require(stopped.stop=="CANCELLED"&&stopped.cycles==0,"Cancellation is not terminal");
    f5::Policy zero=p;zero.max_cycles=0;require(f5::solve(state,events,zero).stop=="BUDGET_STOP","Budget exhaustion mislabeled converged");
    std::cout<<"native_objective="<<before<<" -> "<<after<<" stop="<<trace.stop<<"\n";
}
void local_physical_constraint() {
    const int w=12,h=12;auto state=f5::initialize(w,h,1,1,{});
    std::fill(state.coefficients.begin(),state.coefficients.end(),0.2);
    for(int y=0;y<3;++y)for(int x=0;x<3;++x)state.coefficients[y*w+x]=1e-6;
    f5::Evaluation quadratic;const size_t n=state.coefficients.size();
    quadratic.gradient.assign(n,-1);quadratic.diagonal.assign(n,1);
    quadratic.gradient[0]=1;quadratic.q=[](const auto &x,auto &y){y=x;};
    std::vector<size_t> variables(n);for(size_t i=0;i<n;++i)variables[i]=i;
    const auto step=f5::image_step(state,{},quadratic,variables,1e-6,30);
    require(step.unguarded_fraction<1e-4,"The constraint regression no longer contains a limiting dark sample");
    require(step.feasible_fraction>0.1,"One dark sample still freezes unrelated image regions");
    require(step.direction[n-1]>0.9,"Local constraint damping suppressed a distant unconstrained direction");
    auto updated=state;
    for(size_t i=0;i<n;++i)updated.coefficients[i]+=step.feasible_fraction*step.direction[i];
    for(double value:f5::sample_rgb(updated.geometry,updated.coefficients,1))
        require(value>f5::epsilon_f,"Constraint safeguard used coefficient clipping or produced a negative physical sample");
    const double predicted=step.feasible_fraction*dot(quadratic.gradient,step.direction)+
        0.5*step.feasible_fraction*step.feasible_fraction*dot(step.direction,step.direction);
    require(predicted<-10,"The feasible direction did not improve the independent quadratic objective");
    std::cout<<"physical_constraint_step="<<step.unguarded_fraction<<" -> "<<step.feasible_fraction<<" rounds="<<step.guard_rounds<<"\n";
}
void local_registration() {
    const int w=64,h=64;f5::Guide a,b;
    for(auto *g:{&a,&b}){g->width=w;g->height=h;g->pixel_size=2;g->values.resize(w*h);g->variance.assign(w*h,1e-6);g->validity.assign(w*h,1);}
    auto field=[](double x,double y){return .2+.06*std::sin(x*.31+y*.13)+.04*std::cos(x*.15-y*.27)+.02*std::sin(x*.67)*std::cos(y*.43);};
    for(const auto shift:std::array<std::array<double,2>,3>{{{.23,-.16},{8.1,-1.3},{-14.2,2.7}}}) {
        for(int y=0;y<h;++y)for(int x=0;x<w;++x){a.values[y*w+x]=field(x+shift[0]/2,y+shift[1]/2);b.values[y*w+x]=field(x,y);}
        const auto result=f5::align_local_translation(a,b,20,.25);
        require(result.reliable,"Textured local translation was not accepted");
        const double error=std::hypot(result.shift[0]-shift[0],result.shift[1]-shift[1]);
        require(error<.12,"Local translation has wrong sign, units, or a missed large shift");
        std::cout<<"local_registration_error="<<error<<" cycle="<<result.cycle_error<<"\n";
    }
    std::fill(a.values.begin(),a.values.end(),.2);std::fill(b.values.begin(),b.values.end(),.2);
    require(!f5::align_local_translation(a,b,20,.25).reliable,"Textureless data falsely certified local motion");
}
void direct_physical_safeguard() {
    const int w=12,h=12;auto state=f5::initialize(w,h,1,0,{});const size_t n=state.coefficients.size();
    std::fill(state.coefficients.begin(),state.coefficients.end(),.2);
    for(int y=0;y<3;++y)for(int x=0;x<3;++x)state.coefficients[y*w+x]=2e-6;
    state.coefficients[n-1]=-.01;
    std::vector<double> direction(n);
    for(size_t i=0;i<n;++i)direction[i]=std::sin(double(i)*.37)-.2;
    direction[n-1]=0;direction[n-2]=.5;
    std::vector<f5::Event> events;
    for(int y=0;y<h;++y)for(int x=0;x<w;++x){f5::Event e;e.x=x+.17;e.y=y+.83;e.color=(x+y)%3;events.push_back(e);}
    const auto projected=f5::limit_physical_direction(state,events,direction);auto updated=state;
    double improvement=0;
    for(size_t i=0;i<n;++i){updated.coefficients[i]+=projected[i];improvement+=projected[i]*projected[i]-2*direction[i]*projected[i];}
    for(double value:f5::sample_rgb(updated.geometry,updated.coefficients,1))require(value>f5::epsilon_f,"Direct safeguard violated a native sample");
    for(const auto&e:events)require(f5::predict(updated.geometry,e,updated.coefficients).mean>f5::epsilon_f,"Direct safeguard violated a subpixel RAW constraint");
    require(updated.coefficients[n-1]<0,"Direct safeguard clipped signed coefficients");
    require(projected[n-2]==.5,"Direct safeguard suppressed a positive distant step");
    require(improvement<-1,"Direct safeguard lost all progress on the independent quadratic");
}
void alias_information() {
    auto evaluate=[](const std::array<std::array<double,2>,4>&shifts) {
        std::vector<F5InformationSample> samples;
        for(int frame=0;frame<4;++frame)for(int phase=0;phase<4;++phase)for(int j=0;j<6;++j) {
            const double x=2*((j*5+phase*3)%16)+phase%2+.5+shifts[frame][0];
            const double y=2*((j*7+phase)%16)+phase/2+.5+shifts[frame][1];
            const uint32_t color=phase==0?2:phase==3?0:1,index=frame<2?frame:frame+1;
            samples.push_back({x,y,1,.3,0,0,1e5,color,uint32_t(phase),index,0});
        }
        F5InformationResult result{};
        require(f5_information(samples.data(),samples.size(),.01,1,&result)==0,"Alias information failed");
        return result;
    };
    const auto repeated=evaluate({{{0,0},{0,0},{0,0},{0,0}}});
    const auto integer=evaluate({{{0,0},{1,0},{0,1},{1,1}}});
    const auto single_axis=evaluate({{{0,0},{0,.2},{0,.4},{0,.6}}});
    const auto diverse=evaluate({{{0,0},{.5,0},{0,.5},{.5,.5}}});
    require(repeated.minimum<1e-12&&integer.minimum<1e-12,"Repeated native sampling falsely creates super-resolution information");
    require(single_axis.minimum<1e-12,"One-axis jitter falsely certifies two-axis super-resolution");
    require(diverse.minimum>1&&diverse.condition<1000,"Well-spread subpixel samples lost all high-frequency information");
    std::cout<<"conditional_alias_information="<<repeated.minimum<<","<<single_axis.minimum<<" -> "<<diverse.minimum<<"\n";
}
}
int main() {
    try {operators();likelihoods();objective_derivative();initialization();chromatic_edge_prior();local_physical_constraint();direct_physical_safeguard();local_registration();alias_information();solver();std::cout<<"F5 CPU numerical contracts passed\n";return 0;}
    catch(const std::exception&e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
