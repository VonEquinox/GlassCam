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
                                 options:@{kCIImageProviderTileSize: @[@256, @256]}];
}
- (void)provideImageData:(void *)data bytesPerRow:(size_t)rowBytes origin:(size_t)x :(size_t)y
                    size:(size_t)width :(size_t)height userInfo:(id)info {
    // pread is safe for concurrent Core Image requests and never changes a
    // shared file offset. Edge tiles may extend beyond the image rectangle.
    auto *base = static_cast<unsigned char *>(data);
    if (x >= _width || y >= _height || height == 0) {
        std::memset(base, 0, height * rowBytes);
        return;
    }
    const size_t validRows = std::min(height, _height - y);
    const size_t validCols = std::min(width, _width - x);
    const size_t validRowBytes = validCols * 16;
    if (validRowBytes > rowBytes) {
        _failure.store(EINVAL, std::memory_order_relaxed);
        std::memset(base, 0, height * rowBytes);
        return;
    }
    if (x == 0 && validCols == _width && rowBytes == validRowBytes) {
        size_t remaining = validRows * validRowBytes;
        auto *destination = base;
        off_t offset = off_t(y * _width * 16);
        while (remaining) {
            const ssize_t count = pread(_descriptor, destination, remaining, offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                _failure.store(count < 0 ? errno : EIO, std::memory_order_relaxed);
                std::memset(destination, 0, remaining);
                break;
            }
            destination += count; offset += count; remaining -= size_t(count);
        }
    } else {
        for (size_t row = 0; row < validRows; ++row) {
            auto *rowStart = base + row * rowBytes;
            auto *destination = rowStart;
            size_t remaining = validRowBytes;
            off_t offset = off_t(((y + row) * _width + x) * 16);
            while (remaining) {
                const ssize_t count = pread(_descriptor, destination, remaining, offset);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) {
                    _failure.store(count < 0 ? errno : EIO, std::memory_order_relaxed);
                    std::memset(destination, 0, remaining);
                    break;
                }
                destination += count; offset += count; remaining -= size_t(count);
            }
            if (rowBytes > validRowBytes) {
                std::memset(rowStart + validRowBytes, 0, rowBytes - validRowBytes);
            }
        }
    }
    if (height > validRows) {
        std::memset(base + validRows * rowBytes, 0, (height - validRows) * rowBytes);
    }
}
@end
