#include "metal_color.h"
#include "ffcs_color_data.h"
#include "lumix_color_data.h"
#include "ColorTypes.h"
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>
#include <unistd.h>

namespace {
void setError(NSError **error, NSString *message, NSInteger code = -2) {
    if (error) *error = [NSError errorWithDomain:@"GlassCam.MetalColor" code:code
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
}
struct ColorRuntime {
    id<MTLDevice> device;
    id<MTLComputePipelineState> ffcs, ffcsFinish, lumix;
    explicit ColorRuntime(NSString *path) {
        device=MTLCreateSystemDefaultDevice();
        if(!device)throw std::runtime_error("Metal device unavailable");
        NSError *error=nil;
        id<MTLLibrary> library=[device newDefaultLibrary];
        if(![library newFunctionWithName:@"gc_ffcs_point"]) {
            NSString *source=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
            NSString *types=[NSString stringWithContentsOfFile:[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ColorTypes.h"] encoding:NSUTF8StringEncoding error:&error];
            if(!source||!types)throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal color resource missing");
            source=[types stringByAppendingString:[source stringByReplacingOccurrencesOfString:@"#include \"ColorTypes.h\"" withString:@""]];
            MTLCompileOptions *options=[MTLCompileOptions new];
            options.mathMode=MTLMathModeSafe;
            options.mathFloatingPointFunctions=MTLMathFloatingPointFunctionsPrecise;
            library=[device newLibraryWithSource:source options:options error:&error];
        }
        if(!library)throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal color library unavailable");
        ffcs=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_ffcs_point"] error:&error];
        ffcsFinish=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_ffcs_finish"] error:&error];
        lumix=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_lumix"] error:&error];
        if(!ffcs||!ffcsFinish||!lumix)throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal color pipeline unavailable");
    }
    id<MTLBuffer> upload(const void *data,size_t bytes) {
        id<MTLBuffer> result=[device newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared];
        if(!result)throw std::bad_alloc();return result;
    }
    id<MTLBuffer> floats(const double *data,size_t count) {
        std::vector<float> values(count);std::copy_n(data,count,values.data());
        return upload(values.data(),count*sizeof(float));
    }
};
std::shared_ptr<ColorRuntime> colorRuntime(NSString *path) {
    static std::mutex mutex;
    static std::shared_ptr<ColorRuntime> cached;
    std::lock_guard<std::mutex> lock(mutex);
    if(!cached)cached=std::make_shared<ColorRuntime>(path);
    return cached;
}
void dispatch(id<MTLComputeCommandEncoder> encoder,id<MTLComputePipelineState> pipeline,NSUInteger width,NSUInteger height) {
    const NSUInteger lanes=pipeline.threadExecutionWidth;
    [encoder dispatchThreads:MTLSizeMake(width,height,1)
       threadsPerThreadgroup:MTLSizeMake(lanes,std::min(NSUInteger(4),pipeline.maxTotalThreadsPerThreadgroup/lanes),1)];
}
}

@interface GCColorState : NSObject {
@public
    std::shared_ptr<ColorRuntime> runtime;
    id<MTLComputePipelineState> pipeline;
    id<MTLBuffer> configuration,lut,decode,weights;
    uint32_t halo,seed;
    float exposure,backendExposure;
    CGRect extent;
    int mode;
}
@end
@implementation GCColorState
@end

@interface GCColorKernel : CIImageProcessorKernel
@end
@implementation GCColorKernel
+ (CIFormat)formatForInputAtIndex:(int)index { return kCIFormatRGBAf; }
+ (CIFormat)outputFormat { return kCIFormatRGBAf; }
+ (BOOL)synchronizeInputs { return NO; }
+ (CGRect)roiForInput:(int)index arguments:(NSDictionary *)arguments outputRect:(CGRect)rect {
    GCColorState *state=arguments[@"state"];
    return CGRectIntersection(CGRectInset(rect,-CGFloat(state->halo),-CGFloat(state->halo)),state->extent);
}
+ (BOOL)processWithInputs:(NSArray<id<CIImageProcessorInput>> *)inputs arguments:(NSDictionary *)arguments
                   output:(id<CIImageProcessorOutput>)output error:(NSError **)error {
    GCColorState *state=arguments[@"state"];
    id<CIImageProcessorInput> input=inputs.firstObject;
    id<MTLCommandBuffer> command=output.metalCommandBuffer;
    id<MTLTexture> source=input.metalTexture,destination=output.metalTexture;
    if(!state||!source||!destination||!command||command.device!=state->runtime->device) {
        setError(error,@"Core Image did not provide compatible Metal textures");return NO;
    }
    GCColorRegion region{int32_t(output.region.origin.x-input.region.origin.x),
        int32_t(CGRectGetMaxY(input.region)-CGRectGetMaxY(output.region)),int32_t(input.region.origin.x),
        int32_t(CGRectGetMaxY(state->extent)-CGRectGetMaxY(input.region)),
        uint32_t(input.region.size.width),uint32_t(input.region.size.height),
        uint32_t(output.region.size.width),uint32_t(output.region.size.height),
        uint32_t(state->extent.size.width),uint32_t(state->extent.size.height),state->seed,state->exposure,state->backendExposure};
    id<MTLTexture> intermediate=nil;
    GCColorRegion pointRegion=region;
    if(state->halo) {
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
            width:region.inputWidth height:region.inputHeight mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;
        descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        intermediate=[command.device newTextureWithDescriptor:descriptor];
        if(!intermediate){setError(error,@"Metal neighborhood allocation failed");return NO;}
        pointRegion.offsetX=pointRegion.offsetY=0;
        pointRegion.outputWidth=region.inputWidth;pointRegion.outputHeight=region.inputHeight;
    }
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!encoder){setError(error,@"Metal encoder allocation failed");return NO;}
    [encoder setComputePipelineState:state->pipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:intermediate?:destination atIndex:1];
    [encoder setBytes:&pointRegion length:sizeof(pointRegion) atIndex:0];
    [encoder setBuffer:state->configuration offset:0 atIndex:1];
    [encoder setBuffer:state->lut offset:0 atIndex:2];
    if(state->mode==1)[encoder setBuffer:state->decode offset:0 atIndex:3];
    dispatch(encoder,state->pipeline,pointRegion.outputWidth,pointRegion.outputHeight);
    [encoder endEncoding];
    if(intermediate) {
        encoder=[command computeCommandEncoder];
        if(!encoder){setError(error,@"Metal neighborhood encoder allocation failed");return NO;}
        [encoder setComputePipelineState:state->runtime->ffcsFinish];
        [encoder setTexture:intermediate atIndex:0];[encoder setTexture:destination atIndex:1];
        [encoder setBytes:&region length:sizeof(region) atIndex:0];
        [encoder setBuffer:state->configuration offset:0 atIndex:1];
        [encoder setBuffer:state->weights offset:0 atIndex:2];
        dispatch(encoder,state->runtime->ffcsFinish,region.outputWidth,region.outputHeight);
        [encoder endEncoding];
    }
    return YES;
}
@end

namespace {
CIImage *apply(GCColorState *state,CIImage *image,float exposure,float backendExposure,uint32_t seed,NSError **error) {
    state->extent=image.extent;state->exposure=exposure;state->backendExposure=backendExposure;state->seed=seed;
    return [GCColorKernel applyWithExtent:image.extent inputs:@[image] arguments:@{@"state":state} error:error];
}
struct RenderSlot {
    std::vector<float> pixels;
    CIRenderTask *task=nil;
    size_t row=0,rows=0;
    explicit RenderSlot(size_t count):pixels(count){}
    ~RenderSlot(){if(task)[task waitUntilCompletedAndReturnError:nil];}
};
struct Descriptor {
    int value;
    explicit Descriptor(const char *path):value(open(path,O_WRONLY|O_CLOEXEC)){}
    ~Descriptor(){if(value>=0)close(value);}
};
}

static BOOL renderFile(CIImage *image,CIContext *context,NSString *path,NSUInteger components,NSUInteger maximumRows,
    float *maximum,BOOL (^cancelled)(void),void (^progress)(double),NSError **error,
    const hncs_context *reference=nullptr,float exposure=1.f,unsigned workers=1) {
    try {
        if(!maximum||(components!=3&&components!=4)||!CGRectEqualToRect(image.extent,CGRectIntegral(image.extent))||
            image.extent.origin.x!=0||image.extent.origin.y!=0||image.extent.size.width<=0||image.extent.size.height<=0||
            image.extent.size.width>INT_MAX||image.extent.size.height>INT_MAX)
            throw std::invalid_argument("Invalid GPU raster extent");
        const size_t width=size_t(image.extent.size.width),height=size_t(image.extent.size.height);
        if(width>std::numeric_limits<size_t>::max()/height/16)throw std::invalid_argument("GPU raster size overflow");
        const size_t capacityRows=std::max(size_t(1),size_t(16*1024*1024)/(width*16));
        const size_t rows=std::min(height,std::min(capacityRows,maximumRows?size_t(maximumRows):height));
        Descriptor file(path.fileSystemRepresentation);if(file.value<0)throw std::runtime_error("Unable to open export raster");
        std::array<std::unique_ptr<RenderSlot>,2> slots;
        slots[0]=std::make_unique<RenderSlot>(width*rows*4);
        const size_t bands=(height+rows-1)/rows;
        if(bands>1)slots[1]=std::make_unique<RenderSlot>(width*rows*4);
        std::vector<float> nativeInput(reference?width*rows*3:0);
        float peak=0.f;
        auto retire=[&](RenderSlot &slot)->bool {
            if(!slot.task)return true;
            if(![slot.task waitUntilCompletedAndReturnError:error])return false;
            slot.task=nil;
            if(cancelled()){setError(error,@"Export cancelled",-3);return false;}
            const size_t count=width*slot.rows;
            if(reference) {
                for(size_t i=0;i<count;++i)for(size_t ch=0;ch<3;++ch)
                    nativeInput[i*3+ch]=slot.pixels[i*4+ch]*exposure;
                const int status=hncs_process_apple_hdr_work_float_parallel(reference,nativeInput.data(),slot.pixels.data(),count,workers);
                if(status){setError(error,@"HNCS color processing failed",status);return false;}
            }
            const size_t stride=reference?3:4;
            for(size_t i=0;i<count;++i) {
                for(size_t ch=0;ch<3;++ch) {
                    const float value=slot.pixels[i*stride+ch];
                    if(!std::isfinite(value)||value<0.f||value>(components==3?64.f:10000.f/203.f))
                        throw std::runtime_error("GPU produced invalid color values");
                    peak=std::max(peak,value);
                    if(components==3&&!reference)slot.pixels[i*3+ch]=value;
                }
            }
            auto *data=reinterpret_cast<unsigned char *>(slot.pixels.data());
            size_t bytes=count*components*sizeof(float);off_t offset=off_t(slot.row*width*components*sizeof(float));
            while(bytes){const ssize_t n=pwrite(file.value,data,bytes,offset);if(n<0&&errno==EINTR)continue;if(n<=0)throw std::runtime_error("Export raster write failed");data+=n;bytes-=size_t(n);offset+=n;}
            progress(double(slot.row+slot.rows)/double(height));return true;
        };
        struct ColorSpace {
            CGColorSpaceRef value=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            ~ColorSpace(){if(value)CGColorSpaceRelease(value);}
        } linear;
        if(!linear.value)throw std::bad_alloc();
        for(size_t band=0;band<bands;++band) {
            auto &slot=*slots[band%2];
            if(!retire(slot)){return NO;}
            if(cancelled()){setError(error,@"Export cancelled",-3);return NO;}
            slot.row=band*rows;slot.rows=std::min(rows,height-slot.row);
            NSError *renderError=nil;
            @autoreleasepool {
                CIRenderDestination *destination=[[CIRenderDestination alloc] initWithBitmapData:slot.pixels.data()
                    width:width height:slot.rows bytesPerRow:width*16 format:kCIFormatRGBAf];
                destination.colorSpace=linear.value;destination.flipped=YES;destination.clamped=NO;
                slot.task=[context startTaskToRender:image fromRect:CGRectMake(0,height-slot.row-slot.rows,width,slot.rows)
                    toDestination:destination atPoint:CGPointZero error:&renderError];
            }
            // Retain an error across the inner autorelease pool before exposing
            // it through the Objective-C NSError writeback used by Swift.
            if(!slot.task){if(error)*error=renderError;return NO;}
        }

        for(size_t band=bands>2?bands-2:0;band<bands;++band)if(!retire(*slots[band%2]))return NO;
        *maximum=peak;return YES;
    }catch(const std::exception &failure){setError(error,@(failure.what()));return NO;}
}

@implementation GCMetalColor
+ (CIImage *)ffcs:(CIImage *)image context:(const FFCSContext *)context sourceExposure:(float)exposure
    backendExposure:(float)backendExposure seed:(uint32_t)seed shaderPath:(NSString *)path error:(NSError **)error {
    try {
        ffcs_color_data c{};if(ffcs_get_color_data(context,&c))throw std::invalid_argument("Invalid FFCS context");
        GCColorState *state=[GCColorState new];state->runtime=colorRuntime(path);state->mode=1;
        auto &runtime=*state->runtime;state->pipeline=runtime.ffcs;state->halo=c.reach;
        GCFFCSColor p{};std::copy_n(c.matrix,9,p.matrix);p.contrast=c.contrast;p.saturation=c.saturation;p.hue=c.hue;
        p.shoulder=c.shoulder;p.toe=c.toe;p.grain=c.grain;p.grainSize=c.grain_size;p.chroma=c.chroma;p.sharp=c.sharp;
        p.size=c.size;p.rgbChannels=c.rgb_channels;p.acros=c.acros;p.grainEnabled=c.grain_enabled;p.reach=c.reach;
        state->configuration=runtime.upload(&p,sizeof(p));state->lut=runtime.upload(c.lut,size_t(c.size)*c.size*c.size*3*sizeof(uint16_t));
        state->decode=runtime.floats(c.normalized_codes,65536);
        if(c.reach)state->weights=runtime.floats(c.kernel,size_t(c.reach+1)*(c.reach+1));
        return apply(state,image,exposure,backendExposure,seed,error);
    }catch(const std::exception &failure){setError(error,@(failure.what()));return nil;}
}
+ (CIImage *)lumix:(CIImage *)image context:(const LUMIXContext *)context sourceExposure:(float)exposure
    backendExposure:(float)backendExposure shaderPath:(NSString *)path error:(NSError **)error {
    try {
        lumix_color_data c{};if(lumix_get_color_data(context,&c))throw std::invalid_argument("Invalid LUMIX context");
        GCColorState *state=[GCColorState new];state->runtime=colorRuntime(path);state->mode=2;
        auto &runtime=*state->runtime;state->pipeline=runtime.lumix;
        GCLUMIXColor p{};std::copy_n(c.tone_x,49,p.toneX);std::copy_n(c.tone_y,49,p.toneY);
        p.toneCount=c.tone_count;p.saturation=c.saturation;p.monochrome=c.monochrome;p.blueChroma=c.blue_chroma;p.redChroma=c.red_chroma;
        state->configuration=runtime.upload(&p,sizeof(p));state->lut=runtime.upload(c.cube,size_t(129)*129*129*3*sizeof(uint16_t));
        return apply(state,image,exposure,backendExposure,0,error);
    }catch(const std::exception &failure){setError(error,@(failure.what()));return nil;}
}
+ (BOOL)render:(CIImage *)image context:(CIContext *)context toPath:(NSString *)path components:(NSUInteger)components maximumRows:(NSUInteger)maximumRows
    maximum:(float *)maximum cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error {
    return renderFile(image,context,path,components,maximumRows,maximum,cancelled,progress,error);
}
+ (BOOL)renderHNCS:(CIImage *)image context:(CIContext *)context reference:(const hncs_context *)reference
    sourceExposure:(float)exposure workers:(unsigned)workers toPath:(NSString *)path maximum:(float *)maximum
    cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error {
    if(!reference||!std::isfinite(exposure)||exposure<=0||workers<1||workers>4) {
        setError(error,@"Invalid HNCS render configuration",-1);return NO;
    }
    return renderFile(image,context,path,3,64,maximum,cancelled,progress,error,reference,exposure,workers);
}
@end
