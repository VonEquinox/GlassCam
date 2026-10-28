#include "f5_math.hpp"
#include <algorithm>
#include <cmath>
#include <complex>
#include <numeric>
#include <stdexcept>

namespace f5 {
namespace {
constexpr double pi=3.14159265358979323846;
size_t power2(size_t n) { size_t p=1;while(p<n)p*=2;return p; }
void fft(std::vector<std::complex<double>> &a,bool inverse) {
    const size_t n=a.size();
    for(size_t i=1,j=0;i<n;++i) { size_t bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j)std::swap(a[i],a[j]); }
    for(size_t length=2;length<=n;length*=2) {
        const auto root=std::polar(1.0,(inverse?2:-2)*pi/length);
        for(size_t begin=0;begin<n;begin+=length) { std::complex<double>w=1;for(size_t j=0;j<length/2;++j) {auto u=a[begin+j],v=a[begin+j+length/2]*w;a[begin+j]=u+v;a[begin+j+length/2]=u-v;w*=root;} }
    }
    if(inverse)for(auto &v:a)v/=double(n);
}
void fft2(std::vector<std::complex<double>> &a,int w,int h,bool inverse) {
    std::vector<std::complex<double>>row(w),column(h);
    for(int y=0;y<h;++y){std::copy(a.begin()+size_t(y)*w,a.begin()+size_t(y+1)*w,row.begin());fft(row,inverse);std::copy(row.begin(),row.end(),a.begin()+size_t(y)*w);}
    for(int x=0;x<w;++x){for(int y=0;y<h;++y)column[y]=a[size_t(y)*w+x];fft(column,inverse);for(int y=0;y<h;++y)a[size_t(y)*w+x]=column[y];}
}
double bilinear(const Guide &g,double x,double y,const std::vector<double> &values) {
    if(x<0||y<0||x>g.width-1||y>g.height-1)return 0;
    int ix=int(x),iy=int(y);double fx=x-ix,fy=y-iy;
    auto at=[&](int xx,int yy){return values[size_t(std::min(yy,g.height-1))*g.width+std::min(xx,g.width-1)];};
    return (at(ix,iy)*(1-fx)+at(ix+1,iy)*fx)*(1-fy)+(at(ix,iy+1)*(1-fx)+at(ix+1,iy+1)*fx)*fy;
}
Guide down(const Guide &g) {
    Guide r;r.width=(g.width+1)/2;r.height=(g.height+1)/2;r.pixel_size=g.pixel_size*2;
    r.values.resize(size_t(r.width)*r.height);r.validity.resize(r.values.size());r.variance.resize(r.values.size());
    for(int y=0;y<r.height;++y)for(int x=0;x<r.width;++x){
        double sum=0,weight=0,valid=0,variance=0;
        for(int dy=0;dy<2;++dy)for(int dx=0;dx<2;++dx){int xx=x*2+dx,yy=y*2+dy;if(xx>=g.width||yy>=g.height)continue;
            size_t p=size_t(yy)*g.width+xx;double k=g.validity[p];sum+=g.values[p]*k;weight+=k;valid+=1;
            if(!g.variance.empty())variance+=g.variance[p]*k*k;
        }
        size_t p=size_t(y)*r.width+x;r.values[p]=weight>0?sum/weight:0;r.validity[p]=valid>0?weight/valid:0;r.variance[p]=weight>0?variance/(weight*weight):0;
    }return r;
}
std::vector<std::array<double,3>> phase_peaks(const Guide &input,const Guide &reference) {
    const int w=int(power2(input.width*2)),h=int(power2(input.height*2));
    std::vector<std::complex<double>>a(size_t(w)*h),b(a.size());
    auto mean=[](const Guide &g){double sum=0,n=0;for(size_t i=0;i<g.values.size();++i){sum+=g.values[i]*g.validity[i];n+=g.validity[i];}return n>0?sum/n:0;};
    const double ai=mean(input),br=mean(reference);
    for(int y=0;y<input.height;++y)for(int x=0;x<input.width;++x){const size_t i=size_t(y)*input.width+x;const double window=std::pow(std::sin(pi*(x+0.5)/input.width)*std::sin(pi*(y+0.5)/input.height),2);a[size_t(y)*w+x]=(input.values[i]-ai)*input.validity[i]*window;b[size_t(y)*w+x]=(reference.values[i]-br)*reference.validity[i]*window;}
    fft2(a,w,h,false);fft2(b,w,h,false);
    for(size_t i=0;i<a.size();++i){auto cross=b[i]*std::conj(a[i]);a[i]=cross/std::max(1e-12,std::abs(cross));}
    fft2(a,w,h,true);std::vector<std::array<double,3>>result;
    for(int k=0;k<3;++k){size_t best=0;double value=-1e99;for(size_t i=0;i<a.size();++i)if(a[i].real()>value){best=i;value=a[i].real();}const int x=int(best%w),y=int(best/w);auto at=[&](int xx,int yy){return a[size_t((yy+h)%h)*w+(xx+w)%w].real();};auto sub=[](double l,double c,double r){const double d=l-2*c+r;return std::abs(d)>1e-10?std::clamp(0.5*(l-r)/d,-0.5,0.5):0;};
        result.push_back({double(x>w/2?x-w:x)+sub(at(x-1,y),value,at(x+1,y)),double(y>h/2?y-h:y)+sub(at(x,y-1),value,at(x,y+1)),value});
        for(int dy=-2;dy<=2;++dy)for(int dx=-2;dx<=2;++dx)a[size_t((y+dy+h)%h)*w+(x+dx+w)%w]=-1e99;
    }return result;
}
std::vector<double> linear_solve(std::vector<double>a,std::vector<double>b,int n) {
    for(int i=0;i<n;++i){int pivot=i;for(int j=i+1;j<n;++j)if(std::abs(a[j*n+i])>std::abs(a[pivot*n+i]))pivot=j;if(std::abs(a[pivot*n+i])<1e-15)return std::vector<double>(n);for(int k=0;k<n;++k)std::swap(a[i*n+k],a[pivot*n+k]);std::swap(b[i],b[pivot]);double d=a[i*n+i];for(int k=i;k<n;++k)a[i*n+k]/=d;b[i]/=d;for(int j=0;j<n;++j)if(j!=i){double v=a[j*n+i];for(int k=i;k<n;++k)a[j*n+k]-=v*a[i*n+k];b[j]-=v*b[i];}}
    return b;
}
void refine_affine(const Guide &input,const Guide &reference,std::array<double,6>&a) {
    // Translation is in input pixels. Coordinates below are centered/normalized
    // only while solving the six-parameter guide initialization problem.
    const double cx=(input.width-1)*0.5,cy=(input.height-1)*0.5,scale=std::max(input.width,input.height);
    for(int iteration=0;iteration<20;++iteration){std::vector<double>h(36),g(6);double valid=0;
        for(int y=2;y<input.height-2;++y)for(int x=2;x<input.width-2;++x){size_t i=size_t(y)*input.width+x;if(input.validity[i]<0.75)continue;
            const double px=(x+0.5)*input.pixel_size,py=(y+0.5)*input.pixel_size;
            const double u=(a[0]*px+a[1]*py+a[2])/reference.pixel_size-0.5,v=(a[3]*px+a[4]*py+a[5])/reference.pixel_size-0.5;
            if(u<1||v<1||u>=reference.width-2||v>=reference.height-2||bilinear(reference,u,v,reference.validity)<0.75)continue;
            const double r=bilinear(reference,u,v,reference.values)-input.values[i];
            const double gx=(bilinear(reference,u+1,v,reference.values)-bilinear(reference,u-1,v,reference.values))/2;
            const double gy=(bilinear(reference,u,v+1,reference.values)-bilinear(reference,u,v-1,reference.values))/2;
            const double xx=(x-cx)/scale,yy=(y-cy)/scale;const std::array<double,6>j{gx*xx,gx*yy,gx,gy*xx,gy*yy,gy};
            const double weight=1/std::sqrt(1+r*r/(0.02*0.02));
            for(int c=0;c<6;++c){g[c]-=weight*j[c]*r;for(int d=0;d<6;++d)h[c*6+d]+=weight*j[c]*j[d];}valid+=1;
        }
        if(valid<32)break;for(int j=0;j<6;++j)h[j*6+j]+=1e-8;
        auto delta=linear_solve(h,g,6);double maximum=std::max(std::abs(delta[2]),std::abs(delta[5]));if(maximum>1)for(double&v:delta)v/=maximum;
        a[0]+=delta[0]/scale;a[1]+=delta[1]/scale;a[3]+=delta[3]/scale;a[4]+=delta[4]/scale;
        a[2]+=input.pixel_size*(delta[2]-delta[0]*(cx+0.5)/scale-delta[1]*(cy+0.5)/scale);
        a[5]+=input.pixel_size*(delta[5]-delta[3]*(cx+0.5)/scale-delta[4]*(cy+0.5)/scale);
        double norm=0;for(double v:delta)norm+=v*v;if(norm<1e-10)break;
    }
}
Alignment align_one(const Guide &input,const Guide &reference) {
    std::vector<Guide>ip{input},rp{reference};while(std::min(ip.back().width,ip.back().height)>128){ip.push_back(down(ip.back()));rp.push_back(down(rp.back()));}
    const auto peaks=phase_peaks(ip.back(),rp.back());Alignment out;
    for(const auto &p:peaks)out.hypotheses.push_back({p[0]*ip.back().pixel_size,p[1]*ip.back().pixel_size});
    out.ambiguity=(peaks[0][2]-peaks[1][2])/std::max(1e-12,std::abs(peaks[0][2]));
    out.affine[2]=out.hypotheses[0][0];out.affine[5]=out.hypotheses[0][1];
    for(int i=int(ip.size())-1;i>=0;--i)refine_affine(ip[i],rp[i],out.affine);
    return out;
}
}

Guide make_guide(int w,int h,int frame,const std::vector<Event>&events,int max_edge) {
    int step=2;while(std::max(w,h)/step>max_edge)step*=2;
    Guide guide;guide.width=(w+step-1)/step;guide.height=(h+step-1)/step;guide.pixel_size=step;
    const size_t n=size_t(guide.width)*guide.height;std::vector<double>weights(n),counts(n);
    guide.values.resize(n);guide.validity.resize(n);guide.variance.resize(n);
    for(const auto&e:events)if(e.frame==uint32_t(frame)){
        const int x=int(e.x)/step,y=int(e.y)/step;if(x<0||y<0||x>=guide.width||y>=guide.height)continue;
        const size_t i=size_t(y)*guide.width+x;counts[i]+=1;
        if(e.kind!=EventKind::interval)continue;
        const double signal=(e.lower+e.upper)/2,variance=e.kappa*std::max(0.0,signal)+e.read_sigma*e.read_sigma,gain=e.exposure*e.eta;
        if(signal<3*std::sqrt(variance))continue;
        guide.values[i]+=signal/gain;guide.variance[i]+=variance/(gain*gain);weights[i]+=1;
    }
    for(size_t i=0;i<n;++i){guide.values[i]=weights[i]>0?guide.values[i]/weights[i]:0;guide.variance[i]=weights[i]>0?guide.variance[i]/(weights[i]*weights[i]):0;guide.validity[i]=counts[i]>0?weights[i]/counts[i]:0;}
    return guide;
}
Alignment align_guides(const Guide &input,const Guide &reference) {
    if(input.width!=reference.width||input.height!=reference.height||input.values.empty())throw std::runtime_error("Guide shape mismatch");
    auto a=align_one(input,reference),b=align_one(reference,input);double worst=0;
    for(auto p:std::array<std::array<double,2>,5>{{{0,0},{double(input.width)*input.pixel_size,0},{0,double(input.height)*input.pixel_size},{double(input.width)*input.pixel_size,double(input.height)*input.pixel_size},{input.width*input.pixel_size/2,input.height*input.pixel_size/2}}}){
        const double u=a.affine[0]*p[0]+a.affine[1]*p[1]+a.affine[2],v=a.affine[3]*p[0]+a.affine[4]*p[1]+a.affine[5];
        worst=std::max(worst,std::hypot(b.affine[0]*u+b.affine[1]*v+b.affine[2]-p[0],b.affine[3]*u+b.affine[4]*v+b.affine[5]-p[1]));
    }a.cycle_error=worst;return a;
}

LocalTranslation align_local_translation(const Guide &input,const Guide &reference,double maximum_shift,double maximum_std) {
    if(input.width!=reference.width||input.height!=reference.height||input.width<16||input.height<16||
       input.pixel_size!=reference.pixel_size||input.pixel_size<=0||maximum_shift<=0||maximum_std<=0)
        throw std::runtime_error("Invalid local registration geometry");
    const size_t pixels=size_t(input.width)*input.height;
    for(const auto *g:{&input,&reference})if(g->values.size()!=pixels||g->variance.size()!=pixels||g->validity.size()!=pixels)
        throw std::runtime_error("Local registration requires signal, variance, and validity");
    struct Fit {LocalTranslation result;double objective=1e300,hxx=0,hxy=0,hyy=0;};
    const double limit=maximum_shift/input.pixel_size;
    const int margin=std::max(3,int(std::ceil(limit))+2);
    auto fit_one=[&](const Guide &source,const Guide &target) {
        auto evaluate=[&](std::array<double,2> shift,bool update)->Fit {
            Fit best;best.result.shift=shift;
            for(int iteration=0;iteration<(update?24:1);++iteration) {
                Fit f;f.result.shift=shift;f.objective=0;
                double gx=0,gy=0,variance_sum=0,residual_sum=0,sx=0,sy=0,sxx=0,syy=0,sxy=0;
                for(int y=margin;y<source.height-margin;++y)for(int x=margin;x<source.width-margin;++x) {
                    const size_t i=size_t(y)*source.width+x;if(source.validity[i]<.9)continue;
                    const double u=x+shift[0],v=y+shift[1];if(bilinear(target,u,v,target.validity)<.9)continue;
                    const double a=source.values[i],b=bilinear(target,u,v,target.values),r=b-a;
                    const double variance=std::max(1e-12,source.variance[i]+bilinear(target,u,v,target.variance));
                    const double standardized=r/std::sqrt(variance),robust=1/std::sqrt(1+standardized*standardized/4),weight=robust/variance;
                    const double jx=(bilinear(target,u+.5,v,target.values)-bilinear(target,u-.5,v,target.values));
                    const double jy=(bilinear(target,u,v+.5,target.values)-bilinear(target,u,v-.5,target.values));
                    f.objective+=4*(std::sqrt(1+standardized*standardized/4)-1);
                    f.hxx+=weight*jx*jx;f.hxy+=weight*jx*jy;f.hyy+=weight*jy*jy;
                    gx+=weight*jx*r;gy+=weight*jy*r;variance_sum+=variance;residual_sum+=r*r;
                    sx+=a;sy+=b;sxx+=a*a;syy+=b*b;sxy+=a*b;++f.result.samples;
                }
                const double n=double(f.result.samples);
                if(n<64)return f;
                f.result.residual=std::sqrt(residual_sum/n);
                f.result.normalized_correlation=(sxy-sx*sy/n)/std::sqrt(std::max(1e-30,(sxx-sx*sx/n)*(syy-sy*sy/n)));
                const double minimum=.5*(f.hxx+f.hyy-std::hypot(f.hxx-f.hyy,2*f.hxy));
                f.result.maximum_std=source.pixel_size*std::sqrt(std::max(1.0,residual_sum/std::max(1e-30,variance_sum))/std::max(1e-20,minimum));
                if(f.objective>=best.objective)break;
                best=f;
                if(!update)break;
                const double determinant=f.hxx*f.hyy-f.hxy*f.hxy;
                if(!(determinant>1e-15))break;
                double dx=(-f.hyy*gx+f.hxy*gy)/determinant,dy=(f.hxy*gx-f.hxx*gy)/determinant;
                const double norm=std::hypot(dx,dy);if(norm<1e-5)break;
                if(norm>1){dx/=norm;dy/=norm;}
                shift[0]=std::clamp(shift[0]+dx,-limit,limit);shift[1]=std::clamp(shift[1]+dy,-limit,limit);
            }
            return best;
        };
        Fit best=evaluate({0,0},true);
        for(const auto &peak:phase_peaks(source,target)) {
            if(std::abs(peak[0])>limit||std::abs(peak[1])>limit)continue;
            const auto candidate=evaluate({peak[0],peak[1]},true);
            if(candidate.objective<best.objective)best=candidate;
        }
        return best.result;
    };
    auto forward=fit_one(input,reference),reverse=fit_one(reference,input);
    forward.cycle_error=input.pixel_size*std::hypot(forward.shift[0]+reverse.shift[0],forward.shift[1]+reverse.shift[1]);
    for(double &v:forward.shift)v*=input.pixel_size;
    forward.reliable=forward.samples>=64&&reverse.samples>=64&&forward.maximum_std<=maximum_std&&reverse.maximum_std<=maximum_std&&
        forward.cycle_error<=.35&&forward.normalized_correlation>=.6&&reverse.normalized_correlation>=.6;
    return forward;
}
void initialize_motion(State &state,const std::array<Guide,5>&guides,std::array<Alignment,5>&alignments) {
    const auto &reference=guides[state.geometry.reference];
    for(int f=0;f<5;++f){auto &motion=state.geometry.motion[f];if(f==state.geometry.reference){alignments[f].ambiguity=1;continue;}
        alignments[f]=align_guides(guides[f],reference);const auto &a=alignments[f].affine;
        std::vector<double>gradients(motion.edge_weights.size());
        for(int y=0;y<motion.rows;++y)for(int x=0;x<motion.columns;++x){size_t i=size_t(y)*motion.columns+x;double px=x*motion.spacing,py=y*motion.spacing;
            motion.nodes[i*2]=a[0]*px+a[1]*py+a[2]-px;motion.nodes[i*2+1]=a[3]*px+a[4]*py+a[5]-py;
            double u=std::clamp(px/reference.pixel_size,1.0,double(std::max(1,reference.width-2))),v=std::clamp(py/reference.pixel_size,1.0,double(std::max(1,reference.height-2)));
            gradients[i]=std::hypot(bilinear(reference,u+1,v,reference.values)-bilinear(reference,u-1,v,reference.values),bilinear(reference,u,v+1,reference.values)-bilinear(reference,u,v-1,reference.values))/2;
        }
        auto sorted=gradients;std::sort(sorted.begin(),sorted.end());double g90=std::max(1e-6,sorted[size_t((sorted.size()-1)*0.9)]);
        for(size_t i=0;i<gradients.size();++i)motion.edge_weights[i]=0.05+0.95*std::exp(-gradients[i]*gradients[i]/(g90*g90));
    }
}
int choose_reference(const std::array<Guide,5>&guides,const std::array<double,5>&timestamps,double minimum_sharpness) {
    std::array<double,5>scores{};scores.fill(-1);const double center=(*std::min_element(timestamps.begin(),timestamps.end())+*std::max_element(timestamps.begin(),timestamps.end()))/2;
    for(int f:{0,1,3,4}){
        const auto &g=guides[f];std::vector<double>ratios;
        double norm0=0,norm1=0,p2=g.pixel_size*g.pixel_size;
        for(int y=-3;y<=3;++y)for(int x=-3;x<=3;++x){norm0+=std::exp(-(x*x+y*y)*p2/(2*0.7*0.7));norm1+=std::exp(-(x*x+y*y)*p2/(2*1.4*1.4));}
        for(int ty=0;ty<g.height;ty+=16)for(int tx=0;tx<g.width;tx+=16){
            double high=0,gradient=0,noise_floor=0;int count=0;
            for(int y=std::max(3,ty);y<std::min(g.height-3,ty+16);++y)for(int x=std::max(3,tx);x<std::min(g.width-3,tx+16);++x){
                double band=0,bvar=0,gx=0,gy=0,gvar=0;bool valid=true;
                for(int dy=-3;dy<=3;++dy)for(int dx=-3;dx<=3;++dx){size_t i=size_t(y+dy)*g.width+x+dx;
                    if(g.validity[i]<0.99){valid=false;continue;}
                    auto k=[&](int xx,int yy){return std::exp(-(xx*xx+yy*yy)*p2/(2*1.4*1.4));};
                    const double b=std::exp(-(dx*dx+dy*dy)*p2/(2*0.7*0.7))/norm0-k(dx,dy)/norm1;
                    const double kx=(k(dx-1,dy)-k(dx+1,dy))/(2*g.pixel_size*norm1),ky=(k(dx,dy-1)-k(dx,dy+1))/(2*g.pixel_size*norm1);
                    const double variance=g.variance.empty()?0:g.variance[i];
                    band+=b*g.values[i];bvar+=b*b*variance;gx+=kx*g.values[i];gy+=ky*g.values[i];gvar+=(kx*kx+ky*ky)*variance;
                }
                if(valid){high+=band*band-bvar;gradient+=gx*gx+gy*gy-gvar;noise_floor+=gvar;++count;}
            }
            if(count>=4)ratios.push_back(std::max(0.0,high)/std::max(1e-12,std::max(gradient,noise_floor)));
        }
        if(!ratios.empty()){std::nth_element(ratios.begin(),ratios.begin()+ratios.size()/2,ratios.end());scores[f]=ratios[ratios.size()/2];}
    }
    int best=-1;for(int f:{0,1,3,4})if(scores[f]>=minimum_sharpness){if(best<0||std::abs(timestamps[f]-center)<std::abs(timestamps[best]-center)-1e-9||
        (std::abs(std::abs(timestamps[f]-center)-std::abs(timestamps[best]-center))<1e-9&&(scores[f]>scores[best]|| (scores[f]==scores[best]&&timestamps[f]<timestamps[best]))))best=f;}
    return best;
}
} // namespace f5
