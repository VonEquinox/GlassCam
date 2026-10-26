// Offline native 48-bit VE oracle. This program is never part of the iOS app.
// All offsets are for the SHA-256 pinned SILKYPIX8 binary in reference_lumix.
#include <dlfcn.h>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

static uintptr_t base;
template<class F> F fn(uintptr_t a) { return reinterpret_cast<F>(base+a); }
template<class T> T &at(void *p, size_t a) { return *reinterpret_cast<T *>(static_cast<char *>(p)+a); }
struct alignas(16) Object { std::array<unsigned char, 65536> bytes{}; void *get() { return bytes.data(); } };
static double constant(uintptr_t a) { return *reinterpret_cast<double *>(base+a); }
static void save(const std::string &path, const void *data, size_t bytes) {
    std::ofstream f(path, std::ios::binary); f.write(static_cast<const char *>(data), bytes);
    if (!f) throw std::runtime_error("Cannot save "+path);
}
static std::vector<uint16_t> readCube(const char *path) {
    std::ifstream f(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(f)), {});
    constexpr size_t n=129;
    if (bytes.size()!=n*n*n*6) throw std::runtime_error("Invalid decoded cube");
    // Canonical R-fast RGB -> original B-fast RGB.
    auto p=reinterpret_cast<const uint16_t *>(bytes.data());
    std::vector<uint16_t> result(n*n*n*3);
    for(size_t r=0;r<n;r++) for(size_t g=0;g<n;g++) for(size_t b=0;b<n;b++)
        for(size_t c=0;c<3;c++) result[((r*n+g)*n+b)*3+c]=p[((b*n+g)*n+r)*3+c];
    return result;
}
int main(int argc,char **argv) {
    try {
        if(argc<3) throw std::runtime_error("framework constants directory | framework line cube output style contrast saturation iso white ev colorspace [otherCube firstWeight]");
        auto handle=dlopen(argv[1],RTLD_LAZY|RTLD_LOCAL);
        if(!handle) throw std::runtime_error(dlerror());
        auto known=dlsym(handle,"_ZNK14IslZColor3DLut10GetLutSizeEv");
        if(!known) throw std::runtime_error("Missing pinned symbol");
        base=reinterpret_cast<uintptr_t>(known)-0x7a292a;
        if(std::string(argv[2])=="constants" && argc==4) {
            const std::string dir=argv[3];
            save(dir+"/contrast.bin",reinterpret_cast<void *>(base+0xf6f970),21*70);
            save(dir+"/saturation.bin",reinterpret_cast<void *>(base+0xf34db0),21*2);
            save(dir+"/monochrome.bin",reinterpret_cast<void *>(base+0xf34de0),21*3);
            save(dir+"/low-iso.bin",reinterpret_cast<void *>(base+0xf3bc90),3*0x10e0);
            save(dir+"/temperature.bin",reinterpret_cast<void *>(base+0xf3ef30),64);
            const uintptr_t addresses[]={0xeba7b8,0xeba7e0,0xec8ae0,0xec8ae8,0xec8af0,0xec6c50,
                0xf85fe8,0xf85fe0,0xf85fd8,0xf85fd0,0xef9e70,0xef9e78,0xef9e80,0xef9e88,
                0xed87a8,0xf82d70,0xf86000,0xf86008,0xf85ff0,0xf85ff8,0xf86010,0xf86018,
                0xf86020,0xf86028,0xf83088,0xf85fc8};
            std::printf("{\n");
            for(size_t i=0;i<sizeof(addresses)/sizeof(*addresses);i++)
                std::printf("\"%lx\":%.17g%s\n",addresses[i],constant(addresses[i]),i+1==sizeof(addresses)/sizeof(*addresses)?"":",");
            std::printf("}\n"); return 0;
        }
        if(std::string(argv[2])=="set" && argc==8) {
            // Exercise original dispatch, table selection, mixing and ISO regs.
            fn<short(*)(void *,const char *)>(0xbe9ccc)(reinterpret_cast<void *>(base+0x146d698),argv[3]);
            Object input,pana,small,contrast,bw,pre;
            fn<void(*)(void *)>(0x5a8250)(input.get());
            fn<void(*)(void *)>(0x707a10)(pana.get());
            fn<void(*)(void *)>(0x707a10)(small.get());
            int style=std::stoi(argv[5]),iso=std::stoi(argv[6]),temperature=std::stoi(argv[7]);
            unsigned char saturation=0;uint16_t clip=4095;double ev=0;
            auto call=fn<void(*)(void *,int,int,int,uint16_t,uint16_t,uint16_t,uint16_t,uint16_t,uint16_t,int,int,void *,void *,unsigned char *,void *,void *,uint16_t *,void *,int,double *)>(0x5babf8);
            call(input.get(),106,iso,style,temperature,256,512,256,temperature-256,512-temperature,10,10,
                pana.get(),contrast.get(),&saturation,bw.get(),pre.get(),&clip,small.get(),0,&ev);
            auto table=at<uint16_t *>(pana.get(),8);
            std::printf("{\"grid\":%d,\"step\":%d,\"white\":%u,\"saturation\":%u,\"clip\":%u,\"ev\":%.17g}\n",
                at<int>(pana.get(),0x14c),at<int>(pana.get(),0x148),at<uint16_t>(pana.get(),0x150),saturation,clip,ev);
            if(!table || at<int>(pana.get(),0x14c)!=129)throw std::runtime_error("Original Set3DLUT did not load a cube");
            save(argv[4],table,129*129*129*6);
            save(std::string(argv[4])+".low-iso",pre.get(),196);
            return 0;
        }
        if(std::string(argv[2])!="line" || (argc!=12 && argc!=14)) throw std::runtime_error("Invalid arguments");
        auto cube=readCube(argv[3]);
        int style=std::stoi(argv[5]),contrast=std::stoi(argv[6]),sat=std::stoi(argv[7]),iso=std::stoi(argv[8]);
        double white=std::stod(argv[9]),ev=std::stod(argv[10]); int space=std::stoi(argv[11]);
        if(style<1 || style>21 || contrast<0 || contrast>20 || sat<0 || sat>20 || white<=0 || white>65535)
            throw std::runtime_error("Invalid native parameters");
        if(argc==14) {
            auto other=readCube(argv[12]); int weight=std::stoi(argv[13]);
            if(weight<0 || weight>256) throw std::runtime_error("Invalid LUT mixing weight");
            for(size_t i=0;i<cube.size();i++) cube[i]=(uint32_t(cube[i])*weight+uint32_t(other[i])*(256-weight))/256;
        }
        Object filter; void *p=filter.get();
        fn<void(*)(void *)>(0x82d0ae)(p);
        at<uint8_t>(p,0x5e1)=1; at<int>(p,0x59c)=0x30;
        at<uint64_t>(p,0x5a0)=0xffffffffffffffffULL;
        for(size_t o : {0x3d8,0x3e0,0x3e8,0x3f0,0x3f8,0x400}) at<double>(p,o)=white;
        at<uint16_t *>(p,0x2fa8)=cube.data();
        at<int>(p,0x30e8)=32; at<int>(p,0x30ec)=129; at<uint16_t>(p,0x30f0)=4095;
        std::memcpy(static_cast<char *>(p)+0x3250,reinterpret_cast<void *>(base+0xf6f970+contrast*70),70);
        at<uint16_t>(p,0x3296)=*reinterpret_cast<uint16_t *>(base+0xf34db0+sat*2);
        if((0x942110U>>style)&1) std::memcpy(static_cast<char *>(p)+0x3298,reinterpret_cast<void *>(base+0xf34de0+sat*3),3);
        uintptr_t pre=iso==50?0xf3bc90:iso==64?0xf3cd70:iso==80?0xf3de50:0;
        if(pre) std::memcpy(static_cast<char *>(p)+0x3520,reinterpret_cast<void *>(base+pre+style*196),196);
        at<uint16_t>(p,0x3868)=4095; at<double>(p,0x3870)=ev; at<int>(p,0x3878)=space;
        auto make=fn<short(*)(void *,const void *,double,double)>(0x82d5e4);
        if(make(static_cast<char *>(p)+0x32a0,static_cast<char *>(p)+0x3250,constant(0xed87a8)*white,white*constant(0xf82d70)))
            throw std::runtime_error("Native contrast construction failed");
        if(at<int16_t>(p,0x3580)==-1 && at<int16_t>(p,0x35e2)==-1)
            fn<short(*)(void *,void *,const void *,double,double)>(0x82d48a)(p,static_cast<char *>(p)+0x35e8,static_cast<char *>(p)+0x3520,white/65535.,white/65535.);
        std::printf("{\"contrastPoints\":%d,\"lowISOPoints\":%d,\"saturation\":%u,\"bw\":[%u,%u,%u],\"curves\":[",
            at<int>(p,0x333c),at<int>(p,0x3684),at<uint16_t>(p,0x3296),at<uint8_t>(p,0x3298),at<uint8_t>(p,0x3299),at<uint8_t>(p,0x329a));
        bool first=true;
        for(size_t o:{0x32a0,0x35e8}) {
            if(!first)std::printf(",");first=false;
            std::printf("[");auto points=at<double *>(p,o+0xa0);
            for(int j=0;j<at<int>(p,o+0x9c);j++) std::printf("%s[%.17g,%.17g]",j?",":"",points[j*2],points[j*2+1]);
            std::printf("]");
        }
        std::printf("]}\n");
        constexpr int count=65536+32768+32;
        std::vector<uint16_t> in(count*3),out(count*3),records(count*6);
        uint32_t rng=0x4c554d49;
        for(int i=0;i<count;i++) {
            for(int c=0;c<3;c++) {rng=rng*1664525U+1013904223U;in[i*3+c]=(rng>>8)&65535;}
            if(i<65536) in[i*3]=in[i*3+1]=in[i*3+2]=i;
            if(i>=count-32) for(int c=0;c<3;c++) in[i*3+c]=(i&(1<<c))?uint16_t(white):(i&8)?32:0;
        }
        const void *rows[]={in.data()};std::array<char,1024> lineInfo{};
        auto status=fn<short(*)(void *,void *,const void *const *,int,void *,int,int,const void *)>(0x82d74e)(p,out.data(),rows,count,nullptr,0,0,lineInfo.data());
        if(status)throw std::runtime_error("Native FilteringLine failed");
        for(int i=0;i<count;i++) for(int c=0;c<3;c++) {records[i*6+c]=in[i*3+2-c];records[i*6+3+c]=out[i*3+2-c];}
        save(argv[4],records.data(),records.size()*2);
        // Do not run native destructors on the externally owned LUT storage.
    } catch(const std::exception &e) {std::fprintf(stderr,"%s\n",e.what());return 1;}
}
