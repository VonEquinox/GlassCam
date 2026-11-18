// Registration adapted from Jamy Lafenetre, Copyright (c) 2023.
// MIT license and source identity: vendor/handheld-sr/{LICENSE,ORIGIN.md}.
#include "f5_curvature.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <stdexcept>
#include <vector>

namespace {
struct Failure { int status; const char *message; };
void check(bool ok, int status, const char *message) { if (!ok) throw Failure{status,message}; }
void record(gc_f5_curve_error *error, int status, const char *message) {
    if (error) { error->status=status; error->system_error=0; std::snprintf(error->message,sizeof(error->message),"%s",message); }
}
struct Parameters { simd_uint4 image, level, grid, previous; simd_float4 control; };
struct FFTParameters { simd_uint4 shape, stage; };
static_assert(sizeof(Parameters)==80 && sizeof(FFTParameters)==32);
enum Kernel { fftLoad, fftStage, fftBand, grayStore, gaussianV, gaussianH, upscale, blockMatch, inverseCompositional,
              localStats, robustness, localMinimum, identity, summary, kernelCount };
constexpr const char *names[] = {"f5_reg_fft_load","f5_reg_fft_stage","f5_reg_fft_band","f5_reg_gray_store",
    "f5_reg_gaussian_v","f5_reg_gaussian_h","f5_reg_upscale","f5_reg_block_match","f5_reg_ic",
    "f5_reg_local_stats","f5_reg_robustness","f5_reg_local_min","f5_reg_identity","f5_reg_summary"};
struct Level { uint32_t width,height; id<MTLBuffer> pixels; };
}

struct gc_f5_curve_registration {
    gc_f5_curve_registration_config config;
    id<MTLDevice> device; id<MTLCommandQueue> queue;
    std::array<id<MTLComputePipelineState>,kernelCount> pipelines;
    id<MTLBuffer> raw,kinds,flow,reliability,summaries;
    id<MTLBuffer> fft[2], gaussian, workFlow[2], referenceMean,referenceVariance,movingMean,robust,noiseLUT;
    std::vector<Level> reference,moving;
    uint64_t allocated=0;
    bool ran=false;
    uint32_t columns,rows;

    id<MTLBuffer> allocate(size_t bytes, NSString *label, bool shared=false) {
        check(bytes && bytes<=device.maxBufferLength && bytes<=config.maximum_bytes-allocated,2,"Bayer registration exceeds the working-set budget.");
        auto buffer=[device newBufferWithLength:bytes options:shared?MTLResourceStorageModeShared:MTLResourceStorageModePrivate];
        check(buffer!=nil,2,"Cannot allocate Bayer registration workspace."); buffer.label=label; allocated+=buffer.length; return buffer;
    }
    void release(__strong id<MTLBuffer> &buffer) { allocated-=buffer.length; buffer=nil; }
    gc_f5_curve_registration(const gc_f5_curve_registration_config &c,void *d,void *l,void *r,void *k):config(c) {
        check(c.width>=4 && c.height>=4 && c.width<=16384 && c.height<=16384 && !(c.width%2) && !(c.height%2) &&
              c.frames>=1 && c.frames<=7,1,"Invalid Bayer registration dimensions.");
        device=(__bridge id<MTLDevice>)d; id<MTLLibrary> library=(__bridge id<MTLLibrary>)l;
        raw=(__bridge id<MTLBuffer>)r; kinds=(__bridge id<MTLBuffer>)k;
        check(device && library && raw && kinds && raw.device==device && kinds.device==device &&
              raw.length>=size_t(c.width)*c.height*c.frames*4 && kinds.length>=size_t(c.width)*c.height*c.frames,
              1,"Incomplete Bayer registration inputs.");
        for(unsigned p=0;p<4;++p)check(c.cfa[p]<3 && std::isfinite(c.alpha[p]) && c.alpha[p]>=0 && std::isfinite(c.beta[p]) && c.beta[p]>0,
                                      1,"Invalid Bayer registration noise model.");
        queue=[device newCommandQueue]; check(queue!=nil,2,"Cannot create Bayer registration queue.");
        for(unsigned i=0;i<kernelCount;++i) {
            if(c.frames==1 && i!=identity && i!=summary)continue;
            auto function=[library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
            check(function!=nil,2,"A Bayer registration Metal function is missing.");
            NSError *error=nil; pipelines[i]=[device newComputePipelineStateWithFunction:function error:&error];
            check(pipelines[i] && pipelines[i].maxTotalThreadsPerThreadgroup>=256,2,"Cannot create Bayer registration pipeline.");
        }
        columns=(c.width+15)/16;rows=(c.height+15)/16;
        flow=allocate(size_t(columns)*rows*c.frames*8,@"Bayer reference-to-source tile flow",true);
        reliability=allocate(size_t(c.width/2)*(c.height/2)*c.frames*4,@"Bayer photometric reliability",true);
        summaries=allocate(size_t((c.width+31)/32)*((c.height+31)/32)*c.frames*16,@"Bayer support and censor summaries",true);
        if(c.frames==1)return;
        const size_t pixels=size_t(c.width)*c.height, half=pixels/4;
        fft[0]=allocate(pixels*8,@"Bayer FFT ping"); fft[1]=allocate(pixels*8,@"Bayer FFT pong");
        const auto levels=[&](bool padded) {
            std::vector<Level> result; uint32_t w=padded?columns*16:c.width,h=padded?rows*16:c.height;
            result.push_back({w,h,allocate(size_t(w)*h*4,@"Bayer grayscale pyramid")});
            for(unsigned i=1;i<4;++i) {
                const unsigned factor=i==1?2:4, radius=factor*2;
                if(w<=radius*2 || h<=radius*2)break;
                const unsigned nextW=(w-radius*2)/factor,nextH=(h-radius*2)/factor;
                if(nextW<16 || nextH<16)break;
                w=nextW;h=nextH;result.push_back({w,h,allocate(size_t(w)*h*4,@"Bayer coarse pyramid")});
            }
            return result;
        };
        reference=levels(true);moving=levels(false);
        while(reference.size()>moving.size()) { release(reference.back().pixels);reference.pop_back(); }
        while(moving.size()>reference.size()) { release(moving.back().pixels);moving.pop_back(); }
        gaussian=allocate(size_t(reference[0].width)*reference[0].height*4,@"Bayer separable Gaussian rows");
        workFlow[0]=allocate(size_t(columns)*rows*8,@"Bayer coarse flow ping"); workFlow[1]=allocate(workFlow[0].length,@"Bayer coarse flow pong");
        referenceMean=allocate(half*16,@"Bayer reference RGB means"); referenceVariance=allocate(half*16,@"Bayer reference RGB variances");
        movingMean=allocate(half*16,@"Bayer comparison RGB means"); robust=allocate(half*4,@"Bayer reliability before local minimum");
        noiseLUT=allocate(512*16,@"Bayer square-root noise moments",true);
        auto *table=static_cast<simd_float4 *>(noiseLUT.contents);
        double alpha[3]={},beta[3]={}; unsigned count[3]={};
        for(unsigned p=0;p<4;++p){unsigned channel=c.cfa[p];alpha[channel]+=c.alpha[p];beta[channel]+=c.beta[p];++count[channel];}
        check(count[0]==1 && count[1]==2 && count[2]==1,1,"Registration requires a Bayer color pattern.");
        for(unsigned channel=0;channel<3;++channel){alpha[channel]/=double(count[channel])*count[channel];beta[channel]/=double(count[channel])*count[channel];}
        for(unsigned bin=0;bin<512;++bin) {
            const double signal=std::pow(double(bin)/511,2); double total=0;
            for(unsigned channel=0;channel<3;++channel) {
                const double sigma=std::sqrt(alpha[channel]*signal+beta[channel]); double mass=0,mean=0,second=0;
                for(int j=-64;j<=64;++j) {
                    const double z=j*.125,weight=std::exp(-.5*z*z),sample=std::clamp(signal+sigma*z,0.0,1.0);
                    mass+=weight;mean+=weight*std::sqrt(sample);second+=weight*sample;
                }
                mean/=mass;total+=std::max(0.0,second/mass-mean*mean);
            }
            table[bin]={float(total*8/9),float(total*2/9),0,0};
        }
    }
    void dispatch(id<MTLCommandBuffer> command,Kernel kernel,size_t groups,size_t threads,std::initializer_list<id<MTLBuffer>> buffers,
                  const void *parameters,size_t bytes,const float *weights=nullptr) {
        auto encoder=[command computeCommandEncoder];check(encoder!=nil,2,"Cannot encode Bayer registration.");
        encoder.label=[NSString stringWithUTF8String:names[kernel]];[encoder setComputePipelineState:pipelines[kernel]];
        unsigned index=0;for(auto buffer:buffers)[encoder setBuffer:buffer offset:0 atIndex:index++];
        [encoder setBytes:parameters length:bytes atIndex:index++]; if(weights)[encoder setBytes:weights length:17*4 atIndex:index];
        [encoder dispatchThreadgroups:MTLSizeMake(groups,1,1) threadsPerThreadgroup:MTLSizeMake(threads,1,1)];[encoder endEncoding];
    }
    void wait(id<MTLCommandBuffer> command) {
        check(command!=nil,2,"Cannot create Bayer registration command.");[command commit];[command waitUntilCompleted];
        check(command.status==MTLCommandBufferStatusCompleted,3,"Bayer registration GPU command failed.");
    }
    id<MTLBuffer> fft2(id<MTLCommandBuffer> command,bool inverse,id<MTLBuffer> input) {
        unsigned next=input==fft[0]?1:0;
        for(unsigned axis=0;axis<2;++axis) {
            unsigned length=axis?config.height:config.width,remaining=length,product=1;
            for(unsigned radix: {2u,3u,5u,7u})while(remaining%radix==0) {
                FFTParameters p{{config.width,config.height,axis,inverse?1u:0u},{length,radix,product,0}};
                dispatch(command,fftStage,(size_t(config.width)*config.height+255)/256,256,{input,fft[next]},&p,sizeof(p));
                input=fft[next];next^=1;product*=radix;remaining/=radix;
            }
            check(remaining==1,1,"Bayer FFT dimensions contain an unsupported prime factor.");
        }
        return input;
    }
    void pyramid(unsigned frame,std::vector<Level> &levels) {
        auto command=[queue commandBuffer];check(command!=nil,2,"Cannot create Bayer grayscale command.");
        FFTParameters fp{{config.width,config.height,frame,0},{}};
        dispatch(command,fftLoad,(size_t(config.width)*config.height+255)/256,256,{raw,fft[0]},&fp,sizeof(fp));
        auto transformed=fft2(command,false,fft[0]);
        dispatch(command,fftBand,(size_t(config.width)*config.height+255)/256,256,{transformed},&fp,sizeof(fp));
        transformed=fft2(command,true,transformed);
        Parameters p{{config.width,config.height,frame,config.frames},{levels[0].width,levels[0].height,0,0},{},{},{}};
        dispatch(command,grayStore,(size_t(levels[0].width)*levels[0].height+255)/256,256,{transformed,levels[0].pixels},&p,sizeof(p));
        for(unsigned i=1;i<levels.size();++i) {
            const unsigned factor=i==1?2:4,radius=factor*2; float weights[17]={}; double mass=0;
            for(unsigned j=0;j<=radius*2;++j){const double z=(int(j)-int(radius))/(factor*.5);mass+=std::exp(-.5*z*z);}
            for(unsigned j=0;j<=radius*2;++j){const double z=(int(j)-int(radius))/(factor*.5);weights[j]=float(std::exp(-.5*z*z)/mass);}
            const auto &previous=levels[i-1];p.level={levels[i].width,levels[i].height,previous.width,previous.height};p.previous={factor,radius,0,0};
            dispatch(command,gaussianV,(size_t(previous.width)*(previous.height-radius*2)+255)/256,256,{previous.pixels,gaussian},&p,sizeof(p),weights);
            dispatch(command,gaussianH,(size_t(levels[i].width)*levels[i].height+255)/256,256,{gaussian,levels[i].pixels},&p,sizeof(p),weights);
        }
        wait(command);
    }
    void run(const gc_f5_curve_callbacks *callbacks) {
        check(!ran,1,"Bayer registration contexts are single-use.");
        // Cancellation or failure can leave released or partially written
        // workspace. A fresh context is required for every attempt.
        ran=true;
        const auto cancelled=[&]{if(callbacks && callbacks->cancelled && callbacks->cancelled(callbacks->context))throw Failure{4,"Bayer registration cancelled."};};
        cancelled(); Parameters p{{config.width,config.height,0,config.frames},{},{columns,rows,16,0},{},{}};
        auto command=[queue commandBuffer];check(command!=nil,2,"Cannot initialize Bayer motion.");
        auto blit=[command blitCommandEncoder];check(blit!=nil,2,"Cannot initialize Bayer motion.");
        [blit fillBuffer:flow range:NSMakeRange(0,flow.length) value:0];[blit endEncoding];
        dispatch(command,identity,(size_t(config.width/2)*(config.height/2)*config.frames+255)/256,256,{reliability},&p,sizeof(p));wait(command);
        if(config.frames>1) {
            pyramid(0,reference);cancelled();
            command=[queue commandBuffer];p.control.w=1;std::memcpy(&p.previous,config.cfa,16);
            dispatch(command,localStats,(size_t(config.width/2)*(config.height/2)+255)/256,256,{raw,referenceMean,referenceVariance},&p,sizeof(p));wait(command);
            for(unsigned f=1;f<config.frames;++f) {
                @autoreleasepool {
                    cancelled();pyramid(f,moving);cancelled();
                    command=[queue commandBuffer];check(command!=nil,2,"Cannot encode Bayer local motion.");
                    blit=[command blitCommandEncoder];check(blit!=nil,2,"Cannot initialize Bayer coarse motion.");
                    [blit fillBuffer:workFlow[0] range:NSMakeRange(0,workFlow[0].length) value:0];[blit endEncoding];
                    unsigned current=0; uint32_t oldColumns=0,oldRows=0,oldTile=0;
                    for(int level=int(reference.size())-1;level>=0;--level) {
                        const auto &ref=reference[level],&mov=moving[level];
                        const unsigned tile=reference.size()==4 && level==3?8:16,cols=ref.width/tile,rs=ref.height/tile;
                        const unsigned radius=level==0 && reference.size()>1?1:4;
                        p.image.z=f;p.level={ref.width,ref.height,mov.width,mov.height};p.grid={cols,rs,tile,radius};
                        p.control={level==0?1.0f:2.0f,3,0,0};
                        if(oldColumns) {
                            const unsigned factor=level==0?2:4,repeat=factor*oldTile/tile;
                            p.previous={oldColumns,oldRows,factor,repeat};
                            dispatch(command,upscale,(size_t(cols)*rs+255)/256,256,{workFlow[current],workFlow[current^1]},&p,sizeof(p));current^=1;
                        }
                        dispatch(command,blockMatch,size_t(cols)*rs,256,{ref.pixels,mov.pixels,workFlow[current]},&p,sizeof(p));
                        dispatch(command,inverseCompositional,size_t(cols)*rs,256,{ref.pixels,mov.pixels,workFlow[current]},&p,sizeof(p));
                        oldColumns=cols;oldRows=rs;oldTile=tile;
                    }
                    blit=[command blitCommandEncoder];check(blit!=nil,2,"Cannot retain Bayer motion.");
                    [blit copyFromBuffer:workFlow[current] sourceOffset:0 toBuffer:flow destinationOffset:size_t(f)*columns*rows*8 size:size_t(columns)*rows*8];[blit endEncoding];
                    p.grid={columns,rows,16,0};p.control.w=0;std::memcpy(&p.previous,config.cfa,16);
                    dispatch(command,localStats,(size_t(config.width/2)*(config.height/2)+255)/256,256,{raw,movingMean,referenceVariance},&p,sizeof(p));
                    simd_uint4 cfa;std::memcpy(&cfa,config.cfa,16);p.previous=cfa;
                    dispatch(command,robustness,(size_t(config.width/2)*(config.height/2)+255)/256,256,
                             {referenceMean,referenceVariance,movingMean,flow,noiseLUT,robust},&p,sizeof(p));
                    dispatch(command,localMinimum,(size_t(config.width/2)*(config.height/2)+255)/256,256,{robust,reliability},&p,sizeof(p));wait(command);
                    if(callbacks && callbacks->progress)callbacks->progress(callbacks->context,double(f)/config.frames);
                }
            }
            for(auto &level:reference)release(level.pixels);reference.clear();for(auto &level:moving)release(level.pixels);moving.clear();
            release(fft[0]);release(fft[1]);release(gaussian);release(workFlow[0]);release(workFlow[1]);
            release(referenceMean);release(referenceVariance);release(movingMean);release(robust);release(noiseLUT);
        }
        cancelled();command=[queue commandBuffer];p.image.z=0;p.grid={(config.width+31)/32,(config.height+31)/32,32,0};
        dispatch(command,summary,size_t(p.grid.x)*p.grid.y*config.frames,256,{reliability,kinds,summaries},&p,sizeof(p));wait(command);
        cancelled();raw=nil;kinds=nil;if(callbacks && callbacks->progress)callbacks->progress(callbacks->context,1);
    }
};
extern "C" gc_f5_curve_registration *gc_f5_curve_registration_create(const gc_f5_curve_registration_config *c,void *d,void *l,void *r,void *k,gc_f5_curve_error *error) {
    if(error)*error={};try{@autoreleasepool{check(c!=nullptr,1,"Missing Bayer registration configuration.");return new gc_f5_curve_registration(*c,d,l,r,k);}}
    catch(const Failure &e){record(error,e.status,e.message);}catch(const std::bad_alloc &){record(error,2,"Cannot allocate Bayer registration.");}
    catch(const std::exception &e){record(error,1,e.what());}return nullptr;
}
extern "C" void gc_f5_curve_registration_destroy(gc_f5_curve_registration *c){delete c;}
extern "C" uint64_t gc_f5_curve_registration_allocated_bytes(const gc_f5_curve_registration *c){return c?c->allocated:0;}
extern "C" int32_t gc_f5_curve_registration_run(gc_f5_curve_registration *c,const gc_f5_curve_callbacks *callbacks,gc_f5_curve_error *error){
    if(error)*error={};try{@autoreleasepool{check(c!=nullptr,1,"Missing Bayer registration context.");c->run(callbacks);return 0;}}
    catch(const Failure &e){record(error,e.status,e.message);return e.status;}catch(const std::bad_alloc &){record(error,2,"Cannot allocate Bayer registration metadata.");return 2;}
    catch(const std::exception &e){record(error,1,e.what());return 1;}
}
extern "C" void *gc_f5_curve_registration_flow(gc_f5_curve_registration *c){return c?(__bridge void *)c->flow:nullptr;}
extern "C" void *gc_f5_curve_registration_reliability(gc_f5_curve_registration *c){return c?(__bridge void *)c->reliability:nullptr;}
extern "C" void *gc_f5_curve_registration_summary(gc_f5_curve_registration *c){return c?(__bridge void *)c->summaries:nullptr;}
