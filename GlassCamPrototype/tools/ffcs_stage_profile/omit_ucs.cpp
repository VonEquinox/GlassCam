// Diagnostic approximation only: removing the neutral UCS round-trip is NOT exact.
#include "../../core/ffcs.cpp"
#include <chrono>
#include <ctime>
#include <iostream>
#include <iomanip>
#include "../../validation/ffcs_stage_profile/render_omit_ucs.inc"
int main(int argc,char **argv){
 if(argc!=2)return 2;std::cout<<std::setprecision(12);
 for(size_t look:{size_t(0),size_t(8)}){
  size_t w=512,h=288,n=w*h*3;std::vector<double> input(n),full,omitted;char err[512];
  for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++)for(size_t c=0;c<3;c++)input[(y*w+x)*3+c]=clip(.8*(c==0?double(x)/(w-1):c==1?double(y)/(h-1):double(x+y)/(w+h-2))+.2*(noise(x,y,41+c)+1)/2);
  auto *ctx=ffcs_create(argv[1],look,err,sizeof(err));if(!ctx)return 3;
  for(int run=-1;run<3;run++){
   full=input;omitted=input;
   auto a=std::chrono::steady_clock::now();render(*ctx,full,w,h,37,true,nullptr,nullptr);auto b=std::chrono::steady_clock::now();renderOmitUCS(*ctx,omitted,w,h,37,true,nullptr,nullptr);auto c=std::chrono::steady_clock::now();
   double maxE=0,maxL=0,sum=0;size_t byteMismatch=0;int maxByte=0;
   for(size_t i=0;i<n;i++){double e=std::abs(full[i]-omitted[i]);maxE=std::max(maxE,e);sum+=e*e;maxL=std::max(maxL,std::abs(decode(full[i])-decode(omitted[i])));int d=std::abs(int(quantize(full[i]))-int(quantize(omitted[i])));maxByte=std::max(maxByte,d);byteMismatch+=d!=0;}
   if(run>=0)std::cout<<"{\"look\":\""<<ctx->look.name<<"\",\"width\":"<<w<<",\"height\":"<<h<<",\"run\":"<<run<<",\"full_render_wall_ms\":"<<std::chrono::duration<double,std::milli>(b-a).count()<<",\"omit_ucs_wall_ms\":"<<std::chrono::duration<double,std::milli>(c-b).count()<<",\"encoded_max_abs\":"<<maxE<<",\"encoded_rmse\":"<<std::sqrt(sum/n)<<",\"linear_max_abs\":"<<maxL<<",\"rgb8_changed_channels\":"<<byteMismatch<<",\"rgb8_max_code_difference\":"<<maxByte<<"}\n"<<std::flush;
  }
  ffcs_destroy(ctx);
 }
}
