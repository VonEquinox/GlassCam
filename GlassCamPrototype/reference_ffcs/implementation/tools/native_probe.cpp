// Diagnostic harness for the exported x86_64 mapping ABI in the supplied DMG.
// The object offsets and signatures were checked against its disassembly.
// This is an audit tool, not an application interface or a replacement decoder.
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>

template<class T> T symbol(void* lib, const char* name) {
    auto p = dlsym(lib, name);
    if (!p) { std::fprintf(stderr, "%s: %s\n", name, dlerror()); std::exit(2); }
    return reinterpret_cast<T>(p);
}

struct Pixel { uint16_t b, g, r; };

int main(int argc, char** argv) {
    if (argc < 3) return 2;
    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::fprintf(stderr, "%s\n", dlerror()); return 2; }
    auto ctor = symbol<void(*)(void*,uint16_t,int,double,uint16_t,const double*)>(
        lib, "_ZN18IslZColor3DMappingC1EtidtRK11IslZMatrix3");
    auto storage_ctor = symbol<void(*)(void*,const void*,unsigned)>(
        lib, "_ZN20IslZStorageMemBrowseC1EPKvj");
    auto read = symbol<int(*)(void*,void*)>(
        lib, "_ZN18IslZColor3DMapping15ReadMappingDataEP11IslZStorage");
    auto transform = symbol<int(*)(const void*,const Pixel*,Pixel*,int)>(
        lib, "_ZNK18IslZColor3DMapping18TransFormTrilinearEPK12_ISLZPIXEL48PS0_i");
    auto storage_dtor = symbol<void(*)(void*)>(lib, "_ZN20IslZStorageMemBrowseD1Ev");
    alignas(16) unsigned char mapping[4096] = {};
    alignas(16) unsigned char storage[4096] = {};
    double identity[9] = {1,0,0,0,1,0,0,0,1};
    ctor(mapping, 20000, 78, 1.0, 0, identity);
    std::ifstream file(argv[2], std::ios::binary);
    std::vector<char> data((std::istreambuf_iterator<char>(file)), {});
    if (data.empty()) return 2;
    storage_ctor(storage, data.data(), (unsigned)data.size());
    int code = read(mapping, storage);
    std::fprintf(stderr, "ReadMappingData=%d\n", code);
    if (code != 0) return 3;
    const double* matrix = reinterpret_cast<const double*>(mapping + 0x4f8);
    std::fprintf(stderr, "matrix(column-major):");
    for (int i=0; i<9; i++) std::fprintf(stderr, " %.9g", matrix[i]);
    std::fprintf(stderr, "\ngamma=%.9g id=%u\n",
        *reinterpret_cast<const double*>(mapping+0x4e8),
        *reinterpret_cast<const uint16_t*>(mapping+0x4f0));
    if (argc >= 5) {
        std::ifstream input(argv[3],std::ios::binary);
        std::vector<Pixel> pixels;
        Pixel p;
        while (input.read(reinterpret_cast<char*>(&p),sizeof p)) pixels.push_back(p);
        std::vector<Pixel> out(pixels.size());
        int status=transform(mapping,pixels.data(),out.data(),(int)pixels.size());
        if (status) return 4;
        std::ofstream output(argv[4],std::ios::binary);
        output.write(reinterpret_cast<const char*>(out.data()),out.size()*sizeof(Pixel));
        std::fprintf(stderr,"samples=%zu\n",pixels.size());
    } else {
        Pixel pixels[]={{0,0,0},{0,0,20000},{0,20000,0},{20000,0,0},{10000,10000,10000},{20000,20000,20000}};
        Pixel out[6]={};
        int status=transform(mapping,pixels,out,6);
        std::fprintf(stderr,"TransFormTrilinear=%d\n",status);
        for(int i=0;i<6;i++) std::printf("%u %u %u -> %u %u %u\n",pixels[i].r,pixels[i].g,pixels[i].b,out[i].r,out[i].g,out[i].b);
    }
    storage_dtor(storage);
    // Mapping is process-local; the OS releases it when this probe exits.
    return 0;
}
