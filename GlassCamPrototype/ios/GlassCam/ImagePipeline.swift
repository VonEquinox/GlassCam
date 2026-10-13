import Foundation
import CoreImage
import ImageIO

/// Explicit cancellation crosses the GCD decoder queue; it does not depend on
/// Swift task-local cancellation surviving a synchronous DispatchQueue hop.
final class ImageOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct ImportedImage: @unchecked Sendable {
    let sourceFile: SourceImageFile
    let exportSettings: ExportSettings
    let linearRGB: [Float]
    let width: Int
    let height: Int
    let original: PreviewRaster
    let sourceDescription: String
}

/// Only implemented, audited backends belong in this list. Adding a mode must
/// implement both preview and float export dispatch before exposing it in the UI.
enum ColorMode: String, CaseIterable, Identifiable, Codable, Sendable {
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
struct ProcessingRecipe: Codable, Equatable, Sendable {
    let mode: ColorMode
    let exposureEV: Double
    let illuminantKelvin: Double
    let simulationIndex: Int
    let seed: UInt32
    let hncs: HNCSSettings
    var crop: ImageCrop { mode == .hncs ? hncs.crop : .none }

    static let standard = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                                            simulationIndex: 0, seed: 0, hncs: .standard)
    var isValid: Bool {
        exposureEV.isFinite && (-2...2).contains(exposureEV) &&
        illuminantKelvin.isFinite && (2000...10000).contains(illuminantKelvin) &&
        (0..<Int(ffcs_simulation_count())).contains(simulationIndex) && hncs.isValid
    }

    var displayName: String {
        mode == .ffcs ? "FFCS · \(FFCSEngine.simulationName(at: simulationIndex))" : "HNCS · \(hncs.presetTitle) · \(hncs.filmCurve.title)"
    }
}

struct ProcessedImage: @unchecked Sendable {
    let image: PreviewRaster
    let comparisonSource: PreviewRaster
    // Snapshot belongs to this rendered preview, not the current slider positions.
    // Source and processed previews retain immutable Float32 rasters for GPU display.
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
        case .unsupportedOutput: return "The selected sensor output exceeds the genuine source or changes its uncropped aspect ratio. Capture at a supported resolution; upsampling is disabled."
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
        var decodePrecisionDescription = "Float32 RAW decode · not sensor-native bit depth"
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
            decodePrecisionDescription = "\(thumbnail.bitsPerComponent)-bit decoded thumbnail source"
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
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue])
        // Transparent inputs are intentionally flattened onto black before color conversion.
        image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        // Retain the actual decoded float pixels. ImageIO thumbnail decoding may
        // already have source precision limits; this display route cannot restore them.
        let original = try PreviewRaster(linearRGBA: pixels, width: width, height: height)
        var rgb = [Float]()
        rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            rgb.append(contentsOf: pixels[i..<(i + 3)])
        }
        return ImportedImage(sourceFile: sourceFile, exportSettings: exportSettings, linearRGB: rgb, width: width, height: height,
                             original: original,
                             sourceDescription: isRAW ? "DNG • Apple RAW decode • experimental adapter • \(decodePrecisionDescription)" : "Rendered image • embedded profile → linear sRGB • \(decodePrecisionDescription)")
    }

    static func process(_ input: ImportedImage, recipe: ProcessingRecipe) throws -> ProcessedImage {
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: input.width, height: input.height)
        let comparisonSource = try input.original.cropped(to: crop)
        let rgb: [Float]
        if crop.width == input.width && crop.height == input.height {
            rgb = input.linearRGB
        } else {
            var pixels = [Float]()
            pixels.reserveCapacity(crop.width * crop.height * 3)
            // CIContext bitmap and PreviewRaster share lower-left row ordering.
            for row in crop.ciY..<(crop.ciY + crop.height) {
                let start = (row * input.width + crop.x) * 3
                pixels.append(contentsOf: input.linearRGB[start..<(start + crop.width * 3)])
            }
            rgb = pixels
        }
        // Crop before pointwise/spatial processing, just as the source reference.
        // Exact engines return display-linear Float32; no byte encoder runs.
        let rgba: [Float]
        switch recipe.mode {
        case .hncs:
            rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.exposureEV,
                                                   illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs)
        case .ffcs:
            rgba = try FFCSEngine.exportLinearRGBA(linearSRGB: rgb, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.exposureEV,
                                                   simulationIndex: recipe.simulationIndex, seed: recipe.seed)
        }
        let image = try PreviewRaster(linearRGBA: rgba, width: crop.width, height: crop.height)
        return ProcessedImage(image: image, comparisonSource: comparisonSource, source: input, recipe: recipe)
    }

    /// Export from the retained full-resolution capture, with its immutable recipe.
    /// Exact color processing precedes any reduction to the requested output size.
    /// App-owned scratch is O(width * stripRows); Apple RAW/ImageIO/CI/HEIF may
    /// allocate full-size internal surfaces. Device peak-RSS validation is required.
    static func writeHEIF(_ processed: ProcessedImage, to url: URL,
                          settings: ExportSettings? = nil,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        try decodeQueue.sync {
            try autoreleasepool {
                try exportFullSource(processed, to: url, settings: settings ?? processed.source.exportSettings, isCancelled: isCancelled, progress: progress)
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

    private static func checkExportCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func exportFullSource(_ processed: ProcessedImage, to url: URL,
                                          settings: ExportSettings, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void) throws {
        try checkExportCancellation(isCancelled)
        progress(0)
        let decoded = try fullSourceImage(processed.source.sourceFile)
        try checkExportCancellation(isCancelled)
        // Protect all byte-count arithmetic before allocating or creating a file.
        guard decoded.extent.width < CGFloat(Int.max / 16),
              decoded.extent.height < CGFloat(Int.max / 16) else { throw PipelineError.invalidImage }
        let sourceWidth = Int(decoded.extent.width.rounded(.down))
        let sourceHeight = Int(decoded.extent.height.rounded(.down))
        let recipe = processed.recipe
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: sourceWidth, height: sourceHeight)
        let width = crop.width, height = crop.height
        guard width > 0, height > 0, width <= Int.max / 16 / height else { throw PipelineError.invalidImage }
        let output = try settings.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: recipe.crop)
        let rasterBytes = width * height * 16
        let capacity = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Reserve RGBAf + encoded-output margin and, when needed, 12-byte RGB
        // work plus a conservative 20-byte/pixel global spatial scratch budget.
        let needsSpatial = recipe.mode == .hncs && recipe.hncs.requiresSpatial
        let spatialBytes = needsSpatial ? Double(width) * Double(height) * 32 : 0
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           Double(available) < Double(rasterBytes) * 1.5 + spatialBytes + 64 * 1024 * 1024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let croppedSource = decoded.cropped(to: crop.ciRect)
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)))
        let source = croppedSource.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        let raster = try ExportRasterFile()
        let spatialWork = needsSpatial ? try HNCSPresetWorkFile(width: width, height: height) : nil
        let stripRows = 64
        for start in stride(from: 0, to: height, by: stripRows) {
            try checkExportCancellation(isCancelled)
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
                if let spatialWork {
                    let work = try HNCSEngine.presetWork(linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs)
                    try spatialWork.writeBottomUpRows(work, originY: start, rows: rows)
                    progress(0.1 + 0.35 * Double(start + rows) / Double(height))
                    return
                }
                let rgba: [Float]
                switch recipe.mode {
                case .hncs:
                    rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: width, height: rows,
                                                           exposureEV: recipe.exposureEV,
                                                           illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs)
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
                progress(0.1 + 0.75 * Double(start + rows) / Double(height))
            }
        }
        if let spatialWork {
            try checkExportCancellation(isCancelled)
            progress(0.45)
            // Grain normalization and USM see one complete cropped top-down
            // image, never independently seeded 64-row strips.
            try HNCSEngine.applySpatial(to: spatialWork, settings: recipe.hncs, isCancelled: isCancelled)
            progress(0.65)
            for start in stride(from: 0, to: height, by: stripRows) {
                try checkExportCancellation(isCancelled)
                try autoreleasepool {
                    let rows = min(stripRows, height - start)
                    let work = try spatialWork.readBottomUpRows(originY: start, rows: rows)
                    let rgba = try HNCSEngine.finishPresetWork(work, width: width, height: rows,
                        exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs)
                    guard rgba.count == width * rows * 4,
                          rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                    try raster.append(rgba)
                    progress(0.65 + 0.2 * Double(start + rows) / Double(height))
                }
            }
        }
        try checkExportCancellation(isCancelled)
        let data = try raster.mappedData(expectedBytes: rasterBytes)
        var image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf, colorSpace: linear)
        if output.width != width || output.height != height {
            // Color and spatial effects have already run at cropped source resolution.
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
            progress(0.9)
            try checkExportCancellation(isCancelled)
            try withExtendedLifetime((data, raster)) {
                try context.writeHEIF10Representation(of: image, to: url, colorSpace: sRGB, options: [:])
            }
            try checkExportCancellation(isCancelled)
            guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [String: Any],
                  (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == output.width,
                  (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == output.height,
                  (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10 else {
                throw PipelineError.encoding
            }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
