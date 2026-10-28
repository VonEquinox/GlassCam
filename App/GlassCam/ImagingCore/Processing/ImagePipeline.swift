import Foundation
import CoreImage
import ImageIO

/// Opt-in wall-clock spans for the synchronous export queue. The caller reads
/// this object only after writeHEIF returns. Normal exports pass nil; timings
/// never insert renders, synchronize extra GPU work, or change pixel math.
final class PipelineTiming: @unchecked Sendable {
    private(set) var seconds = [String: Double]()
    private(set) var calls = [String: Int]()
    private(set) var firstSeconds = [String: Double]()
    private(set) var maximumSeconds = [String: Double]()
    private(set) var thermalStates = Set<Int>()

    func start() -> Double { ProcessInfo.processInfo.systemUptime }
    func record(_ stage: String, since start: Double?) {
        guard let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        seconds[stage, default: 0] += elapsed
        calls[stage, default: 0] += 1
        if firstSeconds[stage] == nil { firstSeconds[stage] = elapsed }
        maximumSeconds[stage] = max(maximumSeconds[stage, default: 0], elapsed)
        if stage == "raw_render" { thermalStates.insert(ProcessInfo.processInfo.thermalState.rawValue) }
    }
}

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
    let whiteBalance: PhotoWhiteBalance
    let rawDecode: RAWDecodeRecipe
    /// Pinned input settings before any color engine overrides. Retain these
    /// across re-decodes so changing engines cannot inherit the previous one.
    let baseRAWDecode: RAWDecodeRecipe
    let previewMaximumEdge: Int
    let sourceISO: Int?

    init(sourceFile: SourceImageFile, exportSettings: ExportSettings, linearRGB: [Float],
         width: Int, height: Int, original: PreviewRaster, sourceDescription: String,
         whiteBalance: PhotoWhiteBalance = .renderedD65, rawDecode: RAWDecodeRecipe = .current,
         sourceISO: Int? = nil, baseRAWDecode: RAWDecodeRecipe? = nil,
         previewMaximumEdge: Int? = nil) {
        self.sourceFile = sourceFile; self.exportSettings = exportSettings; self.linearRGB = linearRGB
        self.width = width; self.height = height; self.original = original
        self.sourceDescription = sourceDescription; self.whiteBalance = whiteBalance; self.rawDecode = rawDecode
        self.baseRAWDecode = baseRAWDecode ?? rawDecode
        self.previewMaximumEdge = previewMaximumEdge ?? max(width, height)
        self.sourceISO = sourceISO
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

/// Experimental source adaptation. This is not a calibrated camera-native RGB profile.
/// Core Image honors embedded profiles and converts to extended linear sRGB.
/// Only the display preview is reduced. Export always reloads the immutable source.
enum ImagePipeline {
    static let maximumEdge: CGFloat = 2048
    // PQ represents up to 10,000 nits; Core Image's HDR reference white is 203 nits.
    static let maximumHDRValue: Float = 10_000 / 203

    private static func applyExposure(_ rgb: inout [Float], exposureEV: Double) {
        guard exposureEV != 0 else { return }
        let scale = Float(exp2(exposureEV))
        for i in rgb.indices { rgb[i] *= scale }
    }

    /// Legacy revision-11 HNCS and the existing FFCS HDR adapter. Revision 12
    /// HNCS restores magnitude inside its working image before spatial effects.
    private static func normalizeHighlights(_ rgb: inout [Float], exposureEV: Double = 0) throws -> [Float] {
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
    private static func restoreHighlights(_ rgba: inout [Float], gains: [Float]) -> Float {
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
    // A cancelled detached task may finish its current decoder call. Serialize the
    // complete decode/render stage so superseded RAW decodes never overlap.
    private static let decodeQueue = DispatchQueue(label: "dev.glasscam.decode", qos: .userInitiated)

    static func baselineSharpness(in properties: [AnyHashable: Any]) throws -> Double {
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        guard let value = dng?[kCGImagePropertyDNGBaselineSharpness as String] else { return 0 }
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else {
            throw PipelineError.invalidImage
        }
        return number.doubleValue
    }
    static func sourceISO(in properties: [AnyHashable: Any]) -> Int? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        guard let values = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
              let iso = values.first?.doubleValue, iso.isFinite, (1...1_000_000).contains(iso) else { return nil }
        return Int(iso.rounded())
    }

    /// Shared by reduced RAW decode, metadata-only capture binding, and full
    /// source export. Pin the selected decoder before reading the scene neutral.
    private static func configureRAW(_ raw: CIRAWFilter, recipe: RAWDecodeRecipe,
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

    static func load(data: Data, fileExtension: String?, previewMaximumEdge: Int = 2048,
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
    static func load(sourceFile: SourceImageFile, exportSettings: ExportSettings, rawDecode: RAWDecodeRecipe = .current) throws -> ImportedImage {
        try decodeQueue.sync {
            try autoreleasepool {
                let data = try Data(contentsOf: sourceFile.url)
                return try decode(data: data, fileExtension: sourceFile.fileExtension,
                                  sourceFile: sourceFile, maximumEdge: maximumEdge, exportSettings: exportSettings, rawDecode: rawDecode)
            }
        }
    }

    private static func decode(data: Data, fileExtension: String?, sourceFile: SourceImageFile, maximumEdge: CGFloat, exportSettings: ExportSettings, rawDecode: RAWDecodeRecipe,
                               baseRAWDecode: RAWDecodeRecipe? = nil,
                               frozenWhiteBalance: PhotoWhiteBalance? = nil) throws -> ImportedImage {
        let isRAW = ["dng", "raw"].contains(fileExtension?.lowercased() ?? "")
        var source: CIImage?
        var whiteBalance = PhotoWhiteBalance.renderedD65
        var resolvedRAWDecode = rawDecode
        var captureISO: Int?
        var decodePrecisionDescription = "Float32 RAW decode · not sensor-native bit depth"
        if isRAW {
            if let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") {
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
                             sourceDescription: isRAW ? "DNG • Apple RAW decode • experimental adapter • \(decodePrecisionDescription)" : "Rendered image • embedded profile → linear sRGB • \(decodePrecisionDescription)",
                             whiteBalance: whiteBalance, rawDecode: resolvedRAWDecode, sourceISO: captureISO,
                             baseRAWDecode: baseRAWDecode ?? resolvedRAWDecode, previewMaximumEdge: Int(maximumEdge))
    }

    static func process(resources: ColorResources, _ input: ImportedImage, recipe: ProcessingRecipe) throws -> ProcessedImage {
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        var input = input
        let sourcePolicy = recipe.sourceDecodeRecipe(input.baseRAWDecode)
        let frozenWhite = recipe.photoWhiteBalance?.origin == .appleRAW ? recipe.photoWhiteBalance : nil
        if ["dng", "raw"].contains(input.sourceFile.fileExtension?.lowercased() ?? ""),
           sourcePolicy != input.rawDecode || (frozenWhite != nil && frozenWhite != input.whiteBalance) {
            // Re-decode for the selected engine's pinned RAW input policy and
            // retain that policy in ProcessedImage.source. Automatic capture
            // binds the same policy before any pixel decode.
            let previous = input
            input = try decodeQueue.sync {
                try autoreleasepool {
                    try decode(data: Data(contentsOf: previous.sourceFile.url), fileExtension: previous.sourceFile.fileExtension,
                        sourceFile: previous.sourceFile, maximumEdge: CGFloat(previous.previewMaximumEdge),
                        exportSettings: previous.exportSettings, rawDecode: sourcePolicy, baseRAWDecode: previous.baseRAWDecode,
                        frozenWhiteBalance: frozenWhite)
                }
            }
        }
        let recipe = recipe.resolvingWhiteBalance(input.whiteBalance).resolvingLUMIXSourceISO(input.sourceISO)
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: input.width, height: input.height)
        let comparisonSource = try input.original.cropped(to: crop)
        let rgb: [Float]
        if crop.width == input.width && crop.height == input.height {
            rgb = input.linearRGB
        } else {
            var pixels = [Float]()
            pixels.reserveCapacity(crop.width * crop.height * 3)
            // Decoded bitmaps use top-to-bottom rows; ciY is only for CI rectangles.
            for row in crop.top..<(crop.top + crop.height) {
                let start = (row * input.width + crop.x) * 3
                pixels.append(contentsOf: input.linearRGB[start..<(start + crop.width * 3)])
            }
            rgb = pixels
        }
        // Crop before pointwise/spatial processing, just as the source reference.
        // Exact engines return display-linear Float32; no byte encoder runs.
        var effectInput = rgb
        let gains: [Float]?
        if recipe.usesExtendedHNCSWorkingDomain {
            if recipe.appliesExposureBeforeHighlights { applyExposure(&effectInput, exposureEV: recipe.exposureEV) }
            gains = nil
        }
        else {
            gains = try normalizeHighlights(&effectInput,
                exposureEV: recipe.appliesExposureBeforeHighlights ? recipe.exposureEV : 0)
        }
        var rgba: [Float]
        switch recipe.mode {
        case .hncs:
            rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.backendExposureEV,
                                                   illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance,
                                                   baselineSharpness: input.rawDecode.baselineSharpness ?? 0)
        case .ffcs:
            rgba = try FFCSEngine.exportLinearRGBA(resources: resources, linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.backendExposureEV,
                                                   simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
        case .lumix:
            rgba = try LUMIXEngine.exportLinearRGBA(resources: resources, linearSRGB: effectInput, width: crop.width,
                                                    height: crop.height,
                                                    exposureEV: recipe.backendExposureEV,
                                                    settings: recipe.lumix, illuminantKelvin: recipe.illuminantKelvin)
        }
        if let gains { restoreHighlights(&rgba, gains: gains) }
        let image = try PreviewRaster(linearRGBA: rgba, width: crop.width, height: crop.height)
        return ProcessedImage(image: image, comparisonSource: comparisonSource, source: input, recipe: recipe)
    }

    /// Export from the retained full-resolution capture, with its immutable recipe.
    /// Exact color processing precedes any reduction to the requested output size.
    /// App-owned scratch is O(width * stripRows); Apple RAW/ImageIO/CI/HEIF may
    /// allocate full-size internal surfaces. Device peak-RSS validation is required.
    static func writeHEIF(resources: ColorResources, _ processed: ProcessedImage, to url: URL,
                          settings: ExportSettings? = nil,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          timing: PipelineTiming? = nil) throws {
        try decodeQueue.sync {
            try autoreleasepool {
                try exportFullSource(resources: resources, processed.source.sourceFile, whiteBalance: processed.source.whiteBalance,
                    recipe: processed.recipe, to: url, settings: settings ?? processed.source.exportSettings, rawDecode: processed.source.rawDecode,
                    isCancelled: isCancelled, progress: progress, timing: timing)
            }
        }
    }

    /// Automatic capture needs only the final HEIF and its review image. Read
    /// the as-shot metadata without decoding/processing a discarded RAW preview.
    @discardableResult
    static func writeHEIF(resources: ColorResources, sourceFile: SourceImageFile, recipe: ProcessingRecipe, to url: URL,
                          settings: ExportSettings, rawDecode: RAWDecodeRecipe = .current,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          timing: PipelineTiming? = nil,
                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws -> ProcessingRecipe {
        try decodeQueue.sync {
            try autoreleasepool {
                let metadataStarted = timing?.start()
                try checkExportCancellation(isCancelled)
                guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
                var whiteBalance = PhotoWhiteBalance.renderedD65
                var resolvedRAWDecode = rawDecode
                var captureISO: Int?
                if ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? "") {
                    guard let raw = CIRAWFilter(imageURL: sourceFile.url) else { throw PipelineError.invalidImage }
                    let frozenWhite = recipe.photoWhiteBalance?.origin == .appleRAW ? recipe.photoWhiteBalance : nil
                    resolvedRAWDecode = try configureRAW(raw, recipe: recipe.sourceDecodeRecipe(rawDecode), whiteBalance: frozenWhite)
                    whiteBalance = frozenWhite ?? .asShot(raw)
                    captureISO = sourceISO(in: raw.properties)
                }
                let resolved = recipe.resolvingWhiteBalance(whiteBalance).resolvingLUMIXSourceISO(captureISO)
                timing?.record("metadata_bind", since: metadataStarted)
                try exportFullSource(resources: resources, sourceFile, whiteBalance: whiteBalance, recipe: resolved,
                    to: url, settings: settings, rawDecode: resolvedRAWDecode, isCancelled: isCancelled, progress: progress,
                    timing: timing, onSourceDimensions: onSourceDimensions)
                return resolved
            }
        }
    }

    /// Characterized scene-linear RGB enters without another RAW decode.
    static func writeLinearHEIF(resources: ColorResources, _ image: any SceneLinearImage, metadata: PhotoMetadata, recipe: ProcessingRecipe, to url: URL,
                           isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) throws -> ProcessingRecipe {
        try decodeQueue.sync {
            let white = try image.validatedWhiteBalance()
            let resolved = recipe.resolvingWhiteBalance(white).resolvingLUMIXSourceISO(image.sourceISO)
            try exportLinearSource(resources: resources, image.image,metadata:metadata,recipe:resolved,to:url,settings:.native,rawDecode:.sceneLinear,
                isCancelled:isCancelled,progress:progress)
            return resolved
        }
    }

    static func fullSourceImage(_ source: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                rawDecode: RAWDecodeRecipe, stabilizeRAWDecode: Bool = false) throws -> CIImage {
        let isRAW = ["dng", "raw"].contains(source.fileExtension?.lowercased() ?? "")
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

    private static func checkExportCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func exportFullSource(resources: ColorResources, _ sourceFile: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                          recipe: ProcessingRecipe, to url: URL,
                                          settings: ExportSettings, rawDecode: RAWDecodeRecipe, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          timing: PipelineTiming? = nil,
                                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws {
        try checkExportCancellation(isCancelled)
        progress(0)
        let sourceStarted = timing?.start()
        let stabilizeRAWDecode = recipe.pipelineRevision >= 2 && rawDecode.sharpnessAmount != 0 &&
            ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? "")
        let decoded = try fullSourceImage(sourceFile, whiteBalance: whiteBalance, rawDecode: rawDecode,
            stabilizeRAWDecode: stabilizeRAWDecode)
        timing?.record("source_graph_setup", since: sourceStarted)
        try exportLinearSource(resources: resources, decoded, metadata: sourceFile.metadata, recipe: recipe, to: url, settings: settings,
            rawDecode: rawDecode, isCancelled: isCancelled, progress: progress, timing: timing,
            onSourceDimensions: onSourceDimensions, releaseSourceCache: stabilizeRAWDecode)
    }

    private static func exportLinearSource(resources: ColorResources, _ decoded: CIImage, metadata: PhotoMetadata,
                                          recipe: ProcessingRecipe, to url: URL,
                                          settings: ExportSettings, rawDecode: RAWDecodeRecipe, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          timing: PipelineTiming? = nil,
                                          onSourceDimensions: ((Int, Int) -> Void)? = nil,
                                          releaseSourceCache: Bool = false) throws {
        let setupStarted = timing?.start()
        try checkExportCancellation(isCancelled)
        // Protect all byte-count arithmetic before allocating or creating a file.
        guard decoded.extent.width < CGFloat(Int.max / 16),
              decoded.extent.height < CGFloat(Int.max / 16) else { throw PipelineError.invalidImage }
        let sourceWidth = Int(decoded.extent.width.rounded(.down))
        let sourceHeight = Int(decoded.extent.height.rounded(.down))
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: sourceWidth, height: sourceHeight)
        let width = crop.width, height = crop.height
        guard width > 0, height > 0, width <= Int.max / 16 / height else { throw PipelineError.invalidImage }
        let output = try settings.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: recipe.crop)
        onSourceDimensions?(sourceWidth, sourceHeight)
        let rasterBytes = width * height * 16
        let capacity = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Reserve RGBAf + encoded-output margin and the full work image/scratch.
        // Only legacy HNCS additionally stores a separate per-pixel gain plane.
        let extendedWork = recipe.usesExtendedHNCSWorkingDomain
        let needsSpatial = recipe.mode == .hncs && recipe.hncs.requiresSpatial(effects: recipe.effects)
        let needsWorkImage = needsSpatial || extendedWork
        let workBytesPerPixel = extendedWork ? (needsSpatial ? 32.0 : 12.0) : (needsSpatial ? 36.0 : 0.0)
        let spatialBytes = Double(width) * Double(height) * workBytesPerPixel
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           Double(available) < Double(rasterBytes) * 1.5 + spatialBytes + 64 * 1024 * 1024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        // CIContext colour-matches inputs before executing filters. Clamp only
        // in the destination primaries, so valid negative sRGB components can
        // first become in-gamut BT.2020 values.
        let encodingContext: CIContext
        if extendedWork {
            guard let targetLinear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { throw PipelineError.rendering }
            encodingContext = CIContext(options: [.workingColorSpace: targetLinear,
                                                  .workingFormat: CIFormat.RGBAf.rawValue,
                                                  .cacheIntermediates: false])
        } else { encodingContext = context }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let croppedSource = decoded.cropped(to: crop.ciRect)
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)))
        let source = croppedSource.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        let raster = try ExportRasterFile()
        let highlightWork = needsSpatial && !extendedWork ? try ExportRasterFile() : nil
        let spatialWork = needsWorkImage ? try HNCSPresetWorkFile(width: width, height: height) : nil
        let stripRows = 64
        var outputHeadroom: Float = 1
        var maximumWorkValue: Float = 0
        let halo: Int
        if recipe.mode == .ffcs {
            halo = try FFCSEngine.requiredHalo(resources: resources, simulationIndex: recipe.simulationIndex,
                                               effects: recipe.effects, settings: recipe.ffcs)
        } else { halo = 0 }
        timing?.record("context_scratch_setup", since: setupStarted)
        for start in stride(from: 0, to: height, by: stripRows) {
            try checkExportCancellation(isCancelled)
            try autoreleasepool {
                let rows = min(stripRows, height - start)
                let inputStart = max(0, start - halo)
                let inputEnd = min(height, start + rows + halo)
                let inputRows = inputEnd - inputStart
                let allocationStarted = timing?.start()
                var decodedRGBA = [Float](repeating: 0, count: width * inputRows * 4)
                timing?.record("strip_buffer_allocation", since: allocationStarted)
                let renderStarted = timing?.start()
                decodedRGBA.withUnsafeMutableBytes { buffer in
                    // The strip and native backends count rows from the top.
                    // CI bounds count from the bottom, while render(toBitmap:)
                    // returns the selected rectangle in top-to-bottom order.
                    context.render(source, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                   bounds: CGRect(x: 0, y: CGFloat(height - inputEnd), width: CGFloat(width), height: CGFloat(inputRows)),
                                   format: .RGBAf, colorSpace: linear)
                }
                timing?.record("raw_render", since: renderStarted)
                let packingStarted = timing?.start()
                var rgb = [Float](repeating: 0, count: width * inputRows * 3)
                for pixel in 0..<(width * inputRows) {
                    for channel in 0..<3 { rgb[pixel * 3 + channel] = decodedRGBA[pixel * 4 + channel] }
                }
                let inputGains: [Float]
                if extendedWork {
                    if recipe.appliesExposureBeforeHighlights { applyExposure(&rgb, exposureEV: recipe.exposureEV) }
                    inputGains = []
                } else {
                    inputGains = try normalizeHighlights(&rgb,
                        exposureEV: recipe.appliesExposureBeforeHighlights ? recipe.exposureEV : 0)
                }
                let firstPixel = (start - inputStart) * width
                let gains = extendedWork ? [] : Array(inputGains[firstPixel..<(firstPixel + width * rows)])
                timing?.record("rgb_pack_hdr_split", since: packingStarted)
                if let spatialWork {
                    let gainWriteStarted = timing?.start()
                    if let highlightWork { try highlightWork.append(gains) }
                    timing?.record("intermediate_io", since: gainWriteStarted)
                    let colorStarted = timing?.start()
                    let work = try HNCSEngine.presetWork(linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                    if extendedWork { maximumWorkValue = max(maximumWorkValue, work.max() ?? 0) }
                    timing?.record("color_engine", since: colorStarted)
                    let workWriteStarted = timing?.start()
                    try spatialWork.writeTopDownRows(work, originY: start, rows: rows)
                    timing?.record("intermediate_io", since: workWriteStarted)
                    progress(0.1 + 0.35 * Double(start + rows) / Double(height))
                    return
                }
                var rgba: [Float]
                switch recipe.mode {
                case .hncs:
                    let colorStarted = timing?.start()
                    rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: width, height: rows,
                                                           exposureEV: recipe.backendExposureEV,
                                                           illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                    timing?.record("color_engine", since: colorStarted)
                case .ffcs:
                    let colorStarted = timing?.start()
                    let rendered = try FFCSEngine.exportLinearRGBStrip(resources: resources,
                        linearSRGB: rgb, fullWidth: width, fullHeight: height,
                        inputOriginY: inputStart, inputRows: inputRows,
                        outputOriginY: start, outputRows: rows,
                        exposureEV: recipe.backendExposureEV, simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
                    timing?.record("color_engine", since: colorStarted)
                    let expansionStarted = timing?.start()
                    var expanded = [Float](repeating: 1, count: width * rows * 4)
                    for pixel in 0..<(width * rows) {
                        for channel in 0..<3 { expanded[pixel * 4 + channel] = rendered[pixel * 3 + channel] }
                    }
                    rgba = expanded
                    timing?.record("rgba_pack", since: expansionStarted)
                case .lumix:
                    let colorStarted = timing?.start()
                    rgba = try LUMIXEngine.exportLinearRGBA(resources: resources, linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV,
                        settings: recipe.lumix, illuminantKelvin: recipe.illuminantKelvin)
                    timing?.record("color_engine", since: colorStarted)
                }
                let restoreStarted = timing?.start()
                guard rgba.count == width * rows * 4,
                      rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                outputHeadroom = max(outputHeadroom, restoreHighlights(&rgba, gains: gains))
                timing?.record("hdr_restore_validate", since: restoreStarted)
                let writeStarted = timing?.start()
                try raster.append(rgba)
                timing?.record("rgba_write", since: writeStarted)
                progress(0.1 + 0.75 * Double(start + rows) / Double(height))
            }
        }
        // Preserve the fixed RAW tiles until every source row/halo was read.
        // Release them before whole-image spatial work and HEIF encoding.
        if releaseSourceCache { context.clearCaches() }
        if let spatialWork {
            let gainMapStarted = timing?.start()
            let gainData = try highlightWork?.mappedData(expectedBytes: width * height * 4)
            let workScale = extendedWork ? try HNCSEngine.workingScale(maximum: maximumWorkValue) : 1
            timing?.record("intermediate_io", since: gainMapStarted)
            try checkExportCancellation(isCancelled)
            progress(0.45)
            // Grain normalization and USM see one complete cropped top-down
            // image, never independently seeded 64-row strips.
            let spatialStarted = timing?.start()
            try HNCSEngine.applySpatial(to: spatialWork, settings: recipe.hncs, effects: recipe.effects,
                baselineSharpness: rawDecode.baselineSharpness ?? 0, workScale: workScale, isCancelled: isCancelled)
            timing?.record("spatial_sharpness", since: spatialStarted)
            progress(0.65)
            for start in stride(from: 0, to: height, by: stripRows) {
                try checkExportCancellation(isCancelled)
                try autoreleasepool {
                    let rows = min(stripRows, height - start)
                    let workReadStarted = timing?.start()
                    let work = try spatialWork.readTopDownRows(originY: start, rows: rows)
                    timing?.record("intermediate_io", since: workReadStarted)
                    let finishStarted = timing?.start()
                    var rgba = try HNCSEngine.finishPresetWork(work, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance, workScale: workScale)
                    timing?.record("post_color", since: finishStarted)
                    let restoreStarted = timing?.start()
                    guard rgba.count == width * rows * 4, rgba.allSatisfy({ $0.isFinite }) else { throw PipelineError.rendering }
                    if extendedWork {
                        // This is an upper bound in the source primaries. The
                        // destination-space clamp still owns the physical limit.
                        outputHeadroom = min(maximumHDRValue, max(outputHeadroom, rgba.max() ?? 1))
                    } else {
                        guard let gainData, rgba.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                        let gains = gainData.withUnsafeBytes { bytes in
                            Array(bytes.bindMemory(to: Float.self)[(start * width)..<((start + rows) * width)])
                        }
                        outputHeadroom = max(outputHeadroom, restoreHighlights(&rgba, gains: gains))
                    }
                    timing?.record("hdr_restore_validate", since: restoreStarted)
                    let writeStarted = timing?.start()
                    try raster.append(rgba)
                    timing?.record("rgba_write", since: writeStarted)
                    progress(0.65 + 0.2 * Double(start + rows) / Double(height))
                }
            }
        }
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
