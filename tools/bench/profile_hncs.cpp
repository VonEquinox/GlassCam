// Diagnostic only: include production implementation to profile exact internal stages.
// Separate-pass timings include scratch memory traffic and are not additive to fused API time.
#include "../../core/hncs.cpp"
#include <chrono>
#include <ctime>
#include <iostream>
#include <iomanip>
#include <string>
#include <stdexcept>
using Clock=std::chrono::steady_clock;
volatile uint64_t observed=0;
template<class F> void measure(const std::string& name,size_t n,F f) {
 f(); std::cout<<"{\"name\":\""<<name<<"\",\"pixels\":"<<n<<",\"wall_ms\":[";
 double cpu[5];for(int k=0;k<5;++k){auto a=Clock::now();auto c=std::clock();f();cpu[k]=1000.*(std::clock()-c)/CLOCKS_PER_SEC;double t=std::chrono::duration<double,std::milli>(Clock::now()-a).count();if(k)std::cout<<',';std::cout<<t;}
 std::cout<<"],\"cpu_ms\":[";for(int k=0;k<5;++k){if(k)std::cout<<',';std::cout<<cpu[k];}std::cout<<"]}\n";
}
uint64_t hash(const uint8_t* a,size_t n){uint64_t v=14695981039346656037ull;for(size_t i=0;i<n;++i){v^=a[i];v*=1099511628211ull;}return v;}
int main(int argc,char**argv){std::cout<<std::setprecision(10);size_t n=argc>1?std::stoull(argv[1]):1048576;
 if(n>12000000)throw std::runtime_error("Bounded harness supports at most 12MP");
 hncs_context c(0,5500);std::vector<float> input(n*3);uint32_t rng=928;for(auto&v:input){rng=rng*1664525u+1013904223u;v=float(rng>>8)/16777216.f;}
 std::vector<uint8_t> exact(n*4),out(n*4);std::vector<float> linear(n*4);
 auto checked=[](int status){if(status)throw std::runtime_error("API failure");};
 measure("fused_exact_1",n,[&]{checked(hncs_process_srgb(&c,input.data(),exact.data(),n));});
 measure("fused_fast_1",n,[&]{checked(hncs_process_srgb_fast(&c,input.data(),out.data(),n));});
 auto fh=hash(out.data(),out.size());int diff=0;size_t changes=0;for(size_t i=0;i<out.size();++i){int d=std::abs(int(out[i])-int(exact[i]));diff=std::max(diff,d);changes+=d!=0;}if(diff>1)throw std::runtime_error("Fast error bound failed");
 for(unsigned workers:{2,4}){measure("fused_fast_"+std::to_string(workers),n,[&]{checked(hncs_process_srgb_fast_parallel(&c,input.data(),out.data(),n,workers));});if(hash(out.data(),out.size())!=fh)throw std::runtime_error("Parallel mismatch");}
 measure("fused_linear_float_1",n,[&]{checked(hncs_process_linear_rgba(&c,input.data(),linear.data(),n));});
 std::cout<<"{\"verification\":\"pass\",\"exact_fnv1a64\":\""<<hash(exact.data(),exact.size())<<"\",\"fast_fnv1a64\":\""<<fh<<"\",\"fast_max_byte_error\":"<<diff<<",\"changed_channels\":"<<changes<<"}\n";
 if(n>1048576)return 0; // Stage isolation deliberately uses bounded intermediate buffers.
 std::vector<V> native(n),q(n),yuv(n),mapped(n),weighted(n),rgb(n);std::vector<std::array<uint16_t,3>>codes(n);
 measure("isolated_pure_3x3_float_to_double",n,[&]{for(size_t i=0;i<n;++i)native[i]=transform(c.source_to_native,{input[i*3],input[i*3+1],input[i*3+2]});});
 measure("stage_input_bridge",n,[&]{for(size_t i=0;i<n;++i){V p={double(input[i*3])*c.exposure,double(input[i*3+1])*c.exposure,double(input[i*3+2])*c.exposure};if(!finite(p))throw std::runtime_error("input");native[i]=transform(c.source_to_native,p);if(!finite(native[i]))throw std::runtime_error("bridge");}});
 measure("stage_quantize_u16",n,[&]{for(size_t i=0;i<n;++i)for(int j=0;j<3;++j)q[i][j]=round_even(clamp(native[i][j],0,1)*65535.);});
 measure("stage_incoming_matrix",n,[&]{for(size_t i=0;i<n;++i)yuv[i]=transform(c.incoming,q[i]);});
 measure("stage_chroma_coordinates_bilinear_2d_lut",n,[&]{for(size_t i=0;i<n;++i){const V v=yuv[i];double y=v[0];double x=clamp((y>0?v[1]/y:0)*assets::grid[4]-c.cb0,0,c.width-1),z=clamp((y>0?v[2]/y:0)*assets::grid[4]-c.cr0,0,c.height-1);int x0=int(std::floor(x)),z0=int(std::floor(z)),x1=std::min(x0+1,c.width-1),z1=std::min(z0+1,c.height-1);double fx=x-x0,fy=z-z0;size_t a=size_t(z0*c.width+x0)*2,b=size_t(z1*c.width+x0)*2,d=size_t(z0*c.width+x1)*2,e=size_t(z1*c.width+x1)*2;for(int j=0;j<2;++j)mapped[i][j]=((c.lut[a+j]*(1-fy)+c.lut[b+j]*fy)*(1-fx)+(c.lut[d+j]*(1-fy)+c.lut[e+j]*fy)*fx)/assets::grid[4];}});
 measure("stage_gray_shadow_weight",n,[&]{for(size_t i=0;i<n;++i){double y=yuv[i][0],weight=1.;const auto&p=q[i];if(assets::gray_thresholds[0]>assets::gray_thresholds[1]){double mean=(p[0]+p[1]+p[2])/3.;double saturation=mean>0?std::max({std::abs(p[0]-mean),std::abs(p[1]-mean),std::abs(p[2]-mean)})/mean:0;weight=clamp((saturation-assets::gray_thresholds[1])/(assets::gray_thresholds[0]-assets::gray_thresholds[1]),0,1);}double shadow=y<=assets::shadow_desaturation[0]?(c.shadow_a*y)*y+c.shadow_b*y+c.shadow_d:1.;if(!c.reproduction)weight=std::max(0.,std::min(weight,shadow));weighted[i]={y,(y*weight)*mapped[i][0],(y*weight)*mapped[i][1]};}});
 measure("stage_outgoing_tone_lut",n,[&]{for(size_t i=0;i<n;++i){auto v=weighted[i];for(int j=0;j<3;++j){double value=v[0]>0?v[0]+(v[1]*c.outgoing[j*3+1]+v[2]*c.outgoing[j*3+2]):0;codes[i][j]=c.curve[size_t(clamp(value,0,65535))];}}});
 measure("stage_display_decode_3_matrices_clip",n,[&]{for(size_t i=0;i<n;++i)rgb[i]=c.display_linear(codes[i]);});
 measure("stage_exact_srgb_oetf_and_byte_quantize",n,[&]{for(size_t i=0;i<n;++i){for(int j=0;j<3;++j){double v=rgb[i][j];v=v<=.0031308?12.92*v:1.055*std::pow(v,1./2.4)-.055;out[i*4+j]=uint8_t(round_even(clamp(v*255.,0,255)));}out[i*4+3]=255;}});
 if(out!=exact)throw std::runtime_error("Staged vs production exact mismatch");
 measure("stage_fast_srgb_lut_and_byte_quantize",n,[&]{for(size_t i=0;i<n;++i){for(int j=0;j<3;++j)out[i*4+j]=c.srgb_encode[size_t(round_even(rgb[i][j]*65535.))];out[i*4+3]=255;}});
 if(hash(out.data(),out.size())!=fh)throw std::runtime_error("Staged vs production fast mismatch");
 std::cout<<"{\"stage_reconstruction_byte_exact\":true}\n";
}
