#include "hncs_files.h"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <fcntl.h>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
struct Descriptor {
    int value;
    Descriptor(const char *path,int flags):value(open(path,flags|O_CLOEXEC)){}
    ~Descriptor(){if(value>=0)close(value);}
};
bool transfer(int descriptor,float *values,size_t samples,off_t offset,bool output) {
    auto *cursor=reinterpret_cast<unsigned char *>(values);
    size_t bytes=samples*sizeof(float);
    while(bytes) {
        const ssize_t count=output?pwrite(descriptor,cursor,bytes,offset):pread(descriptor,cursor,bytes,offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return false;
        bytes-=size_t(count);offset+=count;cursor+=count;
    }
    return true;
}
}

extern "C" int hncs_finish_apple_hdr_work_file(const hncs_context *context,
    const char *work_path,const char *output_path,size_t pixels,double scale,unsigned workers,float *maximum,
    hncs_spatial_cancel_fn cancelled,hncs_file_progress_fn progress,void *callback_context) {
    if(!context||!work_path||!output_path||!maximum||!pixels||!workers||workers>4||
       !std::isfinite(scale)||scale<1.||scale>64.||
       pixels>size_t(std::numeric_limits<off_t>::max())/16||pixels>std::numeric_limits<size_t>::max()/16)return -1;
    try {
        if(cancelled&&cancelled(callback_context))return -3;
        Descriptor input(work_path,O_RDONLY),output(output_path,O_WRONLY);
        if(input.value<0||output.value<0)return -2;
        struct stat source{},destination{};
        if(fstat(input.value,&source)||fstat(output.value,&destination))return -2;
        if(!S_ISREG(source.st_mode)||!S_ISREG(destination.st_mode)||source.st_size!=off_t(pixels*12)||
           (source.st_dev==destination.st_dev&&source.st_ino==destination.st_ino))return -1;
        constexpr size_t chunk=262144;
        std::vector<float> work(std::min(chunk,pixels)*3),rgba(std::min(chunk,pixels)*4);
        float peak=1.f;
        for(size_t first=0;first<pixels;first+=chunk) {
            if(cancelled&&cancelled(callback_context))return -3;
            const size_t count=std::min(chunk,pixels-first);
            if(!transfer(input.value,work.data(),count*3,off_t(first*12),false))return -2;
            const int status=hncs_finish_apple_hdr_work_linear_parallel(context,work.data(),rgba.data(),count,scale,workers);
            if(status)return status;
            for(size_t i=0;i<count*4;++i)peak=std::max(peak,rgba[i]);
            if(!transfer(output.value,rgba.data(),count*4,off_t(first*16),true))return -2;
            if(progress)progress(double(first+count)/double(pixels),callback_context);
        }
        if(cancelled&&cancelled(callback_context))return -3;
        if(ftruncate(output.value,off_t(pixels*16)))return -2;
        *maximum=peak;return 0;
    }catch(...){return -2;}
}
