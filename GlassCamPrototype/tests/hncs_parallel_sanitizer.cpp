#include "../core/hncs_c.h"
#include <cassert>
#include <cstring>
#include <limits>
#include <vector>
int main() {
 auto*c=hncs_create(0,5500);assert(c);
 const size_t n=65539;std::vector<float> in(n*3),a(n*4),b(n*4);
 for(size_t i=0;i<in.size();++i)in[i]=float(i%997)/996.f;
 assert(hncs_process_linear_rgba(c,in.data(),a.data(),n)==0);
 for(unsigned workers=1;workers<=4;++workers){
  assert(hncs_process_linear_rgba_parallel(c,in.data(),b.data(),n,workers)==0);
  assert(std::memcmp(a.data(),b.data(),a.size()*sizeof(float))==0);
  assert(hncs_process_linear_rgba_parallel(c,nullptr,nullptr,0,workers)==0);
  assert(hncs_process_linear_rgba_parallel(c,in.data(),b.data(),std::numeric_limits<size_t>::max(),workers)==-1);
 }
 in.back()=std::numeric_limits<float>::infinity();
 assert(hncs_process_linear_rgba_parallel(c,in.data(),b.data(),n,4)==-1);
 assert(hncs_process_linear_rgba_parallel(c,in.data(),b.data(),n,0)==-1);
 assert(hncs_process_linear_rgba_parallel(nullptr,nullptr,nullptr,0,4)==-1);
 hncs_destroy(c);
}
