#include "f5_math.hpp"
#include "f5_c.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <stdexcept>

namespace f5 {
namespace {
constexpr double pi=3.14159265358979323846;
struct Eigen {std::vector<double> values,vectors;};
Eigen eigensystem(std::vector<double>a,int n) {
    Eigen e;e.vectors.assign(size_t(n)*n,0);for(int i=0;i<n;++i)e.vectors[i*n+i]=1;
    for(int iteration=0;iteration<80*n*n;++iteration){int p=0,q=1;double maximum=0;for(int i=0;i<n;++i)for(int j=i+1;j<n;++j)if(std::abs(a[i*n+j])>maximum){maximum=std::abs(a[i*n+j]);p=i;q=j;}
        if(maximum<1e-12)break;const double angle=0.5*std::atan2(2*a[p*n+q],a[q*n+q]-a[p*n+p]),c=std::cos(angle),s=std::sin(angle);
        for(int i=0;i<n;++i){double x=a[i*n+p],y=a[i*n+q];a[i*n+p]=c*x-s*y;a[i*n+q]=s*x+c*y;}
        for(int i=0;i<n;++i){double x=a[p*n+i],y=a[q*n+i];a[p*n+i]=c*x-s*y;a[q*n+i]=s*x+c*y;double vx=e.vectors[i*n+p],vy=e.vectors[i*n+q];e.vectors[i*n+p]=c*vx-s*vy;e.vectors[i*n+q]=s*vx+c*vy;}
    }
    e.values.resize(n);for(int i=0;i<n;++i)e.values[i]=a[i*n+i];return e;
}
uint64_t random_key(size_t index) {uint64_t x=index+0x9e3779b97f4a7c15ULL+20261027;x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;x=(x^(x>>27))*0x94d049bb133111ebULL;return x^(x>>31);}
F5InformationResult conditional_information(const F5InformationSample *samples,size_t count,double noise,int reference) {
    const double color[3][3]={{1/std::sqrt(3.0),1/std::sqrt(3.0),1/std::sqrt(3.0)},
        {1/std::sqrt(2.0),0,-1/std::sqrt(2.0)},{1/std::sqrt(6.0),-2/std::sqrt(6.0),1/std::sqrt(6.0)}};
    // A 0.65 cycle/native-pixel mode aliases to 0.35 on an integer lattice.
    // Project out these native-band alternatives as well as local motion.
    // High-frequency energy alone cannot certify that new resolution is observed.
    std::vector<std::vector<double>> high(12,std::vector<double>(count)),nuisance(20,std::vector<double>(count));
    double short_information=0;
    for(size_t n=0;n<count;++n) {
        const auto&s=samples[n];if(s.kind>=3)continue;
        if(s.frame>=5||s.color>=3||!std::isfinite(s.x)||!std::isfinite(s.y)||!std::isfinite(s.gain)||
           !std::isfinite(s.dx)||!std::isfinite(s.dy)||!std::isfinite(s.curvature)||s.curvature<0)
            throw std::runtime_error("Invalid local information sample");
        const double weight=std::sqrt(s.curvature)*s.gain;
        for(int c=0;c<3;++c)for(int axis=0;axis<2;++axis) {
            const double position=axis==0?s.x:s.y,amplitude=noise*weight*color[c][s.color];
            const int i=c*4+axis*2;
            high[i][n]=amplitude*std::cos(2*pi*.65*position);high[i+1][n]=amplitude*std::sin(2*pi*.65*position);
            nuisance[8+i][n]=amplitude*std::cos(2*pi*.35*position);nuisance[8+i+1][n]=amplitude*std::sin(2*pi*.35*position);
            if(s.frame==2)short_information+=high[i][n]*high[i][n]+high[i+1][n]*high[i+1][n];
        }
        if(int(s.frame)!=reference) {const int i=int(s.frame)-(int(s.frame)>reference?1:0);nuisance[i*2][n]=weight*s.dx;nuisance[i*2+1][n]=weight*s.dy;}
    }
    auto dot=[](const auto&a,const auto&b){return std::inner_product(a.begin(),a.end(),b.begin(),0.0);};
    // Normalize nuisance columns, then use pivoted, twice-reorthogonalized
    // Gram-Schmidt. At most 120 observations and 20 nuisance columns per tile;
    // no image-sized matrix, network, or iterative high-grid solve is required.
    for(auto&column:nuisance) {const double norm=std::sqrt(dot(column,column));if(norm>0)for(auto&v:column)v/=norm;}
    int motion_rank=0;
    auto project=[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            int pivot=k;double largest=dot(nuisance[k],nuisance[k]);
            for(int j=k+1;j<end;++j){const double value=dot(nuisance[j],nuisance[j]);if(value>largest){largest=value;pivot=j;}}
            if(largest<=1e-16)break;
            std::swap(nuisance[k],nuisance[pivot]);auto&q=nuisance[k];for(auto&v:q)v/=std::sqrt(largest);
            auto remove=[&](auto&column){for(int pass=0;pass<2;++pass){const double coefficient=dot(q,column);for(size_t n=0;n<count;++n)column[n]-=coefficient*q[n];}};
            for(int j=k+1;j<20;++j)remove(nuisance[j]);for(auto&column:high)remove(column);
            if(begin==0)++motion_rank;
        }
    };
    project(0,8);project(8,20);
    std::vector<double> fisher(144);
    for(int i=0;i<12;++i)for(int j=0;j<12;++j)fisher[i*12+j]=dot(high[i],high[j]);
    const auto eigen=eigensystem(fisher,12).values;
    const double minimum=std::max(0.0,*std::min_element(eigen.begin(),eigen.end())),top=std::max(0.0,*std::max_element(eigen.begin(),eigen.end()));
    return {minimum,minimum>1e-12?top/minimum:1e30,short_information,motion_rank};
}
}
std::vector<Quality> diagnose(const State &s,const std::vector<Event>&events,const std::array<Alignment,5>&align,const QualityPolicy &policy) {
    const int columns=(s.geometry.width+31)/32,rows=(s.geometry.height+31)/32;std::vector<Quality>quality(size_t(columns)*rows);
    std::vector<std::vector<size_t>>indices(quality.size());
    for(int y=0;y<rows;++y)for(int x=0;x<columns;++x){auto&q=quality[size_t(y)*columns+x];q.x=x*32;q.y=y*32;q.width=std::min(32,s.geometry.width-q.x);q.height=std::min(32,s.geometry.height-q.y);}
    // Attribute observations using their projection into reference geometry.
    for(size_t i=0;i<events.size();++i){const auto&e=events[i];auto p=predict(s.geometry,e,s.coefficients);if(!p.valid)continue;const auto u=e.frame==uint32_t(s.geometry.reference)?std::array<double,2>{0,0}:s.geometry.motion[e.frame].displacement(e.x,e.y);int x=int(e.x+u[0])/32,y=int(e.y+u[1])/32;if(x>=0&&x<columns&&y>=0&&y<rows)indices[size_t(y)*columns+x].push_back(i);}
    for(size_t t=0;t<quality.size();++t){auto&q=quality[t];std::array<double,5>total{},residual{},residual_count{};double squared=0,n=0;int valid_main=0,valid_short=0;
        std::array<std::vector<size_t>,20>strata;
        for(size_t i:indices[t]){const auto&e=events[i];auto p=predict(s.geometry,e,s.coefficients);if(!p.valid)continue;total[e.frame]+=1;
            if(e.kind==EventKind::interval){q.valid[e.frame]+=1;if(e.frame==2)++valid_short;else ++valid_main;}
            else if(e.kind==EventKind::upper)q.upper[e.frame]+=1;else if(e.kind==EventKind::lower)q.lower[e.frame]+=1;
            const double observed=e.kind==EventKind::upper?std::max(p.mean,e.lower):e.kind==EventKind::lower?std::min(p.mean,e.upper):(e.lower+e.upper)/2;
            const double r=(p.mean-observed)/std::sqrt(e.kappa*std::max(0.0,p.mean)+e.read_sigma*e.read_sigma);
            squared+=r*r;n+=1;if(e.kind==EventKind::interval){residual[e.frame]+=r;residual_count[e.frame]+=1;}
            strata[e.frame*4+e.phase].push_back(i);
            if(e.frame!=uint32_t(s.geometry.reference)){
                q.ambiguous=q.ambiguous||align[e.frame].ambiguity<0.05;
                q.occluded=q.occluded||align[e.frame].cycle_error>policy.max_cycle;
            }
        }
        for(int f=0;f<5;++f){if(total[f]>0){q.valid[f]/=total[f];q.upper[f]/=total[f];q.lower[f]/=total[f];}if(residual_count[f]>16&&std::abs(residual[f]/residual_count[f])>policy.residual_sigma)q.flicker=true;}
        q.residual=n>0?std::sqrt(squared/n):0;q.short_only=valid_main==0&&valid_short>0;
        if(valid_main==0&&valid_short==0){q.support=n>0?Quality::highlight_missing:Quality::invalid;continue;}
        std::vector<size_t>sample;
        for(auto &stratum:strata){std::sort(stratum.begin(),stratum.end(),[](size_t a,size_t b){return random_key(a)<random_key(b);});const size_t size=std::min(size_t(6),stratum.size());sample.insert(sample.end(),stratum.begin(),stratum.begin()+size);}
        const int centerX=std::min(s.geometry.width*s.geometry.scale-1,(q.x+q.width/2)*s.geometry.scale),centerY=std::min(s.geometry.height*s.geometry.scale-1,(q.y+q.height/2)*s.geometry.scale);
        const double amplitude=s.noise_scale.empty()?0.01:s.noise_scale[size_t(centerY)*s.geometry.width*s.geometry.scale+centerX];
        std::vector<F5InformationSample> inputs;
        for(size_t i:sample){const auto&e=events[i];const auto p=predict(s.geometry,e,s.coefficients);const auto shift=e.frame==uint32_t(s.geometry.reference)?std::array<double,2>{0,0}:s.geometry.motion[e.frame].displacement(e.x,e.y);
            const double weight=poisson_gaussian(e,p.mean,0.001).curvature;
            inputs.push_back({e.x+shift[0],e.y+shift[1],p.gain,p.mean,p.fx,p.fy,weight,e.color,e.phase,e.frame,uint32_t(e.kind)});
        }
        const auto information=conditional_information(inputs.data(),inputs.size(),amplitude,s.geometry.reference);
        q.minimum_information=information.minimum;q.condition=information.condition;
        bool response=true;for(int frame=0;frame<5;++frame)if(frame!=s.geometry.reference){const auto &m=s.geometry.motion[frame];const double x=q.x+q.width/2.0,y=q.y+q.height/2.0;const auto a=m.displacement(x-0.5,y),b=m.displacement(x+0.5,y),c=m.displacement(x,y-0.5),d=m.displacement(x,y+0.5);response=response&&std::max({std::abs(b[0]-a[0]),std::abs(b[1]-a[1]),std::abs(d[0]-c[0]),std::abs(d[1]-c[1])})<=policy.max_jacobian_deviation;}
        if(q.occluded||q.flicker||q.residual>policy.residual_sigma*2)q.support=Quality::reference_only;
        else if(q.short_only||q.ambiguous||!response||q.minimum_information<policy.min_information||q.condition>policy.max_condition||q.residual>policy.residual_sigma)q.support=Quality::native_fusion;
        else q.support=Quality::full_sr;
    }return quality;
}

std::vector<double> deliver(const State &high,const State &native,const State &reference,const std::vector<Quality>&quality,int scale) {
    const int w=high.geometry.width*scale,h=high.geometry.height*scale,columns=(high.geometry.width+31)/32;
    auto output=sample_rgb(high.geometry,high.coefficients,scale),base=sample_rgb(native.geometry,native.coefficients,scale),single=sample_rgb(reference.geometry,reference.coefficients,scale);
    for(int y=0;y<h;++y)for(int x=0;x<w;++x){const double px=(x+0.5)/scale,py=(y+0.5)/scale;const size_t tile=size_t(int(py)/32)*columns+int(px)/32;const auto&q=quality[tile];
        double high_weight=0;
        if(q.support==Quality::full_sr){double distance=1e9;for(const auto&bad:quality)if(bad.support!=Quality::full_sr){double dx=std::max({double(bad.x)-px,0.0,px-(bad.x+bad.width)}),dy=std::max({double(bad.y)-py,0.0,py-(bad.y+bad.height)});distance=std::min(distance,std::hypot(dx,dy));}distance=std::clamp((distance-2)/16,0.0,1.0);high_weight=0.5-0.5*std::cos(pi*distance);}
        const size_t index=(size_t(y)*w+x)*3;
        for(int c=0;c<3;++c){if(q.support==Quality::reference_only||q.support==Quality::invalid)output[index+c]=single[index+c];else if(q.support==Quality::highlight_missing)output[index+c]=base[index+c];else output[index+c]=high_weight*output[index+c]+(1-high_weight)*base[index+c];}
    }return output;
}
} // namespace f5

extern "C" int f5_information(const F5InformationSample *samples,size_t count,double noise,int reference,F5InformationResult *out) {
    if(!samples||!out||count>128||!std::isfinite(noise)||noise<=0||reference<0||reference>4)return -1;
    try {
        *out=f5::conditional_information(samples,count,noise,reference);return 0;
    }catch(...){return -2;}
}
