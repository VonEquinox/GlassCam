import Foundation
import CoreImage
import UIKit
import ImageIO

struct ImportedImage: @unchecked Sendable {
    let sourceFile: SourceImageFile
    let exportSettings: ExportSettings
    let linearRGB: [Float]
    let width: Int
    let height: Int
    let original: UIImage
    let sourceDescription: String
}

/// Only implemented, audited backends belong in this list. Adding a mode must
/// implement both preview and float export dispatch before exposing it in the UI.
enum ColorMode: String, CaseIterable, Identifiable, Sendable {
    case hncs, ffcs
    var id: Self { self }
    var title: String {
        switch self {
        case .hncs: return "HNCS"
        case .ffcs: return "FFCS"
        }
    }
}

/// Immutable settings captured before background work starts. Export must use
/// the rendered recipe, including its engine, rather than current editor controls.
struct ProcessingRecipe: Equatable, Sendable {
    let mode: ColorMode
    let exposureEV: Double
    let illuminantKelvin: Double
    let simulationIndex: Int
    let seed: UInt32

    var displayName: String {
        mode == .ffcs ? "FFCS · \(FFCSEngine.simulationName(at: simulationIndex))" : mode.title
    }
}

struct ProcessedImage: @unchecked Sendable {
    let image: UIImage
    // Snapshot belongs to this rendered preview, not the current slider positions.
    // Copy-on-write source storage avoids a persistent additional RGBAf buffer.
    let source: ImportedImage
    let recipe: ProcessingRecipe
    var exposureEV: Double { recipe.exposureEV }
    var illuminantKelvin: Double { recipe.illuminantKelvin }
}

enum PipelineError: LocalizedError {
    case invalidImage, rendering, encoding, unsupportedOutput
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image could not be decoded. Try a JPEG, PNG, HEIC, or supported DNG."
        case .rendering: return "The image renderer could not create an output."
        case .unsupportedOutput: return "The selected output dimensions exceed the genuine source or change its aspect ratio. Capture at a supported resolution; upsampling is disabled."
        case .encoding: return "The processed image could not be encoded as 10-bit SDR HEIF. No lower-bit-depth fallback was saved."
        }
    }
}

/// Experimental source adaptation. This is not a calibrated camera-native RGB profile.
/// Core Image honors embedded profiles and converts to extended linear sRGB.
/// Only the display preview is reduced. Export always reloads the immutable source.
enum ImagePipeline {
    static let maximumEdge: CGFloat = 2048
    // A cancelled detached task may finish its current decoder call. Serialize the
    // complete decode/render stage so superseded RAW decodes never overlap.
    private static let decodeQueue = DispatchQueue(label: "dev.glasscam.decode", qos: .userInitiated)

    static func load(data: Data, fileExtension: String?, previewMaximumEdge: Int = 2048,
                     exportSettings: ExportSettings = .native) throws -> ImportedImage {
        try decodeQueue.sync {
            try autoreleasepool {
                guard (256...4096).contains(previewMaximumEdge) else { throw PipelineError.invalidImage }
                let retained = try SourceImageFile(data: data, fileExtension: fileExtension)
                return try decode(data: data, fileExtension: fileExtension, sourceFile: retained, maximumEdge: CGFloat(previewMaximumEdge), exportSettings: exportSettings)
            }
        }
    }

    private static func decode(data: Data, fileExtension: String?, sourceFile: SourceImageFile, maximumEdge: CGFloat, exportSettings: ExportSettings) throws -> ImportedImage {
        let isRAW = ["dng", "raw"].contains(fileExtension?.lowercased() ?? "")
        var source: CIImage?
        if isRAW {
            if let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") {
                // Set the decoder orientation explicitly from source metadata. Do not
                // apply a second CIImage orientation transform to the decoder output.
                if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                   let exif = properties[kCGImagePropertyOrientation as String] as? NSNumber,
                   let orientation = CGImagePropertyOrientation(rawValue: exif.uint32Value) {
                    raw.orientation = orientation
                }
                let native = raw.nativeSize
                let longEdge = max(native.width, native.height)
                guard longEdge.isFinite, longEdge > 0 else { throw PipelineError.invalidImage }
                // Ask the RAW decoder for reduced output before evaluating outputImage.
                // This reduces requested output size; Apple may still use full-size
                // intermediate buffers internally, so it is not a peak-memory guarantee.
                raw.scaleFactor = Float(min(1, maximumEdge / longEdge))
                source = raw.outputImage
            }
        } else {
            let sourceOptions = [kCGImageSourceShouldCache as String: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw PipelineError.invalidImage
            }
            let thumbnailOptions: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: Int(maximumEdge),
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceShouldCacheImmediately as String: true,
                kCGImageSourceShouldAllowFloat as String: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
                throw PipelineError.invalidImage
            }
            // CIImage takes the thumbnail CGImage's embedded color space. Do not
            // force sRGB here: Core Image performs the later linear-sRGB conversion.
            // ImageIO has already applied EXIF orientation during thumbnail creation.
            source = CIImage(cgImage: thumbnail)
        }
        guard var image = source, !image.extent.isEmpty, !image.extent.isInfinite else {
            throw PipelineError.invalidImage
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                       y: -image.extent.minY))
        let scale = min(1, maximumEdge / max(image.extent.width, image.extent.height))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let width = max(1, Int(image.extent.width.rounded(.down)))
        let height = max(1, Int(image.extent.height.rounded(.down)))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear])
        // Transparent inputs are intentionally flattened onto black before color conversion.
        image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        guard let originalCG = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: sRGB)
        else { throw PipelineError.rendering }
        var rgb = [Float]()
        rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            rgb.append(contentsOf: pixels[i..<(i + 3)])
        }
        return ImportedImage(sourceFile: sourceFile, exportSettings: exportSettings, linearRGB: rgb, width: width, height: height,
                             original: UIImage(cgImage: originalCG),
                             sourceDescription: isRAW ? "DNG • Apple RAW decode • experimental adapter" : "Rendered image • embedded profile → linear sRGB")
    }

    static func process(_ input: ImportedImage, recipe: ProcessingRecipe) throws -> ProcessedImage {
        let rgba: [UInt8]
        switch recipe.mode {
        case .hncs:
            rgba = try HNCSEngine.process(linearSRGB: input.linearRGB, width: input.width,
                                          height: input.height, exposureEV: recipe.exposureEV,
                                          illuminantKelvin: recipe.illuminantKelvin)
        case .ffcs:
            rgba = try FFCSEngine.process(linearSRGB: input.linearRGB, width: input.width,
                                          height: input.height, exposureEV: recipe.exposureEV,
                                          simulationIndex: recipe.simulationIndex, seed: recipe.seed)
        }
        guard rgba.count == input.width * input.height * 4,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: input.width, height: input.height,
                               bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: input.width * 4,
                               space: colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { throw PipelineError.rendering }
        let image = UIImage(cgImage: cg)
        return ProcessedImage(image: image, source: input, recipe: recipe)
    }

    /// Export from the retained full-resolution capture, with its immutable recipe.
    /// Exact color processing precedes any reduction to the requested output size.
    /// App-owned scratch is O(width * stripRows); Apple RAW/ImageIO/CI/HEIF may
    /// allocate full-size internal surfaces. Device peak-RSS validation is required.
    static func writeHEIF(_ processed: ProcessedImage, to url: URL,
                          settings: ExportSettings? = nil) throws {
        try decodeQueue.sync {
            try autoreleasepool {
                try exportFullSource(processed, to: url, settings: settings ?? processed.source.exportSettings)
            }
        }
    }

    private static func fullSourceImage(_ source: SourceImageFile) throws -> CIImage {
        let isRAW = ["dng", "raw"].contains(source.fileExtension?.lowercased() ?? "")
        var decoded: CIImage?
        if isRAW {
            if let raw = CIRAWFilter(imageURL: source.url) {
                if let container = CGImageSourceCreateWithURL(source.url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
                   let exif = properties[kCGImagePropertyOrientation as String] as? NSNumber,
                   let orientation = CGImagePropertyOrientation(rawValue: exif.uint32Value) {
                    raw.orientation = orientation
                }
                raw.scaleFactor = 1 // Genuine decoder output, never the preview scale.
                decoded = raw.outputImage
            }
        } else {
            decoded = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true])
        }
        guard let image = decoded, !image.extent.isEmpty, !image.extent.isInfinite,
              image.extent.width.isFinite, image.extent.height.isFinite else {
            throw PipelineError.invalidImage
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))
    }

    private static func exportFullSource(_ processed: ProcessedImage, to url: URL,
                                          settings: ExportSettings) throws {
        let decoded = try fullSourceImage(processed.source.sourceFile)
        // Protect all byte-count arithmetic before allocating or creating a file.
        guard decoded.extent.width < CGFloat(Int.max / 16),
              decoded.extent.height < CGFloat(Int.max / 16) else { throw PipelineError.invalidImage }
        let width = Int(decoded.extent.width.rounded(.down))
        let height = Int(decoded.extent.height.rounded(.down))
        guard width > 0, height > 0, width <= Int.max / 16 / height else { throw PipelineError.invalidImage }
        let output = try settings.dimensions(sourceWidth: width, sourceHeight: height)
        let rasterBytes = width * height * 16
        let capacity = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Allow the uncompressed raster plus a conservative encoded-output margin.
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           Double(available) < Double(rasterBytes) * 1.5 + 64 * 1024 * 1024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let source = decoded.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        let raster = try ExportRasterFile()
        let recipe = processed.recipe
        let stripRows = 64
        for start in stride(from: 0, to: height, by: stripRows) {
            try Task.checkCancellation()
            try autoreleasepool {
                let rows = min(stripRows, height - start)
                let halo = recipe.mode == .ffcs ? 1 : 0
                let inputStart = max(0, start - halo)
                let inputEnd = min(height, start + rows + halo)
                let inputRows = inputEnd - inputStart
                var decodedRGBA = [Float](repeating: 0, count: width * inputRows * 4)
                decodedRGBA.withUnsafeMutableBytes { buffer in
                    context.render(source, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                   bounds: CGRect(x: 0, y: CGFloat(inputStart), width: CGFloat(width), height: CGFloat(inputRows)),
                                   format: .RGBAf, colorSpace: linear)
                }
                var rgb = [Float](repeating: 0, count: width * inputRows * 3)
                for pixel in 0..<(width * inputRows) {
                    for channel in 0..<3 { rgb[pixel * 3 + channel] = decodedRGBA[pixel * 4 + channel] }
                }
                let rgba: [Float]
                switch recipe.mode {
                case .hncs:
                    rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: width, height: rows,
                                                           exposureEV: recipe.exposureEV,
                                                           illuminantKelvin: recipe.illuminantKelvin)
                case .ffcs:
                    let rendered = try FFCSEngine.exportLinearRGBStrip(
                        linearSRGB: rgb, fullWidth: width, fullHeight: height,
                        inputOriginY: inputStart, inputRows: inputRows,
                        outputOriginY: start, outputRows: rows,
                        exposureEV: recipe.exposureEV, simulationIndex: recipe.simulationIndex, seed: recipe.seed)
                    var expanded = [Float](repeating: 1, count: width * rows * 4)
                    for pixel in 0..<(width * rows) {
                        for channel in 0..<3 { expanded[pixel * 4 + channel] = rendered[pixel * 3 + channel] }
                    }
                    rgba = expanded
                }
                guard rgba.count == width * rows * 4,
                      rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                try raster.append(rgba)
            }
        }
        let data = try raster.mappedData(expectedBytes: rasterBytes)
        var image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf, colorSpace: linear)
        if output.width != width || output.height != height {
            // Color and spatial FFCS effects have already run at source resolution.
            // Lanczos executes in linear light, with no fake higher-resolution path.
            let scale = Double(output.height) / Double(height)
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                                                                                 kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(output.width), height: CGFloat(output.height)))
            // Lanczos ringing can leave [0,1]; SDR encoder input must stay bounded.
            image = image.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                                     "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        }
        do {
            // Fresh untagged raster: no source gain map, HDR metadata, PQ or HLG.
            // Keep mapped storage and file alive until synchronous encoding returns.
            try withExtendedLifetime((data, raster)) {
                try context.writeHEIF10Representation(of: image, to: url, colorSpace: sRGB, options: [:])
            }
            guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [String: Any],
                  (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == output.width,
                  (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == output.height,
                  (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10 else {
                throw PipelineError.encoding
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
