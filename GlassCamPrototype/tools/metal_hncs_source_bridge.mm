// Study-only Float32 GPU source-matrix candidate. Never linked into the app.
// The remaining native color, curves, spatial and display work stays on CPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Accelerate/Accelerate.h>
#include <chrono>
#include <mutex>
#include <stdexcept>
#define hncs_process_phocus_work_float_parallel hncs_cpu_process_phocus_work_float_parallel
#include "../core/hncs.cpp"
#undef hncs_process_phocus_work_float_parallel

namespace {
double seconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
struct MatrixParameters { float matrix[9],exposure; uint32_t count; };
struct ColorParameters {
    MatrixParameters source;
    float incoming[9],outgoing[9],shadow[4],cb0,cr0,divisor;
    uint32_t width,height;
};
static_assert(sizeof(ColorParameters)==152);
struct MetalSource {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline;
    id<MTLComputePipelineState> colorPipeline;
    id<MTLBuffer> input,output;
    id<MTLBuffer> lut,curve;
    size_t lutCapacity=0;
    size_t capacity=0;
    std::mutex mutex;
    double compile=0,copy=0,submit_wait=0,gpu=0,cpu_tail=0,calls=0,bytes=0,colorCalls=0;
    MetalSource() {
        const double start=seconds();
        device=MTLCreateSystemDefaultDevice();
        if(!device)throw std::runtime_error("No Metal device");
        queue=[device newCommandQueue];
        NSString* source=@"#include <metal_stdlib>\n"
            "using namespace metal;\n#pragma clang fp contract(off)\n"
            "struct Params { float matrix[9]; float exposure; uint count; };\n"
            "kernel void source_matrix(const device packed_float3* input [[buffer(0)]], "
            "device packed_float3* output [[buffer(1)]], constant Params& p [[buffer(2)]], "
            "uint i [[thread_position_in_grid]]) {\n"
            "if(i>=p.count)return; float3 v=float3(input[i])*p.exposure;\n"
            "output[i]=packed_float3((v.x*p.matrix[0]+v.y*p.matrix[1])+v.z*p.matrix[2],"
            "(v.x*p.matrix[3]+v.y*p.matrix[4])+v.z*p.matrix[5],"
            "(v.x*p.matrix[6]+v.y*p.matrix[7])+v.z*p.matrix[8]); }\n"
            "struct ColorParams { Params source; float incoming[9]; float outgoing[9]; float shadow[4]; "
            "float cb0; float cr0; float divisor; uint width; uint height; };\n"
            "kernel void native_color(const device packed_float3* input [[buffer(0)]], device packed_float3* output [[buffer(1)]], "
            "constant ColorParams& p [[buffer(2)]], const device float2* lut [[buffer(3)]], const device ushort* film [[buffer(4)]], "
            "uint i [[thread_position_in_grid]]) { if(i>=p.source.count)return;\n"
            "float3 v=float3(input[i])*p.source.exposure;\n"
            "float3 rgb=float3((v.x*p.source.matrix[0]+v.y*p.source.matrix[1])+v.z*p.source.matrix[2],"
            "(v.x*p.source.matrix[3]+v.y*p.source.matrix[4])+v.z*p.source.matrix[5],"
            "(v.x*p.source.matrix[6]+v.y*p.source.matrix[7])+v.z*p.source.matrix[8]);\n"
            "rgb=rint(clamp(rgb,0.0f,1.0f)*65535.0f);\n"
            "float y=(p.incoming[0]*rgb.x+p.incoming[1]*rgb.y)+p.incoming[2]*rgb.z;\n"
            "float u=(p.incoming[3]*rgb.x+p.incoming[4]*rgb.y)+p.incoming[5]*rgb.z;\n"
            "float w=(p.incoming[6]*rgb.x+p.incoming[7]*rgb.y)+p.incoming[8]*rgb.z;\n"
            "float x=clamp((y>0.0f?u/y:0.0f)*p.divisor-p.cb0,0.0f,float(p.width-1));\n"
            "float z=clamp((y>0.0f?w/y:0.0f)*p.divisor-p.cr0,0.0f,float(p.height-1));\n"
            "uint x0=uint(floor(x)),z0=uint(floor(z)),x1=min(x0+1,p.width-1),z1=min(z0+1,p.height-1);\n"
            "float fx=x-float(x0),fy=z-float(z0);\n"
            "float2 mapped=((lut[z0*p.width+x0]*(1.0f-fy)+lut[z1*p.width+x0]*fy)*(1.0f-fx)+"
            "(lut[z0*p.width+x1]*(1.0f-fy)+lut[z1*p.width+x1]*fy)*fx)/p.divisor;\n"
            "float shadow=y<=p.shadow[0]?((p.shadow[1]*y)*y+p.shadow[2]*y)+p.shadow[3]:1.0f;\n"
            "float cb=(y*clamp(shadow,0.0f,1.0f))*mapped.x,cr=(y*clamp(shadow,0.0f,1.0f))*mapped.y;\n"
            "float3 codes; for(uint c=0;c<3;c++){ float linear=y>0.0f?y+(cb*p.outgoing[c*3+1]+cr*p.outgoing[c*3+2]):0.0f; "
            "codes[c]=float(film[uint(clamp(linear,0.0f,65535.0f))]); } output[i]=packed_float3(codes); }\n";
        MTLCompileOptions* options=[MTLCompileOptions new];
        options.fastMathEnabled=NO;
        NSError* error=nil;
        id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
        if(!library)throw std::runtime_error([[error description] UTF8String]);
        pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"source_matrix"] error:&error];
        if(!pipeline)throw std::runtime_error([[error description] UTF8String]);
        colorPipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"native_color"] error:&error];
        if(!colorPipeline)throw std::runtime_error([[error description] UTF8String]);
        compile=seconds()-start;
    }
};
MetalSource& metalSource(){static MetalSource value;return value;}
int finish_native_matrix(const hncs_context* context,const float* input,float* output,size_t count) {
    for(size_t i=0;i<count;++i) {
        const V p={double(input[3*i]),double(input[3*i+1]),double(input[3*i+2])};
        if(!finite(p))return -1;
        const F work=phocus_work(context->preset,context->preset_tone,context->render(p));
        for(int ch=0;ch<3;++ch)output[3*i+ch]=work[ch];
    }
    return 0;
}
int finish_native_color(const hncs_context* context,const float* input,float* output,size_t count) {
    for(size_t i=0;i<count;++i) {
        const Codes codes={uint16_t(input[3*i]),uint16_t(input[3*i+1]),uint16_t(input[3*i+2])};
        const F work=phocus_work(context->preset,context->preset_tone,codes);
        for(int ch=0;ch<3;++ch)output[3*i+ch]=work[ch];
    }
    return 0;
}
}
static int gpu_work(const hncs_context* context,const float* input,float* output,size_t count,unsigned workers,bool color) {
    if(!context||(!input&&count)||(!output&&count)||workers<1||workers>4||count>UINT32_MAX)return -1;
    if(!count)return 0;
    for(size_t i=0;i<count*3;++i)if(!std::isfinite(input[i]))return -1;
    try {
        @autoreleasepool {
            auto& state=metalSource();std::lock_guard<std::mutex> lock(state.mutex);
            const size_t bytes=count*3*sizeof(float);
            if(state.capacity<bytes) {
                state.input=[state.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
                state.output=[state.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
                if(!state.input||!state.output)return -1;
                state.capacity=bytes;
            }
            MatrixParameters params{};params.exposure=float(context->exposure);params.count=uint32_t(count);
            for(int i=0;i<9;++i)params.matrix[i]=float(context->source_to_native[i]);
            double start=seconds();std::memcpy(state.input.contents,input,bytes);state.copy+=seconds()-start;
            ColorParameters colorParams{};
            if(color) {
                if(context->reproduction||assets::gray_thresholds[0]>assets::gray_thresholds[1])return -1;
                colorParams.source=params;
                for(unsigned k=0;k<9;++k){colorParams.incoming[k]=float(context->incoming[k]);colorParams.outgoing[k]=float(context->outgoing[k]);}
                colorParams.shadow[0]=float(context->shadow_threshold);colorParams.shadow[1]=float(context->shadow_a);
                colorParams.shadow[2]=float(context->shadow_b);colorParams.shadow[3]=float(context->shadow_d);
                colorParams.cb0=float(context->cb0);colorParams.cr0=float(context->cr0);colorParams.divisor=float(assets::grid[4]);
                colorParams.width=uint32_t(context->width);colorParams.height=uint32_t(context->height);
                const size_t lutBytes=context->lut.size()*sizeof(float);
                if(state.lutCapacity<lutBytes){state.lut=[state.device newBufferWithLength:lutBytes options:MTLResourceStorageModeShared];state.lutCapacity=lutBytes;}
                if(!state.curve)state.curve=[state.device newBufferWithLength:65536*sizeof(uint16_t) options:MTLResourceStorageModeShared];
                if(!state.lut||!state.curve)return -1;
                start=seconds();
                auto* lutValues=static_cast<float*>(state.lut.contents);
                for(size_t k=0;k<context->lut.size();++k)lutValues[k]=float(context->lut[k]);
                std::memcpy(state.curve.contents,context->curve,65536*sizeof(uint16_t));
                state.copy+=seconds()-start;state.bytes+=double(lutBytes+65536*sizeof(uint16_t));
            }
            start=seconds();
            id<MTLCommandBuffer> command=[state.queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
            [encoder setComputePipelineState:color?state.colorPipeline:state.pipeline];
            [encoder setBuffer:state.input offset:0 atIndex:0];[encoder setBuffer:state.output offset:0 atIndex:1];
            if(color) {
                [encoder setBytes:&colorParams length:sizeof(colorParams) atIndex:2];
                [encoder setBuffer:state.lut offset:0 atIndex:3];[encoder setBuffer:state.curve offset:0 atIndex:4];
            }else [encoder setBytes:&params length:sizeof(params) atIndex:2];
            [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256,state.pipeline.maxTotalThreadsPerThreadgroup),1,1)];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];
            state.submit_wait+=seconds()-start;
            if(command.status!=MTLCommandBufferStatusCompleted)return -1;
            state.gpu+=command.GPUEndTime-command.GPUStartTime;
            start=seconds();
            const int status=parallel_float(context,static_cast<const float*>(state.output.contents),output,count,workers,3,color?finish_native_color:finish_native_matrix);
            state.cpu_tail+=seconds()-start;state.calls+=1;state.bytes+=double(bytes);if(color)state.colorCalls+=1;
            return status;
        }
    }catch(const std::exception& error){std::fprintf(stderr,"Metal source candidate: %s\n",error.what());return -1;}
    catch(...){return -1;}
}
static std::atomic<int> selectedBackend{1};
extern "C" void color_study_select_backend(int backend){selectedBackend.store(backend);}
extern "C" int hncs_process_phocus_work_float_parallel(const hncs_context* context,const float* input,float* output,size_t count,unsigned workers) {
    if(selectedBackend.load()==0)return hncs_cpu_process_phocus_work_float_parallel(context,input,output,count,workers);
    return gpu_work(context,input,output,count,workers,selectedBackend.load()==2);
}
extern "C" int hncs_study_metal_color_work(const hncs_context* context,const float* input,float* output,size_t count,unsigned workers) {
    return gpu_work(context,input,output,count,workers,true);
}
extern "C" int metal_study_stats(double* output,size_t count) {
    if(!output||count<9)return -1;
    try {
        auto& s=metalSource();std::lock_guard<std::mutex> lock(s.mutex);
        const double values[]={s.compile,s.copy,s.submit_wait,s.gpu,s.cpu_tail,s.calls,s.bytes,double(s.capacity*2+s.lutCapacity+(s.curve?65536*sizeof(uint16_t):0)),double(s.device.hasUnifiedMemory)};
        std::copy(std::begin(values),std::end(values),output);if(count>=10)output[9]=s.colorCalls;return 0;
    }catch(...){return -1;}
}
extern "C" const char* metal_study_device() {
    try{return metalSource().device.name.UTF8String;}catch(...){return "unavailable";}
}
extern "C" int hncs_study_finish_native_matrix(const hncs_context* context,const float* input,
                                                float* output,size_t count,unsigned workers) {
    return parallel_float(context,input,output,count,workers,3,finish_native_matrix);
}
extern "C" int hncs_study_accelerate_work(const hncs_context* context,const float* input,
                                           float* output,size_t count,unsigned workers) {
    if(!context||!input||!output||workers<1||workers>4||count>INT_MAX)return -1;
    try {
        std::vector<double> source(count*3),native(count*3);
        vDSP_vspdp(input,1,source.data(),1,count*3);
        vDSP_vsmulD(source.data(),1,&context->exposure,source.data(),1,count*3);
        cblas_dgemm(CblasRowMajor,CblasNoTrans,CblasTrans,int(count),3,3,1.,source.data(),3,
                    context->source_to_native.data(),3,0.,native.data(),3);
        struct Work {const hncs_context* context;const double* input;float* output;size_t count;unsigned workers;};
        Work work{context,native.data(),output,count,workers};
        dispatch_apply_f(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&work,[](void* opaque,size_t index) {
            auto& job=*static_cast<Work*>(opaque);
            for(size_t i=job.count*index/job.workers;i<job.count*(index+1)/job.workers;++i) {
                const V p={job.input[3*i],job.input[3*i+1],job.input[3*i+2]};
                const F value=phocus_work(job.context->preset,job.context->preset_tone,job.context->render(p));
                for(int c=0;c<3;++c)job.output[3*i+c]=value[c];
            }
        });
        return 0;
    }catch(...){return -1;}
}
