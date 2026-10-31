#include "f5_curvature.h"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <new>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

extern "C" int32_t gc_f5_curve_write_rgb(int input, int output, uint32_t width, uint32_t height,
                                         uint64_t offset, const gc_f5_curve_callbacks *callbacks, gc_f5_curve_error *error) {
    if(error)*error={};
    const auto fail=[&](int status,const char *message) {
        if(error){error->status=status;error->system_error=status==5?errno:0;std::snprintf(error->message,sizeof(error->message),"%s",message);}return status;
    };
    if(input<0 || output<0 || input==output || !width || !height || width>32768 || height>32768 ||
       offset>UINT32_MAX || uint64_t(width)*height*12+offset>UINT32_MAX)return fail(1,"Invalid LinearRaw archive dimensions.");
    struct stat source{};
    if(fstat(input,&source)!=0 || uint64_t(source.st_size)!=uint64_t(width)*height*16)return fail(1,"Camera archive raster has an incorrect size.");
    try {
        std::vector<float> rgba(size_t(width)*16*4),rgb(size_t(width)*16*3);
        for(uint32_t top=0;top<height;top+=16) {
            if(callbacks && callbacks->cancelled && callbacks->cancelled(callbacks->context))return fail(4,"RAW archival cancelled.");
            const size_t pixels=size_t(width)*std::min(16u,height-top),bytes=pixels*16;
            size_t done=0;
            while(done<bytes){ssize_t n=pread(input,reinterpret_cast<char *>(rgba.data())+done,bytes-done,off_t(top)*width*16+done);
                if(n<0 && errno==EINTR)continue;if(n<=0)return fail(5,"Cannot read camera raster for LinearRaw archival.");done+=size_t(n);}
            for(size_t p=0;p<pixels;++p)for(unsigned c=0;c<3;++c){float value=rgba[p*4+c];if(!std::isfinite(value))return fail(3,"Nonfinite LinearRaw archive sample.");rgb[p*3+c]=value;}
            done=0;
            while(done<pixels*12){ssize_t n=pwrite(output,reinterpret_cast<const char *>(rgb.data())+done,pixels*12-done,off_t(offset)+off_t(top)*width*12+done);
                if(n<0 && errno==EINTR)continue;if(n<=0)return fail(5,"Cannot write LinearRaw archive.");done+=size_t(n);}
        }
        return 0;
    }catch(const std::bad_alloc &){return fail(2,"Cannot allocate bounded LinearRaw archive rows.");}
}
