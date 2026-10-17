// Original SILKYPIX x86_64 mapping ABI. Not linked into the application.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

template<class F> F native(void* library,const char* name) {
    auto* result=dlsym(library,name);
    if(!result)throw std::runtime_error(name);
    return reinterpret_cast<F>(result);
}
struct Pixel {std::uint16_t b,g,r;};
static_assert(sizeof(Pixel)==6);
template<class T> T field(const unsigned char* object,std::size_t offset) {
    T value;std::memcpy(&value,object+offset,sizeof value);return value;
}
void save(const std::string& path,const void* data,std::size_t size) {
    std::ofstream file(path,std::ios::binary);file.write(static_cast<const char*>(data),size);
    if(!file)throw std::runtime_error("Cannot write probe output");
}
int main(int argc,char** argv) {
    if(argc!=5)return 2;
    try {
        void* library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
        if(!library)throw std::runtime_error(dlerror());
        auto ctor=native<void(*)(void*,std::uint16_t,int,double,std::uint16_t,const double*)>(library,
            "_ZN18IslZColor3DMappingC1EtidtRK11IslZMatrix3");
        auto storage_ctor=native<void(*)(void*,const void*,unsigned)>(library,"_ZN20IslZStorageMemBrowseC1EPKvj");
        auto read=native<int(*)(void*,void*)>(library,"_ZN18IslZColor3DMapping15ReadMappingDataEP11IslZStorage");
        using Transform=int(*)(const void*,const Pixel*,Pixel*,int);
        auto tri=native<Transform>(library,"_ZNK18IslZColor3DMapping18TransFormTrilinearEPK12_ISLZPIXEL48PS0_i");
        auto dispatch=native<int(*)(const void*,const Pixel*,Pixel*,int,unsigned char)>(library,
            "_ZNK18IslZColor3DMapping9TransFormEPK12_ISLZPIXEL48PS0_ih");
        auto set_sigma=native<void(*)(void*,double)>(library,"_ZN18IslZColor3DMapping20SetStandardDeviationEd");
        auto fixed=native<Transform>(library,"_ZNK18IslZColor3DMapping35TransFormByNormalDistribution2FixedEPK12_ISLZPIXEL48PS0_i");
        alignas(16) unsigned char mapping[4096]{},storage[4096]{};
        double identity[9]={1,0,0,0,1,0,0,0,1};
        ctor(mapping,20000,78,1.,0,identity);
        std::ifstream source(argv[2],std::ios::binary);
        std::vector<char> data((std::istreambuf_iterator<char>(source)),{});
        if(data.empty())throw std::runtime_error("Empty original mapping resource");
        storage_ctor(storage,data.data(),unsigned(data.size()));
        const int read_status=read(mapping,storage);
        if(read_status)throw std::runtime_error("Original mapping read failed");
        const double gamma=field<double>(mapping,0x4e8);
        const std::uint16_t limit=field<std::uint16_t>(mapping,0x4e0);
        const auto* lut_object=field<unsigned char*>(mapping,0x120);
        const unsigned nodes=unsigned(field<int>(lut_object,0xc8))+2;
        const auto* lut=field<Pixel*>(lut_object,0xa8);
        const auto* gamma_in=field<std::uint32_t*>(mapping,0x588);
        const auto* gamma_out=field<std::uint16_t*>(mapping,0x5b0);
        if(!lut||!gamma_in||!gamma_out||nodes<2||nodes>256||limit!=20000)
            throw std::runtime_error("Unexpected native mapping layout");
        std::ifstream input(argv[3],std::ios::binary);
        std::vector<Pixel> pixels;Pixel pixel;
        while(input.read(reinterpret_cast<char*>(&pixel),sizeof pixel)) {
            if(pixel.r>limit||pixel.g>limit||pixel.b>limit)throw std::runtime_error("Input outside original working range");
            pixels.push_back(pixel);
        }
        if(pixels.empty()||pixels.size()>1000000)throw std::runtime_error("Invalid probe input size");
        const std::string prefix=argv[4];
        save(prefix+".lut",lut,std::size_t(nodes)*nodes*nodes*sizeof(Pixel));
        save(prefix+".gamma-in",gamma_in,(std::size_t(limit)+1)*sizeof(std::uint32_t));
        save(prefix+".gamma-out",gamma_out,20001*sizeof(std::uint16_t));
        save(prefix+".matrix",mapping+0x4f8,9*sizeof(double));
        std::vector<Pixel> result(pixels.size());
        if(tri(mapping,pixels.data(),result.data(),int(pixels.size())))throw std::runtime_error("Original trilinear failed");
        save(prefix+".trilinear",result.data(),result.size()*sizeof(Pixel));
        const int dispatch_status=dispatch(mapping,pixels.data(),result.data(),int(pixels.size()),0);
        if(!dispatch_status)save(prefix+".dispatch",result.data(),result.size()*sizeof(Pixel));
        auto* normal_flag=static_cast<unsigned char*>(dlsym(library,"_ZN15IslZGlobalFlags30m_b3DMappingNormalDistributionE"));
        const int default_normal=normal_flag?int(*normal_flag):-1;
        std::memcpy(mapping+0x4f8,identity,sizeof identity);
        if(tri(mapping,pixels.data(),result.data(),int(pixels.size())))throw std::runtime_error("Matrix-isolation trilinear failed");
        save(prefix+".matrix-identity",result.data(),result.size()*sizeof(Pixel));
        if(dispatch(mapping,pixels.data(),result.data(),int(pixels.size()),0))throw std::runtime_error("Matrix-isolation dispatch failed");
        save(prefix+".matrix-identity-dispatch",result.data(),result.size()*sizeof(Pixel));
        int sigma_status[3]{};const double sigmas[]={.5,1.,2.};
        for(unsigned i=0;i<3;++i) {
            set_sigma(mapping,sigmas[i]);
            sigma_status[i]=fixed(mapping,pixels.data(),result.data(),int(pixels.size()));
            if(!sigma_status[i])save(prefix+".normal-"+std::to_string(i),result.data(),result.size()*sizeof(Pixel));
        }
        std::printf("{\"read_status\":%d,\"nodes\":%u,\"gamma\":%.17g,\"working_max\":%u,\"scale_id\":%u,\"samples\":%zu,\"default_normal_flag\":%d,\"dispatch_status\":%d,\"normal_status\":[%d,%d,%d]}\n",
                    read_status,nodes,gamma,unsigned(limit),unsigned(field<std::uint16_t>(mapping,0x4f0)),pixels.size(),default_normal,dispatch_status,sigma_status[0],sigma_status[1],sigma_status[2]);
        return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"%s\n",error.what());return 1;}
}
