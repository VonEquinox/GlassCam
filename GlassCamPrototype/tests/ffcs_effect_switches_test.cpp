// Test-only access to unchanged reference stages and private coefficient-zero
// contexts. Public callers use opaque immutable FFCSContext instances.
#include "../core/ffcs.cpp"
#include <climits>
#include <iostream>
#include <map>
#include <memory>

#define CHECK(x) do { if(!(x)) { \
 std::cerr<<"Fail line "<<__LINE__<<": "<<#x<<"; "<<error.data()<<"\n"; \
 return 1; } } while(false)

namespace {
using Context=std::unique_ptr<FFCSContext,decltype(&ffcs_destroy)>;
using Stages=std::map<std::string,std::vector<double>>;
void capture(const char *name,const double *rgb,size_t w,size_t h,void *user) {
 (*static_cast<Stages*>(user))[name]=std::vector<double>(rgb,rgb+w*h*3);
}
template<class T> bool exact(const std::vector<T> &a,const std::vector<T> &b) {
 return a.size()==b.size() && std::memcmp(a.data(),b.data(),a.size()*sizeof(T))==0;
}
}

int main(int argc,char **argv) {
 if(argc!=2) return 2;
 std::array<char,1024> error{};
 size_t frames=0,strips=0,encoded=0,defaults=0,colorOnly=0,invalid=0;
 CHECK(ffcs_simulation_count()==19);
 for(size_t look=0;look<ffcs_simulation_count();++look) {
  Context legacy(ffcs_create(argv[1],look,error.data(),error.size()),ffcs_destroy);
  CHECK(legacy);
  CHECK(legacy->grainEnabled && legacy->sharpenEnabled);
  for(int grain:{0,1}) for(int sharp:{0,1}) {
   Context ctx(ffcs_create_options(argv[1],look,grain,sharp,error.data(),error.size()),ffcs_destroy);
   CHECK(ctx && error[0]=='\0');
   CHECK(ctx->grainEnabled==bool(grain) && ctx->sharpenEnabled==bool(sharp));
   CHECK(ctx->look.grain==legacy->look.grain && ctx->look.sharp==legacy->look.sharp);
   FFCSContext oracle=*legacy;
   if(!grain) oracle.look.grain=0;
   if(!sharp) oracle.look.sharp=0;
   for(auto dimensions:std::vector<std::pair<size_t,size_t>>{{1,1},{1,7},{9,1},{7,3},{131,19}}) {
    const size_t w=dimensions.first,h=dimensions.second,n=w*h*3;
    std::vector<float> input(n),full(n),expected(n),optimized(n);
    std::vector<uint8_t> preview(n/3*4),expectedPreview(n/3*4),optimizedPreview(n/3*4);
    for(size_t i=0;i<n;++i) input[i]=float((i*3919+look*13)%8191)/6000.f-.1f;
    input[0]=0;input[1]=.0031308f;input[2]=1;
    for(auto settings:std::vector<std::pair<float,uint32_t>>{{-2.f,0u},{.7f,37u},{2.f,0xffffffffu}}) {
     const float ev=settings.first;const uint32_t seed=settings.second;
     CHECK(ffcs_process_linear_rgb(ctx.get(),input.data(),n,w,h,ev,seed,full.data(),n,
       preview.data(),preview.size(),error.data(),error.size()));
     CHECK(ffcs_process_linear_rgb(&oracle,input.data(),n,w,h,ev,seed,expected.data(),n,
       expectedPreview.data(),expectedPreview.size(),error.data(),error.size()));
     CHECK(exact(full,expected) && exact(preview,expectedPreview));
     for(size_t pixel=0;pixel<w*h;++pixel) CHECK(preview[pixel*4+3]==255);
     ++frames;
     if(grain && sharp) {
      CHECK(ffcs_process_linear_rgb(legacy.get(),input.data(),n,w,h,ev,seed,expected.data(),n,
        expectedPreview.data(),expectedPreview.size(),error.data(),error.size()));
      CHECK(exact(full,expected) && exact(preview,expectedPreview));++defaults;
     }
     for(unsigned workers:{1u,2u,3u,4u}) {
      CHECK(ffcs_process_linear_rgb_optimized(ctx.get(),input.data(),n,w,h,ev,seed,
        optimized.data(),n,optimizedPreview.data(),optimizedPreview.size(),workers,error.data(),error.size()));
      CHECK(exact(full,optimized) && exact(preview,optimizedPreview));
      // Separate output modes still honor both switches.
      CHECK(ffcs_process_linear_rgb_optimized(ctx.get(),input.data(),n,w,h,ev,seed,
        optimized.data(),n,nullptr,0,workers,error.data(),error.size()));
      CHECK(exact(full,optimized));
      CHECK(ffcs_process_linear_rgb_optimized(ctx.get(),input.data(),n,w,h,ev,seed,
        nullptr,0,optimizedPreview.data(),optimizedPreview.size(),workers,error.data(),error.size()));
      CHECK(exact(preview,optimizedPreview));
      for(size_t y=0;y<h;) {
       const size_t rows=std::min(h-y,workers==1?size_t(1):size_t(5));
       const size_t first=y?y-1:0,last=std::min(h,y+rows+1);
       const size_t ni=(last-first)*w*3,no=rows*w*3;
       std::vector<float> stripInput(input.begin()+first*w*3,input.begin()+last*w*3);
       std::vector<float> output(no+8,-7.f);
       CHECK(ffcs_process_linear_rgb_strip(ctx.get(),stripInput.data(),ni,w,h,first,last-first,
         y,rows,ev,seed,output.data()+4,no,workers,error.data(),error.size()));
       CHECK(std::memcmp(output.data()+4,full.data()+y*w*3,no*sizeof(float))==0);
       for(size_t k=0;k<4;++k) CHECK(output[k]==-7.f && output[no+4+k]==-7.f);
       ++strips;y+=rows;
      }
     }
    }
    // Encoded-double reference API and its complete nine-stage callbacks.
    std::vector<double> encodedInput(input.begin(),input.end()),actual(n),expectedEncoded(n);
    Stages actualStages,expectedStages;
    CHECK(ffcs_process_encoded_double(ctx.get(),encodedInput.data(),n,w,h,0xffffffffu,
      actual.data(),n,capture,&actualStages,error.data(),error.size()));
    CHECK(ffcs_process_encoded_double(&oracle,encodedInput.data(),n,w,h,0xffffffffu,
      expectedEncoded.data(),n,capture,&expectedStages,error.data(),error.size()));
    CHECK(exact(actual,expectedEncoded) && actualStages.size()==9);
    for(const auto &stage:expectedStages) CHECK(exact(actualStages.at(stage.first),stage.second));
    if(!grain) CHECK(exact(actualStages.at("tone_curve"),actualStages.at("film_grain")));
    if(!sharp) CHECK(exact(actualStages.at("film_grain"),actualStages.at("sharpen")));
    ++encoded;
   }
   // Color-only output ignores context switches; both-off full output at EV=0
   // matches the independently retained pointwise entry point bit for bit.
   const size_t w=37,h=11,n=w*h*3;
   std::vector<float> normalized(n),color(n/3*4),legacyColor(n/3*4),off(n);
   for(size_t i=0;i<n;++i) normalized[i]=float((i*3919+look*13)%8191)/8190.f;
   CHECK(ffcs_process_linear_rgb_color_only(ctx.get(),normalized.data(),n,w*h,
     color.data(),color.size(),error.data(),error.size()));
   CHECK(ffcs_process_linear_rgb_color_only(legacy.get(),normalized.data(),n,w*h,
     legacyColor.data(),legacyColor.size(),error.data(),error.size()));
   CHECK(exact(color,legacyColor));++colorOnly;
   if(!grain) {
    std::vector<float> otherSeed(n);
    CHECK(ffcs_process_linear_rgb(ctx.get(),normalized.data(),n,w,h,0,0,
      off.data(),n,nullptr,0,error.data(),error.size()));
    CHECK(ffcs_process_linear_rgb(ctx.get(),normalized.data(),n,w,h,0,0xffffffffu,
      otherSeed.data(),n,nullptr,0,error.data(),error.size()));
    CHECK(exact(off,otherSeed));
   }
   if(!grain && !sharp) {
    CHECK(ffcs_process_linear_rgb(ctx.get(),normalized.data(),n,w,h,0,0xffffffffu,
      off.data(),n,nullptr,0,error.data(),error.size()));
    for(size_t i=0;i<w*h;++i) {
     CHECK(std::memcmp(off.data()+i*3,color.data()+i*4,3*sizeof(float))==0);
     CHECK(color[i*4+3]==1.f);
    }
   }
   // A zero-coefficient preset cannot gain effects from enabled flags. Public
   // looks all have nonzero spatial coefficients, so use a test-owned copy.
   FFCSContext zero=*ctx;zero.look.grain=0;zero.look.sharp=0;
   CHECK(ffcs_process_linear_rgb(&zero,normalized.data(),n,w,h,0,13,off.data(),n,
     nullptr,0,error.data(),error.size()));
   for(size_t i=0;i<w*h;++i) CHECK(std::memcmp(off.data()+i*3,color.data()+i*4,3*sizeof(float))==0);
   CHECK(ffcs_process_linear_rgb_optimized(&zero,normalized.data(),n,w,h,0,13,off.data(),n,
     nullptr,0,4,error.data(),error.size()));
   for(size_t i=0;i<w*h;++i) CHECK(std::memcmp(off.data()+i*3,color.data()+i*4,3*sizeof(float))==0);
   CHECK(ffcs_process_linear_rgb_strip(&zero,normalized.data(),n,w,h,0,h,0,h,0,13,
     off.data(),n,4,error.data(),error.size()));
   for(size_t i=0;i<w*h;++i) CHECK(std::memcmp(off.data()+i*3,color.data()+i*4,3*sizeof(float))==0);
   // The same immutable context can serve concurrent mixed APIs.
   std::array<std::thread,4> threads;std::array<int,4> results{};
   std::array<std::vector<float>,4> concurrent;
   for(size_t t=0;t<4;++t) {
    concurrent[t].resize(n);
    threads[t]=std::thread([&,t] {
     if(t&1) results[t]=ffcs_process_linear_rgb_strip(ctx.get(),normalized.data(),n,w,h,
       0,h,0,h,0,37,concurrent[t].data(),n,1,nullptr,0);
     else results[t]=ffcs_process_linear_rgb_optimized(ctx.get(),normalized.data(),n,w,h,
       0,37,concurrent[t].data(),n,nullptr,0,1,nullptr,0);
    });
   }
   for(auto &thread:threads) thread.join();
   for(size_t t=0;t<4;++t) CHECK(results[t] && exact(concurrent[0],concurrent[t]));
   CHECK(ctx->grainEnabled==bool(grain) && ctx->sharpenEnabled==bool(sharp));
   CHECK(ctx->look.grain==legacy->look.grain && ctx->look.sharp==legacy->look.sharp);
   // Validate strip errors and untouched outputs for all four switch states.
   std::vector<float> guarded(n,-7.f);
   auto reject=[&](size_t first,size_t rows,size_t countIn,size_t countOut,unsigned workers) {
    const auto before=guarded;
    const int result=ffcs_process_linear_rgb_strip(ctx.get(),normalized.data(),countIn,w,h,
      first,rows,2,3,0,0,guarded.data(),countOut,workers,error.data(),error.size());
    ++invalid;return result==0 && error[0] && guarded==before;
   };
   CHECK(reject(0,h,n,n,0));CHECK(reject(0,h,n,n,5));
   CHECK(reject(0,h,n-1,n,1));CHECK(reject(0,h,n,3*w*3-1,1));
   CHECK(reject(2,h-2,n,n,1));CHECK(reject(0,5,n,n,1));
  }
  for(int bad:{-1,2,INT_MIN,INT_MAX}) for(int which:{0,1}) {
   error.fill('x');
   Context invalidContext(ffcs_create_options(argv[1],look,which?1:bad,which?bad:1,
     error.data(),error.size()),ffcs_destroy);
   CHECK(!invalidContext && error[0] && error.back()=='\0');++invalid;
  }
 }
 // Constructor boundaries: input validation precedes file I/O; the error
 // buffer accepts NULL/zero and is always terminated when space is provided.
 CHECK(!ffcs_create_options(nullptr,0,1,1,error.data(),error.size()));
 CHECK(!ffcs_create_options("",0,1,1,error.data(),error.size()));
 CHECK(!ffcs_create_options(argv[1],19,1,1,error.data(),error.size()));
 CHECK(!ffcs_create_options(argv[1],std::numeric_limits<size_t>::max(),1,1,error.data(),error.size()));
 CHECK(!ffcs_create_options(argv[1],0,-1,0,nullptr,1024));
 char tiny='x';CHECK(!ffcs_create_options(argv[1],0,0,2,&tiny,1));CHECK(tiny=='\0');
 tiny='x';CHECK(!ffcs_create_options(argv[1],0,0,2,&tiny,0));CHECK(tiny=='x');
 invalid+=7;
 ffcs_destroy(nullptr);
 std::cout<<"{\"status\":\"pass\",\"looks\":19,\"flag_combinations\":4,"
  <<"\"reference_float_cases\":"<<frames<<",\"strip_calls\":"<<strips
  <<",\"encoded_nine_stage_cases\":"<<encoded<<",\"legacy_default_cases\":"<<defaults
  <<",\"color_only_invariance_cases\":"<<colorOnly<<",\"invalid_calls\":"<<invalid
  <<",\"workers\":[1,2,3,4],\"max_float_error\":0,\"bit_exact\":true,"
  <<"\"zero_coefficients_remain_inactive\":true,\"grain_off_seed_independent\":true,\"concurrent_contexts\":true}\n";
}
