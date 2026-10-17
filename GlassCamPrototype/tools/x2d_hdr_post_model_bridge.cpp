#include "../core/hncs_phocus_hdr_post.hpp"
#include "../core/hncs_c.h"
#include <cstddef>
extern "C" int hdr_post_model(const uint16_t* source,uint16_t* output,size_t count,int stage,
                              double amount,double saturation,int lstar) {
    if(stage==2)return hncs_render_x2d_hdr_post(source,output,count,amount,saturation,lstar);
    for(size_t i=0;i<count;++i) {
        hncs_phocus_hdr_post::Codes p={source[3*i],source[3*i+1],source[3*i+2]};
        const auto q=stage==0?hncs_phocus_hdr_post::highlight(p,amount,saturation):
                             hncs_phocus_hdr_post::gamma(p,lstar!=0);
        for(unsigned c=0;c<3;++c)output[3*i+c]=q[c];
    }
    return 0;
}
