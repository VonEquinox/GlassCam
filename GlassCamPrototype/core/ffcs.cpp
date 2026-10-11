// Portable adaptation of supplied FFCS implementation/{pipeline,color,effects,lutdata,models}.py.
// XH2S reference-asset path only. Preserve stage order, constants, clipping,
// BGR axes, header matrix, all look parameters, grain and float sharpening.
#include "ffcs_c.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <exception>
#include <thread>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>
namespace {
struct Look { const char *name,*asset; double contrast,saturation,hue,shoulder,toe,grain,size,chroma,sharp; bool acros; };
const Look looks[] = {
 {"PROVIA","provia.lutz",1.03,1.02,0,.10,0,.015,1,.10,.22,false},
 {"VELVIA","velvia.lutz",1.14,1.34,.012,.18,-.01,.025,.9,.13,.12,false},
 {"ASTIA","astia.lutz",1,1.08,-.008,.08,.005,.015,1,.09,.18,false},
 {"CLASSIC CHROME","classic_chrome.lutz",1.10,.88,-.012,.24,.01,.012,1.1,.08,.20,false},
 {"CLASSIC NEG.","classic_neg.lutz",1.06,1.05,.018,.20,.015,.020,1.2,.11,.16,false},
 {"NOSTALGIC NEG.","nostalgic_neg.lutz",1.04,.96,.025,.14,.025,.022,1.25,.10,.15,false},
 {"ETERNA","eterna.lutz",.86,.81,-.008,.30,.02,.018,1,.10,.10,false},
 {"ETERNA BLEACH BYPASS","bleach_bypass.lutz",1.23,.43,-.01,.34,.01,.024,.85,.12,.08,false},
 {"ACROS","acros.lutz",1.15,0,0,.28,.02,.035,1.15,.12,.25,true},
 {"MONOCHROME","bw.lutz",1.08,0,0,.18,.01,.022,1.1,.10,.20,false},
 {"PRO NEG. HI","pro_neg_hi.lutz",1.10,.93,-.008,.12,.005,.012,1,.08,.18,false},
 {"PRO NEG. STD","pro_neg_std.lutz",.96,.92,0,.06,.008,.012,1,.08,.18,false},
 {"SEPIA","sepia.lutz",1,.38,0,.16,.025,.018,1.1,.10,.14,false},
 {"ACROS+G","acros_g_filter.lutz",1.15,0,-.025,.28,.02,.035,1.15,.12,.25,true},
 {"ACROS+R","acros_r_filter.lutz",1.15,0,.032,.28,.02,.035,1.15,.12,.25,true},
 {"ACROS+Ye","acros_ye_filter.lutz",1.15,0,.052,.28,.02,.035,1.15,.12,.25,true},
 {"MONOCHROME+G","mono_g_filter.lutz",1.08,0,-.025,.18,.01,.022,1.1,.10,.20,false},
 {"MONOCHROME+R","mono_r_filter.lutz",1.08,0,.032,.18,.01,.022,1.1,.10,.20,false},
 {"MONOCHROME+Ye","mono_ye_filter.lutz",1.08,0,.052,.18,.01,.022,1.1,.10,.20,false}
};
using RGB=std::array<double,3>;
double clip(double x) { return x<0?0:x>1?1:x; }
double decode(double x) { x=clip(x); return x<=.04045?x/12.92:std::pow((x+.055)/1.055,2.4); }
double encode(double x) { x=clip(x); return x<=.0031308?12.92*x:1.055*std::pow(x,1.0/2.4)-.055; }
RGB mul(RGB v,const double *m) { RGB o{}; for(int i=0;i<3;++i) for(int j=0;j<3;++j) o[i]+=m[i*3+j]*v[j]; return o; }
const double xyzM[]={.4124564,.3575761,.1804375,.2126729,.7151522,.0721750,.0193339,.1191920,.9503041};
const double rgbM[]={3.2404542,-1.5371385,-.4985314,-.9692660,1.8760108,.0415560,.0556434,-.2040259,1.0572252};
double labf(double t) { const double d=6.0/29; return t>d*d*d?std::pow(t,1.0/3):t/(3*d*d)+4.0/29; }
double labi(double t) { const double d=6.0/29; return t>d?std::pow(t,3):3*d*d*(t-4.0/29); }
RGB lab(RGB v,const Look &s) {
 for(auto &x:v) { x=decode(x); }
 v=mul(v,xyzM);
 double x=labf(v[0]/.95047), y=labf(v[1]), z=labf(v[2]/1.08883);
 double l=std::max(0.,std::min(100.,50+((116*y-16)-50))), a=500*(x-y), b=200*(y-z);
 double c=std::hypot(a,b)*s.saturation, h=std::atan2(b,a)+s.hue*2*3.14159265358979323846;
 a=c*std::cos(h); b=c*std::sin(h); double fy=(l+16)/116;
 v={labi(fy+a/500)*.95047,labi(fy),labi(fy-b/200)*1.08883};v=mul(v,rgbM);
 for(auto &q:v) { q=clip(encode(q)); }
 return v;
}
RGB ucs(RGB v) {
 for(auto &x:v) { x=decode(x); }
 double r=v[0],g=v[1],b=v[2];
 double l=.4122214708*r+.5363325363*g+.0514459929*b;
 double m=.2119034982*r+.6806995451*g+.1073969566*b;
 double s=.0883024619*r+.2817188376*g+.6299787005*b;
 l=std::copysign(std::pow(std::abs(l),1.0/3),l);m=std::copysign(std::pow(std::abs(m),1.0/3),m);s=std::copysign(std::pow(std::abs(s),1.0/3),s);
 double L=.2104542553*l+.7936177850*m-.0040720468*s;
 double a=1.9779984951*l-2.4285922050*m+.4505937099*s;
 double bb=.0259040371*l+.7827717662*m-.8086757660*s;
 double c=std::hypot(a,bb),h=std::atan2(bb,a);L=.5+(L-.5);a=c*std::cos(h);bb=c*std::sin(h);
 l=std::pow(L+.3963377774*a+.2158037573*bb,3);
 m=std::pow(L-.1055613458*a-.0638541728*bb,3);
 s=std::pow(L-.0894841775*a-1.2914855480*bb,3);
 v={4.0767416621*l-3.3077115913*m+.2309699292*s,-1.2684380046*l+2.6097574011*m-.3413193965*s,-.0041960863*l-.7034186147*m+1.7076147010*s};
 for(auto &x:v) { x=clip(encode(x)); }
 return v;
}
double noise(uint32_t x,uint32_t y,uint32_t seed) { uint32_t n=x*374761393u+y*668265263u+seed*69069u;n=(n^(n>>13))*1274126177u;n^=n>>16;return (n/4294967295.0)*2-1; }
double smooth(size_t x,size_t y,size_t width,uint32_t seed) {
 double scale=std::max(1.,width*.008),xx=x/scale,yy=y/scale;uint32_t gx=uint32_t(xx),gy=uint32_t(yy);
 double fx=xx-gx,fy=yy-gy;double a=noise(gx,gy,seed)*(1-fx)+noise(gx+1,gy,seed)*fx,b=noise(gx,gy+1,seed)*(1-fx)+noise(gx+1,gy+1,seed)*fx;return a*(1-fy)+b*fy;
}
void errorText(char *e,size_t n,const char *s) {if(e&&n){std::strncpy(e,s,n-1);e[n-1]=0;}}
size_t count(size_t w,size_t h) {if(!w||!h||w>100000||h>100000||w>std::numeric_limits<size_t>::max()/h/(3*sizeof(double)))throw std::runtime_error("Invalid image dimensions");return w*h*3;}
bool overlaps(const void *a, size_t an, const void *b, size_t bn) {
 if(!a || !b || !an || !bn) return false;
 const auto x=reinterpret_cast<uintptr_t>(a), y=reinterpret_cast<uintptr_t>(b);
 if(an>std::numeric_limits<uintptr_t>::max()-x || bn>std::numeric_limits<uintptr_t>::max()-y)
  throw std::runtime_error("FFCS buffer address overflow");
 return x<y+bn && y<x+an;
}
uint16_t u16(const unsigned char *p){return uint16_t(p[0])|uint16_t(p[1])<<8;}
uint32_t u32(const unsigned char *p){return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
float f32(const unsigned char *p){uint32_t x=u32(p);float f;std::memcpy(&f,&x,4);return f;}
}
struct FFCSContext {Look look;size_t size;double scale;double matrix[9];bool rgbChannels;std::vector<uint16_t> lut;};
namespace {
RGB mapLUT(const FFCSContext &c,RGB v) {
 double p[]={clip(v[2])*(c.size-1),clip(v[1])*(c.size-1),clip(v[0])*(c.size-1)};size_t lo[3],hi[3];double f[3];
 for(int i=0;i<3;++i){lo[i]=size_t(std::floor(p[i]));hi[i]=std::min(lo[i]+1,c.size-1);f[i]=p[i]-lo[i];}
 auto at=[&](size_t x,size_t y,size_t z,int ch){return c.lut[((z*c.size+y)*c.size+x)*3+ch]/c.scale;};RGB o{};
 for(int ch=0;ch<3;++ch){double a=at(lo[0],lo[1],lo[2],ch)*(1-f[0])+at(hi[0],lo[1],lo[2],ch)*f[0];double b=at(lo[0],hi[1],lo[2],ch)*(1-f[0])+at(hi[0],hi[1],lo[2],ch)*f[0];double c0=a*(1-f[1])+b*f[1];a=at(lo[0],lo[1],hi[2],ch)*(1-f[0])+at(hi[0],lo[1],hi[2],ch)*f[0];b=at(lo[0],hi[1],hi[2],ch)*(1-f[0])+at(hi[0],hi[1],hi[2],ch)*f[0];double c1=a*(1-f[1])+b*f[1];o[ch]=clip(c0*(1-f[2])+c1*f[2]);}
 if(!c.rgbChannels) { std::swap(o[0],o[2]); }
 return o;
}
void render(const FFCSContext &ctx,std::vector<double> &p,size_t w,size_t h,uint32_t seed,bool linear,FFCSStageCallback cb,void *user){
 auto put=[&](const char *n){if(cb)cb(n,p.data(),w,h,user);};
 auto transform=[&](auto fn){for(size_t i=0;i<p.size();i+=3){RGB v={p[i],p[i+1],p[i+2]};v=fn(v);for(int j=0;j<3;++j)p[i+j]=v[j];}};
 put("input_normalized");if(!linear)for(auto &v:p)v=decode(v);put("gamma_pre");
 transform([&](RGB v){v=mul(v,ctx.matrix);for(auto &x:v)x=clip(x);return v;});put("matrix_3x3");
 transform([&](RGB v){for(auto &x:v)x=encode(x);return mapLUT(ctx,v);});put("lut_3d");
 transform([&](RGB v){return ucs(lab(v,ctx.look));});put("lab_ucs");
 const auto &s=ctx.look;for(auto &x:p){double y=.5+(clip(x)-.5)*std::max(.05,s.contrast);if(s.toe)y+=s.toe*(1-y)*(.18-.18*y);if(s.shoulder)y-=s.shoulder*y*y*.22;x=clip(y);}put("tone_curve");
 if(s.grain>0){for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x){size_t i=(y*w+x)*3;double n=.72*noise(uint32_t(x),uint32_t(y),seed)+.28*smooth(size_t(x/s.size),size_t(y/s.size),std::max(size_t(1),size_t(w/s.size)),seed+17u);double lum=.2126*p[i]+.7152*p[i+1]+.0722*p[i+2];double delta=n*(s.grain*.035)*(.35+.9*std::sqrt(std::max(0.,lum*(1-.45*lum))));if(s.acros||s.saturation==0){double g=clip(clip(lum)+delta);p[i]=p[i+1]=p[i+2]=g;}else{double c=n*(s.grain*.035)*s.chroma*.45;p[i]=clip(p[i]+delta+c);p[i+1]=clip(p[i+1]+delta);p[i+2]=clip(p[i+2]+delta-c);}}}put("film_grain");
 if(s.sharp>0){std::vector<double> out(p.size());double strength=std::max(0.,std::min(3.,s.sharp))*.35;for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x){RGB sum{};size_t n=0;for(size_t yy=(y?y-1:0);yy<std::min(h,y+2);++yy)for(size_t xx=(x?x-1:0);xx<std::min(w,x+2);++xx){++n;for(int c=0;c<3;++c)sum[c]+=p[(yy*w+xx)*3+c];}for(int c=0;c<3;++c){size_t i=(y*w+x)*3+c;out[i]=clip(p[i]+strength*(p[i]-sum[c]/n));}}p.swap(out);}put("sharpen");put("output_icc");
}
// Mobile render keeps only three post-grain rows in double precision. The
// original stages before sharpen are pointwise (grain depends on coordinates,
// width and seed), so this is numerically identical without full-frame doubles.
RGB mobilePixel(const FFCSContext &ctx, const float *in, size_t x, size_t y,
                size_t w, double gain, uint32_t seed) {
 RGB v={clip(double(in[0])*gain),clip(double(in[1])*gain),clip(double(in[2])*gain)};
 v=mul(v,ctx.matrix);
 for(auto &q:v) { q=encode(clip(q)); }
 v=ucs(lab(mapLUT(ctx,v),ctx.look));
 const auto &s=ctx.look;
 for(auto &q:v) {
  double t=.5+(clip(q)-.5)*std::max(.05,s.contrast);
  if(s.toe) t+=s.toe*(1-t)*(.18-.18*t);
  if(s.shoulder) t-=s.shoulder*t*t*.22;
  q=clip(t);
 }
 if(s.grain>0) {
  double n=.72*noise(uint32_t(x),uint32_t(y),seed)+.28*smooth(size_t(x/s.size),size_t(y/s.size),std::max(size_t(1),size_t(w/s.size)),seed+17u);
  double lum=.2126*v[0]+.7152*v[1]+.0722*v[2];
  double delta=n*(s.grain*.035)*(.35+.9*std::sqrt(std::max(0.,lum*(1-.45*lum))));
  if(s.acros||s.saturation==0) {
   double g=clip(clip(lum)+delta);v={g,g,g};
  } else {
   double c=n*(s.grain*.035)*s.chroma*.45;
   v={clip(v[0]+delta+c),clip(v[1]+delta),clip(v[2]+delta-c)};
  }
 }
 return v;
}
uint8_t quantize(double x){double v=clip(x)*255,base=std::floor(v),f=v-base;if(f>.5||(f==.5&&std::fmod(base,2.)!=0))++base;return uint8_t(base);}
}
extern "C" {
size_t ffcs_simulation_count(void){return sizeof(looks)/sizeof(looks[0]);}
const char *ffcs_simulation_name(size_t i){return i<ffcs_simulation_count()?looks[i].name:nullptr;}
const char *ffcs_simulation_asset(size_t i){return i<ffcs_simulation_count()?looks[i].asset:nullptr;}
FFCSContext *ffcs_create(const char *dir,size_t index,char *err,size_t en){
 try {if(!dir||!*dir||index>=ffcs_simulation_count())throw std::runtime_error("Invalid FFCS asset directory or simulation index");
 std::string path=std::string(dir)+"/"+looks[index].asset;std::ifstream in(path,std::ios::binary|std::ios::ate);if(!in)throw std::runtime_error("Missing FFCS reference LUT: "+path);auto len=in.tellg();if(len<60||len>64*1024*1024)throw std::runtime_error("Invalid FFCS LUT file size");std::vector<unsigned char> b(static_cast<size_t>(len));in.seekg(0);if(!in.read(reinterpret_cast<char*>(b.data()),len))throw std::runtime_error("Cannot read FFCS LUT");
 bool v2=std::memcmp(b.data(),"FFCSLUT2",8)==0,v1=std::memcmp(b.data(),"FFCSLUT1",8)==0;if(!v1&&!v2)throw std::runtime_error("Unsupported FFCS LUT container");size_t size=u16(b.data()+8);double scale=f32(b.data()+12);if(size<2||size>256||u16(b.data()+10)!=3||!std::isfinite(scale)||scale<=0)throw std::runtime_error("Invalid FFCS LUT header");size_t start=v2?60:56;uint32_t packed=u32(b.data()+(v2?56:52));if(packed!=b.size()-start)throw std::runtime_error("FFCS LUT compressed length mismatch");size_t expected=size*size*size*6;std::vector<unsigned char> raw(expected);uLongf dest=expected;if(uncompress(raw.data(),&dest,b.data()+start,packed)!=Z_OK||dest!=expected)throw std::runtime_error("Corrupt FFCS LUT payload");
 FFCSContext ctx{looks[index],size,scale,{},v2&&(b[52]&1),{}};for(int i=0;i<9;++i){ctx.matrix[i]=f32(b.data()+16+4*i);if(!std::isfinite(ctx.matrix[i]))throw std::runtime_error("Nonfinite FFCS matrix");}ctx.lut.resize(expected/2);for(size_t i=0;i<ctx.lut.size();++i)ctx.lut[i]=u16(raw.data()+i*2);errorText(err,en,"");return new FFCSContext(std::move(ctx));
 }catch(const std::exception &e){errorText(err,en,e.what());return nullptr;}catch(...){errorText(err,en,"Unknown FFCS initialization failure");return nullptr;}}
void ffcs_destroy(FFCSContext *c){delete c;}
int ffcs_process_encoded_double(const FFCSContext *c,const double *in,size_t ni,size_t w,size_t h,uint32_t seed,double *out,size_t no,FFCSStageCallback cb,void *user,char *err,size_t en){try{size_t n=count(w,h);if(!c||!in||!out||ni<n||no<n)throw std::runtime_error("Invalid FFCS double buffers");for(size_t i=0;i<n;++i)if(!std::isfinite(in[i]))throw std::runtime_error("Nonfinite FFCS input");std::vector<double> p(in,in+n);render(*c,p,w,h,seed,false,cb,user);std::copy(p.begin(),p.end(),out);errorText(err,en,"");return 1;}catch(const std::exception &e){errorText(err,en,e.what());return 0;}catch(...){errorText(err,en,"Unknown FFCS rendering failure");return 0;}}
int ffcs_process_linear_rgb(const FFCSContext *c,const float *in,size_t ni,size_t w,size_t h,float ev,uint32_t seed,float *out,size_t no,uint8_t *rgba,size_t nb,char *err,size_t en) {
 try {
  size_t n=count(w,h);
  if(!c||!in||!out||ni<n||no<n||(rgba&&nb<(n/3)*4)||!std::isfinite(ev)||ev < -32||ev>32)
   throw std::runtime_error("Invalid FFCS float buffers or exposure");
  double gain=std::exp2(double(ev));std::vector<double> p(n);
  for(size_t i=0;i<n;++i) {
   if(!std::isfinite(in[i])) throw std::runtime_error("Nonfinite FFCS input");
   p[i]=clip(double(in[i])*gain);
  }
  render(*c,p,w,h,seed,true,nullptr,nullptr);
  for(size_t i=0;i<n;++i) out[i]=float(decode(p[i]));
  if(rgba) for(size_t i=0;i<n/3;++i) {
   for(int j=0;j<3;++j) rgba[i*4+j]=quantize(p[i*3+j]);
   rgba[i*4+3]=255;
  }
  errorText(err,en,"");return 1;
 } catch(const std::exception &e) { errorText(err,en,e.what());return 0; }
 catch(...) { errorText(err,en,"Unknown FFCS rendering failure");return 0; }
}
int ffcs_process_linear_rgb_optimized(const FFCSContext *c,const float *in,size_t ni,size_t w,size_t h,float ev,uint32_t seed,float *out,size_t no,uint8_t *rgba,size_t nb,unsigned workers,char *err,size_t en){try{size_t n=count(w,h);if(!c||!in||(!out&&!rgba)||ni<n||(out&&no<n)||workers<1||workers>4||(rgba&&nb<(n/3)*4)||!std::isfinite(ev)||ev < -32||ev>32)throw std::runtime_error("Invalid FFCS float buffers or exposure");if(overlaps(in,n*sizeof(float),out,n*sizeof(float)) ||
 overlaps(in,n*sizeof(float),rgba,(n/3)*4) ||
 overlaps(out,n*sizeof(float),rgba,(n/3)*4)) {
 throw std::runtime_error("FFCS optimized buffers must not overlap");
 }
 double gain=std::exp2(double(ev));
 for(size_t i=0;i<n;++i) {
  if(!std::isfinite(in[i])) throw std::runtime_error("Nonfinite FFCS input");
 }
 auto tile=[&](size_t first,size_t last) {
 std::array<std::vector<RGB>,3> rows;
 for(auto &row:rows) row.resize(w);
 auto fill=[&](size_t y) {
  auto &row=rows[y%3];
  for(size_t x=0;x<w;++x) row[x]=mobilePixel(*c,in+(y*w+x)*3,x,y,w,gain,seed);
 };
 if(first>0) fill(first-1);
 fill(first); if(first+1<h) fill(first+1);
 double strength=std::max(0.,std::min(3.,c->look.sharp))*.35;
 for(size_t y=first;y<last;++y) {
  if(y+1<h && y>first) fill(y+1);
  for(size_t x=0;x<w;++x) {
   RGB v=rows[y%3][x];
   if(c->look.sharp>0) {
    RGB sum{};size_t neighbors=0;
    for(size_t yy=(y?y-1:0);yy<std::min(h,y+2);++yy) {
     for(size_t xx=(x?x-1:0);xx<std::min(w,x+2);++xx) {
      ++neighbors;
      for(int ch=0;ch<3;++ch) sum[ch]+=rows[yy%3][xx][ch];
     }
    }
    for(int ch=0;ch<3;++ch) v[ch]=clip(v[ch]+strength*(v[ch]-sum[ch]/neighbors));
   }
   size_t pixel=y*w+x;
   for(int ch=0;ch<3;++ch) {
    if(out) out[pixel*3+ch]=float(decode(v[ch]));
    if(rgba) rgba[pixel*4+ch]=quantize(v[ch]);
   }
   if(rgba) rgba[pixel*4+3]=255;
  }
 }
 };
 unsigned actual=unsigned(std::min(size_t(workers),h));
 if(actual==1) tile(0,h);
 else {
  std::array<std::thread,4> threads;
  std::array<std::exception_ptr,4> failures{};
  unsigned launched=0;
  try {
   for(unsigned t=0;t<actual;++t) {
    threads[t]=std::thread([&,t] {
     try { tile(h*t/actual,h*(t+1)/actual); }
     catch(...) { failures[t]=std::current_exception(); }
    });
    ++launched;
   }
  } catch(...) {
   for(unsigned t=0;t<launched;++t) threads[t].join();
   throw;
  }
  for(unsigned t=0;t<launched;++t) threads[t].join();
  for(unsigned t=0;t<actual;++t) if(failures[t]) std::rethrow_exception(failures[t]);
 }
 errorText(err,en,"");return 1;}catch(const std::exception &e){errorText(err,en,e.what());return 0;}catch(...){errorText(err,en,"Unknown FFCS rendering failure");return 0;}}
}
