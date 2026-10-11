#include "ffcs_c.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>
#define CHECK(x) do { if(!(x)){std::cerr<<"Fail line "<<__LINE__<<": "<<error.data()<<"\n";return 1;} }while(false)
int main(int argc,char **argv){
 if(argc!=2)return 2;std::array<char,1024> error{};size_t calls=0;
 for(size_t look=0;look<19;++look){
  std::unique_ptr<FFCSContext,decltype(&ffcs_destroy)> ctx(ffcs_create(argv[1],look,error.data(),error.size()),ffcs_destroy);CHECK(ctx);
  for(auto dim:std::vector<std::pair<size_t,size_t>>{{1,1},{1,7},{9,1},{7,3},{131,19}}){
   size_t w=dim.first,h=dim.second,n=w*h*3;std::vector<float> in(n),full(n);
   for(size_t i=0;i<n;++i)in[i]=float((i*3919+look*13)%8191)/6000.f-.1f;
   CHECK(ffcs_process_linear_rgb_optimized(ctx.get(),in.data(),n,w,h,.7f,0xffffffffu,full.data(),n,nullptr,0,1,error.data(),error.size()));
   for(unsigned worker:{1u,4u})for(size_t start=0;start<h;){
    size_t rows=std::min(h-start,worker==1?size_t(1):size_t(5));size_t first=start?start-1:0,last=std::min(h,start+rows+1),ni=(last-first)*w*3,no=rows*w*3;
    std::vector<float> input(in.begin()+first*w*3,in.begin()+last*w*3),out(no);
    CHECK(ffcs_process_linear_rgb_strip(ctx.get(),input.data(),ni,w,h,first,last-first,start,rows,.7f,0xffffffffu,out.data(),no,worker,error.data(),error.size()));
    CHECK(std::memcmp(out.data(),full.data()+start*w*3,no*sizeof(float))==0);++calls;
    CHECK(!ffcs_process_linear_rgb_strip(ctx.get(),input.data(),ni,w,h,first,last-first,start,rows,.7f,0xffffffffu,out.data(),no,0,error.data(),error.size()));
    CHECK(!ffcs_process_linear_rgb_strip(ctx.get(),input.data(),ni,w,h,first,last-first,start,rows,.7f,0xffffffffu,out.data(),no-1,worker,error.data(),error.size()));
    CHECK(!ffcs_process_linear_rgb_strip(ctx.get(),input.data(),ni,w,h,first,last-first,start,rows,.7f,0xffffffffu,input.data(),no,worker,error.data(),error.size()));
    start+=rows;
   }
  }
 }
 std::cout<<"Strip sanitizer smoke passed: 19 looks, "<<calls<<" calls, 1/4 workers, bit-exact halos/borders, invalid counts/overlap.\n";
}
