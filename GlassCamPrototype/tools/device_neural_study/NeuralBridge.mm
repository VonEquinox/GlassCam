// Isolated research build only. The production hncs.cpp file is not modified.
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <Metal/Metal.h>
#import <os/signpost.h>
#include <chrono>
#include <mutex>
#define hncs_process_phocus_work_float_parallel hncs_cpu_process_phocus_work_float_parallel
#include "../../core/hncs.cpp"
#undef hncs_process_phocus_work_float_parallel

namespace {
double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
thread_local std::string resultJSON;
std::string lastError;
std::mutex stateMutex;
const char *json(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    resultJSON = data ? std::string((const char *)data.bytes, data.length) : "{}";
    return resultJSON.c_str();
}
struct Metrics { double pack=0, predict=0, unpack=0, gpu=0, tail=0, calls=0, uploaded=0; };
struct State {
    int backend=0, units=0;
    Metrics metrics;
    NSString *name=@"cpu";
    MLModel *model=nil;
    MLMultiArray *input=nil;
    MLDictionaryFeatureProvider *provider=nil;
    NSMutableDictionary<NSString*,NSURL*> *compiled=[NSMutableDictionary new];
    id<MTLDevice> device=nil;
    id<MTLCommandQueue> queue=nil;
    NSArray<id<MTLComputePipelineState>> *pipelines=nil;
    id<MTLBuffer> a=nil,b=nil,c=nil;
    size_t capacity=0;
    bool checkContext=false;
    double expectedMatrix[9]={}, expectedExposure=1, contextDelta=0;
    std::vector<float> native;
    os_log_t log=os_log_create("dev.glasscam.neuralstudy", "Execution");
};
State &state() { static State value; return value; }

NSArray *describePlan(MLComputePlan *plan) {
    NSMutableArray *rows=[NSMutableArray new];
    for (MLModelStructureProgramFunction *function in plan.modelStructure.program.functions.allValues) {
        for (MLModelStructureProgramOperation *operation in function.block.operations) {
            MLComputePlanDeviceUsage *usage=[plan computeDeviceUsageForMLProgramOperation:operation];
            NSMutableArray *supported=[NSMutableArray new];
            for (id device in usage.supportedComputeDevices) [supported addObject:NSStringFromClass([device class])];
            [rows addObject:@{@"operation":operation.operatorName ?: @"", @"preferred":usage ? NSStringFromClass([usage.preferredComputeDevice class]) : @"none",
                             @"supported":supported}];
        }
    }
    return rows;
}
void require(bool value, NSString *message) {
    if (!value) throw std::runtime_error(message.UTF8String ?: "Neural study failure");
}
MLComputeUnits computeUnits(int value) {
    switch(value) {
        case 0: return MLComputeUnitsCPUOnly;
        case 1: return MLComputeUnitsCPUAndNeuralEngine;
        case 2: return MLComputeUnitsCPUAndGPU;
        default: return MLComputeUnitsAll;
    }
}
void prepareGPU(State &s, NSString *root) {
    if (s.pipelines) return;
    s.device=MTLCreateSystemDefaultDevice(); require(s.device!=nil,@"Metal unavailable");
    s.queue=[s.device newCommandQueue];
    NSError *error=nil;
    id<MTLLibrary> library=[s.device newLibraryWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Neural.metallib"]] error:&error];
    require(library!=nil,error.description);
    NSMutableArray *pipelines=[NSMutableArray new];
    for (NSString *name in @[@"source_scalar",@"source_tensor_fp32",@"source_tensor_fp16",@"source_tensor8_fp32",@"source_tensor8_fp16"]) {
        id<MTLComputePipelineState> pipeline=[s.device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
        require(pipeline!=nil,error.description); [pipelines addObject:pipeline];
    }
    s.pipelines=pipelines;
}
const float *coreMLMatrix(State &s, const float *input, size_t count) {
    const size_t channels=s.input.shape[1].unsignedLongLongValue;
    require(channels>=3 && s.input.count==count*channels,@"Model input shape does not match the source strip");
    require(s.input.dataType==MLMultiArrayDataTypeFloat32,@"Expected Float32 model input");
    double start=now();
    float *destination=(float *)s.input.dataPointer;
    const size_t h=s.input.shape[2].unsignedLongLongValue,w=s.input.shape[3].unsignedLongLongValue;
    const size_t cs=s.input.strides[1].unsignedLongLongValue,ys=s.input.strides[2].unsignedLongLongValue,xs=s.input.strides[3].unsignedLongLongValue;
    if(channels>3)std::memset(destination,0,s.input.count*sizeof(float));
    for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x)for(size_t channel=0;channel<3;++channel)
        destination[channel*cs+y*ys+x*xs]=input[(y*w+x)*3+channel];
    s.metrics.pack+=now()-start;
    NSError *error=nil;
    const os_signpost_id_t ident=os_signpost_id_generate(s.log);
    os_signpost_interval_begin(s.log,ident,"CoreMLSourceMatrix","%{public}s",s.name.UTF8String);
    start=now();
    id<MLFeatureProvider> result=[s.model predictionFromFeatures:s.provider error:&error];
    s.metrics.predict+=now()-start;
    os_signpost_interval_end(s.log,ident,"CoreMLSourceMatrix");
    require(result!=nil,error.description);
    MLMultiArray *array=[result featureValueForName:result.featureNames.allObjects.firstObject].multiArrayValue;
    require(array.count==count*channels && array.shape.count==4,@"Unexpected model output shape");
    start=now(); s.native.resize(count*3);
    const size_t oc=array.strides[1].unsignedLongLongValue,oy=array.strides[2].unsignedLongLongValue,ox=array.strides[3].unsignedLongLongValue;
    // Read Objective-C properties once, outside the per-channel loop.
    const auto type=array.dataType; const void *pointer=array.dataPointer;
    if(type==MLMultiArrayDataTypeFloat32) {
        const float *source=(const float*)pointer;
        for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x)for(size_t channel=0;channel<3;++channel)
            s.native[(y*w+x)*3+channel]=source[channel*oc+y*oy+x*ox];
    } else if(type==MLMultiArrayDataTypeFloat16) {
        const _Float16 *source=(const _Float16*)pointer;
        for(size_t y=0;y<h;++y)for(size_t x=0;x<w;++x)for(size_t channel=0;channel<3;++channel)
            s.native[(y*w+x)*3+channel]=float(source[channel*oc+y*oy+x*ox]);
    } else throw std::runtime_error("Unsupported model output type");
    s.metrics.unpack+=now()-start;
    return s.native.data();
}
const float *gpuMatrix(State &s,const hncs_context *context,const float *input,size_t count) {
    const size_t bytes=count*3*sizeof(float);
    if(s.capacity<bytes) {
        s.a=[s.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        s.b=[s.device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        s.c=[s.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        require(s.a&&s.b&&s.c,@"GPU buffer allocation failed"); s.capacity=bytes;
        s.a.label=@"Source RGB tensor"; s.b.label=@"Source matrix weights"; s.c.label=@"Native RGB tensor";
    }
    double start=now();
    const bool half=s.backend==4||s.backend==6;
    void *inputPointer=s.a.contents,*weightPointer=s.b.contents,*outputPointer=s.c.contents;
    for(size_t i=0;i<count*3;++i) {
        if(half)((_Float16*)inputPointer)[i]=(_Float16)((_Float16)input[i]*(_Float16)context->exposure);
        else ((float*)inputPointer)[i]=input[i]*float(context->exposure);
    }
    for(int row=0;row<3;++row)for(int col=0;col<3;++col) {
        if(half)((_Float16*)weightPointer)[row*3+col]=(_Float16)context->source_to_native[col*3+row];
        else ((float*)weightPointer)[row*3+col]=float(context->source_to_native[col*3+row]);
    }
    std::memset(outputPointer,0,bytes);
    s.metrics.pack+=now()-start; s.metrics.uploaded+=double(half?bytes/2:bytes);
    struct { uint32_t m,n,k; } dimensions{uint32_t(count),3,3};
    const NSUInteger index=NSUInteger(s.backend-2);
    id<MTLComputePipelineState> pipeline=s.pipelines[index];
    start=now();
    id<MTLCommandBuffer> command=[s.queue commandBuffer]; command.label=s.name;
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder]; encoder.label=s.name;
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:s.a offset:0 atIndex:0]; [encoder setBuffer:s.b offset:0 atIndex:1]; [encoder setBuffer:s.c offset:0 atIndex:2];
    [encoder setBytes:&dimensions length:sizeof(dimensions) atIndex:3];
    if(index==0) [encoder dispatchThreads:MTLSizeMake(count*3,1,1) threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256,pipeline.maxTotalThreadsPerThreadgroup),1,1)];
    else [encoder dispatchThreadgroups:MTLSizeMake(1,(count+63)/64,1) threadsPerThreadgroup:MTLSizeMake(pipeline.threadExecutionWidth*(index>=3?1:4),1,1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    s.metrics.predict+=now()-start;
    require(command.status==MTLCommandBufferStatusCompleted,command.error.description);
    s.metrics.gpu+=command.GPUEndTime-command.GPUStartTime;
    return (const float*)s.c.contents;
}
int finishMatrix(const hncs_context *context,const float *input,float *output,size_t count) {
    for(size_t i=0;i<count;++i) {
        const V p={double(input[3*i]),double(input[3*i+1]),double(input[3*i+2])};
        if(!finite(p))return -1;
        const F work=phocus_work(context->preset,context->preset_tone,context->render(p));
        for(int ch=0;ch<3;++ch)output[3*i+ch]=work[ch];
    }
    return 0;
}
}

extern "C" const char *neural_study_prepare(const char *root,const char *model,int units,int backend) {
    std::lock_guard<std::mutex> lock(stateMutex);
    @autoreleasepool { try {
        auto &s=state(); s.backend=backend; s.units=units; s.metrics={}; s.model=nil; s.input=nil; s.provider=nil;
        s.name=[NSString stringWithUTF8String:model];
        NSString *directory=[NSString stringWithUTF8String:root];
        s.checkContext=false; s.contextDelta=0;
        NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"manifest.json"]] options:0 error:nil];
        for(NSDictionary *entry in manifest[@"cases"]) {
            if([s.name hasPrefix:[entry[@"preset"] stringByAppendingString:@"-"]]) {
                for(int row=0;row<3;++row)for(int col=0;col<3;++col)s.expectedMatrix[row*3+col]=[entry[@"matrix"][row][col] doubleValue];
                s.expectedExposure=[entry[@"exposure"] doubleValue]; s.checkContext=true;
            }
        }
        NSMutableDictionary *report=[@{@"backend":@(backend),@"model":s.name,@"units":@(units)} mutableCopy];
        double start=now();
        if(backend==1) {
            NSError *error=nil;
            NSURL *compiled=s.compiled[s.name];
            if(!compiled) {
                NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[s.name stringByAppendingString:@".mlpackage"]]];
                compiled=[MLModel compileModelAtURL:url error:&error]; require(compiled!=nil,error.description);
                s.compiled[s.name]=compiled;
            }
            report[@"compile_seconds"]=@(now()-start);
            MLModelConfiguration *configuration=[MLModelConfiguration new]; configuration.computeUnits=computeUnits(units);
            start=now(); s.model=[MLModel modelWithContentsOfURL:compiled configuration:configuration error:&error];
            require(s.model!=nil,error.description); report[@"load_seconds"]=@(now()-start);
            MLFeatureDescription *description=s.model.modelDescription.inputDescriptionsByName[@"source"];
            s.input=[[MLMultiArray alloc] initWithShape:description.multiArrayConstraint.shape dataType:MLMultiArrayDataTypeFloat32 error:&error];
            require(s.input!=nil,error.description);
            s.provider=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"source":[MLFeatureValue featureValueWithMultiArray:s.input]} error:&error];
            require(s.provider!=nil,error.description);
            dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);
            __block NSArray *rows=nil; __block NSString *planError=nil;
            [MLComputePlan loadContentsOfURL:compiled configuration:configuration completionHandler:^(MLComputePlan *plan,NSError *error) {
                rows=plan?describePlan(plan):nil; planError=error.description; dispatch_semaphore_signal(semaphore);
            }];
            const long timeout=dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC));
            report[@"plan"]=rows?:@[]; report[@"plan_error"]=timeout?@"plan timed out":(planError?:@"");
            report[@"input_shape"]=s.input.shape;
        } else if(backend>=2) {
            prepareGPU(s,directory); report[@"prepare_seconds"]=@(now()-start); report[@"device"]=s.device.name;
            NSMutableArray *sets=[NSMutableArray new];
            for(id<MTLCounterSet> set in s.device.counterSets) {
                NSMutableArray *counters=[NSMutableArray new];
                for(id<MTLCounter> counter in set.counters)[counters addObject:counter.name];
                [sets addObject:@{@"name":set.name,@"counters":counters}];
            }
            report[@"counter_sets"]=sets;
        }
        report[@"status"]=@"ready";
        return json(report);
    }catch(const std::exception &error) { lastError=error.what(); return json(@{@"status":@"error",@"error":[NSString stringWithUTF8String:error.what()]}); } }
}
extern "C" int hncs_process_phocus_work_float_parallel(const hncs_context *context,const float *input,float *output,size_t count,unsigned workers) {
    std::lock_guard<std::mutex> lock(stateMutex);
    auto &s=state();
    if(context&&s.checkContext) {
        double delta=std::abs(context->exposure-s.expectedExposure);
        for(int i=0;i<9;++i)delta=std::max(delta,std::abs(context->source_to_native[i]-s.expectedMatrix[i]));
        s.contextDelta=std::max(s.contextDelta,delta);
        if(delta>1e-12) { lastError="Prepared model does not match this photo's source matrix/exposure"; return -1; }
    }
    if(s.backend==0)return hncs_cpu_process_phocus_work_float_parallel(context,input,output,count,workers);
    if(!context||!input||!output||!count||workers<1||workers>4)return -1;
    @autoreleasepool { try {
        const float *native=s.backend==1?coreMLMatrix(s,input,count):gpuMatrix(s,context,input,count);
        const double start=now();
        const int result=parallel_float(context,native,output,count,workers,3,finishMatrix);
        s.metrics.tail+=now()-start; s.metrics.calls+=1;
        return result;
    }catch(const std::exception &error) { lastError=error.what(); std::fprintf(stderr,"NEURAL-STUDY ERROR: %s\n",error.what()); return -1; } }
}
extern "C" const char *neural_study_stats(int reset) {
    std::lock_guard<std::mutex> lock(stateMutex); auto &s=state(); const auto m=s.metrics;
    if(reset)s.metrics={};
    return json(@{@"calls":@(m.calls),@"pack_seconds":@(m.pack),@"predict_or_submit_wait_seconds":@(m.predict),
                  @"unpack_seconds":@(m.unpack),@"gpu_timestamp_seconds":@(m.gpu),@"cpu_color_tail_seconds":@(m.tail),@"uploaded_bytes":@(m.uploaded),@"context_delta_max":@(s.contextDelta)});
}
extern "C" const char *neural_study_dense(int iterations,const char *output) {
    std::lock_guard<std::mutex> lock(stateMutex);
    @autoreleasepool { try {
        auto &s=state(); require(s.model&&s.input,@"Dense model not prepared");
        float *values=(float*)s.input.dataPointer;
        for(NSInteger i=0;i<s.input.count;++i)values[i]=float((i*17)%1000)*.001f;
        NSMutableArray *times=[NSMutableArray new]; id<MLFeatureProvider> result=nil; NSError *error=nil;
        for(int iteration=0;iteration<=iterations;++iteration) {
            const os_signpost_id_t ident=os_signpost_id_generate(s.log);
            os_signpost_interval_begin(s.log,ident,"CoreMLDenseControl","units=%d",s.units);
            const double start=now(); result=[s.model predictionFromFeatures:s.provider error:&error];
            const double elapsed=now()-start;
            os_signpost_interval_end(s.log,ident,"CoreMLDenseControl");
            require(result!=nil,error.description); [times addObject:@(elapsed)];
        }
        MLMultiArray *array=[result featureValueForName:result.featureNames.allObjects.firstObject].multiArrayValue;
        const size_t elementBytes=array.dataType==MLMultiArrayDataTypeFloat16?2:4;
        NSData *data=[NSData dataWithBytes:array.dataPointer length:array.count*elementBytes];
        require([data writeToFile:[NSString stringWithUTF8String:output] options:NSDataWritingAtomic error:&error],error.description);
        return json(@{@"status":@"complete",@"times_including_first":times,@"shape":array.shape,@"strides":array.strides,@"element_bytes":@(elementBytes)});
    }catch(const std::exception &error) { lastError=error.what();return json(@{@"status":@"error",@"error":[NSString stringWithUTF8String:error.what()]}); } }
}
extern "C" const char *neural_study_error(void) { return lastError.c_str(); }
extern "C" int neural_study_backend(void) { return state().backend; }
