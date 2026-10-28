// Test-only access to the original stage runner and private copied contexts.
// Production users include ffcs_c.h and select immutable effect options.
#include "../../Sources/CFFCS/ffcs.cpp"
#include <iostream>
#include <memory>
#include <random>

#define CHECK(x) do { if(!(x)) { \
 std::cerr<<"Fail line "<<__LINE__<<": "<<#x<<"; "<<error.data()<<"\n"; \
 return 1; } } while(false)

namespace {
void captureTone(const char *name,const double *rgb,size_t w,size_t h,void *user) {
 if(std::strcmp(name,"tone_curve")==0) {
  auto &tone=*static_cast<std::vector<double>*>(user);
  tone.assign(rgb,rgb+w*h*3);
 }
}
bool sameFloat(float a,float b) { return std::memcmp(&a,&b,sizeof(float))==0; }
}

int main(int argc,char **argv) {
 if(argc!=2) return 2;
 std::array<char,1024> error{};
 std::vector<float> input;
 auto append=[&](double r,double g,double b) {
  input.push_back(float(r));input.push_back(float(g));input.push_back(float(b));
 };
 // Original 80^3 source-LUT coordinates, transfer breakpoints, cube vertices,
 // a shaped 17^3 grid, boundary/saturated samples and deterministic holdouts.
 for(int r=0;r<=16;++r) for(int g=0;g<=16;++g) for(int b=0;b<=16;++b)
  append(decode(r/16.),decode(g/16.),decode(b/16.));
 for(int i=0;i<80;++i) append(decode(i/79.),decode(i/79.),decode(i/79.));
 for(float x:{0.f,-0.f,std::numeric_limits<float>::denorm_min(),
              std::nextafter(.0031308f,0.f),.0031308f,std::nextafter(.0031308f,1.f),
              .04045f,.18f,.5f,std::nextafter(1.f,0.f),1.f}) {
  append(x,x,x);append(x,0,1);append(1,x,0);append(0,1,x);
 }
 std::mt19937 rng(20261011);
 auto randomUnit=[&]() { return double(rng())/double(rng.max()); };
 for(int i=0;i<4096;++i) {
  const double r=randomUnit(),g=randomUnit(),b=randomUnit();
  append(r,g,b);append(decode(r),decode(g),decode(b));
 }
 const size_t pixels=input.size()/3;
 const size_t output_n=pixels*4;
 size_t compared=0,invalid_calls=0;
 CHECK(ffcs_simulation_count()==20);
 for(size_t look=0;look<19;++look) {
  std::unique_ptr<FFCSContext,decltype(&ffcs_destroy)> context(
   ffcs_create_config(argv[1],look,1,1,1,1,error.data(),error.size()),ffcs_destroy);
  CHECK(context);
  const auto *ctx=context.get();
  const double originalGrain=ctx->look.grain,originalSharp=ctx->look.sharp;
  // Baseline before the new API: nontrivial image with real spatial effects.
  const size_t full_w=19,full_h=7,full_n=full_w*full_h*3;
  std::vector<float> full_before(full_n),full_after(full_n);
  CHECK(ffcs_process_linear_rgb(ctx,input.data(),input.size(),full_w,full_h,
   .7f,0xffffffffu,full_before.data(),full_n,nullptr,0,error.data(),error.size()));
  std::vector<float> output(output_n+8,-7.f);
  CHECK(ffcs_process_linear_rgb_color_only(ctx,input.data(),input.size(),pixels,
   output.data()+4,output_n,error.data(),error.size()));
  CHECK(error[0]=='\0');
  for(size_t i=0;i<4;++i) CHECK(output[i]==-7.f && output[output_n+4+i]==-7.f);
  // Original stage sequence with original, spatially active context. Capturing
  // tone_curve is independent of the added pointwise function.
  std::vector<double> original(input.begin(),input.end()),tone;
  render(*ctx,original,pixels,1,123,true,captureTone,&tone);
  CHECK(tone.size()==input.size());
  // Original full-image linear C ABI with only spatial coefficients zeroed in
  // a test-owned copy. Never mutate the production/shared context.
  FFCSContext zeroSpatial=*ctx;
  zeroSpatial.look.grain=0;zeroSpatial.look.sharp=0;
  std::vector<float> zero_output(input.size());
  CHECK(ffcs_process_linear_rgb(&zeroSpatial,input.data(),input.size(),pixels,1,
   0,0,zero_output.data(),zero_output.size(),nullptr,0,error.data(),error.size()));
  for(size_t i=0;i<pixels;++i) {
   // Same test-private oracle used in the prior LUT proxy study.
   RGB oracle=mobilePixel(zeroSpatial,input.data()+i*3,0,0,1,1,0);
   for(int ch=0;ch<3;++ch) {
    const float actual=output[4+i*4+ch];
    CHECK(std::isfinite(actual) && actual>=0.f && actual<=1.f);
    CHECK(sameFloat(actual,float(decode(tone[i*3+ch]))));
    CHECK(sameFloat(actual,zero_output[i*3+ch]));
    CHECK(sameFloat(actual,float(decode(oracle[ch]))));
    ++compared;
   }
   CHECK(output[4+i*4+3]==1.f);
  }
  // Deterministic batch invariance and shared immutable-context concurrency.
  std::vector<float> batched(output_n);
  std::array<std::thread,4> threads;
  std::array<int,4> ok{};
  for(size_t worker=0;worker<4;++worker) {
   const size_t first=pixels*worker/4,last=pixels*(worker+1)/4;
   threads[worker]=std::thread([&,worker,first,last] {
    ok[worker]=ffcs_process_linear_rgb_color_only(ctx,input.data()+first*3,
     (last-first)*3,last-first,batched.data()+first*4,(last-first)*4,nullptr,0);
   });
  }
  for(auto &thread:threads) thread.join();
  for(int result:ok) CHECK(result==1);
  CHECK(std::memcmp(batched.data(),output.data()+4,output_n*sizeof(float))==0);
  CHECK(ctx->look.grain==originalGrain && ctx->look.sharp==originalSharp);
  CHECK(ffcs_process_linear_rgb(ctx,input.data(),input.size(),full_w,full_h,
   .7f,0xffffffffu,full_after.data(),full_n,nullptr,0,error.data(),error.size()));
  CHECK(std::memcmp(full_before.data(),full_after.data(),full_n*sizeof(float))==0);

  // Guard every documented failure without touching outputs.
  std::vector<float> valid={0,.18f,1,.1f,.2f,.3f};
  std::vector<float> guarded(16,-3.f);
  auto reject=[&](const FFCSContext *c,const float *in,size_t ni,size_t n,
                  float *out,size_t no) {
   const auto before=guarded;
   const auto valid_before=valid;
   error.fill('x');
   const int result=ffcs_process_linear_rgb_color_only(c,in,ni,n,out,no,error.data(),error.size());
   ++invalid_calls;
   return result==0 && error[0] && error.back()=='\0' && guarded==before && valid==valid_before;
  };
  CHECK(reject(nullptr,valid.data(),6,2,guarded.data(),8));
  CHECK(reject(ctx,nullptr,6,2,guarded.data(),8));
  CHECK(reject(ctx,valid.data(),6,2,nullptr,8));
  CHECK(reject(ctx,valid.data(),6,0,guarded.data(),8));
  CHECK(reject(ctx,valid.data(),5,2,guarded.data(),8));
  CHECK(reject(ctx,valid.data(),6,2,guarded.data(),7));
  CHECK(reject(ctx,valid.data(),6,std::numeric_limits<size_t>::max(),guarded.data(),8));
  CHECK(reject(ctx,valid.data(),6,std::numeric_limits<size_t>::max()/(4*sizeof(float))+1,guarded.data(),8));
  // Same base, partial forward overlap, partial backward overlap.
  CHECK(reject(ctx,guarded.data(),6,2,guarded.data(),8));
  CHECK(reject(ctx,guarded.data(),6,2,guarded.data()+1,8));
  CHECK(reject(ctx,guarded.data()+3,6,2,guarded.data(),8));
  for(float bad:{std::numeric_limits<float>::quiet_NaN(),
                 std::numeric_limits<float>::infinity(),
                 -std::numeric_limits<float>::infinity(),
                 -std::numeric_limits<float>::denorm_min(),std::nextafter(1.f,2.f)}) {
   std::vector<float> invalid=valid;invalid.back()=bad;
   CHECK(reject(ctx,invalid.data(),invalid.size(),2,guarded.data(),8));
  }
  char one='x';
  CHECK(!ffcs_process_linear_rgb_color_only(nullptr,nullptr,0,0,nullptr,0,&one,1));
  CHECK(one=='\0');
  one='x';
  CHECK(!ffcs_process_linear_rgb_color_only(nullptr,nullptr,0,0,nullptr,0,&one,0));
  CHECK(one=='x');
  // Counts may exceed the required active range; tails are never read/written.
  valid.push_back(std::numeric_limits<float>::quiet_NaN());
  CHECK(ffcs_process_linear_rgb_color_only(ctx,valid.data(),valid.size(),2,
   guarded.data(),guarded.size(),nullptr,1024));
  for(size_t i=8;i<guarded.size();++i) CHECK(guarded[i]==-3.f);
 }
 std::cout<<"FFCS color-only passed: 19 looks, "<<pixels
          <<" inputs/look, "<<compared<<" bit-exact RGB comparisons per oracle"
          <<", 3 independent stage/spatial-zero checks, "<<invalid_calls
          <<" rejected calls, RGBA guards, batch/concurrent determinism, unchanged full-photo output.\n";
}
