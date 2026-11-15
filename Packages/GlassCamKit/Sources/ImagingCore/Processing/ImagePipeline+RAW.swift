import Foundation
import CoreImage
import ImageIO

extension ImagePipeline {
    private static let sharedPreviewColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private static let sharedPreviewContext: CIContext? = sharedPreviewColorSpace.map {
        CIContext(options: [.workingColorSpace: $0,
                            .workingFormat: CIFormat.RGBAf.rawValue])
    }

    static func baselineSharpness(in properties: [AnyHashable: Any]) throws -> Double {
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        guard let value = dng?[kCGImagePropertyDNGBaselineSharpness as String] else { return 0 }
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else {
            throw PipelineError.invalidImage
        }
        return number.doubleValue
    }
    package static func sourceISO(in properties: [AnyHashable: Any]) -> Int? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        guard let values = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
              let iso = values.first?.doubleValue, iso.isFinite, (1...1_000_000).contains(iso) else { return nil }
        return Int(iso.rounded())
    }

    /// Shared by reduced RAW decode, metadata-only capture binding, and full
    /// source export. Pin the selected decoder before reading the scene neutral.
    static func configureRAW(_ raw: CIRAWFilter, recipe: RAWDecodeRecipe,
                                     whiteBalance: PhotoWhiteBalance? = nil) throws -> RAWDecodeRecipe {
        guard recipe.isValid else { throw PipelineError.invalidImage }
        let version = recipe.decoderVersion ?? raw.decoderVersion.rawValue
        guard raw.supportedDecoderVersions.contains(where: { $0.rawValue == version }) else {
            throw PipelineError.invalidImage
        }
        if raw.decoderVersion.rawValue != version { raw.decoderVersion = CIRAWDecoderVersion(rawValue: version) }
        // CRawImageFile::GetBaselineSharpness initializes its return value to 0
        // before reading DNG tag 50732. Missing does not mean a made-up 1.5.
        let sourceBaseline = try baselineSharpness(in: raw.properties)
        guard sourceBaseline.isFinite, sourceBaseline >= 0,
              recipe.baselineSharpness == nil || recipe.baselineSharpness == sourceBaseline else {
            throw PipelineError.invalidImage
        }
        if let amount = recipe.sharpnessAmount, raw.isSharpnessSupported {
            raw.sharpnessAmount = amount
            guard raw.sharpnessAmount == amount else { throw PipelineError.rendering }
        }
        if let value = raw.properties[kCGImagePropertyOrientation as String] as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) {
            raw.orientation = orientation
        }
        if let whiteBalance, whiteBalance.origin == .appleRAW {
            raw.neutralChromaticity = CGPoint(x: whiteBalance.x, y: whiteBalance.y)
        }
        if recipe.decoderExposureEV != 0 { raw.exposure = recipe.decoderExposureEV }
        if recipe.rendering == .sceneLinear {
            // Apple's WWDC21 10160 scene-referred recipe. boostShadowAmount is
            // inactive at boostAmount=0 and is deliberately left at its default.
            raw.baselineExposure = 0
            raw.shadowBias = 0
            raw.boostAmount = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.isGamutMappingEnabled = false
        } else if recipe.rendering == .cameraNeutral {
            // boostAmount is specifically the global tone curve (CIRAWFilter.h).
            // Keep per-photo BaselineExposure and local tone mapping: clearing
            // those too makes ProRAW underexposed and loses lifted shadows.
            raw.boostAmount = 0
        }
        raw.extendedDynamicRangeAmount = recipe.edrAmount ?? (recipe.rendering == .sceneLinear ? 0 : 1)
        return RAWDecodeRecipe(rendering: recipe.rendering, decoderVersion: version,
            linearExposureEV: recipe.linearExposureEV, decoderExposureEV: recipe.decoderExposureEV,
            edrAmount: recipe.edrAmount, sharpnessAmount: recipe.sharpnessAmount,
            baselineSharpness: sourceBaseline)
    }

    private static func rawOutput(_ raw: CIRAWFilter, recipe: RAWDecodeRecipe) -> CIImage? {
        guard let image = raw.outputImage else { return nil }
        // Explicit scalar adjustment in the render context's linear working
        // space, before HNCS; never per-channel or automatic histogram matching.
        return recipe.linearExposureEV == 0 ? image : image.applyingFilter("CIExposureAdjust",
            parameters: [kCIInputEVKey: recipe.linearExposureEV])
    }

    static func inspectRAW(sourceFile: SourceImageFile, recipe: RAWDecodeRecipe = .current) throws -> [String: Any] {
        try decodeQueue.sync {
            guard let raw = CIRAWFilter(imageURL: sourceFile.url) else { throw PipelineError.invalidImage }
            func parameters() -> [String: Any] {
                ["decoder_version": raw.decoderVersion.rawValue,
                 "supported_decoder_versions": raw.supportedDecoderVersions.map(\.rawValue),
                 "baseline_exposure": raw.baselineExposure, "exposure": raw.exposure,
                 "shadow_bias": raw.shadowBias, "boost_amount": raw.boostAmount,
                 "boost_shadow_amount": raw.boostShadowAmount,
                 "local_tone_map_amount": raw.localToneMapAmount,
                 "local_tone_map_supported": raw.isLocalToneMapSupported,
                 "sharpness_amount": raw.sharpnessAmount, "sharpness_supported": raw.isSharpnessSupported,
                 "gamut_mapping": raw.isGamutMappingEnabled, "edr_amount": raw.extendedDynamicRangeAmount,
                 "white_xy": [raw.neutralChromaticity.x, raw.neutralChromaticity.y],
                 "temperature": raw.neutralTemperature, "tint": raw.neutralTint,
                 "native_width": raw.nativeSize.width, "native_height": raw.nativeSize.height,
                 "orientation": raw.orientation.rawValue, "draft_mode": raw.isDraftModeEnabled]
            }
            let defaults = parameters()
            let resolved = try configureRAW(raw, recipe: recipe)
            return ["defaults": defaults, "configured": parameters(),
                    "recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved))]
        }
    }

    public static func load(data: Data, fileExtension: String?, previewMaximumEdge: Int = 2048,
                     exportSettings: ExportSettings = .native, rawDecode: RAWDecodeRecipe = .current) throws -> ImportedImage {
        try decodeQueue.sync {
            try autoreleasepool {
                guard (256...4096).contains(previewMaximumEdge) else { throw PipelineError.invalidImage }
                let retained = try SourceImageFile(data: data, fileExtension: fileExtension)
                return try decode(data: data, fileExtension: fileExtension, sourceFile: retained, maximumEdge: CGFloat(previewMaximumEdge), exportSettings: exportSettings, rawDecode: rawDecode)
            }
        }
    }

    /// Reuse the retained shutter source instead of writing a second DNG copy.
    public static func load(sourceFile: SourceImageFile, exportSettings: ExportSettings, rawDecode: RAWDecodeRecipe = .current) throws -> ImportedImage {
        try decodeQueue.sync {
            try autoreleasepool {
                let data = try Data(contentsOf: sourceFile.url)
                return try decode(data: data, fileExtension: sourceFile.fileExtension,
                                  sourceFile: sourceFile, maximumEdge: maximumEdge, exportSettings: exportSettings, rawDecode: rawDecode)
            }
        }
    }

    /// Decode a bounded HDR preview raster directly from a saved file URL without
    /// writing a duplicate temporary file or allocating an unused linearRGB array.
    public static func decodePreviewRaster(at url: URL, maximumEdge: Int = 2048) throws -> (raster: PreviewRaster, pixelWidth: Int, pixelHeight: Int) {
        try decodeQueue.sync {
            try autoreleasepool {
                guard (64...4096).contains(maximumEdge) else { throw PipelineError.invalidImage }
                let sourceOptions = [kCGImageSourceShouldCache as String: false] as CFDictionary
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                      let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                      let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
                    throw PipelineError.encoding
                }
                let thumbnailOptions: [String: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                    kCGImageSourceThumbnailMaxPixelSize as String: maximumEdge,
                    kCGImageSourceCreateThumbnailWithTransform as String: true,
                    kCGImageSourceShouldCacheImmediately as String: true,
                    kCGImageSourceShouldAllowFloat as String: true,
                    kCGImageSourceDecodeRequest as String: kCGImageSourceDecodeToHDR
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
                    throw PipelineError.invalidImage
                }
                var image = CIImage(cgImage: thumbnail)
                guard !image.extent.isEmpty, !image.extent.isInfinite else { throw PipelineError.invalidImage }
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                y: -image.extent.minY))
                let edge = CGFloat(maximumEdge)
                let scale = min(1, edge / max(image.extent.width, image.extent.height))
                if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
                let width = max(1, Int(image.extent.width.rounded(.down)))
                let height = max(1, Int(image.extent.height.rounded(.down)))
                let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
                guard let linear = sharedPreviewColorSpace,
                      let context = sharedPreviewContext else { throw PipelineError.rendering }
                image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
                    .cropped(to: bounds)
                var pixels = Data(count: width * height * 16)
                pixels.withUnsafeMutableBytes { bytes in
                    context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                                   bounds: bounds, format: .RGBAf, colorSpace: linear)
                }
                let raster = try PreviewRaster(linearRGBAData: pixels, width: width, height: height)
                return (raster, pixelWidth.intValue, pixelHeight.intValue)
            }
        }
    }

    static func decode(data: Data, fileExtension: String?, sourceFile: SourceImageFile, maximumEdge: CGFloat, exportSettings: ExportSettings, rawDecode: RAWDecodeRecipe,
                               baseRAWDecode: RAWDecodeRecipe? = nil,
                               frozenWhiteBalance: PhotoWhiteBalance? = nil) throws -> ImportedImage {
        let isRAW = sourceFile.isRAW
        var source: CIImage?
        var whiteBalance = PhotoWhiteBalance.renderedD65
        var resolvedRAWDecode = rawDecode
        var captureISO: Int?
        var decodePrecisionDescription = "Float32 RAW decode · not sensor-native bit depth"
        if isRAW {
            if let raw = CIRAWFilter(imageURL: sourceFile.url) {
                resolvedRAWDecode = try configureRAW(raw, recipe: rawDecode, whiteBalance: frozenWhiteBalance)
                whiteBalance = frozenWhiteBalance ?? .asShot(raw)
                captureISO = sourceISO(in: raw.properties)
                let native = raw.nativeSize
                let longEdge = max(native.width, native.height)
                guard longEdge.isFinite, longEdge > 0 else { throw PipelineError.invalidImage }
                // Ask the RAW decoder for reduced output before evaluating outputImage.
                // This reduces requested output size; Apple may still use full-size
                // intermediate buffers internally, so it is not a peak-memory guarantee.
                raw.scaleFactor = Float(min(1, maximumEdge / longEdge))
                source = rawOutput(raw, recipe: resolvedRAWDecode)
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
                kCGImageSourceShouldAllowFloat as String: true,
                kCGImageSourceDecodeRequest as String: kCGImageSourceDecodeToHDR
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
        guard let linear = sharedPreviewColorSpace,
              let context = sharedPreviewContext else { throw PipelineError.rendering }
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
        let rgb = try FloatRasterOperations.rgb(fromRGBA: pixels)
        return ImportedImage(sourceFile: sourceFile, exportSettings: exportSettings, linearRGB: rgb, width: width, height: height,
                             original: original,
                             sourceDescription: isRAW ? "RAW • Apple RAW decode • experimental adapter • \(decodePrecisionDescription)" : "Rendered image • embedded profile → linear sRGB • \(decodePrecisionDescription)",
                             whiteBalance: whiteBalance, rawDecode: resolvedRAWDecode, sourceISO: captureISO,
                             baseRAWDecode: baseRAWDecode ?? resolvedRAWDecode, previewMaximumEdge: Int(maximumEdge))
    }

    static func fullSourceImage(_ source: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                rawDecode: RAWDecodeRecipe, stabilizeRAWDecode: Bool = false) throws -> CIImage {
        let isRAW = source.isRAW
        var decoded: CIImage?
        if isRAW {
            if let raw = CIRAWFilter(imageURL: source.url) {
                let resolved = try configureRAW(raw, recipe: rawDecode, whiteBalance: whiteBalance)
                raw.scaleFactor = 1 // Genuine decoder output, never the preview scale.
                decoded = rawOutput(raw, recipe: resolved)
                if stabilizeRAWDecode, raw.isSharpnessSupported, raw.sharpnessAmount > 0, let image = decoded {
                    // Re-evaluating sharpened RAW for each small ROI can vary
                    // a few Float32 samples. Fixed cached tiles keep repeated
                    // exports stable without disabling Apple's source detail.
                    guard #available(iOS 26, macOS 26, *) else { throw PipelineError.rendering }
                    decoded = image.insertingTiledIntermediate()
                }
            }
        } else {
            decoded = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true, .expandToHDR: true])
        }
        guard let image = decoded, !image.extent.isEmpty, !image.extent.isInfinite,
              image.extent.width.isFinite, image.extent.height.isFinite else {
            throw PipelineError.invalidImage
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))
    }
}
