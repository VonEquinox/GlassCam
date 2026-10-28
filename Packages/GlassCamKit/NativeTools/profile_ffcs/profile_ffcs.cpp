// Diagnostic stage callback profiling of retained reference-order FFCS.
#include "../../Sources/CFFCS/ffcs.cpp"
#include <chrono>
#include <ctime>
#include <iostream>
#include <iomanip>
using Clock=std::chrono::steady_clock;
struct Timer {Clock::time_point wall;std::clock_t cpu;bool emit;};
void stage(const char* name,const double*,size_t,size_t,void* state){auto*t=static_cast<Timer*>(state);auto w=Clock::now();auto c=std::clock();if(t->emit)std::cout<<"{\"stage\":\""<<name<<"\",\"wall_ms\":"<<std::chrono::duration<double,std::milli>(w-t->wall).count()<<",\"cpu_ms\":"<<1000.*(c-t->cpu)/CLOCKS_PER_SEC<<"}\n";t->wall=Clock::now();t->cpu=std::clock();}
int main(int argc,char**argv){if(argc!=2)return 1;std::cout<<std::setprecision(10);char err[1024];auto*c=ffcs_create(argv[1],0,err,sizeof(err));if(!c)throw std::runtime_error(err);size_t w=1024,h=1024,n=w*h*3;std::vector<float>x(n),out(n),expected(n);std::vector<uint8_t>bytes(w*h*4),ref(bytes.size());uint32_t rng=928;for(auto&v:x){rng=rng*1664525u+1013904223u;v=float(rng>>8)/16777216.f;}
 for(int sample=-1;sample<5;++sample){std::vector<double>p(x.begin(),x.end());Timer t{Clock::now(),std::clock(),sample>=0};render(*c,p,w,h,0,true,stage,&t);for(size_t i=0;i<n;++i)out[i]=float(decode(p[i]));stage("display_decode_float",nullptr,w,h,&t);}
 auto run=[&](int workers,bool preview){int ok=workers<0?ffcs_process_linear_rgb(c,x.data(),n,w,h,0,0,out.data(),n,preview?bytes.data():nullptr,preview?bytes.size():0,err,sizeof(err)):ffcs_process_linear_rgb_optimized(c,x.data(),n,w,h,0,0,out.data(),n,preview?bytes.data():nullptr,preview?bytes.size():0,workers,err,sizeof(err));if(!ok)throw std::runtime_error(err);};
 run(-1,true);expected=out;ref=bytes;
 for(int workers:{-1,1,4})for(bool preview:{false,true}){run(workers,preview);if(out!=expected||(preview&&bytes!=ref))throw std::runtime_error("FFCS parity failure");for(int sample=0;sample<5;++sample){auto a=Clock::now();auto b=std::clock();run(workers,preview);double cpu=1000.*(std::clock()-b)/CLOCKS_PER_SEC;double wall=std::chrono::duration<double,std::milli>(Clock::now()-a).count();std::cout<<"{\"api\":\""<<(workers<0?"baseline":"optimized")<<"\",\"workers\":"<<(workers<0?1:workers)<<",\"outputs\":\""<<(preview?"linear_and_preview":"linear")<<"\",\"wall_ms\":"<<wall<<",\"cpu_ms\":"<<cpu<<"}\n";}}
 std::cout<<"{\"verification\":\"pass\",\"float_and_preview_bit_exact\":true,\"pixels\":"<<w*h<<",\"look\":\"PROVIA\"}\n";ffcs_destroy(c);
}
