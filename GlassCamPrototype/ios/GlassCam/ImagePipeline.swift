import Foundation
import CoreImage
import UIKit
import ImageIO

struct ImportedImage: @unchecked Sendable {
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
    case invalidImage, rendering, encoding
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image could not be decoded. Try a JPEG, PNG, HEIC, or supported DNG."
        case .rendering: return "The image renderer could not create an output."
        case .encoding: return "The processed image could not be encoded as 10-bit SDR HEIF. No lower-bit-depth fallback was saved."
        }
    }
}

/// Experimental source adaptation. This is not a calibrated camera-native RGB profile.
/// Core Image honors embedded profiles and converts to extended linear sRGB.
/// Processing and export are deliberately capped at 2048 pixels on the long edge.
enum ImagePipeline {
    static let maximumEdge: CGFloat = 2048
    // A cancelled detached task may finish its current decoder call. Serialize the
    // complete decode/render stage so superseded RAW decodes never overlap.
    private static let decodeQueue = DispatchQueue(label: "dev.glasscam.decode", qos: .userInitiated)

    static func load(data: Data, fileExtension: String?) throws -> ImportedImage {
        try decodeQueue.sync {
            try autoreleasepool { try decode(data: data, fileExtension: fileExtension) }
        }
    }

    private static func decode(data: Data, fileExtension: String?) throws -> ImportedImage {
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
        return ImportedImage(linearRGB: rgb, width: width, height: height,
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

    /// Export independently from the UInt8 display preview. The numerical core returns
    /// display-linear sRGB floats in [0, 1] after each backend’s output inverse. Core Image
    /// applies the sRGB transfer function exactly once when encoding the HEIF.
    static func writeHEIF(_ processed: ProcessedImage, to url: URL) throws {
        try autoreleasepool {
            let source = processed.source
            let rgba: [Float]
            switch processed.recipe.mode {
            case .hncs:
                rgba = try HNCSEngine.exportLinearRGBA(
                    linearSRGB: source.linearRGB, width: source.width, height: source.height,
                    exposureEV: processed.exposureEV, illuminantKelvin: processed.illuminantKelvin)
            case .ffcs:
                rgba = try FFCSEngine.exportLinearRGBA(
                    linearSRGB: source.linearRGB, width: source.width, height: source.height,
                    exposureEV: processed.exposureEV, simulationIndex: processed.recipe.simulationIndex,
                    seed: processed.recipe.seed)
            }
            guard rgba.count == source.width * source.height * 4,
                  rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw PipelineError.rendering
            }
            let data = rgba.withUnsafeBytes { Data($0) }
            let image = CIImage(bitmapData: data, bytesPerRow: source.width * 16,
                                size: CGSize(width: CGFloat(source.width), height: CGFloat(source.height)),
                                format: .RGBAf, colorSpace: linear)
            let context = CIContext(options: [.workingColorSpace: linear,
                                              .workingFormat: CIFormat.RGBAf.rawValue])
            // Standard-gamut, SDR sRGB. No PQ/HLG, extended-range values, HDR
            // expansion, gain-map image, or source properties enter this new image.
            // This dedicated encoder requests 10 bits; do not substitute the generic
            // writeHEIFRepresentation API or pass the 8-bit UIImage here.
            do {
                try context.writeHEIF10Representation(of: image, to: url,
                                                       colorSpace: sRGB, options: [:])
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) > 0 else { throw PipelineError.encoding }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

}
