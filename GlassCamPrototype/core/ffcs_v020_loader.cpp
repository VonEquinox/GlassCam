// Adversarial FFCS 0.2.0 loader harness: synthetic files, no bundled resources needed.
#include "ffcs_c.h"
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>
using Bytes=std::vector<unsigned char>;
static void require(bool ok,const char *m){if(!ok)throw std::runtime_error(m);}
static void u16(Bytes &b,size_t p,uint16_t n){b[p]=n&255;b[p+1]=n>>8;}
static void u32(Bytes &b,size_t p,uint32_t n){for(int i=0;i<4;++i)b[p+i]=(n>>(i*8))&255;}
static void f32(Bytes &b,size_t p,float x){uint32_t n;std::memcpy(&n,&x,4);u32(b,p,n);}
static Bytes pack(bool v2,Bytes raw=Bytes(48,0)){
 Bytes b(v2?60:56,0);std::memcpy(b.data(),v2?"FFCSLUT2":"FFCSLUT1",8);u16(b,8,2);u16(b,10,3);f32(b,12,65535.f);for(size_t i:{0u,4u,8u})f32(b,16+i*4,1.f);if(v2)b[52]=1;
 uLongf n=compressBound(raw.size());Bytes zip(n);require(compress2(zip.data(),&n,raw.data(),raw.size(),9)==Z_OK,"compress");zip.resize(n);u32(b,v2?56:52,uint32_t(n));b.insert(b.end(),zip.begin(),zip.end());return b;
}
int main(int argc,char **argv){try{
 require(argc==2,"Pass an empty temporary directory");std::filesystem::path root=argv[1];require(!std::filesystem::exists(root),"Temporary directory must not already exist");std::filesystem::create_directories(root/"xh2s");size_t tests=0;
 auto check=[&](Bytes bytes,bool success){auto path=root/"xh2s"/"provia.lutz";{std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());}char error[512]{};auto *ctx=ffcs_create_family_config(root.c_str(),"XH2S",0,1,1,0,1,error,sizeof(error));require(bool(ctx)==success,success?error:"Invalid LUT accepted");if(ctx)ffcs_destroy(ctx);else require(error[0],"Missing failure explanation");++tests;};
 for(bool v2:{false,true}){
  auto good=pack(v2);check(good,true);size_t header=v2?60:56,lenAt=v2?56:52;
  for(size_t len=0;len<header;++len)check(Bytes(good.begin(),good.begin()+len),false);
  auto b=good;b[0]='X';check(b,false);
  for(size_t sz:{0u,1u,257u}){b=good;u16(b,8,uint16_t(sz));check(b,false);}
  b=good;u16(b,10,4);check(b,false);
  for(float scale:{0.f,-1.f,std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity()}){b=good;f32(b,12,scale);check(b,false);}
  b=good;f32(b,16,std::numeric_limits<float>::quiet_NaN());check(b,false);
  b=good;f32(b,48,std::numeric_limits<float>::infinity());check(b,false);
  if(v2){for(unsigned flag:{2u,3u,128u,255u}){b=good;b[52]=flag;check(b,false);}}
  check(pack(v2,Bytes(47)),false);check(pack(v2,Bytes(49)),false);check(pack(v2,Bytes(1048576)),false);
  b=good;b.pop_back();check(b,false);u32(b,lenAt,uint32_t(b.size()-header));check(b,false);
  b=good;b.push_back(0);check(b,false);u32(b,lenAt,uint32_t(b.size()-header));check(b,false);
  b=good;b.insert(b.end(),good.begin()+header,good.end());u32(b,lenAt,uint32_t(b.size()-header));check(b,false);
  b=good;b[header]^=255;check(b,false);
 }
 auto good=pack(true);check(good,true);
 for(const char *camera:{"../xh2s","xh2s/..","/xh2s","XH2S/","../../tmp","", "GFX100II/../xh2s"})require(!ffcs_resolved_asset_family(root.c_str(),camera,0),"Family traversal accepted");
 require(!ffcs_resolved_asset_family(root.c_str(),nullptr,0),"NULL camera accepted");require(!ffcs_resolved_asset_family(nullptr,"xh2s",0),"NULL root accepted");require(!ffcs_resolved_asset_family(root.c_str(),"xh2s",20),"Out-of-range index accepted");
 std::filesystem::remove_all(root);std::cout<<"PASS "<<tests<<" loader cases + family traversal rejection\n";return 0;
 }catch(const std::exception &e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}}
