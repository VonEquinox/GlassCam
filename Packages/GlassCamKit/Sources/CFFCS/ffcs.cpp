// Portable adaptation of supplied FFCS implementation/{pipeline,color,effects,lutdata,models}.py.
// FFCS 0.2.0 native LUT path and explicit analytic modes. Preserve clipping,
// BGR axes, header matrix, all look parameters, grain and float sharpening.
#include "ffcs_c.h"
#include "ffcs_color_data.h"
#include "ffcs_native_mapping.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <exception>
#include <thread>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif
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
 {"MONOCHROME+Ye","mono_ye_filter.lutz",1.08,0,.052,.18,.01,.022,1.1,.10,.20,false},
 {"REALA ACE","reala_ace.lutz",1.02,1.07,-.005,.10,.004,.015,1,.09,.18,false}
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
template<class Tile> void parallelRows(size_t first,size_t rows,unsigned workers,Tile& tile) {
 if(workers==1){tile(first,first+rows);return;}
 std::array<std::exception_ptr,4> failures{};
#if defined(__APPLE__)
 struct Task {Tile* tile;size_t first,rows;unsigned workers;std::exception_ptr* failures;};
 Task task{&tile,first,rows,workers,failures.data()};
 dispatch_apply_f(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&task,
  [](void* opaque,size_t index) {
   auto& job=*static_cast<Task*>(opaque);
   try {(*job.tile)(job.first+job.rows*index/job.workers,job.first+job.rows*(index+1)/job.workers);}
   catch(...){job.failures[index]=std::current_exception();}
  });
#else
 std::array<std::thread,4> threads;
 unsigned launched=0;
 try {
  for(unsigned t=0;t<workers;++t) {
   threads[t]=std::thread([&,t] {
    try {tile(first+rows*t/workers,first+rows*(t+1)/workers);}
    catch(...){failures[t]=std::current_exception();}
   });
   ++launched;
  }
 } catch(...) {
  for(unsigned t=0;t<launched;++t)threads[t].join();
  throw;
 }
 for(unsigned t=0;t<launched;++t)threads[t].join();
#endif
 for(unsigned t=0;t<workers;++t)if(failures[t])std::rethrow_exception(failures[t]);
}
}
struct FFCSContext {Look look;bool grainEnabled,sharpenEnabled;double radius=1;std::vector<double> kernel;size_t reach=0;std::string family;size_t size;double scale;double matrix[9];bool rgbChannels;std::vector<uint16_t> lut;std::vector<double> normalized_codes;std::shared_ptr<const FFCSNativeMapping> nativeMapping;};
namespace {
RGB mapLUT(const FFCSContext &c,RGB v) {
 if(c.nativeMapping) {
  const auto &mapping=*c.nativeMapping;
  std::array<uint16_t,3> input{};
  for(unsigned ch=0;ch<3;++ch)
   input[ch]=uint16_t(std::floor(std::pow(clip(v[2-ch]),mapping.gamma)*mapping.maximum+.5));
  const auto output=mapping.map(c.lut.data(),uint32_t(c.size),input);
  return {c.normalized_codes[output[2]],c.normalized_codes[output[1]],c.normalized_codes[output[0]]};
 }
 double p[]={clip(v[2])*(c.size-1),clip(v[1])*(c.size-1),clip(v[0])*(c.size-1)};size_t lo[3],hi[3];double f[3];
 for(int i=0;i<3;++i){lo[i]=size_t(std::floor(p[i]));hi[i]=std::min(lo[i]+1,c.size-1);f[i]=p[i]-lo[i];}
 auto at=[&](size_t x,size_t y,size_t z,int ch){return c.normalized_codes[c.lut[((z*c.size+y)*c.size+x)*3+ch]];};RGB o{};
 for(int ch=0;ch<3;++ch){double a=at(lo[0],lo[1],lo[2],ch)*(1-f[0])+at(hi[0],lo[1],lo[2],ch)*f[0];double b=at(lo[0],hi[1],lo[2],ch)*(1-f[0])+at(hi[0],hi[1],lo[2],ch)*f[0];double c0=a*(1-f[1])+b*f[1];a=at(lo[0],lo[1],hi[2],ch)*(1-f[0])+at(hi[0],lo[1],hi[2],ch)*f[0];b=at(lo[0],hi[1],hi[2],ch)*(1-f[0])+at(hi[0],hi[1],hi[2],ch)*f[0];double c1=a*(1-f[1])+b*f[1];o[ch]=clip(c0*(1-f[2])+c1*f[2]);}
 if(!c.rgbChannels) { std::swap(o[0],o[2]); }
 return o;
}
// Reference native LUTs already contain MONO/filter/sepia transforms. The
// 0.2.0 pre-desaturation weighted analytic fallback is intentionally not exposed.
RGB perceptual(const FFCSContext &ctx,RGB v) {
 const auto &s=ctx.look;
 return s.saturation==1 && s.hue==0?v:ucs(lab(v,s));
}
RGB tone(RGB v,const Look &s) {
 if(s.contrast==1 && s.toe==0 && s.shoulder==0) return v;
 for(auto &q:v) {double t=.5+(clip(q)-.5)*std::max(.05,s.contrast);
  if(s.toe)t+=s.toe*(1-t)*(.18-.18*t);
  if(s.shoulder)t-=s.shoulder*t*t*.22;
  q=clip(t);}
 return v;
}
// Preserve Python's y-major, x-major Gaussian summation order, including
// truncation and renormalization at the actual image edges.
template<class Pixel> RGB sharpenPixel(const FFCSContext &c,size_t x,size_t y,size_t w,size_t h,Pixel pixel) {
 RGB v=pixel(x,y);if(!c.reach)return v;
 RGB sum{};double total=0;
 for(size_t yy=y>c.reach?y-c.reach:0;yy<std::min(h,y+c.reach+1);++yy)
  for(size_t xx=x>c.reach?x-c.reach:0;xx<std::min(w,x+c.reach+1);++xx) {
   const size_t dx=xx>x?xx-x:x-xx,dy=yy>y?yy-y:y-yy;
   double weight=c.kernel[dy*(c.reach+1)+dx];
   total+=weight;RGB q=pixel(xx,yy);for(int ch=0;ch<3;++ch)sum[ch]+=q[ch]*weight;
  }
 double strength=std::max(0.,std::min(3.,c.look.sharp))*.35;
 for(int ch=0;ch<3;++ch)v[ch]=clip(v[ch]+strength*(v[ch]-sum[ch]/total));
 return v;
}
RGB colorOnlyPixel(const FFCSContext &ctx,const float *in) {
 RGB v={double(in[0]),double(in[1]),double(in[2])};
 v=mul(v,ctx.matrix);
 for(auto &q:v) q=encode(clip(q));
 v=perceptual(ctx,mapLUT(ctx,v));
 v=tone(v,ctx.look);
 return v;
}
void render(const FFCSContext &ctx,std::vector<double> &p,size_t w,size_t h,uint32_t seed,bool linear,FFCSStageCallback cb,void *user){
 auto put=[&](const char *n){if(cb)cb(n,p.data(),w,h,user);};
 auto transform=[&](auto fn){for(size_t i=0;i<p.size();i+=3){RGB v={p[i],p[i+1],p[i+2]};v=fn(v);for(int j=0;j<3;++j)p[i+j]=v[j];}};
 put("input_normalized");if(!linear)for(auto &v:p)v=decode(v);put("gamma_pre");
 transform([&](RGB v){v=mul(v,ctx.matrix);for(auto &x:v)x=clip(x);return v;});put("matrix_3x3");
 transform([&](RGB v){for(auto &x:v)x=encode(x);return mapLUT(ctx,v);});put("lut_3d");
 transform([&](RGB v){return perceptual(ctx,v);});put("lab_ucs");
 const auto &s=ctx.look;transform([&](RGB v){return tone(v,s);});put("tone_curve");
 if(ctx.grainEnabled && s.grain>0){for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x){size_t i=(y*w+x)*3;double n=.72*noise(uint32_t(x),uint32_t(y),seed)+.28*smooth(size_t(x/s.size),size_t(y/s.size),std::max(size_t(1),size_t(w/s.size)),seed+17u);double lum=.2126*p[i]+.7152*p[i+1]+.0722*p[i+2];double delta=n*(s.grain*.035)*(.35+.9*std::sqrt(std::max(0.,lum*(1-.45*lum))));if(s.acros||s.saturation==0){double g=clip(clip(lum)+delta);p[i]=p[i+1]=p[i+2]=g;}else{double c=n*(s.grain*.035)*s.chroma*.45;p[i]=clip(p[i]+delta+c);p[i+1]=clip(p[i+1]+delta);p[i+2]=clip(p[i+2]+delta-c);}}}put("film_grain");
 if(ctx.reach){std::vector<double> out(p.size());
 auto pixel=[&](size_t x,size_t y){size_t i=(y*w+x)*3;return RGB{p[i],p[i+1],p[i+2]};};
 for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x){RGB v=sharpenPixel(ctx,x,y,w,h,pixel);for(int ch=0;ch<3;++ch)out[(y*w+x)*3+ch]=v[ch];}
 p.swap(out);}put("sharpen");put("output_icc");
}
// Pointwise stages use full-image coordinates for reproducible grain.
RGB mobilePixel(const FFCSContext &ctx, const float *in, size_t x, size_t y,
                size_t w, double gain, uint32_t seed) {
 RGB v={clip(double(in[0])*gain),clip(double(in[1])*gain),clip(double(in[2])*gain)};
 v=mul(v,ctx.matrix);
 for(auto &q:v) { q=encode(clip(q)); }
 v=perceptual(ctx,mapLUT(ctx,v));
 const auto &s=ctx.look;v=tone(v,s);
 if(ctx.grainEnabled && s.grain>0) {
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
int ffcs_get_color_data(const FFCSContext *c,ffcs_color_data *out) {
 if(!c||!out)return -1;
 *out={};std::copy_n(c->matrix,9,out->matrix);
 const auto &s=c->look;out->contrast=s.contrast;out->saturation=s.saturation;out->hue=s.hue;
 out->shoulder=s.shoulder;out->toe=s.toe;out->grain=s.grain;out->grain_size=s.size;
 out->chroma=s.chroma;out->sharp=s.sharp;out->size=uint32_t(c->size);out->rgb_channels=c->rgbChannels;
 out->acros=s.acros;out->grain_enabled=c->grainEnabled;out->reach=uint32_t(c->reach);
 out->lut=c->lut.data();out->normalized_codes=c->normalized_codes.data();out->kernel=c->kernel.data();
 if(c->nativeMapping) {
  const auto &mapping=*c->nativeMapping;
  out->native_mapping=1;out->mapping_gamma=mapping.gamma;out->working_maximum=mapping.maximum;
  out->fixed_mapping=mapping.fixed;out->gamma_in=mapping.gammaIn.data();out->gamma_out=mapping.gammaOut.data();
  out->gaussian=mapping.gaussian.data();out->distances=mapping.distances.data();
 }
 return 0;
}
size_t ffcs_simulation_count(void){return sizeof(looks)/sizeof(looks[0]);}
const char *ffcs_simulation_name(size_t i){return i<ffcs_simulation_count()?looks[i].name:nullptr;}
const char *ffcs_simulation_asset(size_t i){return i<ffcs_simulation_count()?looks[i].asset:nullptr;}
FFCSContext *ffcs_create(const char *dir,size_t index,char *err,size_t en){
 return ffcs_create_options(dir,index,1,1,err,en);
}
FFCSContext *ffcs_create_options(const char *dir,size_t index,int grain,int sharpen,char *err,size_t en){
 return ffcs_create_config(dir,index,grain,sharpen,0,1.0,err,en);
}
FFCSContext *ffcs_create_config(const char *dir,size_t index,int grain,int sharpen,int overlay,double radius,char *err,size_t en){
 try {
 if((grain!=0&&grain!=1)||(sharpen!=0&&sharpen!=1)||(overlay!=0&&overlay!=1))throw std::runtime_error("FFCS flags must be 0 or 1");
 if(!std::isfinite(radius)||radius<=0||radius>64)throw std::runtime_error("FFCS sharpen radius must be finite in (0,64]");
 if(!dir||!*dir||index>=ffcs_simulation_count())throw std::runtime_error("Invalid FFCS asset directory or simulation index");
 std::string path=std::string(dir)+"/"+looks[index].asset;std::ifstream in(path,std::ios::binary|std::ios::ate);if(!in)throw std::runtime_error("Missing FFCS reference LUT: "+path);auto len=in.tellg();if(len<56||len>64*1024*1024)throw std::runtime_error("Invalid FFCS LUT file size");std::vector<unsigned char> b(static_cast<size_t>(len));in.seekg(0);if(!in.read(reinterpret_cast<char*>(b.data()),len))throw std::runtime_error("Cannot read FFCS LUT");
 bool v2=std::memcmp(b.data(),"FFCSLUT2",8)==0,v1=std::memcmp(b.data(),"FFCSLUT1",8)==0;if(!v1&&!v2)throw std::runtime_error("Unsupported FFCS LUT container");
 size_t start=v2?60:56;if(b.size()<start)throw std::runtime_error("Truncated FFCS LUT header");
 size_t size=u16(b.data()+8);double scale=f32(b.data()+12);if(size<2||size>256||u16(b.data()+10)!=3||!std::isfinite(scale)||scale<=0)throw std::runtime_error("Invalid FFCS LUT header");
 if(v2&&(b[52]&~1))throw std::runtime_error("Invalid FFCS LUT flags");
 uint32_t packed=u32(b.data()+(v2?56:52));if(packed!=b.size()-start)throw std::runtime_error("FFCS LUT compressed length mismatch");
 size_t expected=size*size*size*6;std::vector<unsigned char> raw(expected+1);
 z_stream z{};z.next_in=b.data()+start;z.avail_in=packed;z.next_out=raw.data();z.avail_out=static_cast<uInt>(raw.size());
 if(inflateInit(&z)!=Z_OK)throw std::runtime_error("Cannot initialize FFCS LUT decoder");
 int status=inflate(&z,Z_FINISH);bool valid=status==Z_STREAM_END&&z.total_out==expected&&z.total_in==packed;inflateEnd(&z);
 if(!valid)throw std::runtime_error("Corrupt, truncated or trailing FFCS LUT payload");
 FFCSContext ctx{};ctx.look=looks[index];ctx.grainEnabled=grain!=0;ctx.sharpenEnabled=sharpen!=0;ctx.radius=std::max(.1,radius);ctx.size=size;ctx.scale=scale;ctx.rgbChannels=v2&&(b[52]&1);
 if(!overlay){ctx.look.contrast=ctx.look.saturation=1;ctx.look.hue=ctx.look.shoulder=ctx.look.toe=ctx.look.grain=ctx.look.sharp=0;}
 ctx.reach=ctx.sharpenEnabled&&ctx.look.sharp>0?size_t(std::ceil(3*ctx.radius)):0;
 ctx.kernel.resize((ctx.reach+1)*(ctx.reach+1));
 for(size_t y=0;y<=ctx.reach;++y)for(size_t x=0;x<=ctx.reach;++x)ctx.kernel[y*(ctx.reach+1)+x]=std::exp(-double(x*x+y*y)/(2*ctx.radius*ctx.radius));
 for(int i=0;i<9;++i){ctx.matrix[i]=f32(b.data()+16+4*i);if(!std::isfinite(ctx.matrix[i]))throw std::runtime_error("Nonfinite FFCS matrix");}
 // Cache the same binary64 division for each possible UInt16 code. Keeping
 // the packed 3D nodes bounds additional memory to 512 KiB per live context.
 // Corner interpolation and all subsequent arithmetic retain their order.
 ctx.normalized_codes.resize(65536);for(size_t i=0;i<ctx.normalized_codes.size();++i)ctx.normalized_codes[i]=double(i)/ctx.scale;
 ctx.lut.resize(expected/2);for(size_t i=0;i<ctx.lut.size();++i)ctx.lut[i]=u16(raw.data()+i*2);errorText(err,en,"");return new FFCSContext(std::move(ctx));
 }catch(const std::exception &e){errorText(err,en,e.what());return nullptr;}catch(...){errorText(err,en,"Unknown FFCS initialization failure");return nullptr;}
}
size_t ffcs_required_halo(const FFCSContext *c){return c?c->reach:0;}
const char *ffcs_resolved_asset_family(const char *root,const char *camera,size_t index){
 try {
  if(!root||!*root||!camera||index>=ffcs_simulation_count())return nullptr;
  std::string requested=camera;for(auto &ch:requested)if(ch>='A'&&ch<='Z')ch=char(ch-'A'+'a');
  const char *family=nullptr;
  for(const char *candidate:{"xh2s","xa3","gfx100","gfx100s","gfx100ii"})if(requested==candidate)family=candidate;
  if(!family)return nullptr;
  if(std::ifstream(std::string(root)+"/"+family+"/"+looks[index].asset,std::ios::binary).good())return family;
  if((requested=="gfx100s"||requested=="gfx100ii")&&std::ifstream(std::string(root)+"/gfx100/"+looks[index].asset,std::ios::binary).good())return "gfx100";
  return nullptr;
 }catch(...){return nullptr;}
}
int ffcs_simulation_available(const char *root,const char *camera,size_t index){
 return ffcs_resolved_asset_family(root,camera,index)!=nullptr;
}
FFCSContext *ffcs_create_family_config(const char *root,const char *camera,size_t index,int grain,int sharpen,int overlay,double radius,char *err,size_t en){
 try {
  const char *family=ffcs_resolved_asset_family(root,camera,index);
  if(!family)throw std::runtime_error("Unsupported or missing FFCS camera/look native asset");
  std::string dir=std::string(root)+"/"+family;
  std::unique_ptr<FFCSContext> ctx(ffcs_create_config(dir.c_str(),index,grain,sharpen,overlay,radius,err,en));
  if(ctx)ctx->family=family;
  return ctx.release();
 }catch(const std::exception &e){errorText(err,en,e.what());return nullptr;}catch(...){errorText(err,en,"Unknown FFCS family initialization failure");return nullptr;}
}
FFCSContext *ffcs_create_native_family_config(const char *root,const char *camera,size_t index,
 int grain,int sharpen,int details,double radius,char *err,size_t en) {
 try {
  std::unique_ptr<FFCSContext> ctx(ffcs_create_family_config(root,camera,index,grain,sharpen,details,radius,err,en));
  if(!ctx)return nullptr;
  std::string asset=looks[index].asset;asset.replace(asset.size()-5,5,".ffcm");
  const std::string path=std::string(root)+"/"+ctx->family+"/"+asset;
  std::ifstream stream(path,std::ios::binary|std::ios::ate);
  if(!stream)throw std::runtime_error("Missing FFCS native mapping");
  const auto length=stream.tellg();
  if(length<36||length>32*1024*1024)throw std::runtime_error("Invalid FFCS mapping size");
  std::vector<unsigned char> packed(static_cast<size_t>(length));
  stream.seekg(0);stream.read(reinterpret_cast<char*>(packed.data()),length);
  if(!stream||std::memcmp(packed.data(),"FFCSMAP1",8))throw std::runtime_error("Invalid FFCS mapping header");
  const uint32_t nodes=u32(packed.data()+8),maximum=u32(packed.data()+12),fixed=u32(packed.data()+16);
  const uint64_t gammaBits=uint64_t(u32(packed.data()+20))|(uint64_t(u32(packed.data()+24))<<32);
  double gamma;std::memcpy(&gamma,&gammaBits,8);
  if(nodes<3||nodes>128||maximum!=20000||fixed>1||!std::isfinite(gamma)||gamma<=0||gamma>8)
   throw std::runtime_error("Invalid FFCS mapping parameters");
  const size_t expected=size_t(nodes)*nodes*nodes*6;
  if(u32(packed.data()+28)!=expected)throw std::runtime_error("Invalid FFCS mapping payload size");
  std::vector<unsigned char> raw(expected);
  uLongf decoded=raw.size();uLong consumed=packed.size()-36;
  if(uncompress2(raw.data(),&decoded,packed.data()+36,&consumed)!=Z_OK||
     decoded!=expected||consumed!=packed.size()-36)
   throw std::runtime_error("FFCS mapping decompression or checksum failed");
  for(size_t i=3;i<expected/2;++i) {
   const uint16_t value=uint16_t(u16(raw.data()+i*2)+u16(raw.data()+(i-3)*2));
   raw[i*2]=value&255;raw[i*2+1]=value>>8;
  }
  if(crc32(0,raw.data(),uInt(raw.size()))!=u32(packed.data()+32))
   throw std::runtime_error("FFCS mapping checksum failed");
  auto mapping=std::make_shared<FFCSNativeMapping>();
  mapping->maximum=maximum;mapping->fixed=fixed;mapping->gamma=gamma;mapping->prepare(nodes);
  ctx->size=nodes;ctx->scale=maximum;ctx->rgbChannels=false;
  ctx->lut.resize(expected/2);
  for(size_t i=0;i<ctx->lut.size();++i)ctx->lut[i]=u16(raw.data()+i*2);
  for(size_t i=0;i<ctx->normalized_codes.size();++i)
   ctx->normalized_codes[i]=std::pow(clip(double(i)/maximum),1./gamma);
  // The factory mapping already includes the style's colour and tonal shape.
  // Optional detail effects do not add the old analytic colour/tone overlay.
  ctx->look.contrast=ctx->look.saturation=1.;
  ctx->look.hue=ctx->look.shoulder=ctx->look.toe=0.;
  ctx->look.acros=looks[index].acros||looks[index].saturation==0.;
  ctx->nativeMapping=std::move(mapping);
  errorText(err,en,"");return ctx.release();
 }catch(const std::exception &e){errorText(err,en,e.what());return nullptr;}
 catch(...){errorText(err,en,"Unknown FFCS native mapping failure");return nullptr;}
}
int ffcs_process_native_codes(const FFCSContext *c,const uint16_t *input,uint16_t *output,
 size_t pixels,char *err,size_t en) {
 try {
  if(!c||!c->nativeMapping||!input||!output||!pixels||
     pixels>std::numeric_limits<size_t>::max()/6)
   throw std::runtime_error("Invalid FFCS native buffers");
  if(overlaps(input,pixels*6,output,pixels*6))
   throw std::runtime_error("FFCS native buffers must not overlap");
  for(size_t i=0;i<pixels*3;++i)if(input[i]>c->nativeMapping->maximum)
   throw std::runtime_error("FFCS native input exceeds working maximum");
  for(size_t i=0;i<pixels;++i) {
   const auto value=c->nativeMapping->map(c->lut.data(),uint32_t(c->size),
                                        {input[3*i],input[3*i+1],input[3*i+2]});
   std::copy(value.begin(),value.end(),output+i*3);
  }
  errorText(err,en,"");return 1;
 }catch(const std::exception &e){errorText(err,en,e.what());return 0;}
 catch(...){errorText(err,en,"Unknown FFCS native mapping failure");return 0;}
}
const char *ffcs_asset_family(const FFCSContext *c){return c?c->family.c_str():nullptr;}
void ffcs_destroy(FFCSContext *c){delete c;}
int ffcs_process_linear_rgb_color_only(const FFCSContext *c,const float *in,
 size_t ni,size_t pixels,float *out,size_t no,char *err,size_t en) {
 try {
  if(!c || !in || !out || !pixels ||
     pixels>std::numeric_limits<size_t>::max()/(4*sizeof(float)))
   throw std::runtime_error("Invalid FFCS color-only arguments");
  const size_t input_n=pixels*3,output_n=pixels*4;
  if(ni<input_n || no<output_n)
   throw std::runtime_error("FFCS color-only buffer is too small");
  if(overlaps(in,input_n*sizeof(float),out,output_n*sizeof(float)))
   throw std::runtime_error("FFCS color-only buffers must not overlap");
  for(size_t i=0;i<input_n;++i)
   if(!std::isfinite(in[i]) || in[i]<0.f || in[i]>1.f)
    throw std::runtime_error("FFCS color-only input must be finite linear-sRGB in [0,1]");
  for(size_t i=0;i<pixels;++i) {
   RGB v=colorOnlyPixel(*c,in+i*3);
   for(int ch=0;ch<3;++ch) out[i*4+ch]=float(decode(v[ch]));
   out[i*4+3]=1.f;
  }
  errorText(err,en,"");return 1;
 } catch(const std::exception &e) { errorText(err,en,e.what());return 0; }
 catch(...) { errorText(err,en,"Unknown FFCS color-only failure");return 0; }
}
int ffcs_process_encoded_double(const FFCSContext *c,const double *in,size_t ni,size_t w,size_t h,uint32_t seed,double *out,size_t no,FFCSStageCallback cb,void *user,char *err,size_t en){try{size_t n=count(w,h);if(!c||!in||!out||ni<n||no<n)throw std::runtime_error("Invalid FFCS double buffers");for(size_t i=0;i<n;++i)if(!std::isfinite(in[i]))throw std::runtime_error("Nonfinite FFCS input");std::vector<double> p(in,in+n);render(*c,p,w,h,seed,false,cb,user);std::copy(p.begin(),p.end(),out);errorText(err,en,"");return 1;}catch(const std::exception &e){errorText(err,en,e.what());return 0;}catch(...){errorText(err,en,"Unknown FFCS rendering failure");return 0;}}
int ffcs_process_linear_rgb(const FFCSContext *c,const float *in,size_t ni,size_t w,size_t h,float ev,uint32_t seed,float *out,size_t no,uint8_t *rgba,size_t nb,char *err,size_t en) {
 try {
  size_t n=count(w,h);
  if(!c||!in||!out||ni<n||no<n||(rgba&&nb<(n/3)*4)||!std::isfinite(ev)||ev < -32||ev>32)
   throw std::runtime_error("Invalid FFCS float buffers or exposure");
  if(overlaps(in,n*sizeof(float),out,n*sizeof(float)) ||
     overlaps(in,n*sizeof(float),rgba,(n/3)*4))
   throw std::runtime_error("FFCS input and output buffers must not overlap");
  if(overlaps(out,n*sizeof(float),rgba,(n/3)*4))
   throw std::runtime_error("FFCS float and preview outputs must not overlap");
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
 const size_t ringSize=std::min(h,2*c->reach+1);
 std::vector<std::vector<RGB>> rows(ringSize,std::vector<RGB>(w));
 auto fill=[&](size_t y) {auto &row=rows[y%ringSize];for(size_t x=0;x<w;++x)row[x]=mobilePixel(*c,in+(y*w+x)*3,x,y,w,gain,seed);};
 size_t loaded=first>c->reach?first-c->reach:0;
 auto pixel=[&](size_t x,size_t y){return rows[y%ringSize][x];};
 for(size_t y=first;y<last;++y) {
  const size_t end=std::min(h,y+c->reach+1);while(loaded<end)fill(loaded++);
  for(size_t x=0;x<w;++x) {RGB v=sharpenPixel(*c,x,y,w,h,pixel);size_t pixelIndex=y*w+x;
   for(int ch=0;ch<3;++ch){if(out)out[pixelIndex*3+ch]=float(decode(v[ch]));if(rgba)rgba[pixelIndex*4+ch]=quantize(v[ch]);}if(rgba)rgba[pixelIndex*4+3]=255;
  }
 }
 };
 unsigned actual=unsigned(std::min(size_t(workers),h));
 parallelRows(0,h,actual,tile);
 errorText(err,en,"");return 1;}catch(const std::exception &e){errorText(err,en,e.what());return 0;}catch(...){errorText(err,en,"Unknown FFCS rendering failure");return 0;}}
int ffcs_process_linear_rgb_strip(const FFCSContext *c, const float *in,
 size_t input_count, size_t w, size_t h, size_t input_y, size_t input_rows,
 size_t output_y, size_t output_rows, float ev, uint32_t seed,
 float *out, size_t output_count, unsigned workers, char *err, size_t en) {
 try {
  // Validate dimensions and row ranges before any subtraction or addition.
  count(w,h);
  if(!c || !in || !out || input_y>=h || output_y>=h ||
     !input_rows || input_rows>h-input_y || !output_rows || output_rows>h-output_y ||
     workers<1 || workers>4 || !std::isfinite(ev) || ev < -32 || ev > 32)
   throw std::runtime_error("Invalid FFCS strip arguments");
  const size_t first_needed=output_y>c->reach ? output_y-c->reach : 0;
  const size_t last_needed=std::min(h,output_y+output_rows+c->reach);
  if(input_y>first_needed || input_y+input_rows<last_needed)
   throw std::runtime_error("FFCS strip is missing the required sharpening halo");
  const size_t input_n=count(w,input_rows), output_n=count(w,output_rows);
  if(input_count<input_n || output_count<output_n)
   throw std::runtime_error("FFCS strip buffer is too small");
  if(overlaps(in,input_n*sizeof(float),out,output_n*sizeof(float)))
   throw std::runtime_error("FFCS strip buffers must not overlap");
 double gain=std::exp2(double(ev));
 for(size_t i=0;i<input_n;++i) {
  if(!std::isfinite(in[i])) throw std::runtime_error("Nonfinite FFCS input");
 }
 auto tile=[&](size_t first,size_t last) {
 const size_t ringSize=std::min(h,2*c->reach+1);
 std::vector<std::vector<RGB>> rows(ringSize,std::vector<RGB>(w));
 auto fill=[&](size_t y) {auto &row=rows[y%ringSize];for(size_t x=0;x<w;++x)row[x]=mobilePixel(*c,in+((y-input_y)*w+x)*3,x,y,w,gain,seed);};
 size_t loaded=first>c->reach?first-c->reach:0;
 auto pixel=[&](size_t x,size_t y){return rows[y%ringSize][x];};
 for(size_t y=first;y<last;++y) {
  const size_t end=std::min(h,y+c->reach+1);while(loaded<end)fill(loaded++);
  for(size_t x=0;x<w;++x) {RGB v=sharpenPixel(*c,x,y,w,h,pixel);size_t pixelIndex=(y-output_y)*w+x;
   for(int ch=0;ch<3;++ch)out[pixelIndex*3+ch]=float(decode(v[ch]));
  }
 }
 };
 unsigned actual=unsigned(std::min(size_t(workers),output_rows));
 parallelRows(output_y,output_rows,actual,tile);
 errorText(err,en,"");return 1;}catch(const std::exception &e){errorText(err,en,e.what());return 0;}catch(...){errorText(err,en,"Unknown FFCS rendering failure");return 0;}}
}
