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

/// Immutable RAW input policy. The scene-linear candidate is diagnostic-only;
/// Existing tone/EDR defaults are retained. HNCS disables decoder sharpening
/// before applying its independently verified native sharpness stage.
struct RAWDecodeRecipe: Codable, Equatable, Sendable {
    enum Rendering: String, Codable, Sendable { case appleRendered, sceneLinear }
    let rendering: Rendering
    let decoderVersion: String?
    let linearExposureEV: Double
    let decoderExposureEV: Float
    let edrAmount: Float?
    /// nil keeps the decoder default; HNCS explicitly requests zero before its
    /// own sharpness stage. BaselineSharpness belongs to this RAW, not a preset.
    let sharpnessAmount: Float?
    let baselineSharpness: Double?

    init(rendering: Rendering = .appleRendered, decoderVersion: String? = nil,
         linearExposureEV: Double = 0, decoderExposureEV: Float = 0, edrAmount: Float? = nil,
         sharpnessAmount: Float? = nil, baselineSharpness: Double? = nil) {
        self.rendering = rendering; self.decoderVersion = decoderVersion
        self.linearExposureEV = linearExposureEV; self.decoderExposureEV = decoderExposureEV
        self.edrAmount = edrAmount
        self.sharpnessAmount = sharpnessAmount; self.baselineSharpness = baselineSharpness
    }
    static let current = RAWDecodeRecipe()
    static let sceneLinear = RAWDecodeRecipe(rendering: .sceneLinear)
    var withoutDecoderSharpness: RAWDecodeRecipe {
        RAWDecodeRecipe(rendering: rendering, decoderVersion: decoderVersion,
            linearExposureEV: linearExposureEV, decoderExposureEV: decoderExposureEV,
            edrAmount: edrAmount, sharpnessAmount: 0, baselineSharpness: baselineSharpness)
    }
    var isValid: Bool {
        linearExposureEV.isFinite && (-10...10).contains(linearExposureEV) &&
        decoderExposureEV.isFinite && (-10...10).contains(decoderExposureEV) &&
        (edrAmount == nil || (edrAmount!.isFinite && (0...2).contains(edrAmount!))) &&
        (sharpnessAmount == nil || (sharpnessAmount!.isFinite && (0...1).contains(sharpnessAmount!))) &&
        (baselineSharpness == nil || (baselineSharpness!.isFinite && baselineSharpness! >= 0))
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

    init(sourceFile: SourceImageFile, exportSettings: ExportSettings, linearRGB: [Float],
         width: Int, height: Int, original: PreviewRaster, sourceDescription: String,
         whiteBalance: PhotoWhiteBalance = .renderedD65, rawDecode: RAWDecodeRecipe = .current) {
        self.sourceFile = sourceFile; self.exportSettings = exportSettings; self.linearRGB = linearRGB
        self.width = width; self.height = height; self.original = original
        self.sourceDescription = sourceDescription; self.whiteBalance = whiteBalance; self.rawDecode = rawDecode
    }
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

/// Independent, persisted stage gates. Enabling a gate uses only the selected
/// preset's existing parameters; it never invents grain, sharpening or crop.
struct EffectToggles: Codable, Equatable, Sendable {
    var applyGrain = true
    var applySharpness = true
    var applyExtraCrop = true
    static let standard = EffectToggles()

    init(applyGrain: Bool = true, applySharpness: Bool = true, applyExtraCrop: Bool = true) {
        self.applyGrain = applyGrain
        self.applySharpness = applySharpness
        self.applyExtraCrop = applyExtraCrop
    }

    private enum CodingKeys: String, CodingKey { case applyGrain, applySharpness, applyExtraCrop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applyGrain = try values.decodeIfPresent(Bool.self, forKey: .applyGrain) ?? true
        applySharpness = try values.decodeIfPresent(Bool.self, forKey: .applySharpness) ?? true
        applyExtraCrop = try values.decodeIfPresent(Bool.self, forKey: .applyExtraCrop) ?? true
    }
}

/// FFCS 0.2 native asset defaults. Missing fields deliberately adopt the corrected
/// neutral reference behavior; the independent user stage gates remain intact.
enum FFCSCameraFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case xh2s = "XH2S", xa3 = "XA3", gfx100 = "GFX100", gfx100s = "GFX100S", gfx100ii = "GFX100II"
    var id: String { rawValue }
}

struct FFCSSettings: Codable, Equatable, Sendable {
    static let currentRenderRevision = 2 // FFCS reference 0.2.0 native-default contract.
    var renderRevision = currentRenderRevision
    var cameraFamily: FFCSCameraFamily = .xh2s
    var applyReferenceAdjustments = false
    var sharpenRadius = 1.0
    static let standard = FFCSSettings()
    var isValid: Bool {
        renderRevision == Self.currentRenderRevision &&
        sharpenRadius.isFinite && (0.1...5.0).contains(sharpenRadius)
    }

    init(cameraFamily: FFCSCameraFamily = .xh2s, applyReferenceAdjustments: Bool = false,
         sharpenRadius: Double = 1.0) {
        self.cameraFamily = cameraFamily
        self.applyReferenceAdjustments = applyReferenceAdjustments
        self.sharpenRadius = sharpenRadius
    }
    private enum CodingKeys: String, CodingKey { case renderRevision, cameraFamily, applyReferenceAdjustments, sharpenRadius }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        renderRevision = try values.decodeIfPresent(Int.self, forKey: .renderRevision) ?? Self.currentRenderRevision
        cameraFamily = try values.decodeIfPresent(FFCSCameraFamily.self, forKey: .cameraFamily) ?? .xh2s
        applyReferenceAdjustments = try values.decodeIfPresent(Bool.self, forKey: .applyReferenceAdjustments) ?? false
        sharpenRadius = try values.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? 1.0
    }
}

/// Immutable settings captured before background work starts. Export must use
/// the rendered recipe, including every stage gate, rather than current controls.
struct ProcessingRecipe: Codable, Equatable, Sendable {
    let mode: ColorMode
    let exposureEV: Double
    let illuminantKelvin: Double
    let simulationIndex: Int
    let seed: UInt32
    let hncs: HNCSSettings
    let effects: EffectToggles
    let ffcs: FFCSSettings
    let photoWhiteBalance: PhotoWhiteBalance?
    // Only the HNCS square preset defines a crop. FFCS has no extra-crop stage.
    var crop: ImageCrop { mode == .hncs ? hncs.crop(effects: effects) : .none }

    init(mode: ColorMode, exposureEV: Double, illuminantKelvin: Double,
         simulationIndex: Int, seed: UInt32, hncs: HNCSSettings,
         effects: EffectToggles = .standard, ffcs: FFCSSettings = .standard,
         photoWhiteBalance: PhotoWhiteBalance? = nil) {
        self.mode = mode; self.exposureEV = exposureEV; self.illuminantKelvin = illuminantKelvin
        self.simulationIndex = simulationIndex; self.seed = seed; self.hncs = hncs
        self.effects = effects; self.ffcs = ffcs; self.photoWhiteBalance = photoWhiteBalance
    }

    private enum CodingKeys: String, CodingKey {
        case mode, exposureEV, illuminantKelvin, simulationIndex, seed, hncs, effects, ffcs, photoWhiteBalance
    }
    private enum LegacyEffectKeys: String, CodingKey { case applyGrain, applySharpness }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(ColorMode.self, forKey: .mode) ?? .hncs
        exposureEV = try values.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        illuminantKelvin = try values.decodeIfPresent(Double.self, forKey: .illuminantKelvin) ?? 6500
        simulationIndex = try values.decodeIfPresent(Int.self, forKey: .simulationIndex) ?? 0
        seed = try values.decodeIfPresent(UInt32.self, forKey: .seed) ?? 0
        hncs = try values.decodeIfPresent(HNCSSettings.self, forKey: .hncs) ?? .legacyStandard
        photoWhiteBalance = try values.decodeIfPresent(PhotoWhiteBalance.self, forKey: .photoWhiteBalance)
        ffcs = try values.decodeIfPresent(FFCSSettings.self, forKey: .ffcs) ?? .standard
        if let savedEffects = try values.decodeIfPresent(EffectToggles.self, forKey: .effects) {
            effects = savedEffects
        } else if mode == .hncs, values.contains(.hncs), try !values.decodeNil(forKey: .hncs) {
            // revision8.v1 stored the two old switches inside HNCS. Preserve
            // explicit false choices for the active HNCS render. Old FFCS always
            // applied both stages, so its saved stage gates stay enabled. The
            // separate FFCS 0.2 setting now defaults to neutral native LUT output.
            let legacy = try values.nestedContainer(keyedBy: LegacyEffectKeys.self, forKey: .hncs)
            effects = EffectToggles(
                applyGrain: try legacy.decodeIfPresent(Bool.self, forKey: .applyGrain) ?? true,
                applySharpness: try legacy.decodeIfPresent(Bool.self, forKey: .applySharpness) ?? true,
                applyExtraCrop: true)
        } else {
            effects = .standard
        }
    }

    func resolvingWhiteBalance(_ value: PhotoWhiteBalance) -> ProcessingRecipe {
        // An already resolved render/retry keeps the original photo white point.
        guard photoWhiteBalance == nil else { return self }
        return ProcessingRecipe(mode: mode, exposureEV: exposureEV,
            illuminantKelvin: value.modelKelvin ?? 6500, simulationIndex: simulationIndex,
            seed: seed, hncs: hncs, effects: effects, ffcs: ffcs, photoWhiteBalance: value)
    }

    static let standard = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                                            simulationIndex: 0, seed: 0, hncs: .standard)
    var isValid: Bool {
        exposureEV.isFinite && (-2...2).contains(exposureEV) &&
        illuminantKelvin.isFinite && (2000...10000).contains(illuminantKelvin) &&
        (photoWhiteBalance == nil || photoWhiteBalance!.isValid) &&
        (0..<Int(ffcs_simulation_count())).contains(simulationIndex) && hncs.isValid && ffcs.isValid
    }

    var displayName: String {
        guard mode == .ffcs else { return "HNCS · \(hncs.presetTitle) · \(hncs.filmCurve.title)" }
        let actual = FFCSEngine.resolvedAssetFamily(simulationIndex, family: ffcs.cameraFamily)
        let family = actual.map { $0 == ffcs.cameraFamily.rawValue ? $0 : "\(ffcs.cameraFamily.rawValue) / \($0) asset" }
            ?? "\(ffcs.cameraFamily.rawValue) / asset unavailable"
        return "FFCS · \(family) · \(FFCSEngine.simulationName(at: simulationIndex))"
    }

    var whiteBalanceDescription: String? {
        if mode == .hncs, hncs.whiteBalancePolicy == .preset, let kelvin = hncs.presetWhiteBalanceKelvin {
            return "Preset WB · \(hncs.presetTitle) · \(kelvin) K"
        }
        return photoWhiteBalance?.description
    }

    var usesExtendedHNCSWorkingDomain: Bool { mode == .hncs && hncs.usesExtendedWorkingDomain }
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
    case invalidImage, rendering, encoding, unsupportedOutput, metadata
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image could not be decoded. Try a JPEG, PNG, HEIC, or supported DNG."
        case .rendering: return "The image renderer could not create an output."
        case .unsupportedOutput: return "The selected sensor output exceeds the genuine source or changes its uncropped aspect ratio. Capture at a supported resolution; upsampling is disabled."
        case .encoding: return "The processed image could not be encoded as 10-bit HDR HEIF. No lower-bit-depth fallback was saved."
        case .metadata: return "The photo's capture information could not be preserved. Its source has been retained for retry."
        }
    }
}

/// Experimental source adaptation. This is not a calibrated camera-native RGB profile.
/// Core Image honors embedded profiles and converts to extended linear sRGB.
/// Only the display preview is reduced. Export always reloads the immutable source.
enum ImagePipeline {
    static let maximumEdge: CGFloat = 2048
    // PQ represents up to 10,000 nits; Core Image's HDR reference white is 203 nits.
    static let maximumHDRValue: Float = 10_000 / 203

    /// Legacy revision-11 HNCS and the existing FFCS HDR adapter. Revision 12
    /// HNCS restores magnitude inside its working image before spatial effects.
    private static func normalizeHighlights(_ rgb: inout [Float]) throws -> [Float] {
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
        }
        raw.extendedDynamicRangeAmount = recipe.edrAmount ?? (recipe.rendering == .appleRendered ? 1 : 0)
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

    private static func decode(data: Data, fileExtension: String?, sourceFile: SourceImageFile, maximumEdge: CGFloat, exportSettings: ExportSettings, rawDecode: RAWDecodeRecipe) throws -> ImportedImage {
        let isRAW = ["dng", "raw"].contains(fileExtension?.lowercased() ?? "")
        var source: CIImage?
        var whiteBalance = PhotoWhiteBalance.renderedD65
        var resolvedRAWDecode = rawDecode
        var decodePrecisionDescription = "Float32 RAW decode · not sensor-native bit depth"
        if isRAW {
            if let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") {
                resolvedRAWDecode = try configureRAW(raw, recipe: rawDecode)
                whiteBalance = .asShot(raw)
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
                             whiteBalance: whiteBalance, rawDecode: resolvedRAWDecode)
    }

    static func process(_ input: ImportedImage, recipe: ProcessingRecipe) throws -> ProcessedImage {
        var input = input
        if recipe.mode == .hncs, ["dng", "raw"].contains(input.sourceFile.fileExtension?.lowercased() ?? ""),
           input.rawDecode.sharpnessAmount != 0 {
            // A generic import can retain Apple's sharpening. Re-decode for
            // HNCS and retain that exact input policy in ProcessedImage.source.
            // Automatic capture binds this policy before any pixel decode.
            let previous = input
            input = try decodeQueue.sync {
                try autoreleasepool {
                    try decode(data: Data(contentsOf: previous.sourceFile.url), fileExtension: previous.sourceFile.fileExtension,
                        sourceFile: previous.sourceFile, maximumEdge: CGFloat(max(previous.width, previous.height)),
                        exportSettings: previous.exportSettings, rawDecode: previous.rawDecode.withoutDecoderSharpness)
                }
            }
        }
        let recipe = recipe.resolvingWhiteBalance(input.whiteBalance)
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
        if recipe.usesExtendedHNCSWorkingDomain { gains = nil }
        else { gains = try normalizeHighlights(&effectInput) }
        var rgba: [Float]
        switch recipe.mode {
        case .hncs:
            rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.exposureEV,
                                                   illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance,
                                                   baselineSharpness: input.rawDecode.baselineSharpness ?? 0)
        case .ffcs:
            rgba = try FFCSEngine.exportLinearRGBA(linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.exposureEV,
                                                   simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
        }
        if let gains { restoreHighlights(&rgba, gains: gains) }
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
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          timing: PipelineTiming? = nil) throws {
        try decodeQueue.sync {
            try autoreleasepool {
                try exportFullSource(processed.source.sourceFile, whiteBalance: processed.source.whiteBalance,
                    recipe: processed.recipe, to: url, settings: settings ?? processed.source.exportSettings, rawDecode: processed.source.rawDecode,
                    isCancelled: isCancelled, progress: progress, timing: timing)
            }
        }
    }

    /// Automatic capture needs only the final HEIF and its review image. Read
    /// the as-shot metadata without decoding/processing a discarded RAW preview.
    @discardableResult
    static func writeHEIF(sourceFile: SourceImageFile, recipe: ProcessingRecipe, to url: URL,
                          settings: ExportSettings, rawDecode: RAWDecodeRecipe = .current,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          timing: PipelineTiming? = nil,
                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws -> ProcessingRecipe {
        try decodeQueue.sync {
            try autoreleasepool {
                let metadataStarted = timing?.start()
                try checkExportCancellation(isCancelled)
                var whiteBalance = PhotoWhiteBalance.renderedD65
                var resolvedRAWDecode = rawDecode
                if ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? "") {
                    guard let raw = CIRAWFilter(imageURL: sourceFile.url) else { throw PipelineError.invalidImage }
                    resolvedRAWDecode = try configureRAW(raw, recipe: recipe.mode == .hncs ? rawDecode.withoutDecoderSharpness : rawDecode)
                    whiteBalance = .asShot(raw)
                }
                let resolved = recipe.resolvingWhiteBalance(whiteBalance)
                timing?.record("metadata_bind", since: metadataStarted)
                try exportFullSource(sourceFile, whiteBalance: whiteBalance, recipe: resolved,
                    to: url, settings: settings, rawDecode: resolvedRAWDecode, isCancelled: isCancelled, progress: progress,
                    timing: timing, onSourceDimensions: onSourceDimensions)
                return resolved
            }
        }
    }

    static func fullSourceImage(_ source: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                rawDecode: RAWDecodeRecipe) throws -> CIImage {
        let isRAW = ["dng", "raw"].contains(source.fileExtension?.lowercased() ?? "")
        var decoded: CIImage?
        if isRAW {
            if let raw = CIRAWFilter(imageURL: source.url) {
                let resolved = try configureRAW(raw, recipe: rawDecode, whiteBalance: whiteBalance)
                raw.scaleFactor = 1 // Genuine decoder output, never the preview scale.
                decoded = rawOutput(raw, recipe: resolved)
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

    private static func exportFullSource(_ sourceFile: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                          recipe: ProcessingRecipe, to url: URL,
                                          settings: ExportSettings, rawDecode: RAWDecodeRecipe, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          timing: PipelineTiming? = nil,
                                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws {
        try checkExportCancellation(isCancelled)
        progress(0)
        let sourceStarted = timing?.start()
        let decoded = try fullSourceImage(sourceFile, whiteBalance: whiteBalance, rawDecode: rawDecode)
        timing?.record("source_graph_setup", since: sourceStarted)
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
            halo = try FFCSEngine.requiredHalo(simulationIndex: recipe.simulationIndex,
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
                let inputGains = extendedWork ? [] : try normalizeHighlights(&rgb)
                let firstPixel = (start - inputStart) * width
                let gains = extendedWork ? [] : Array(inputGains[firstPixel..<(firstPixel + width * rows)])
                timing?.record("rgb_pack_hdr_split", since: packingStarted)
                if let spatialWork {
                    let gainWriteStarted = timing?.start()
                    if let highlightWork { try highlightWork.append(gains) }
                    timing?.record("intermediate_io", since: gainWriteStarted)
                    let colorStarted = timing?.start()
                    let work = try HNCSEngine.presetWork(linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
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
                                                           exposureEV: recipe.exposureEV,
                                                           illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                    timing?.record("color_engine", since: colorStarted)
                case .ffcs:
                    let colorStarted = timing?.start()
                    let rendered = try FFCSEngine.exportLinearRGBStrip(
                        linearSRGB: rgb, fullWidth: width, fullHeight: height,
                        inputOriginY: inputStart, inputRows: inputRows,
                        outputOriginY: start, outputRows: rows,
                        exposureEV: recipe.exposureEV, simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
                    timing?.record("color_engine", since: colorStarted)
                    let expansionStarted = timing?.start()
                    var expanded = [Float](repeating: 1, count: width * rows * 4)
                    for pixel in 0..<(width * rows) {
                        for channel in 0..<3 { expanded[pixel * 4 + channel] = rendered[pixel * 3 + channel] }
                    }
                    rgba = expanded
                    timing?.record("rgba_pack", since: expansionStarted)
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
                        exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance, workScale: workScale)
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
            image = image.settingProperties(sourceFile.metadata.encodingProperties(
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
            try sourceFile.metadata.validate(in: properties)
            timing?.record("output_validate", since: validationStarted)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
