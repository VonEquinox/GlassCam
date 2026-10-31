#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN
/// Immutable Float32 RGBA backing. Core Image requests bounded tiles instead
/// of uploading the complete photo for each render destination.
@interface GCFileRaster : NSObject
- (nullable instancetype)initWithPath:(NSString *)path width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error;
- (CIImage *)imageWithColorSpace:(CGColorSpaceRef)colorSpace;
@property(nonatomic, readonly) int readError;
@end
NS_ASSUME_NONNULL_END
