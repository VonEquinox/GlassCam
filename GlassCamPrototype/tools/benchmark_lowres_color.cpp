// Bounded exact-Float low-resolution diagnostic. Production kernels are unchanged.
#include "../core/hncs_c.h"
#include "../core/ffcs_c.h"
#include <algorithm>
#include <chrono>
#include <ctime>
#include <cstring>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using Clock=std::chrono::steady_clock;
double cpu_seconds(){timespec t{};if(clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t))throw std::runtime_error("clock");return t.tv_sec+t.tv_nsec*1e-9;}
uint64_t hash(const std::vector<float>& a){uint64_t h=14695981039346656037ull;const auto*p=reinterpret_cast<const uint8_t*>(a.data());for(size_t i=0;i<a.size()*sizeof(float);++i){h^=p[i];h*=1099511628211ull;}return h;}
int main(int argc,char**argv){if(argc<2||argc>3)return 1;std::cout<<std::setprecision(12);char err[1024];auto*hn=hncs_create(0,5500);auto*pr=ffcs_create(argv[1],0,err,sizeof(err));auto*ac=ffcs_create(argv[1],8,err,sizeof(err));if(!hn||!pr||!ac)throw std::runtime_error(err);
 const char* names[]={"HNCS_exact_float","FFCS_PROVIA_full","FFCS_ACROS_full"};
 const std::vector<std::pair<size_t,size_t>> sizes=argc==3?std::vector<std::pair<size_t,size_t>>{{128,72}}:std::vector<std::pair<size_t,size_t>>{{128,72},{256,144},{512,288},{1280,720},{1920,1080}};
 for(auto wh:sizes){auto w=wh.first,h=wh.second,n=w*h;std::vector<float>in(n*3),hnout(n*4),ffout(n*3);uint32_t rng=928;for(auto&v:in){rng=rng*1664525u+1013904223u;v=float(rng>>8)/16777216.f;}
 auto run=[&](int kind,unsigned workers){if(kind==0){if(hncs_process_linear_rgba_parallel(hn,in.data(),hnout.data(),n,workers))throw std::runtime_error("HNCS");}else if(!ffcs_process_linear_rgb_optimized(kind==1?pr:ac,in.data(),in.size(),w,h,0,0,ffout.data(),ffout.size(),nullptr,0,workers,err,sizeof(err)))throw std::runtime_error(err);};
 uint64_t expected[3];if(hncs_process_linear_rgba(hn,in.data(),hnout.data(),n))throw std::runtime_error("HNCS oracle");expected[0]=hash(hnout);
 for(int kind=1;kind<=2;++kind){if(!ffcs_process_linear_rgb(kind==1?pr:ac,in.data(),in.size(),w,h,0,0,ffout.data(),ffout.size(),nullptr,0,err,sizeof(err)))throw std::runtime_error(err);expected[kind]=hash(ffout);}
 for(int kind=0;kind<3;++kind)for(unsigned workers:{1,2,4}){run(kind,workers);if(hash(kind?ffout:hnout)!=expected[kind])throw std::runtime_error("Warmup mismatch");}
 // Rotate configurations each round; every configuration has five samples.
 for(int round=0;round<5;++round)for(int step=0;step<9;++step){int j=(step+round*2)%9,kind=j/3;unsigned workers=1u<<(j%3);auto a=Clock::now();double c=cpu_seconds();run(kind,workers);double cpu=cpu_seconds()-c;double wall=std::chrono::duration<double>(Clock::now()-a).count();auto actual=hash(kind?ffout:hnout);if(actual!=expected[kind])throw std::runtime_error("Measured output mismatch");std::cout<<"{\"pipeline\":\""<<names[kind]<<"\",\"width\":"<<w<<",\"height\":"<<h<<",\"requested_workers\":"<<workers<<",\"effective_workers\":"<<((kind==0&&n<65536)?1:workers)<<",\"sample\":"<<round<<",\"wall_seconds\":"<<wall<<",\"cpu_seconds\":"<<cpu<<",\"fnv1a64\":\""<<actual<<"\",\"oracle_equal\":true}"<<std::endl;}
 }
 hncs_destroy(hn);ffcs_destroy(pr);ffcs_destroy(ac);
}
