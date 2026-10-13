// Focused FFCS 0.2.0 native-path contract harness. No private implementation access.
// Build: c++ -std=c++17 -O2 -ffp-contract=off ffcs.cpp ffcs_v020_native.cpp -lz -pthread
#include "ffcs_c.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include <string>
using Context=std::unique_ptr<FFCSContext,decltype(&ffcs_destroy)>;
static void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
int main(int argc,char **argv){try{
 require(argc==2,"Pass the FFCS data root (contains xh2s/, etc.)");char error[1024]{};size_t cases=0;
 require(ffcs_simulation_count()==20,"20 stable simulation indices required");
 require(std::string(ffcs_simulation_name(19))=="REALA ACE","REALA must be appended");
 require(!ffcs_simulation_available(argv[1],"XH2S",19),"No XH2S REALA native asset");
 require(std::string(ffcs_resolved_asset_family(argv[1],"GFX100II",0))=="gfx100","GFX100II PROVIA fallback");
 require(std::string(ffcs_resolved_asset_family(argv[1],"GFX100II",19))=="gfx100ii","GFX100II REALA native");
 require(std::string(ffcs_resolved_asset_family(argv[1],"GFX100S",5))=="gfx100s","GFX100S Nostalgic native");
 for(auto dims: {std::pair<size_t,size_t>{1,1},{1,9},{9,1},{13,17},{4,5}})
 for(int overlay:{0,1})for(int grain:{0,1})for(int sharp:{0,1})for(double radius:{.05,.7,1.,2.3}){
  size_t w=dims.first,h=dims.second,n=w*h*3;std::vector<float> input(n),full(n),fast(n),strips(n);std::vector<uint8_t> preview(w*h*4),fastPreview(w*h*4);
  for(size_t i=0;i<n;++i)input[i]=float(((i*127+51)%1021)/1020.);
  Context c(ffcs_create_family_config(argv[1],"XH2S",cases%19,grain,sharp,overlay,radius,error,sizeof(error)),ffcs_destroy);require(bool(c),error);
  const size_t halo=ffcs_required_halo(c.get());require(halo==(overlay&&sharp?size_t(std::ceil(3*std::max(.1,radius))):0),"Dynamic halo mismatch");
  require(ffcs_process_linear_rgb(c.get(),input.data(),n,w,h,.5f,0xffffffffu,full.data(),n,preview.data(),preview.size(),error,sizeof(error)),error);
  for(unsigned workers:{1u,2u,4u}){
   require(ffcs_process_linear_rgb_optimized(c.get(),input.data(),n,w,h,.5f,0xffffffffu,fast.data(),n,fastPreview.data(),fastPreview.size(),workers,error,sizeof(error)),error);
   require(!std::memcmp(full.data(),fast.data(),n*sizeof(float)),"Full/threaded Float32 mismatch");
   require(preview==fastPreview,"Full/threaded RGBA8 mismatch");
   for(size_t y=0;y<h;y+=3){size_t rows=std::min(size_t(3),h-y),iy=y>halo?y-halo:0,ie=std::min(h,y+rows+halo);
    require(ffcs_process_linear_rgb_strip(c.get(),input.data()+iy*w*3,(ie-iy)*w*3,w,h,iy,ie-iy,y,rows,.5f,0xffffffffu,strips.data()+y*w*3,rows*w*3,workers,error,sizeof(error)),error);
   }
   require(!std::memcmp(full.data(),strips.data(),n*sizeof(float)),"Full/strip Float32 mismatch");
  }
  ++cases;
 }
 Context c(ffcs_create_family_config(argv[1],"XH2S",0,1,1,1,1,error,sizeof(error)),ffcs_destroy);require(bool(c),error);
 std::vector<float> input(9*11*3,.5f),out(9*3);
 require(!ffcs_process_linear_rgb_strip(c.get(),input.data()+4*9*3,3*9*3,9,11,4,3,5,1,0,0,out.data(),out.size(),1,error,sizeof(error)),"Insufficient dynamic halo accepted");
 require(!ffcs_create_family_config(argv[1],"XH2S",0,1,1,2,1,error,sizeof(error)),"Invalid overlay flag accepted");
 require(!ffcs_create_family_config(argv[1],"XH2S",0,1,1,1,0,error,sizeof(error)),"Zero radius accepted");
 require(!ffcs_create_family_config(argv[1],"XH2S",0,1,1,1,65,error,sizeof(error)),"Unsupported radius accepted");
 std::cout<<"PASS "<<cases<<" cases: bit-exact full/threaded/strip output, dynamic halo, family resolution, option validation\n";
 return 0;
 }catch(const std::exception &e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}}
