import Foundation
import CoreImage
import Metal

/// Immutable Float32 pixels in top-to-bottom row order, as returned by
/// CIContext.render(toBitmap:). The deferred CIImage retains its owned bytes.
final class PreviewRaster: @unchecked Sendable {
    let width: Int
    let height: Int
    let image: CIImage
    private let storage: Data

    init(linearRGBA: [Float], width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              linearRGBA.count == width * height * 4,
              linearRGBA.allSatisfy({ $0.isFinite }),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw PipelineError.rendering
        }
        self.width = width
        self.height = height
        let data = linearRGBA.withUnsafeBytes { Data($0) }
        self.storage = data
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGBAf, colorSpace: space)
        if #available(iOS 26, macOS 26, *) {
            let peak = stride(from: 0, to: linearRGBA.count, by: 4).reduce(Float(1)) {
                max($0, linearRGBA[$1], linearRGBA[$1 + 1], linearRGBA[$1 + 2])
            }
            self.image = image.settingContentHeadroom(peak)
        } else { self.image = image }
    }

    private init(image: CIImage, width: Int, height: Int, storage: Data) {
        self.image = image; self.width = width; self.height = height; self.storage = storage
    }

    func cropped(to crop: PixelCrop) throws -> PreviewRaster {
        guard crop.x >= 0, crop.ciY >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= width, crop.ciY + crop.height <= height else {
            throw PipelineError.rendering
        }
        if crop.x == 0 && crop.ciY == 0 && crop.width == width && crop.height == height { return self }
        let cropped = image.cropped(to: crop.ciRect)
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)))
        return PreviewRaster(image: cropped, width: crop.width, height: crop.height, storage: storage)
    }
}

/// Both the editor and live camera use the same top-left Metal destination.
/// This changes presentation orientation only; it does not flip source pixels
/// or the coordinates used by photo effects and export.
enum PreviewRendering {
    static func render(_ image: CIImage, with context: CIContext, to texture: MTLTexture,
                       commandBuffer: MTLCommandBuffer, colorSpace: CGColorSpace) throws -> CIRenderTask {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.isFlipped = true
        return try context.startTask(toRender: image, to: destination)
    }
}
