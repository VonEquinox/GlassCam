// Offline validation only. Including FFCS implementation exposes a private copy
// of context settings without adding or changing the production ABI or sources.
#include "../core/ffcs.cpp"
#include "../core/hncs_c.h"
extern "C" {
void *lut_proxy_create(const char *assets, int look) {
 char err[1024]; auto *c=ffcs_create(assets,look,err,sizeof(err));
 if(c){c->look.grain=0;c->look.sharp=0;} return c;
}
void lut_proxy_destroy(void *p){ffcs_destroy(static_cast<FFCSContext*>(p));}
int lut_proxy_render(void *p,const float *in,float *out,size_t n) {
 if(!p)return 0; const auto &c=*static_cast<FFCSContext*>(p);
 for(size_t i=0;i<n;++i){auto v=mobilePixel(c,in+3*i,0,0,1,1,0);for(int j=0;j<3;++j)out[3*i+j]=float(decode(v[j]));}return 1;
}
// Match normalized 3D-texture trilinear node interpolation; packed RGB CPU
// storage differs from a Metal RGBA texture. Half values arrive promoted to f32.
void lut_proxy_lookup(const float *lut,int size,const float *in,float *out,size_t n){
 for(size_t i=0;i<n;++i){int lo[3],hi[3];float f[3];for(int j=0;j<3;++j){float x=std::max(0.f,std::min(1.f,in[3*i+j]))*(size-1);lo[j]=int(x);hi[j]=std::min(lo[j]+1,size-1);f[j]=x-lo[j];}
 auto at=[&](int r,int g,int b,int c){return lut[((r*size+g)*size+b)*3+c];};
 for(int c=0;c<3;++c){float a=at(lo[0],lo[1],lo[2],c)*(1-f[2])+at(lo[0],lo[1],hi[2],c)*f[2];float b=at(lo[0],hi[1],lo[2],c)*(1-f[2])+at(lo[0],hi[1],hi[2],c)*f[2];float d=at(hi[0],lo[1],lo[2],c)*(1-f[2])+at(hi[0],lo[1],hi[2],c)*f[2];float e=at(hi[0],hi[1],lo[2],c)*(1-f[2])+at(hi[0],hi[1],hi[2],c)*f[2];out[3*i+c]=(a*(1-f[1])+b*f[1])*(1-f[0])+(d*(1-f[1])+e*f[1])*f[0];}
 }
}
}
extern "C" void lut_proxy_tetra(const float *lut,int size,const float *in,float *out,size_t n){
 for(size_t i=0;i<n;++i){int lo[3],hi[3],order[]={0,1,2};float f[3];for(int j=0;j<3;++j){float x=std::max(0.f,std::min(1.f,in[3*i+j]))*(size-1);lo[j]=int(x);hi[j]=std::min(lo[j]+1,size-1);f[j]=x-lo[j];}
 std::sort(order,order+3,[&](int a,int b){return f[a]>f[b];});
 int q[4][3];for(int k=0;k<4;++k)for(int j=0;j<3;++j)q[k][j]=lo[j];for(int k=1;k<4;++k)for(int j=0;j<k;++j)q[k][order[j]]=hi[order[j]];
 float w[]={1-f[order[0]],f[order[0]]-f[order[1]],f[order[1]]-f[order[2]],f[order[2]]};
 for(int c=0;c<3;++c){float v=0;for(int k=0;k<4;++k)v+=w[k]*lut[((q[k][0]*size+q[k][1])*size+q[k][2])*3+c];out[3*i+c]=v;}
 }
}
