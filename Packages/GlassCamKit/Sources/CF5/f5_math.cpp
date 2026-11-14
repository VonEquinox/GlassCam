#include "f5_math.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <memory>

namespace f5 {
namespace {
constexpr double log2pi = 1.83787706640934548;
double logadd(double a, double b) {
    if (!std::isfinite(a)) return b;
    if (!std::isfinite(b)) return a;
    return std::max(a, b) + std::log1p(std::exp(-std::abs(a - b)));
}
double logdiff(double a, double b) {
    if (b == -std::numeric_limits<double>::infinity()) return a;
    if (b >= a) return -std::numeric_limits<double>::infinity();
    return a + std::log(-std::expm1(b - a));
}
double loginterval(double lower, double upper) {
    if (!(upper > lower)) return -std::numeric_limits<double>::infinity();
    if (upper - lower < 1e-7 / std::max(1.0, std::max(std::abs(upper), std::abs(lower)))) {
        const double z = (upper + lower) * 0.5;
        return std::log(upper - lower) - z * z / 2 - log2pi / 2;
    }
    if (lower > 0) return logdiff(log_normal_cdf(-lower), log_normal_cdf(-upper));
    return logdiff(log_normal_cdf(upper), log_normal_cdf(lower));
}
double logq(const Event &e, double electrons) {
    const double mu = e.kappa * electrons;
    if (e.kind == EventKind::upper) return log_normal_cdf((mu - e.lower) / e.read_sigma);
    if (e.kind == EventKind::lower) return log_normal_cdf((e.upper - mu) / e.read_sigma);
    return loginterval((e.lower - mu) / e.read_sigma, (e.upper - mu) / e.read_sigma);
}
Likelihood mix(const Event &e, double logp, double score, double curvature, double pi0) {
    if (!std::isfinite(logp) || !std::isfinite(score)) throw std::runtime_error("NONFINITE likelihood");
    Likelihood value;
    const double inlier = std::log1p(-pi0) + logp;
    const double mixed = pi0 > 0 ? logadd(inlier, std::log(pi0) + std::log(e.uniform_probability)) : logp;
    value.nll = -mixed; value.responsibility = std::exp(inlier - mixed);
    value.score = value.responsibility * score;
    value.curvature = std::max(1e-12, value.responsibility * curvature);
    value.probability = std::exp(logp);
    return value;
}
double dot(const std::vector<double> &a, const std::vector<double> &b) {
    double value = 0; for (size_t i = 0; i < a.size(); ++i) value += a[i] * b[i]; return value;
}
size_t count(const Geometry &g) { return size_t(g.width) * g.height * g.scale * g.scale * 3; }
std::array<double, 3> to_opponent(const std::array<double, 3> &v) {
    return {(v[0] + v[1] + v[2]) / std::sqrt(3.0), (v[0] - v[2]) / std::sqrt(2.0), (v[0] - 2*v[1] + v[2]) / std::sqrt(6.0)};
}
std::array<double, 3> from_opponent(const std::array<double, 3> &v) {
    return {v[0]/std::sqrt(3.0) + v[1]/std::sqrt(2.0) + v[2]/std::sqrt(6.0),
            v[0]/std::sqrt(3.0) - 2*v[2]/std::sqrt(6.0),
            v[0]/std::sqrt(3.0) - v[1]/std::sqrt(2.0) + v[2]/std::sqrt(6.0)};
}
struct HessianStencil {
    std::array<size_t, 9> index;
    std::array<std::array<double, 9>, 3> weights{};
};
HessianStencil hessian_stencil(int x, int y, int w, int h, double spacing) {
    HessianStencil s;
    int n = 0; for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx)
        s.index[n++] = size_t(mirror(y + dy, h)) * w + mirror(x + dx, w);
    const double h2 = 1 / (spacing * spacing);
    s.weights[0][3] = s.weights[0][5] = h2; s.weights[0][4] = -2*h2;
    s.weights[2][1] = s.weights[2][7] = h2; s.weights[2][4] = -2*h2;
    const double d = h2 * std::sqrt(2.0) / 4;
    s.weights[1][0] = s.weights[1][8] = d; s.weights[1][2] = s.weights[1][6] = -d;
    return s;
}
struct Row { std::vector<size_t> index; std::vector<double> values; double curvature; };
void compact(Row &r) {
    // Mirrored ghost points may address the same coefficient. Sum before
    // squaring for a Jacobi diagonal or accumulating a normal operator.
    for (size_t i = 0; i < r.index.size(); ++i) for (size_t j = i + 1; j < r.index.size();) {
        if (r.index[i] == r.index[j]) {
            r.values[i] += r.values[j]; r.values.erase(r.values.begin() + j); r.index.erase(r.index.begin() + j);
        } else ++j;
    }
}
void add_row(const Row &r, double score, std::vector<double> &gradient, std::vector<double> &diagonal) {
    for (size_t j = 0; j < r.index.size(); ++j) {
        gradient[r.index[j]] += r.values[j] * score;
        diagonal[r.index[j]] += r.values[j] * r.values[j] * r.curvature;
    }
}
Row basis_row(const Stencil &s, double gain, double curvature) {
    Row row; row.index.assign(s.index.begin(), s.index.end()); row.values.assign(s.weight.begin(), s.weight.end());
    for (double &w : row.values) w *= gain;
    row.curvature = curvature; compact(row); return row;
}
void apply_rows(const std::vector<Row> &rows, const std::vector<double> &input, std::vector<double> &output) {
    output.assign(input.size(), 0);
    for (const Row &row : rows) {
        double p = 0; for (size_t j = 0; j < row.index.size(); ++j) p += row.values[j] * input[row.index[j]];
        p *= row.curvature;
        for (size_t j = 0; j < row.index.size(); ++j) output[row.index[j]] += row.values[j] * p;
    }
}
Likelihood likelihood(const Event &e, double mu, const Policy &p) {
    return p.gaussian_minimum_electrons > 0 && mu / e.kappa >= p.gaussian_minimum_electrons ?
        gaussian_event(e, mu, p.pi0) : poisson_gaussian(e, mu, p.pi0);
}
} // namespace

double log_normal_cdf(double z) {
    if (z > -10) return std::log(0.5 * std::erfc(-z / std::sqrt(2.0)));
    // Mills ratio asymptotic expansion, optimally truncated before it diverges.
    const double inv = 1 / (z*z); double sum = 1, term = 1, previous = 1;
    for (int k = 1; k < 100; ++k) {
        term *= -(2*k - 1)*inv;
        if (std::abs(term) >= previous) break;
        sum += term; previous = std::abs(term);
        if (previous < std::abs(sum)*1e-16) break;
    }
    return -z*z/2 - log2pi/2 - std::log(-z) + std::log(sum);
}

Likelihood poisson_gaussian(const Event &e, double mu, double pi0) {
    if (!e.valid()) return {};
    if (!(mu >= 0 && std::isfinite(mu) && e.kappa > 0 && e.read_sigma > 0 &&
          pi0 >= 0 && pi0 <= 0.02 && e.uniform_probability > 0)) throw std::runtime_error("Invalid PG domain");
    const double lambda = mu / e.kappa;
    const double radius = std::sqrt(2 * (lambda + 1) * 36.0) + 72;
    double low = std::max(0.0, std::floor(lambda - radius)), high = std::ceil(lambda + radius);
    // Include the event's tail saddle as well as the Poisson mass. A fixed
    // +/-sigma support would give incorrect scores for rare censored events.
    const double eventlo = e.kind == EventKind::upper ? e.lower : e.kind == EventKind::lower ? 0 : e.lower;
    const double eventhi = e.kind == EventKind::lower ? e.upper : e.kind == EventKind::upper ? e.lower : e.upper;
    low = std::max(0.0, std::min(low, std::floor((eventlo - 12*e.read_sigma) / e.kappa)));
    high = std::max(high, std::ceil((eventhi + 12*e.read_sigma) / e.kappa));
    if (lambda == 0) { low = 0; high = 0; }
    if (high > 5e7 || !std::isfinite(high)) throw std::runtime_error("PG reference budget exceeded");
    std::array<double, 3> sums; sums.fill(-std::numeric_limits<double>::infinity());
    double lp = lambda == 0 ? 0 : -lambda + low * std::log(lambda) - std::lgamma(low + 1);
    for (int64_t n = int64_t(low); n <= int64_t(high); ++n) {
        for (int j = 0; j < 3; ++j) sums[j] = logadd(sums[j], lp + logq(e, double(n+j)));
        if (lambda > 0) lp += std::log(lambda) - std::log(double(n + 1));
    }
    const double r1 = std::exp(sums[1]-sums[0]), r2 = std::exp(sums[2]-sums[0]);
    const double score = (1-r1) / e.kappa;
    const double observed = (r1*r1-r2) / (e.kappa*e.kappa);
    const double fisher = 1 / (e.kappa*mu + e.read_sigma*e.read_sigma);
    double positive = fisher;
    if (e.kind != EventKind::interval) {
        const double logp = std::min(0.0, sums[0]), complement = -std::expm1(logp);
        positive = complement > 1e-15 ? score * score * std::exp(logp) / complement : 0;
    }
    return mix(e, std::min(0.0, sums[0]), score, std::max({1e-12, positive, observed}), pi0);
}

Likelihood gaussian_event(const Event &e, double mu, double pi0) {
    if (!e.valid()) return {};
    if (!(mu >= 0 && std::isfinite(mu))) throw std::runtime_error("Invalid Gaussian mean");
    const double v = e.kappa*mu + e.read_sigma*e.read_sigma, sigma = std::sqrt(v);
    const double zl = (e.lower-mu)/sigma, zu = (e.upper-mu)/sigma;
    auto dz = [&](double z) { return -1/sigma - z*e.kappa/(2*v); };
    double logp, derivative;
    if (e.kind == EventKind::upper) {
        logp = log_normal_cdf(-zl);
        derivative = -std::exp(-zl*zl/2-log2pi/2-logp)*dz(zl);
    } else if (e.kind == EventKind::lower) {
        logp = log_normal_cdf(zu);
        derivative = std::exp(-zu*zu/2-log2pi/2-logp)*dz(zu);
    } else {
        logp = loginterval(zl, zu);
        derivative = std::exp(-zu*zu/2-log2pi/2-logp)*dz(zu) - std::exp(-zl*zl/2-log2pi/2-logp)*dz(zl);
    }
    const double complement = -std::expm1(std::min(0.0, logp));
    const double curvature = e.kind == EventKind::interval ? 1/v + e.kappa*e.kappa/(2*v*v) :
        (complement > 1e-15 ? derivative*derivative*std::exp(logp)/complement : 1e-12);
    return mix(e, logp, -derivative, curvature, pi0);
}

double cubic(double t) {
    t = std::abs(t); if (t >= 2) return 0;
    if (t >= 1) return std::pow(2-t, 3)/6;
    return (4-6*t*t+3*t*t*t)/6;
}
double cubic_derivative(double t) {
    const double a = std::abs(t), sign = t < 0 ? -1 : 1;
    if (a >= 2 || a == 0) return 0;
    return sign * (a >= 1 ? -(2-a)*(2-a)/2 : (-12*a+9*a*a)/6);
}
int mirror(int i, int n) {
    if (n <= 1) return 0;
    const int period = n*2; i %= period; if (i < 0) i += period;
    return i < n ? i : period - i - 1;
}
Stencil stencil(int w, int h, int scale, double x, double y, int color) {
    if (w <= 0 || h <= 0 || scale <= 0 || color < 0 || color > 2 || !std::isfinite(x) || !std::isfinite(y)) throw std::runtime_error("Invalid spline descriptor");
    Stencil result;
    const double u = scale*x-0.5, v = scale*y-0.5;
    const double first = double(std::numeric_limits<int>::min()) + 1;
    const double last = double(std::numeric_limits<int>::max()) - 4;
    if (!(u >= first && u <= last && v >= first && v <= last))
        throw std::runtime_error("Spline coordinate exceeds the integer stencil domain");
    const int ix = int(std::floor(u))-1, iy = int(std::floor(v))-1;
    int j = 0;
    for (int yy = iy; yy < iy+4; ++yy) for (int xx = ix; xx < ix+4; ++xx, ++j) {
        const double wx = cubic(u-xx), wy = cubic(v-yy);
        result.index[j] = size_t(color)*w*h + size_t(mirror(yy,h))*w + mirror(xx,w);
        result.weight[j] = wx*wy;
        result.dx[j] = scale*cubic_derivative(u-xx)*wy;
        result.dy[j] = scale*wx*cubic_derivative(v-yy);
    }
    return result;
}
double Stencil::evaluate(const std::vector<double> &x) const {
    double result = 0; for (int i = 0; i < 16; ++i) result += x[index[i]]*weight[i]; return result;
}
std::array<double, 2> Stencil::derivative(const std::vector<double> &x) const {
    std::array<double,2> result{}; for (int i = 0; i < 16; ++i) { result[0] += x[index[i]]*dx[i]; result[1] += x[index[i]]*dy[i]; } return result;
}
void Stencil::transpose(double value, std::vector<double> &out) const { for (int i = 0; i < 16; ++i) out[index[i]] += weight[i]*value; }
Motion::Motion(int w, int h, int step): columns((w+step-1)/step+1), rows((h+step-1)/step+1), spacing(step), nodes(size_t(columns)*rows*2,0), edge_weights(size_t(columns)*rows,1) {}
Motion::Weights Motion::weights(double x, double y) const {
    const double u = std::clamp(x/spacing,0.0,double(columns-1)), v = std::clamp(y/spacing,0.0,double(rows-1));
    const int ix = std::min(columns-2,int(u)), iy = std::min(rows-2,int(v));
    const double fx = u-ix, fy = v-iy;
    return {{size_t(iy*columns+ix),size_t(iy*columns+ix+1),size_t((iy+1)*columns+ix),size_t((iy+1)*columns+ix+1)},
            {(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy}};
}
std::array<double,2> Motion::displacement(double x, double y) const {
    const auto p = weights(x,y); std::array<double,2> value{};
    for (int i=0;i<4;++i) for (int c=0;c<2;++c) value[c] += p.weight[i]*nodes[2*p.index[i]+c]; return value;
}
Prediction predict(const Geometry &g, const Event &e, const std::vector<double> &x) {
    const auto u = e.frame == uint32_t(g.reference) ? std::array<double,2>{0,0} : g.motion[e.frame].displacement(e.x,e.y);
    const double px = e.x+u[0], py = e.y+u[1], gain = e.exposure*e.eta;
    if (!e.valid() || px < 0 || py < 0 || px > g.width || py > g.height) return {{},0,0,0,gain,false};
    auto basis = stencil(g.width*g.scale,g.height*g.scale,g.scale,px,py,e.color);
    auto d = basis.derivative(x);
    return {basis,basis.evaluate(x)*gain,d[0],d[1],gain,true};
}
std::vector<double> apply_a(const Geometry &g, const std::vector<Event> &events, const std::vector<double> &x) {
    std::vector<double> out(events.size()); for (size_t j=0;j<events.size();++j) { auto p=predict(g,events[j],x); out[j]=p.valid?p.mean:0; } return out;
}
std::vector<double> apply_at(const Geometry &g, const std::vector<Event> &events, const std::vector<double> &r) {
    std::vector<double> out(count(g)), zero(count(g));
    for (size_t j=0;j<events.size();++j) { auto p=predict(g,events[j],zero); if (p.valid) p.basis.transpose(p.gain*r[j],out); } return out;
}
std::vector<double> sample_rgb(const Geometry &g, const std::vector<double> &x, int scale) {
    const int w=g.width*scale,h=g.height*scale; std::vector<double> out(size_t(w)*h*3);
    for(int y=0;y<h;++y) for(int xx=0;xx<w;++xx) for(int c=0;c<3;++c)
        out[(size_t(y)*w+xx)*3+c]=stencil(g.width*g.scale,g.height*g.scale,g.scale,(xx+0.5)/scale,(y+0.5)/scale,c).evaluate(x);
    return out;
}

PCGResult pcg(const Operator &a,const std::vector<double> &b,const std::vector<double> &diag,int max_steps,double tolerance) {
    PCGResult out; out.x.assign(b.size(),0); std::vector<double> r=b,z(b.size()),p,q;
    const double initial=std::sqrt(dot(b,b)); if(initial==0) return out;
    for(size_t i=0;i<r.size();++i) z[i]=r[i]/std::max(1e-15,diag[i]);
    p=z; double rz=dot(r,z);
    for(int k=0;k<max_steps;++k) {
        a(p,q); const double pq=dot(p,q);
        if(!(pq>0 && std::isfinite(pq))) { out.positive=false; break; }
        const double alpha=rz/pq;
        for(size_t i=0;i<r.size();++i) { out.x[i]+=alpha*p[i]; r[i]-=alpha*q[i]; }
        out.iterations=k+1; out.relative_residual=std::sqrt(dot(r,r))/initial;
        if(out.relative_residual<tolerance) break;
        for(size_t i=0;i<r.size();++i) z[i]=r[i]/std::max(1e-15,diag[i]);
        const double next=dot(r,z),beta=next/rz;
        for(size_t i=0;i<p.size();++i) p[i]=z[i]+beta*p[i]; rz=next;
    }
    return out;
}
Prolongation::Prolongation(int w,int h,int c,int step):width(w),height(h),channels(c),step(step),cw((w-1+step-1)/step+1),ch((h-1+step-1)/step+1) {}
std::vector<double> Prolongation::apply(const std::vector<double> &x) const {
    std::vector<double> out(size_t(width)*height*channels);
    for(int c=0;c<channels;++c) for(int y=0;y<height;++y) for(int xx=0;xx<width;++xx) {
        const int ix=xx/step,iy=y/step; const double fx=double(xx%step)/step,fy=double(y%step)/step;
        const size_t base=size_t(c)*cw*ch;
        out[(size_t(c)*height+y)*width+xx]=
            (x[base+iy*cw+ix]*(1-fx)+x[base+iy*cw+std::min(ix+1,cw-1)]*fx)*(1-fy)+
            (x[base+std::min(iy+1,ch-1)*cw+ix]*(1-fx)+x[base+std::min(iy+1,ch-1)*cw+std::min(ix+1,cw-1)]*fx)*fy;
    } return out;
}
std::vector<double> Prolongation::transpose(const std::vector<double> &x) const {
    std::vector<double> out(size_t(cw)*ch*channels);
    for(int c=0;c<channels;++c) for(int y=0;y<height;++y) for(int xx=0;xx<width;++xx) {
        const int ix=xx/step,iy=y/step; const double fx=double(xx%step)/step,fy=double(y%step)/step;
        const size_t b=size_t(c)*cw*ch; const double v=x[(size_t(c)*height+y)*width+xx];
        out[b+iy*cw+ix]+=v*(1-fx)*(1-fy); out[b+iy*cw+std::min(ix+1,cw-1)]+=v*fx*(1-fy);
        out[b+std::min(iy+1,ch-1)*cw+ix]+=v*(1-fx)*fy; out[b+std::min(iy+1,ch-1)*cw+std::min(ix+1,cw-1)]+=v*fx*fy;
    } return out;
}

Evaluation evaluate(const State &s,const std::vector<Event> &events,const Policy &policy,double tau,bool derivatives) {
    const auto &g=s.geometry; const int w=g.width*g.scale,h=g.height*g.scale;
    const size_t n=count(g),m=size_t(w)*h;
    Evaluation out; if(derivatives) { out.gradient.assign(n,0); out.diagonal.assign(n,0); }
    auto rows=std::make_shared<std::vector<Row>>();
    size_t event_count=0;
    for(size_t i=0;i<events.size();++i) if((s.eligible.empty() || s.eligible[i]) && predict(g,events[i],s.coefficients).valid) ++event_count;
    const double barrier_weight=double(event_count)*tau/double(n+event_count);
    auto barrier=[&](const Stencil &basis,double z) {
        if(!(z>epsilon_f && std::isfinite(z))) { out.feasible=false; out.value=std::numeric_limits<double>::infinity(); return; }
        const double gap=z-epsilon_f; out.value-=barrier_weight*std::log(gap);
        if(derivatives && barrier_weight>0) { auto row=basis_row(basis,1,barrier_weight/(gap*gap)); add_row(row,-barrier_weight/gap,out.gradient,out.diagonal); rows->push_back(std::move(row)); }
    };
    for(size_t i=0;i<events.size();++i) {
        if(!s.eligible.empty() && !s.eligible[i]) continue;
        const auto &e=events[i]; const auto p=predict(g,e,s.coefficients); if(!p.valid) continue;
        barrier(p.basis,p.mean/p.gain); if(!out.feasible) return out;
        const auto l=likelihood(e,p.mean,policy); out.value+=l.nll;
        if(derivatives) { auto row=basis_row(p.basis,p.gain,l.curvature); add_row(row,l.score,out.gradient,out.diagonal); rows->push_back(std::move(row)); }
    }
    std::vector<double> sampled(n);
    for(int c=0;c<3;++c) for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        const auto b=stencil(w,h,g.scale,(x+0.5)/g.scale,(y+0.5)/g.scale,c);
        const double z=b.evaluate(s.coefficients); sampled[(size_t(c)*h+y)*w+x]=z; barrier(b,z); if(!out.feasible) return out;
    }
    const std::array<std::array<double,3>,3> fixed_color_basis{{{1/std::sqrt(3.0),1/std::sqrt(3.0),1/std::sqrt(3.0)},
        {1/std::sqrt(2.0),0,-1/std::sqrt(2.0)}, {1/std::sqrt(6.0),-2/std::sqrt(6.0),1/std::sqrt(6.0)}}};
    if(!s.color_axis.empty()&&s.color_axis.size()!=m)throw std::runtime_error("Invalid frozen color-axis grid");
    if(!s.color_confidence.empty()&&s.color_confidence.size()!=m)throw std::runtime_error("Invalid frozen color-confidence grid");
    if(!s.luminance_prior_scale.empty()&&s.luminance_prior_scale.size()!=m)throw std::runtime_error("Invalid frozen prior-scale grid");
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        const size_t pixel=size_t(y)*w+x; const auto hs=hessian_stencil(x,y,w,h,1.0/g.scale);
        auto color_basis=fixed_color_basis;
        if(!s.color_axis.empty()) {
            const auto &v=s.color_axis[pixel];const double length=std::sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
            if(!(length>0&&std::isfinite(length)))throw std::runtime_error("Invalid frozen color direction");
            auto &a=color_basis[0];for(int c=0;c<3;++c)a[c]=v[c]/length;
            const double xy=std::hypot(a[0],a[1]);
            if(!(xy>1e-8))throw std::runtime_error("Degenerate frozen color direction");
            color_basis[1]={a[1]/xy,-a[0]/xy,0};const auto &b=color_basis[1];
            color_basis[2]={a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]};
        }
        const double sigma=std::max(1e-12,s.noise_scale.empty()?0.01:s.noise_scale[pixel]);
        const double confidence=s.color_confidence.empty()?1:s.color_confidence[pixel];
        if(!(confidence>=0&&confidence<=1))throw std::runtime_error("Invalid frozen color confidence");
        const double scale=s.luminance_prior_scale.empty()?1:s.luminance_prior_scale[pixel];
        if(!(scale>=1&&std::isfinite(scale)))throw std::runtime_error("Invalid frozen luminance-prior scale");
        const double lambda_y=policy.lambda_y*scale;
        const double lambda_c=policy.lambda_y+confidence*(policy.lambda_c-policy.lambda_y)*(1+(scale-1)*confidence);
        std::array<std::array<double,3>,3> value{};
        for(int component=0;component<3;++component) {
            std::array<double,3> rgb{};
            for(int c=0;c<3;++c) for(int j=0;j<9;++j) rgb[c]+=hs.weights[component][j]*sampled[c*m+hs.index[j]]/sigma;
            for(int c=0;c<3;++c)for(int j=0;j<3;++j)value[c][component]+=color_basis[c][j]*rgb[j];
        }
        double yy=0,cc=0; for(int j=0;j<3;++j) { yy+=value[0][j]*value[0][j]; cc+=value[1][j]*value[1][j]+value[2][j]*value[2][j]; }
        const double normalization=double(event_count)/m;
        out.value+=normalization*(lambda_y*(std::sqrt(1+yy)-1)+lambda_c*(std::sqrt(1+cc)-1));
        if(!derivatives) continue;
        for(int opponent=0;opponent<3;++opponent) for(int component=0;component<3;++component) {
            const double factor=normalization*(opponent==0?lambda_y/std::sqrt(1+yy):lambda_c/std::sqrt(1+cc));
            Row row; row.curvature=factor;
            for(int c=0;c<3;++c) if(color_basis[opponent][c]!=0) for(int j=0;j<9;++j) if(hs.weights[component][j]!=0) {
                const int xx=int(hs.index[j]%w),yy=int(hs.index[j]/w);
                const auto b=stencil(w,h,g.scale,(xx+0.5)/g.scale,(yy+0.5)/g.scale,c);
                for(int k=0;k<16;++k) { row.index.push_back(b.index[k]); row.values.push_back(b.weight[k]*hs.weights[component][j]*color_basis[opponent][c]/sigma); }
            }
            compact(row); add_row(row,factor*value[opponent][component],out.gradient,out.diagonal); rows->push_back(std::move(row));
        }
    }
    out.value+=motion_penalty(g,policy.lambda_motion,event_count);
    if(derivatives) out.q=[rows](const std::vector<double> &x,std::vector<double> &y) { apply_rows(*rows,x,y); };
    return out;
}

double motion_penalty(const Geometry &g,double lambda,size_t event_count) {
    size_t total=0; for(int f=0;f<5;++f) if(f!=g.reference) total+=g.motion[f].nodes.size()/2;
    if(total==0) return 0;
    double value=0;
    for(int f=0;f<5;++f) if(f!=g.reference) {
        const auto &m=g.motion[f];
        for(int y=0;y<m.rows;++y) for(int x=0;x<m.columns;++x) {
            const auto hs=hessian_stencil(x,y,m.columns,m.rows,1); double norm=0;
            for(int c=0;c<2;++c) for(int component=0;component<3;++component) {
                double v=0; for(int j=0;j<9;++j) v+=hs.weights[component][j]*m.nodes[hs.index[j]*2+c]; norm+=v*v;
            }
            value+=m.edge_weights[size_t(y)*m.columns+x]*(std::sqrt(1+norm)-1);
        }
    }
    return event_count*lambda*value/total;
}

bool refine_motion(State &s,const std::vector<Event> &events,const Policy &policy,double tau,double *metric,bool update) {
    bool changed=false;
    if(metric)*metric=0;
    size_t valid_count=0;
    for(size_t i=0;i<events.size();++i)if((s.eligible.empty()||s.eligible[i])&&predict(s.geometry,events[i],s.coefficients).valid)++valid_count;
    for(int f=0;f<5;++f) if(f!=s.geometry.reference) {
        auto &motion=s.geometry.motion[f]; const size_t n=motion.nodes.size(); if(n==0) continue;
        std::vector<Row> rows; std::vector<double> gradient(n),diag(n,1e-6);
        size_t total_nodes=0; for(int ff=0;ff<5;++ff) if(ff!=s.geometry.reference) total_nodes+=s.geometry.motion[ff].nodes.size()/2;
        for(size_t i=0;i<events.size();++i) {
            const auto &e=events[i]; if(e.frame!=uint32_t(f) || (!s.eligible.empty()&&!s.eligible[i])) continue;
            const auto p=predict(s.geometry,e,s.coefficients); if(!p.valid) continue;
            auto l=likelihood(e,p.mean,policy);
            const double z=p.mean/p.gain,gap=z-epsilon_f;
            const double bw=valid_count*tau/(s.coefficients.size()+valid_count);
            const double score=l.score-bw/(gap*p.gain),curvature=l.curvature+bw/(gap*gap*p.gain*p.gain);
            const auto weights=motion.weights(e.x,e.y); Row row; row.curvature=curvature;
            for(int j=0;j<4;++j) for(int c=0;c<2;++c) { row.index.push_back(weights.index[j]*2+c); row.values.push_back(p.gain*(c==0?p.fx:p.fy)*weights.weight[j]); }
            compact(row); add_row(row,score,gradient,diag); rows.push_back(std::move(row));
        }
        for(int y=0;y<motion.rows;++y) for(int x=0;x<motion.columns;++x) {
            const auto hs=hessian_stencil(x,y,motion.columns,motion.rows,1); std::array<double,6> v{}; double norm=0;
            for(int c=0;c<2;++c) for(int d=0;d<3;++d) { for(int j=0;j<9;++j) v[c*3+d]+=hs.weights[d][j]*motion.nodes[hs.index[j]*2+c]; norm+=v[c*3+d]*v[c*3+d]; }
            const double weight=valid_count*policy.lambda_motion/total_nodes*motion.edge_weights[size_t(y)*motion.columns+x]/std::sqrt(1+norm);
            for(int c=0;c<2;++c) for(int d=0;d<3;++d) {
                Row row; row.curvature=weight; for(int j=0;j<9;++j) if(hs.weights[d][j]!=0) { row.index.push_back(hs.index[j]*2+c); row.values.push_back(hs.weights[d][j]); }
                compact(row); add_row(row,weight*v[c*3+d],gradient,diag); rows.push_back(std::move(row));
            }
        }
        if(metric)for(size_t j=0;j<n;++j)*metric=std::max(*metric,std::abs(gradient[j])/std::sqrt(diag[j]+1e-15));
        if(!update)continue;
        auto rhs=gradient; for(double &v:rhs) v=-v;
        auto step=pcg([&](const std::vector<double> &x,std::vector<double> &y) { apply_rows(rows,x,y); for(size_t j=0;j<n;++j) y[j]+=1e-6*x[j]; },rhs,diag,policy.pcg_steps,0.01);
        double maxnorm=0; for(size_t j=0;j<n;j+=2) maxnorm=std::max(maxnorm,std::hypot(step.x[j],step.x[j+1]));
        if(maxnorm>0.25) for(double &v:step.x) v*=0.25/maxnorm;
        const auto before=motion.nodes; const double objective=evaluate(s,events,policy,tau,false).value,gd=dot(gradient,step.x);
        if(!(gd<0)) continue;
        double alpha=1; bool accepted=false;
        for(int bt=0;bt<12;++bt,alpha*=0.5) {
            for(size_t j=0;j<n;++j) motion.nodes[j]=before[j]+alpha*step.x[j];
            bool same_support=true;
            State old=s; old.geometry.motion[f].nodes=before;
            for(size_t j=0;j<events.size();++j) if(events[j].frame==uint32_t(f) && (s.eligible.empty()||s.eligible[j])) {
                if(predict(old.geometry,events[j],s.coefficients).valid != predict(s.geometry,events[j],s.coefficients).valid) { same_support=false; break; }
            }
            const double candidate=same_support?evaluate(s,events,policy,tau,false).value:std::numeric_limits<double>::infinity();
            if(candidate<=objective+1e-4*alpha*gd) { accepted=true; changed=true; break; }
        }
        if(!accepted) motion.nodes=before;
    }
    return changed;
}

namespace {
double feasible_step(const State &s,const std::vector<Event> &events,const std::vector<double> &direction) {
    double alpha=1;
    auto check=[&](const Stencil &b) { const double delta=b.evaluate(direction); if(delta<0) alpha=std::min(alpha,0.99*(b.evaluate(s.coefficients)-epsilon_f)/(-delta)); };
    const auto &g=s.geometry; const int w=g.width*g.scale,h=g.height*g.scale;
    for(int c=0;c<3;++c) for(int y=0;y<h;++y) for(int x=0;x<w;++x) check(stencil(w,h,g.scale,(x+0.5)/g.scale,(y+0.5)/g.scale,c));
    for(size_t i=0;i<events.size();++i) if(s.eligible.empty()||s.eligible[i]) { const auto p=predict(g,events[i],s.coefficients); if(p.valid) check(p.basis); }
    return std::max(0.0,alpha);
}
bool accept_step(State &s,const std::vector<Event> &events,const Policy &p,double tau,const Evaluation &eval,const std::vector<double> &direction) {
    const double gd=dot(eval.gradient,direction); if(!(gd<0)) return false;
    double alpha=feasible_step(s,events,direction); const auto before=s.coefficients;
    for(int k=0;k<12;++k,alpha*=0.5) {
        for(size_t j=0;j<before.size();++j) s.coefficients[j]=before[j]+alpha*direction[j];
        const auto candidate=evaluate(s,events,p,tau,false);
        if(candidate.feasible && candidate.value<=eval.value+1e-4*alpha*gd) return true;
    }
    s.coefficients=before; return false;
}
double normalized_gradient(const Evaluation &e) {
    double result=0; for(size_t j=0;j<e.gradient.size();++j) result=std::max(result,std::abs(e.gradient[j])/std::sqrt(e.diagonal[j]+1e-15)); return result;
}
}

std::vector<double> limit_physical_direction(const State &s,const std::vector<Event> &events,const std::vector<double> &direction) {
    if(direction.size()!=s.coefficients.size())throw std::runtime_error("Physical step shape mismatch");
    std::vector<double> limits(direction.size(),1);
    auto constrain=[&](const Stencil &b) {
        const double gap=b.evaluate(s.coefficients)-epsilon_f;
        if(!(gap>0))throw std::runtime_error("Physical step starts outside the feasible domain");
        double positive=0,negative=0;
        for(size_t j=0;j<16;++j){const double v=b.weight[j]*direction[b.index[j]];if(v>=0)positive+=v;else negative-=v;}
        if(negative<=positive+.9*gap)return;
        const double factor=std::clamp((positive+.9*gap)/negative,0.0,1.0);
        for(size_t j=0;j<16;++j)if(b.weight[j]>0&&direction[b.index[j]]<0)limits[b.index[j]]=std::min(limits[b.index[j]],factor);
    };
    const auto &g=s.geometry;const int w=g.width*g.scale,h=g.height*g.scale;
    for(int c=0;c<3;++c)for(int y=0;y<h;++y)for(int x=0;x<w;++x)constrain(stencil(w,h,g.scale,(x+.5)/g.scale,(y+.5)/g.scale,c));
    for(size_t i=0;i<events.size();++i)if(s.eligible.empty()||s.eligible[i]){const auto p=predict(g,events[i],s.coefficients);if(p.valid)constrain(p.basis);}
    auto result=direction;for(size_t i=0;i<result.size();++i)if(result[i]<0)result[i]*=limits[i];return result;
}

ImageStep image_step(const State &s,const std::vector<Event> &events,const Evaluation &eval,
                     const std::vector<size_t> &variables,double damping,int max_steps) {
    const size_t n=s.coefficients.size();
    std::vector<int> local(n,-1);
    std::vector<double> rhs(variables.size()),diagonal(variables.size());
    for(size_t i=0;i<variables.size();++i) {
        local[variables[i]]=int(i);rhs[i]=-eval.gradient[variables[i]];
        diagonal[i]=eval.diagonal[variables[i]]+damping;
    }
    std::vector<Row> guards;
    ImageStep result;
    for(int round=0;round<=6;++round) {
        auto step=pcg([&](const std::vector<double> &x,std::vector<double> &y) {
            std::vector<double> full(n),q;
            for(size_t i=0;i<variables.size();++i)full[variables[i]]=x[i];
            eval.q(full,q);
            y.resize(variables.size());
            for(size_t i=0;i<variables.size();++i)y[i]=q[variables[i]]+damping*x[i];
            for(const auto &row:guards) {
                double value=0;for(size_t j=0;j<row.index.size();++j)value+=row.values[j]*x[row.index[j]];
                for(size_t j=0;j<row.index.size();++j)y[row.index[j]]+=row.curvature*row.values[j]*value;
            }
        },rhs,diagonal,max_steps,0.01);
        result.direction.assign(n,0);
        for(size_t i=0;i<variables.size();++i)result.direction[variables[i]]=step.x[i];
        result.feasible_fraction=feasible_step(s,events,result.direction);
        result.guard_rounds=round;
        if(round==0)result.unguarded_fraction=result.feasible_fraction;
        if(result.feasible_fraction>=0.5 || round==6)break;
        const size_t before=guards.size();
        auto guard=[&](const Stencil &basis) {
            const double gap=basis.evaluate(s.coefficients)-epsilon_f,delta=basis.evaluate(result.direction);
            if(!(gap>0 && delta < -0.5*gap))return;
            auto full=basis_row(basis,1,0);Row row;double metric=0;
            for(size_t j=0;j<full.index.size();++j) {
                const int index=local[full.index[j]];if(index<0)continue;
                const double weight=full.values[j];
                row.index.push_back(size_t(index));row.values.push_back(weight);
                metric+=weight*weight/std::max(1e-30,diagonal[size_t(index)]);
            }
            if(!(metric>0))return;
            // For an isolated constraint, Sherman-Morrison reduces its
            // predicted negative change to half the available physical gap.
            row.curvature=std::min(1e12,(-2*delta/gap-1)/metric);
            for(size_t j=0;j<row.index.size();++j)diagonal[row.index[j]]+=row.curvature*row.values[j]*row.values[j];
            guards.push_back(std::move(row));
        };
        const auto &g=s.geometry;const int w=g.width*g.scale,h=g.height*g.scale;
        for(int c=0;c<3;++c)for(int y=0;y<h;++y)for(int x=0;x<w;++x)
            guard(stencil(w,h,g.scale,(x+0.5)/g.scale,(y+0.5)/g.scale,c));
        for(size_t i=0;i<events.size();++i)if(s.eligible.empty()||s.eligible[i]) {
            const auto p=predict(g,events[i],s.coefficients);if(p.valid)guard(p.basis);
        }
        if(guards.size()==before)break;
    }
    return result;
}

Trace solve(State &s,const std::vector<Event> &events,const Policy &p,int epoch,const std::function<bool()> &cancelled) {
    Trace trace; trace.scale=s.geometry.scale; trace.epoch=epoch;
    const auto started=std::chrono::steady_clock::now();
    const auto stop=[&]() { if(cancelled&&cancelled()) return true; return p.max_seconds>0 && std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count()>=p.max_seconds; };
    const int w=s.geometry.width*s.geometry.scale,h=s.geometry.height*s.geometry.scale;
    const size_t n=s.coefficients.size();
    std::vector<std::vector<size_t>> blocks;
    for(int color=0;color<4;++color) for(int y=0;y<h;y+=p.block_size) for(int x=0;x<w;x+=p.block_size) {
        if(((y/p.block_size)%2)*2+(x/p.block_size)%2!=color) continue;
        std::vector<size_t> indices;
        for(int c=0;c<3;++c) for(int yy=y;yy<std::min(h,y+p.block_size);++yy) for(int xx=x;xx<std::min(w,x+p.block_size);++xx) indices.push_back((size_t(c)*h+yy)*w+xx);
        blocks.push_back(std::move(indices));
    }
    if(p.reverse_blocks) std::reverse(blocks.begin(),blocks.end());
    Prolongation prolong(w,h,3,8);
    int stable=0,stalls=0,geometry_updates=0; double previous=std::numeric_limits<double>::infinity();
    const std::array<double,3> taus{1e-4,1e-6,1e-8};
    for(int cycle=0;cycle<p.max_cycles;++cycle) {
        if(stop()) { trace.stop=cancelled&&cancelled()?"CANCELLED":"BUDGET_STOP"; return trace; }
        const double tau=taus[std::min(2,cycle)];
        if(geometry_updates<p.geometry_rounds && (cycle==0 || cycle>=geometry_updates*std::max(1,p.max_cycles/std::max(1,p.geometry_rounds)) ||
            (cycle>2 && trace.standardized_gradient<p.gradient_tolerance))) {
            refine_motion(s,events,p,tau);++geometry_updates;stable=0;previous=std::numeric_limits<double>::infinity();
        }
        bool updated=false;
        for(const auto &indices:blocks) {
            if(stop()) { trace.stop=cancelled&&cancelled()?"CANCELLED":"BUDGET_STOP"; return trace; }
            auto e=evaluate(s,events,p,tau); if(!e.feasible) { trace.stop="NONFINITE"; return trace; }
            double damping=1e-6;
            for(int attempt=0;attempt<3;++attempt,damping*=10) {
                auto step=image_step(s,events,e,indices,damping,p.pcg_steps);
                if(accept_step(s,events,p,tau,e,step.direction)) { updated=true; break; }
            }
        }
        auto e=evaluate(s,events,p,tau);
        auto rhs=prolong.transpose(e.gradient); for(double &v:rhs) v=-v;
        // Exact Galerkin diagonal on the small reference coarse problem. The
        // mobile path accumulates the same P weights in its tile normal kernel.
        const size_t nc=rhs.size(); std::vector<double> diag(nc);
        const Operator coarse=[&](const std::vector<double> &x,std::vector<double> &y) {
            auto fine=prolong.apply(x); std::vector<double> q; e.q(fine,q); y=prolong.transpose(q);
            for(size_t i=0;i<y.size();++i) y[i]+=1e-6*x[i];
        };
        for(size_t i=0;i<nc;++i) { std::vector<double> basis(nc),q; basis[i]=1; coarse(basis,q); diag[i]=q[i]; }
        auto correction=pcg(coarse,rhs,diag,30,0.01);
        updated=accept_step(s,events,p,tau,e,prolong.apply(correction.x))||updated;
        auto final=evaluate(s,events,p,tau); trace.standardized_gradient=normalized_gradient(final);
        if(p.geometry_rounds>0)refine_motion(s,events,p,tau,&trace.standardized_motion_gradient,false);
        trace.objective.push_back(final.value); trace.barrier_tau.push_back(tau); trace.cycles=cycle+1;
        const double relative=std::abs(previous-final.value)/std::max(1.0,std::abs(previous));
        if(cycle>=3 && relative<p.objective_tolerance && trace.standardized_gradient<p.gradient_tolerance && trace.standardized_motion_gradient<p.gradient_tolerance) ++stable; else stable=0;
        if(stable>=2) { trace.stop="CONVERGED"; return trace; }
        if(!updated && trace.standardized_gradient>=p.gradient_tolerance) ++stalls; else stalls=0;
        if(stalls>=3) { trace.stop="NUMERICAL_STALL"; return trace; }
        previous=final.value;
    }
    trace.stop="BUDGET_STOP"; return trace;
}

State initialize(int width,int height,int scale,int reference,const std::vector<Event> &events) {
    if(width<=0 || height<=0 || scale<1 || scale>2 || reference<0 || reference>=5) throw std::runtime_error("Invalid state shape");
    State state; state.geometry={width,height,scale,reference,{}};
    for(auto &motion:state.geometry.motion) motion=Motion(width,height);
    const size_t pixels=size_t(width)*height*scale*scale; state.coefficients.resize(pixels*3);
    // Match the data-based native initializer: a flat color seed is far outside
    // the narrow real-RAW noise distribution at edges and makes the robust
    // mixture reject genuine image structure before optimization can recover it.
    std::vector<const Event *> reference_grid(size_t(width)*height,nullptr);
    for(const auto &e:events) if(e.frame==uint32_t(reference)&&e.valid()&&e.color<3&&std::isfinite(e.x)&&std::isfinite(e.y)&&
        e.x>=0&&e.y>=0&&e.x<width&&e.y<height&&e.exposure*e.eta>0) {
        reference_grid[size_t(int(e.y))*width+int(e.x)]=&e;
    }
    state.noise_scale.resize(pixels);
    for(int y=0;y<height*scale;++y)for(int x=0;x<width*scale;++x){
        std::array<double,3> sum{},weight{};double read_floor=0;
        const int px=x/scale,py=y/scale;
        for(int dy=-2;dy<=2;++dy)for(int dx=-2;dx<=2;++dx){
            const auto *e=reference_grid[size_t(mirror(py+dy,height))*width+mirror(px+dx,width)];if(!e)continue;
            const double value=e->kind==EventKind::upper?e->lower:e->kind==EventKind::lower?0:(e->lower+e->upper)*0.5;
            const double gain=e->exposure*e->eta,k=1.0/(1+dx*dx+dy*dy);
            sum[e->color]+=k*std::max(1e-6,value/gain);weight[e->color]+=k;read_floor=std::max(read_floor,e->read_sigma/gain);
        }
        const size_t index=size_t(y)*width*scale+x;
        for(int c=0;c<3;++c)state.coefficients[c*pixels+index]=weight[c]>0?std::max(1e-6,sum[c]/weight[c]):0.18;
        state.noise_scale[index]=std::max(1e-6,read_floor);
    }
    state.eligible.resize(events.size(),1); return state;
}
void freeze_noise_scale(State &state,const std::vector<Event> &events) {
    const auto &g=state.geometry; const size_t pixels=size_t(g.width)*g.height*g.scale*g.scale;
    std::vector<double> information(pixels); double floor=std::numeric_limits<double>::infinity();
    for(const auto &e:events) { const auto p=predict(g,e,state.coefficients); if(!p.valid) continue;
        const double fisher=p.gain*p.gain/(e.kappa*std::max(0.0,p.mean)+e.read_sigma*e.read_sigma);
        for(int j=0;j<16;++j) information[p.basis.index[j]%pixels]+=p.basis.weight[j]*fisher;
        floor=std::min(floor,e.read_sigma/p.gain);
    }
    state.noise_scale.resize(pixels); for(size_t i=0;i<pixels;++i) state.noise_scale[i]=std::max(std::isfinite(floor)?floor:1e-4,information[i]>0?std::sqrt(3/information[i]):1.0);
}
State lift(const State &native,int scale) {
    State out=native; out.geometry.scale=scale;
    const int w=out.geometry.width*scale,h=out.geometry.height*scale; const auto image=sample_rgb(native.geometry,native.coefficients,scale);
    out.coefficients.resize(size_t(w)*h*3); out.noise_scale.resize(size_t(w)*h);
    if(!native.color_axis.empty())out.color_axis.resize(size_t(w)*h);
    if(!native.color_confidence.empty())out.color_confidence.resize(size_t(w)*h);
    if(!native.luminance_prior_scale.empty())out.luminance_prior_scale.resize(size_t(w)*h);
    // A conservative positive initialization, not a claim that sampled values
    // are already the correct fine spline coefficients. The data solve follows.
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        const size_t p=size_t(y)*w+x;
        for(int c=0;c<3;++c) out.coefficients[size_t(c)*w*h+p]=std::max(1e-6,image[p*3+c]);
        const int nx=std::min(native.geometry.width-1,x/scale),ny=std::min(native.geometry.height-1,y/scale);
        out.noise_scale[p]=native.noise_scale[size_t(ny)*native.geometry.width+nx];
        if(!native.color_axis.empty())out.color_axis[p]=native.color_axis[size_t(ny)*native.geometry.width+nx];
        if(!native.color_confidence.empty())out.color_confidence[p]=native.color_confidence[size_t(ny)*native.geometry.width+nx];
        if(!native.luminance_prior_scale.empty())out.luminance_prior_scale[p]=native.luminance_prior_scale[size_t(ny)*native.geometry.width+nx];
    }
    return out;
}
} // namespace f5
