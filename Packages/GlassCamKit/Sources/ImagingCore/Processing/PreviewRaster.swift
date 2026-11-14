import Foundation
import CoreImage
import Metal
import QuartzCore
import CMetalImage

/// Immutable Float32 pixels in top-to-bottom row order, as returned by
/// CIContext.render(toBitmap:). The deferred CIImage retains its owned bytes.
public final class PreviewRaster: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let image: CIImage
    public let headroom: Float
    private let storage: Data

    public convenience init(linearRGBA: [Float], width: Int, height: Int) throws {
        let data = linearRGBA.withUnsafeBytes { Data($0) }
        try self.init(linearRGBAData: data, width: width, height: height)
    }

    public init(linearRGBAData: Data, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              linearRGBAData.count == width * height * 16,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw PipelineError.rendering
        }
        var peak: Float = 1
        let valid = linearRGBAData.withUnsafeBytes {
            gc_float_rgba_peak($0.bindMemory(to: Float.self).baseAddress, width * height, &peak)
        }
        guard valid != 0 else { throw PipelineError.rendering }
        self.width = width
        self.height = height
        headroom = peak
        self.storage = linearRGBAData
        let image = CIImage(bitmapData: linearRGBAData, bytesPerRow: width * 16,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGBAf, colorSpace: space)
        if #available(iOS 26, macOS 26, *) {
            self.image = image.settingContentHeadroom(headroom)
        } else { self.image = image }
    }

    private init(image: CIImage, width: Int, height: Int, headroom: Float, storage: Data) {
        self.image = image; self.width = width; self.height = height
        self.headroom = headroom; self.storage = storage
    }

    public func cropped(to crop: PixelCrop) throws -> PreviewRaster {
        guard crop.x >= 0, crop.ciY >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= width, crop.ciY + crop.height <= height else {
            throw PipelineError.rendering
        }
        if crop.x == 0 && crop.ciY == 0 && crop.width == width && crop.height == height { return self }
        let cropped = image.cropped(to: crop.ciRect)
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)))
        // A crop cannot increase the peak. Keep the source bound without another
        // GPU readback or a copy of the immutable raster.
        return PreviewRaster(image: cropped, width: crop.width, height: crop.height,
                             headroom: headroom, storage: storage)
    }
}

/// Still-photo display only. Core Animation adapts tagged drawables to the
/// screen's changing EDR capacity without modifying the source or export pixels.
public enum PreviewDisplay {
    public static func headroom(source: PreviewRaster, processed: PreviewRaster?,
                         comparisonFraction: CGFloat?) -> Float {
        guard let processed, processed.width == source.width, processed.height == source.height else {
            return source.headroom
        }
        guard let fraction = comparisonFraction else { return processed.headroom }
        if !fraction.isFinite || fraction <= 0 { return source.headroom }
        if fraction >= 1 { return processed.headroom }
        return max(source.headroom, processed.headroom)
    }

    /// Set before acquiring a drawable. CIImage headroom does not transfer to a
    /// Metal texture automatically, so the compositor needs its own metadata.
    public static func configure(_ layer: CAMetalLayer, headroom: Float) {
        let peak = min(ImagePipeline.maximumHDRValue, max(1, headroom))
        layer.wantsExtendedDynamicRangeContent = peak > 1
        if #available(iOS 26, macOS 26, *) {
            layer.edrMetadata = nil
            layer.contentsHeadroom = CGFloat(peak)
            layer.preferredDynamicRange = .high
            layer.toneMapMode = .ifSupported
        } else {
            // Legacy EDR metadata uses a display-referred 100-nit diffuse white.
            // This scale describes the drawable, not the saved PQ HEIF encoding.
            layer.edrMetadata = peak > 1 ? .hdr10(minLuminance: 0, maxLuminance: peak * 100,
                                                opticalOutputScale: 100) : nil
        }
    }
}

/// Both the editor and live camera use the same top-left Metal destination.
/// This changes presentation orientation only; it does not flip source pixels
/// or the coordinates used by photo effects and export.
public enum PreviewRendering {
    public static func render(_ image: CIImage, with context: CIContext, to texture: MTLTexture,
                       commandBuffer: MTLCommandBuffer, colorSpace: CGColorSpace) throws -> CIRenderTask {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.isFlipped = true
        return try context.startTask(toRender: image, to: destination)
    }
}
