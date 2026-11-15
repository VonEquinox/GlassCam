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
    id<MTLComputePipelineState> ffcs, ffcsHorizontal, ffcsFinish, lumix;
    explicit ColorRuntime(NSString *path) {
        device=MTLCreateSystemDefaultDevice();
        if(!device)throw std::runtime_error("Metal device unavailable");
        NSError *error=nil;
        id<MTLLibrary> library=[device newDefaultLibrary];
        if(![library newFunctionWithName:@"gc_ffcs_horizontal"]) {
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
        ffcsHorizontal=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_ffcs_horizontal"] error:&error];
        ffcsFinish=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_ffcs_finish"] error:&error];
        lumix=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gc_lumix"] error:&error];
        if(!ffcs||!ffcsHorizontal||!ffcsFinish||!lumix)throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal color pipeline unavailable");
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

@interface GCMetalColorResources () {
@public
    std::shared_ptr<ColorRuntime> runtime;
    id<MTLComputePipelineState> pipeline;
    id<MTLBuffer> configuration,lut,decode,weights,gammaIn,gammaOut,normalWeights,distances;
    double grainSize;
    uint32_t halo;
    int mode;
}
@end
@implementation GCMetalColorResources
@end

@interface GCColorState : NSObject {
@public
    GCMetalColorResources *resources;
    id<MTLBuffer> grainCoordinates;
    uint32_t halo,seed;
    float exposure,backendExposure;
    CGRect extent;
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
    GCMetalColorResources *resources=state?state->resources:nil;
    id<CIImageProcessorInput> input=inputs.firstObject;
    id<MTLCommandBuffer> command=output.metalCommandBuffer;
    id<MTLTexture> source=input.metalTexture,destination=output.metalTexture;
    if(!state||!resources||!source||!destination||!command||command.device!=resources->runtime->device) {
        setError(error,@"Core Image did not provide compatible Metal textures");return NO;
    }
    GCColorRegion region{int32_t(output.region.origin.x-input.region.origin.x),
        int32_t(CGRectGetMaxY(input.region)-CGRectGetMaxY(output.region)),int32_t(input.region.origin.x),
        int32_t(CGRectGetMaxY(state->extent)-CGRectGetMaxY(input.region)),
        uint32_t(input.region.size.width),uint32_t(input.region.size.height),
        uint32_t(output.region.size.width),uint32_t(output.region.size.height),
        uint32_t(state->extent.size.width),uint32_t(state->extent.size.height),state->seed,state->exposure,state->backendExposure};
    id<MTLTexture> intermediate=nil,horizontal=nil;
    GCColorRegion pointRegion=region;
    if(state->halo) {
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
            width:region.inputWidth height:region.inputHeight mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;
        descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        intermediate=[command.device newTextureWithDescriptor:descriptor];
        MTLTextureDescriptor *horizontalDescriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
            width:region.outputWidth height:region.inputHeight mipmapped:NO];
        horizontalDescriptor.storageMode=MTLStorageModePrivate;
        horizontalDescriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        horizontal=[command.device newTextureWithDescriptor:horizontalDescriptor];
        if(!intermediate||!horizontal){setError(error,@"Metal neighborhood allocation failed");return NO;}
        pointRegion.offsetX=pointRegion.offsetY=0;
        pointRegion.outputWidth=region.inputWidth;pointRegion.outputHeight=region.inputHeight;
    }
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!encoder){setError(error,@"Metal encoder allocation failed");return NO;}
    [encoder setComputePipelineState:resources->pipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:intermediate?:destination atIndex:1];
    [encoder setBytes:&pointRegion length:sizeof(pointRegion) atIndex:0];
    [encoder setBuffer:resources->configuration offset:0 atIndex:1];
    [encoder setBuffer:resources->lut offset:0 atIndex:2];
    if(resources->mode==1) {
        [encoder setBuffer:resources->decode offset:0 atIndex:3];
        [encoder setBuffer:state->grainCoordinates offset:0 atIndex:4];
        [encoder setBuffer:resources->gammaIn offset:0 atIndex:5];
        [encoder setBuffer:resources->gammaOut offset:0 atIndex:6];
        [encoder setBuffer:resources->normalWeights offset:0 atIndex:7];
        [encoder setBuffer:resources->distances offset:0 atIndex:8];
    }
    dispatch(encoder,resources->pipeline,pointRegion.outputWidth,pointRegion.outputHeight);
    [encoder endEncoding];
    if(intermediate) {
        encoder=[command computeCommandEncoder];
        if(!encoder){setError(error,@"Metal neighborhood encoder allocation failed");return NO;}
        [encoder setComputePipelineState:resources->runtime->ffcsHorizontal];
        [encoder setTexture:intermediate atIndex:0];[encoder setTexture:horizontal atIndex:1];
        [encoder setBytes:&region length:sizeof(region) atIndex:0];
        [encoder setBuffer:resources->configuration offset:0 atIndex:1];
        [encoder setBuffer:resources->weights offset:0 atIndex:2];
        dispatch(encoder,resources->runtime->ffcsHorizontal,region.outputWidth,region.inputHeight);
        [encoder endEncoding];

        encoder=[command computeCommandEncoder];
        if(!encoder){setError(error,@"Metal neighborhood encoder allocation failed");return NO;}
        [encoder setComputePipelineState:resources->runtime->ffcsFinish];
        [encoder setTexture:intermediate atIndex:0];
        [encoder setTexture:horizontal atIndex:1];
        [encoder setTexture:destination atIndex:2];
        [encoder setBytes:&region length:sizeof(region) atIndex:0];
        [encoder setBuffer:resources->configuration offset:0 atIndex:1];
        [encoder setBuffer:resources->weights offset:0 atIndex:2];
        dispatch(encoder,resources->runtime->ffcsFinish,region.outputWidth,region.outputHeight);
        [encoder endEncoding];
    }
    return YES;
}
@end

namespace {
CIImage *apply(GCMetalColorResources *resources,CIImage *image,float exposure,float backendExposure,uint32_t seed,NSError **error) {
    try {
        GCColorState *state=[GCColorState new];
        state->resources=resources;state->halo=resources->halo;
        state->extent=image.extent;state->exposure=exposure;state->backendExposure=backendExposure;state->seed=seed;
        if(resources->mode==1) {
            std::vector<uint32_t> coordinates(1,1);
            if(resources->grainSize>0) {
                const auto extent=image.extent;
                if(!CGRectEqualToRect(extent,CGRectIntegral(extent))||
                    extent.origin.x!=0||extent.origin.y!=0||extent.size.width<=0||extent.size.height<=0||
                    extent.size.width>INT_MAX||extent.size.height>INT_MAX)
                    throw std::invalid_argument("Invalid FFCS grain extent");
                const size_t width=size_t(extent.size.width),height=size_t(extent.size.height);
                coordinates.resize(1+width+height);
                // Float division can cross an integer boundary (55/1.1).
                // Match mobilePixel's Double division before hashing the grid.
                const double size=resources->grainSize;
                coordinates[0]=uint32_t(std::max(size_t(1),size_t(width/size)));
                for(size_t x=0;x<width;++x)coordinates[1+x]=uint32_t(size_t(x/size));
                for(size_t y=0;y<height;++y)coordinates[1+width+y]=uint32_t(size_t(y/size));
            }
            state->grainCoordinates=resources->runtime->upload(coordinates.data(),coordinates.size()*sizeof(uint32_t));
        }
        return [GCColorKernel applyWithExtent:image.extent inputs:@[image] arguments:@{@"state":state} error:error];
    }catch(const std::exception &failure){setError(error,@(failure.what()));return nil;}
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
+ (GCMetalColorResources *)ffcsResources:(const FFCSContext *)context
    shaderPath:(NSString *)path error:(NSError **)error {
    try {
        ffcs_color_data c{};if(ffcs_get_color_data(context,&c))throw std::invalid_argument("Invalid FFCS context");
        GCMetalColorResources *resources=[GCMetalColorResources new];
        resources->runtime=colorRuntime(path);resources->mode=1;
        auto &runtime=*resources->runtime;resources->pipeline=runtime.ffcs;resources->halo=c.reach;
        GCFFCSColor p{};std::copy_n(c.matrix,9,p.matrix);p.contrast=c.contrast;p.saturation=c.saturation;p.hue=c.hue;
        p.shoulder=c.shoulder;p.toe=c.toe;p.grain=c.grain;p.chroma=c.chroma;p.sharp=c.sharp;
        resources->grainSize=c.grain_enabled&&c.grain>0?c.grain_size:0;
        p.size=c.size;p.rgbChannels=c.rgb_channels;p.acros=c.acros;p.grainEnabled=c.grain_enabled;p.reach=c.reach;
        p.nativeMapping=c.native_mapping;p.mappingGamma=c.mapping_gamma;
        p.workingMaximum=c.working_maximum;p.fixedMapping=c.fixed_mapping;
        resources->configuration=runtime.upload(&p,sizeof(p));
        resources->lut=runtime.upload(c.lut,size_t(c.size)*c.size*c.size*3*sizeof(uint16_t));
        resources->decode=runtime.floats(c.normalized_codes,65536);
        const uint32_t zero=0;
        resources->gammaIn=c.native_mapping?runtime.upload(c.gamma_in,(size_t(c.working_maximum)+1)*sizeof(uint32_t)):runtime.upload(&zero,sizeof(zero));
        resources->gammaOut=c.native_mapping?runtime.upload(c.gamma_out,20001*sizeof(uint16_t)):runtime.upload(&zero,sizeof(zero));
        resources->normalWeights=c.native_mapping?runtime.upload(c.gaussian,1536*sizeof(int32_t)):runtime.upload(&zero,sizeof(zero));
        resources->distances=c.native_mapping?runtime.upload(c.distances,1024*sizeof(int32_t)):runtime.upload(&zero,sizeof(zero));
        if(c.reach)resources->weights=runtime.floats(c.kernel,size_t(c.reach+1));
        return resources;
    }catch(const std::exception &failure){setError(error,@(failure.what()));return nil;}
}
+ (GCMetalColorResources *)lumixResources:(const LUMIXContext *)context
    shaderPath:(NSString *)path error:(NSError **)error {
    try {
        lumix_color_data c{};if(lumix_get_color_data(context,&c))throw std::invalid_argument("Invalid LUMIX context");
        GCMetalColorResources *resources=[GCMetalColorResources new];
        resources->runtime=colorRuntime(path);resources->mode=2;
        auto &runtime=*resources->runtime;resources->pipeline=runtime.lumix;
        GCLUMIXColor p{};std::copy_n(c.tone_x,49,p.toneX);std::copy_n(c.tone_y,49,p.toneY);
        p.toneCount=c.tone_count;p.saturation=c.saturation;p.monochrome=c.monochrome;p.blueChroma=c.blue_chroma;p.redChroma=c.red_chroma;
        std::copy_n(c.pre_x,49,p.preX);std::copy_n(c.pre_y,49,p.preY);
        p.preCount=c.pre_count;p.nativePipeline=c.native_pipeline;
        resources->configuration=runtime.upload(&p,sizeof(p));
        resources->lut=runtime.upload(c.cube,size_t(129)*129*129*3*sizeof(uint16_t));
        return resources;
    }catch(const std::exception &failure){setError(error,@(failure.what()));return nil;}
}
+ (CIImage *)ffcs:(CIImage *)image context:(const FFCSContext *)context
    resources:(GCMetalColorResources *)resources
    sourceExposure:(float)exposure backendExposure:(float)backendExposure seed:(uint32_t)seed
    shaderPath:(NSString *)path error:(NSError **)error {
    GCMetalColorResources *resolved=resources?:[self ffcsResources:context shaderPath:path error:error];
    if(!resolved)return nil;
    return apply(resolved,image,exposure,backendExposure,seed,error);
}
+ (CIImage *)lumix:(CIImage *)image context:(const LUMIXContext *)context
    resources:(GCMetalColorResources *)resources
    sourceExposure:(float)exposure backendExposure:(float)backendExposure
    shaderPath:(NSString *)path error:(NSError **)error {
    GCMetalColorResources *resolved=resources?:[self lumixResources:context shaderPath:path error:error];
    if(!resolved)return nil;
    return apply(resolved,image,exposure,backendExposure,0,error);
}
+ (BOOL)render:(CIImage *)image context:(CIContext *)context toPath:(NSString *)path components:(NSUInteger)components maximumRows:(NSUInteger)maximumRows
    maximum:(float *)maximum cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error {
    return renderFile(image,context,path,components,maximumRows,maximum,cancelled,progress,error);
}
+ (BOOL)renderHNCS:(CIImage *)image context:(CIContext *)context reference:(const hncs_context *)reference
    sourceExposure:(float)exposure workers:(unsigned)workers maximumRows:(NSUInteger)maximumRows
    toPath:(NSString *)path maximum:(float *)maximum
    cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error {
    if(!reference||!std::isfinite(exposure)||exposure<=0||workers<1||workers>4) {
        setError(error,@"Invalid HNCS render configuration",-1);return NO;
    }
    return renderFile(image,context,path,3,maximumRows,maximum,cancelled,progress,error,reference,exposure,workers);
}
@end
