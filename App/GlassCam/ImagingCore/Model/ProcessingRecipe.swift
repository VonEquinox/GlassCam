import CFFCS
import Foundation

/// Only implemented, audited backends belong in this list. Adding a mode must
/// implement both preview and float export dispatch before exposing it in the UI.
enum ColorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case hncs, ffcs, lumix
    var id: Self { self }
    var title: String {
        switch self {
        case .hncs: return "HNCS"
        case .ffcs: return "FFCS"
        case .lumix: return "LUMIX"
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
    static let currentPipelineRevision = 2
    let pipelineRevision: Int
    let mode: ColorMode
    let exposureEV: Double
    let illuminantKelvin: Double
    let simulationIndex: Int
    let seed: UInt32
    let hncs: HNCSSettings
    let effects: EffectToggles
    let ffcs: FFCSSettings
    let lumix: LUMIXSettings
    let photoWhiteBalance: PhotoWhiteBalance?
    let rawInputPolicy: RAWInputPolicy
    // Only the HNCS square preset defines a crop. FFCS has no extra-crop stage.
    var crop: ImageCrop { mode == .hncs ? hncs.crop(effects: effects) : .none }

    init(mode: ColorMode, exposureEV: Double, illuminantKelvin: Double,
         simulationIndex: Int, seed: UInt32, hncs: HNCSSettings,
         effects: EffectToggles = .standard, ffcs: FFCSSettings = .standard,
         photoWhiteBalance: PhotoWhiteBalance? = nil, lumix: LUMIXSettings = .standard,
         rawInputPolicy: RAWInputPolicy = .cameraNeutral,
         pipelineRevision: Int = Self.currentPipelineRevision) {
        self.pipelineRevision = pipelineRevision
        self.mode = mode; self.exposureEV = exposureEV; self.illuminantKelvin = illuminantKelvin
        self.simulationIndex = simulationIndex; self.seed = seed; self.hncs = hncs
        self.effects = effects; self.ffcs = ffcs; self.photoWhiteBalance = photoWhiteBalance
        self.lumix = lumix
        self.rawInputPolicy = rawInputPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case mode, exposureEV, illuminantKelvin, simulationIndex, seed, hncs, effects, ffcs, photoWhiteBalance, lumix, rawInputPolicy, pipelineRevision
    }
    private enum LegacyEffectKeys: String, CodingKey { case applyGrain, applySharpness }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pipelineRevision = try values.decodeIfPresent(Int.self, forKey: .pipelineRevision) ?? 1
        mode = try values.decodeIfPresent(ColorMode.self, forKey: .mode) ?? .hncs
        exposureEV = try values.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        illuminantKelvin = try values.decodeIfPresent(Double.self, forKey: .illuminantKelvin) ?? 6500
        simulationIndex = try values.decodeIfPresent(Int.self, forKey: .simulationIndex) ?? 0
        seed = try values.decodeIfPresent(UInt32.self, forKey: .seed) ?? 0
        hncs = try values.decodeIfPresent(HNCSSettings.self, forKey: .hncs) ?? .legacyStandard
        photoWhiteBalance = try values.decodeIfPresent(PhotoWhiteBalance.self, forKey: .photoWhiteBalance)
        ffcs = try values.decodeIfPresent(FFCSSettings.self, forKey: .ffcs) ?? .standard
        lumix = try values.decodeIfPresent(LUMIXSettings.self, forKey: .lumix) ?? .standard
        rawInputPolicy = try values.decodeIfPresent(RAWInputPolicy.self, forKey: .rawInputPolicy) ?? .legacy
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
            seed: seed, hncs: hncs, effects: effects, ffcs: ffcs, photoWhiteBalance: value, lumix: lumix,
            rawInputPolicy: rawInputPolicy, pipelineRevision: pipelineRevision)
    }
    func resolvingLUMIXSourceISO(_ value: Int?) -> ProcessingRecipe {
        guard mode == .lumix, lumix.renderRevision >= 2, lumix.sourceISO == nil else { return self }
        var resolved = lumix; resolved.sourceISO = value ?? 100
        return ProcessingRecipe(mode: mode, exposureEV: exposureEV,
            illuminantKelvin: illuminantKelvin, simulationIndex: simulationIndex, seed: seed,
            hncs: hncs, effects: effects, ffcs: ffcs, photoWhiteBalance: photoWhiteBalance, lumix: resolved,
            rawInputPolicy: rawInputPolicy, pipelineRevision: pipelineRevision)
    }

    func sourceDecodeRecipe(_ original: RAWDecodeRecipe) -> RAWDecodeRecipe {
        if rawInputPolicy == .cameraNeutral {
            let neutral = original.cameraNeutralInput
            // Do not inherit another engine's decoder-sharpening override.
            if mode == .hncs { return neutral.withoutDecoderSharpness }
            if mode == .ffcs { return neutral }
            return RAWDecodeRecipe(rendering: neutral.rendering, decoderVersion: neutral.decoderVersion,
                linearExposureEV: neutral.linearExposureEV, decoderExposureEV: neutral.decoderExposureEV,
                edrAmount: neutral.edrAmount, baselineSharpness: neutral.baselineSharpness)
        }
        if mode == .hncs { return original.withoutDecoderSharpness }
        if mode == .lumix && lumix.renderRevision >= 2 { return original.sceneLinearInput }
        return original
    }

    static let standard = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                                            simulationIndex: 0, seed: 0, hncs: .standard)
    var isValid: Bool {
        (1...Self.currentPipelineRevision).contains(pipelineRevision) &&
        exposureEV.isFinite && (-2...2).contains(exposureEV) &&
        illuminantKelvin.isFinite && (2000...10000).contains(illuminantKelvin) &&
        (photoWhiteBalance == nil || photoWhiteBalance!.isValid) &&
        (0..<Int(ffcs_simulation_count())).contains(simulationIndex) && hncs.isValid && ffcs.isValid && lumix.isValid
    }

    var whiteBalanceDescription: String? {
        if mode == .hncs, hncs.whiteBalancePolicy == .preset, let kelvin = hncs.presetWhiteBalanceKelvin {
            return "Preset WB · \(hncs.presetTitle) · \(kelvin) K"
        }
        return photoWhiteBalance?.description
    }

    var usesExtendedHNCSWorkingDomain: Bool { mode == .hncs && hncs.usesExtendedWorkingDomain }

    /// Revision 3 includes user exposure in the restored HDR magnitude. Saved
    /// revision 1/2 photos retain their previous exposure and clipping behavior.
    var appliesLUMIXExposureBeforeHighlights: Bool { mode == .lumix && lumix.renderRevision >= 3 }
    /// New photos apply EV to the complete linear source, before either the
    /// shared split or HNCS's internal split. Old recipes keep their arithmetic.
    var appliesExposureBeforeHighlights: Bool { pipelineRevision >= 2 || appliesLUMIXExposureBeforeHighlights }
    var backendExposureEV: Double { appliesExposureBeforeHighlights ? 0 : exposureEV }
}
