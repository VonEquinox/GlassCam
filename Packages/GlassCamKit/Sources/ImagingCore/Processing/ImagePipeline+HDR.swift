import Foundation
import CoreImage
import ImageIO

extension ImagePipeline {
    /// Legacy revision-11 HNCS and the existing FFCS HDR adapter. Revision 12
    /// HNCS restores magnitude inside its working image before spatial effects.
    static func normalizeHighlights(_ rgb: inout [Float], exposureEV: Double = 0) throws -> [Float] {
        applyExposure(&rgb, exposureEV: exposureEV)
        guard rgb.count % 3 == 0, rgb.allSatisfy({ $0.isFinite }) else { throw PipelineError.rendering }
        var gains = [Float](repeating: 1, count: rgb.count / 3)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let gain = max(1, rgb[i], rgb[i + 1], rgb[i + 2])
            gains[i / 3] = gain
            if gain > 1 { for channel in 0..<3 { rgb[i + channel] /= gain } }
        }
        return gains
    }

    @discardableResult
    static func restoreHighlights(_ rgba: inout [Float], gains: [Float]) -> Float {
        var headroom: Float = 1
        for pixel in gains.indices {
            for channel in 0..<3 {
                let value = min(maximumHDRValue, max(0, rgba[pixel * 4 + channel] * gains[pixel]))
                rgba[pixel * 4 + channel] = value
                headroom = max(headroom, value)
            }
        }
        return headroom
    }
    /// Colour and spatial effects are complete before this linear-light resize.
    /// Extend edge samples so the reconstruction filter never mixes in black
    /// outside the finite source rectangle.
    static func resizedForExport(_ source: CIImage, width: Int, height: Int) -> CIImage {
        guard source.extent.width != CGFloat(width) || source.extent.height != CGFloat(height) else { return source }
        let scale = Double(height) / Double(source.extent.height)
        let aspect = Double(width) / Double(source.extent.width) / scale
        return source.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect
        ]).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func encodeHDR(raster: ExportRasterFile, rasterBytes: Int, width: Int, height: Int,
                          output: (width: Int, height: Int), linear: CGColorSpace, pq: CGColorSpace,
                          outputHeadroom: Float, encodingContext: CIContext, metadata: PhotoMetadata,
                          recipe: ProcessingRecipe, to url: URL, isCancelled: @escaping @Sendable () -> Bool,
                          progress: @escaping @Sendable (Double) -> Void) throws {
        try checkExportCancellation(isCancelled)
        var image = try raster.tiledImage(width: width, height: height, colorSpace: linear)
        image = resizedForExport(image, width: output.width, height: output.height)
        // For revision 12 these filters execute in linear BT.2020. Remove
        // out-of-target-gamut/ringing values there, while keeping super-white
        // values up to PQ's physical ceiling. Legacy recipes retain their domain.
        image = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: CGFloat(maximumHDRValue), y: CGFloat(maximumHDRValue), z: CGFloat(maximumHDRValue), w: 1)
        ]).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(output.width), height: CGFloat(output.height)))
        if #available(iOS 26, macOS 26, *) { image = image.settingContentHeadroom(outputHeadroom) }
        do {
            // Encode actual extended-linear pixels into BT.2020/PQ 10-bit HDR.
            // Keep mapped storage and file alive until synchronous encoding returns.
            progress(0.9)
            try checkExportCancellation(isCancelled)
            image = image.settingProperties(metadata.encodingProperties(
                width: output.width, height: output.height,
                presetWhiteBalance: recipe.mode == .hncs && recipe.hncs.whiteBalancePolicy == .preset && recipe.hncs.presetWhiteBalanceKelvin != nil))
            try withExtendedLifetime(raster) {
                try encodingContext.writeHEIF10Representation(of: image, to: url, colorSpace: pq,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
            }
            try raster.validateImageReads()
            try ImageFileProtection.apply(to: url)
            try checkExportCancellation(isCancelled)
            guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [String: Any],
                  (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == output.width,
                  (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == output.height,
                  (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10,
                  CIImage(contentsOf: url)?.colorSpace?.isHDR() == true else {
                throw PipelineError.encoding
            }
            try metadata.validate(in: properties)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
