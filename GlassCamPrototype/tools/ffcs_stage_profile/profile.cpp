// Diagnostic only. Include production helpers without changing/linking a modified library.
#include "../../core/ffcs.cpp"
#include <chrono>
#include <ctime>
#include <iostream>
#include <iomanip>
#include <map>
#include <functional>
#include "../../validation/ffcs_stage_profile/render_instrumented.inc"
using Clock=std::chrono::steady_clock;
struct Timer {
 Clock::time_point t=Clock::now();
 std::map<std::string,double> stages;
 void mark(const char *name) { auto now=Clock::now(); stages[name]+=std::chrono::duration<double,std::milli>(now-t).count(); t=Clock::now(); }
};
void callback(const char* name,const double*,size_t,size_t,void* ptr){static_cast<Timer*>(ptr)->mark(name);}
// Byte comparisons of every common stage, outside the timed runs.
struct Snapshots { std::map<std::string,std::vector<double>> values; bool check=false; };
void verifyStage(const char* raw,const double* p,size_t w,size_t h,void* ptr){
 auto &snap=*static_cast<Snapshots*>(ptr);std::string name=raw;
 if(name=="lut_input_encode"||name=="lab"||name=="sharpen_allocation")return;
 if(name=="lut_sample")name="lut_3d";if(name=="ucs")name="lab_ucs";
 if(!snap.check)snap.values[name]=std::vector<double>(p,p+w*h*3);
 else if(!snap.values.count(name)||std::memcmp(snap.values[name].data(),p,w*h*3*sizeof(double)))throw std::runtime_error("Stage parity failed: "+name);
}
int main(int argc,char **argv){
 if(argc!=2) return 2;
 std::cout<<std::setprecision(12);
 for(size_t look : {size_t(0),size_t(8)}) for(auto dim : {std::array<size_t,2>{256,144},{512,288},{1280,720}}){
  size_t w=dim[0],h=dim[1],n=w*h*3; char err[512];
  auto *ctx=ffcs_create(argv[1],look,err,sizeof(err));if(!ctx){std::cerr<<err;return 3;}
  std::vector<float> in(n),reference(n),out(n);std::vector<uint8_t> referenceRGBA(w*h*4),rgba(w*h*4);
  for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++)for(size_t c=0;c<3;c++)in[(y*w+x)*3+c]=float(clip(.8*(c==0?double(x)/(w-1):c==1?double(y)/(h-1):double(x+y)/(w+h-2))+.2*(noise(x,y,41+c)+1)/2));
  in[0]=0;in[1]=1;
  if(!ffcs_process_linear_rgb(ctx,in.data(),n,w,h,0,37,reference.data(),n,referenceRGBA.data(),referenceRGBA.size(),err,sizeof(err)))return 4;
  { Snapshots snap;std::vector<double> p(in.begin(),in.end());
    render(*ctx,p,w,h,37,true,verifyStage,&snap);
    p.assign(in.begin(),in.end());snap.check=true;
    profileRender(*ctx,p,w,h,37,true,verifyStage,&snap);
  }
  for(std::string mode : {"production_full","profile_split","profile_original","optimized_one","optimized_four","optimized_rgba_four"})for(int run=-1;run<3;run++){
   Timer timer;auto begin=Clock::now();auto cpu=std::clock();
   if(mode=="profile_split"||mode=="profile_original"){
    std::vector<double> p(n);timer.mark("input_allocation");
    double gain=std::exp2(0.);
    for(size_t i=0;i<n;i++){if(!std::isfinite(in[i]))return 5;p[i]=clip(double(in[i])*gain);}timer.mark("input_validation_gain");
    if(mode=="profile_split")profileRender(*ctx,p,w,h,37,true,callback,&timer);else render(*ctx,p,w,h,37,true,callback,&timer);
    for(size_t i=0;i<n;i++)out[i]=float(decode(p[i]));timer.mark("output_decode_float");
    for(size_t i=0;i<n/3;i++){for(int j=0;j<3;j++)rgba[i*4+j]=quantize(p[i*3+j]);rgba[i*4+3]=255;}timer.mark("output_rgba_quantize");
   }else{
    bool ok=mode=="production_full"?ffcs_process_linear_rgb(ctx,in.data(),n,w,h,0,37,out.data(),n,rgba.data(),rgba.size(),err,sizeof(err)):ffcs_process_linear_rgb_optimized(ctx,in.data(),n,w,h,0,37,mode=="optimized_rgba_four"?nullptr:out.data(),n,rgba.data(),rgba.size(),mode=="optimized_one"?1:4,err,sizeof(err));
    if(!ok){std::cerr<<err;return 6;}
   }
   auto end=Clock::now();double cpuMs=1000.*(std::clock()-cpu)/CLOCKS_PER_SEC,wall=std::chrono::duration<double,std::milli>(end-begin).count();
   double error=0;size_t mismatch=0;
   if(mode!="optimized_rgba_four")for(size_t i=0;i<n;i++)error=std::max(error,std::abs(double(out[i])-reference[i]));
   for(size_t i=0;i<rgba.size();i++)mismatch+=rgba[i]!=referenceRGBA[i];
   if(error!=0||mismatch){std::cerr<<"Parity failed "<<mode<<" "<<error<<" "<<mismatch;return 7;}
   if(run<0)continue;
   std::cout<<"{\"look\":\""<<ffcs_simulation_name(look)<<"\",\"width\":"<<w<<",\"height\":"<<h<<",\"mode\":\""<<mode<<"\",\"run\":"<<run<<",\"wall_ms\":"<<wall<<",\"cpu_ms\":"<<cpuMs<<",\"max_float_error\":"<<error<<",\"rgba_mismatches\":"<<mismatch<<",\"common_stages_double_byte_exact\":true"<<",\"stages_ms\":{";
   bool first=true;for(auto& entry:timer.stages){if(!first)std::cout<<",";first=false;std::cout<<"\""<<entry.first<<"\":"<<entry.second;}std::cout<<"}}\n"<<std::flush;
  }
  ffcs_destroy(ctx);
 }
}
