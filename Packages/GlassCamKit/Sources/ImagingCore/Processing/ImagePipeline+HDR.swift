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
    static func encodeHDR(raster: ExportRasterFile, rasterBytes: Int, width: Int, height: Int,
                          output: (width: Int, height: Int), linear: CGColorSpace, pq: CGColorSpace,
                          outputHeadroom: Float, encodingContext: CIContext, metadata: PhotoMetadata,
                          recipe: ProcessingRecipe, to url: URL, isCancelled: @escaping @Sendable () -> Bool,
                          progress: @escaping @Sendable (Double) -> Void, timing: PipelineTiming?) throws {
        try checkExportCancellation(isCancelled)
        let outputGraphStarted = timing?.start()
        let data = try raster.mappedData(expectedBytes: rasterBytes)
        var image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf, colorSpace: linear)
        if output.width != width || output.height != height {
            // Color and spatial effects have already run at cropped source resolution.
            // The camera's 24/48MP policy can explicitly request interpolation.
            // Resampling stays in linear light after the original color/spatial stages.
            let scale = Double(output.height) / Double(height)
            let pixelAspect = Double(output.width) / Double(width) / scale
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                                                                                 kCIInputAspectRatioKey: pixelAspect])
                .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(output.width), height: CGFloat(output.height)))
        }
        // For revision 12 these filters execute in linear BT.2020. Remove
        // out-of-target-gamut/ringing values there, while keeping super-white
        // values up to PQ's physical ceiling. Legacy recipes retain their domain.
        image = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: CGFloat(maximumHDRValue), y: CGFloat(maximumHDRValue), z: CGFloat(maximumHDRValue), w: 1)
        ]).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(output.width), height: CGFloat(output.height)))
        if #available(iOS 26, macOS 26, *) { image = image.settingContentHeadroom(outputHeadroom) }
        timing?.record("output_graph", since: outputGraphStarted)
        do {
            // Encode actual extended-linear pixels into BT.2020/PQ 10-bit HDR.
            // Keep mapped storage and file alive until synchronous encoding returns.
            progress(0.9)
            try checkExportCancellation(isCancelled)
            let metadataStarted = timing?.start()
            image = image.settingProperties(metadata.encodingProperties(
                width: output.width, height: output.height,
                presetWhiteBalance: recipe.mode == .hncs && recipe.hncs.whiteBalancePolicy == .preset && recipe.hncs.presetWhiteBalanceKelvin != nil))
            timing?.record("capture_metadata", since: metadataStarted)
            let encodeStarted = timing?.start()
            try withExtendedLifetime((data, raster)) {
                try encodingContext.writeHEIF10Representation(of: image, to: url, colorSpace: pq, options: [:])
            }
            timing?.record("heif_encode_ci", since: encodeStarted)
            let validationStarted = timing?.start()
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
            timing?.record("output_validate", since: validationStarted)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
