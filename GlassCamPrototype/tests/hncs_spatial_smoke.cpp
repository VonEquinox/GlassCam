#include "../core/hncs_spatial.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>
#include <unistd.h>

static int cancel(void *context) {return ++*static_cast<int *>(context)>=4;}
int main() {
    const char *keys[]={"film-grain-artistic","film-grain-fine-texture","film-grain-high-iso","film-grain-medium-iso","film-grain-rough-color","film-grain-slide-high-iso","film-grain-slide-medium-iso","film-grain-tabular-grain","sharpness-high","sharpness-portrait","standard"};
    for(const auto &shape:{std::pair<size_t,size_t>{1,1},{1,7},{7,1},{31,57},{4097,3}}) {
        const size_t w=shape.first,h=shape.second;std::vector<float> original(w*h*3);
        for(size_t i=0;i<original.size();++i)original[i]=static_cast<float>(i%65536)/65535.f;
        for(const char *key:keys) {
            auto memory=original;assert(hncs_apply_spatial_preset(memory.data(),w,h,key,1,1)==0);
            char path[]="/tmp/hncs-spatial-smoke-XXXXXX";int fd=mkstemp(path);assert(fd>=0);FILE *file=fdopen(fd,"w+b");assert(file);
            assert(std::fwrite(original.data(),sizeof(float),original.size(),file)==original.size());std::fclose(file);
            assert(hncs_apply_spatial_preset_file(path,w,h,key,1,1,"/tmp",nullptr,nullptr)==0);
            file=std::fopen(path,"rb");assert(file);std::vector<float> disk(original.size());assert(std::fread(disk.data(),sizeof(float),disk.size(),file)==disk.size());std::fclose(file);
            assert(std::memcmp(memory.data(),disk.data(),memory.size()*sizeof(float))==0);
            int count=0;assert(hncs_apply_spatial_preset_file(path,w,h,"film-grain-artistic",1,1,"/tmp",cancel,&count)==-3);
            unlink(path);
        }
    }
    float value[3]={0,0,0};assert(hncs_apply_spatial_preset(nullptr,1,1,"standard",1,1)==-1);
    assert(hncs_apply_spatial_preset(value,0,1,"standard",1,1)==-1);
    assert(hncs_apply_spatial_preset(value,std::numeric_limits<size_t>::max(),3,"standard",1,1)==-1);
    assert(hncs_apply_spatial_preset(value,1,1,"invalid",1,1)==-1);
    value[0]=std::numeric_limits<float>::quiet_NaN();assert(hncs_apply_spatial_preset(value,1,1,"standard",1,1)==-1);
    std::puts("HNCS spatial smoke: memory/file equality, invalid inputs and cancellation passed.");
}
