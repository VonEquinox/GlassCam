#import "file_raster.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

@implementation GCFileRaster {
    int _descriptor;
    size_t _width, _height;
    std::atomic<int> _failure;
}
- (instancetype)initWithPath:(NSString *)path width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _descriptor = -1; _failure = 0;
    int code = EINVAL;
    if (width && height && width <= size_t(std::numeric_limits<off_t>::max()) / 16 / height) {
        _descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        struct stat status{};
        if (_descriptor >= 0 && fstat(_descriptor, &status) == 0 && status.st_size == off_t(width * height * 16)) {
            _width = width; _height = height;
            return self;
        }
        if (_descriptor < 0) code = errno;
    }
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return nil;
}
- (void)dealloc { if (_descriptor >= 0) close(_descriptor); }
- (int)readError { return _failure.load(std::memory_order_relaxed); }
- (CIImage *)imageWithColorSpace:(CGColorSpaceRef)colorSpace {
    return [CIImage imageWithImageProvider:self size:_width :_height format:kCIFormatRGBAf colorSpace:colorSpace
                                 options:@{kCIImageProviderTileSize: @[@512, @64]}];
}
- (void)provideImageData:(void *)data bytesPerRow:(size_t)rowBytes origin:(size_t)x :(size_t)y
                    size:(size_t)width :(size_t)height userInfo:(id)info {
    // pread is safe for concurrent Core Image requests and never changes a
    // shared file offset. Edge tiles may extend beyond the image rectangle.
    for (size_t row = 0; row < height; ++row) {
        auto destination = static_cast<unsigned char *>(data) + row * rowBytes;
        std::memset(destination, 0, rowBytes);
        if (x >= _width || y >= _height || row >= _height - y) continue;
        size_t remaining = std::min(width, _width - x) * 16;
        if (remaining > rowBytes) { _failure.store(EINVAL, std::memory_order_relaxed); continue; }
        off_t offset = off_t(((y + row) * _width + x) * 16);
        while (remaining) {
            const ssize_t count = pread(_descriptor, destination, remaining, offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { _failure.store(count < 0 ? errno : EIO, std::memory_order_relaxed); break; }
            destination += count; offset += count; remaining -= size_t(count);
        }
    }
}
@end
