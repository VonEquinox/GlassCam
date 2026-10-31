#ifndef GLASSCAM_METAL_COLOR_H
#define GLASSCAM_METAL_COLOR_H
#ifdef __OBJC__
#import <CoreImage/CoreImage.h>
#import "file_raster.h"
#include "hncs_c.h"
#include "ffcs_c.h"
#include "lumix_c.h"
NS_ASSUME_NONNULL_BEGIN

/// Immutable resource bindings. The image retains them until rendering ends.
@interface GCMetalColor : NSObject
+ (BOOL)renderHNCS:(CIImage *)image context:(CIContext *)context reference:(const hncs_context *)reference
    sourceExposure:(float)exposure workers:(unsigned)workers toPath:(NSString *)path maximum:(float *)maximum
    cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error;
+ (nullable CIImage *)ffcs:(CIImage *)image context:(const FFCSContext *)context
    sourceExposure:(float)exposure backendExposure:(float)backendExposure seed:(uint32_t)seed
    shaderPath:(NSString *)shaderPath error:(NSError **)error;
+ (nullable CIImage *)lumix:(CIImage *)image context:(const LUMIXContext *)context
    sourceExposure:(float)exposure backendExposure:(float)backendExposure
    shaderPath:(NSString *)shaderPath error:(NSError **)error;
/// Materialize the lazy GPU graph in bounded, reusable native buffers. A work
/// image stores packed RGB; a final raster stores RGBA. Rows are top-down.
/// maximumRows=0 uses the buffer capacity; RAW callers pin it to 64 so changing
/// scheduling does not change the system decoder's region-dependent pixels.
+ (BOOL)render:(CIImage *)image context:(CIContext *)context toPath:(NSString *)path
    components:(NSUInteger)components maximumRows:(NSUInteger)maximumRows maximum:(float *)maximum
    cancelled:(BOOL (^)(void))cancelled progress:(void (^)(double))progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
#endif
#endif
