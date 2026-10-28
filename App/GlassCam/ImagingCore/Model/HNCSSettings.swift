import CHNCS
import Foundation

enum HNCSFilmCurve: Int, CaseIterable, Codable, Identifiable, Sendable {
    case asShot = 4, standard = 2, lowContrast = 6, highContrast = 1, oldStandard = 0, linear = 7
    var id: Self { self }
    var title: String {
        switch self {
        case .asShot: return "As Shot (Standard fallback)"
        case .standard: return "Standard"
        case .lowContrast: return "Low Contrast"
        case .highContrast: return "High Contrast"
        case .oldStandard: return "Old Standard"
        case .linear: return "Linear"
        }
    }
}

enum HNCSWorkingSpace: String, CaseIterable, Codable, Identifiable, Sendable {
    case legacy, lstar
    var id: Self { self }
    var title: String { self == .legacy ? "Hasselblad RGB (legacy)" : "Hasselblad L*RGB" }
}

enum HNCSIntent: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, reproduction
    var id: Self { self }
    var title: String { self == .standard ? "Standard" : "Reproduction (pure curve)" }
}

enum HNCSWhiteBalancePolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case photo, preset
    var id: Self { self }
    var title: String { self == .photo ? "Photo · Automatic" : "Original preset" }
}

struct HNCSSettings: Codable, Equatable, Sendable {
    static let currentRenderRevision = 12
    var renderRevision = currentRenderRevision
    var presetKey = "standard"
    var filmCurve: HNCSFilmCurve = .asShot
    var rawFilmCurveType = 2
    var workingSpace: HNCSWorkingSpace = .legacy
    var intent: HNCSIntent = .standard
    var whiteBalancePolicy: HNCSWhiteBalancePolicy = .photo
    // This selects factory matrix/LUT interpolation only. It does not replace
    // capture CCT or the selected target-camera white-balance gains.
    var factoryKelvinOverride: Double? = nil
    var applyToneCurve = true
    static let standard = HNCSSettings()
    static let legacyStandard: HNCSSettings = {
        var value = HNCSSettings()
        value.renderRevision = 11
        return value
    }()

    init() {}
    private enum CodingKeys: String, CodingKey {
        case renderRevision, presetKey, filmCurve, rawFilmCurveType, workingSpace, intent
        case factoryKelvinOverride, applyToneCurve, whiteBalancePolicy
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedRevision = try values.decodeIfPresent(Int.self, forKey: .renderRevision) ?? 11
        // Old durable recipes must keep their original preset WB when replayed.
        // Camera preferences migrate separately to photo WB for future shots.
        renderRevision = [8, 9, 10].contains(savedRevision) ? 11 : savedRevision
        presetKey = try values.decodeIfPresent(String.self, forKey: .presetKey) ?? "standard"
        filmCurve = try values.decodeIfPresent(HNCSFilmCurve.self, forKey: .filmCurve) ?? .asShot
        rawFilmCurveType = try values.decodeIfPresent(Int.self, forKey: .rawFilmCurveType) ?? 2
        workingSpace = try values.decodeIfPresent(HNCSWorkingSpace.self, forKey: .workingSpace) ?? .legacy
        intent = try values.decodeIfPresent(HNCSIntent.self, forKey: .intent) ?? .standard
        whiteBalancePolicy = try values.decodeIfPresent(HNCSWhiteBalancePolicy.self, forKey: .whiteBalancePolicy) ?? .preset
        factoryKelvinOverride = try values.decodeIfPresent(Double.self, forKey: .factoryKelvinOverride)
        applyToneCurve = try values.decodeIfPresent(Bool.self, forKey: .applyToneCurve) ?? true
    }

    func crop(effects: EffectToggles) -> ImageCrop {
        effects.applyExtraCrop && presetKey == "square-crop" ? .centeredSquare : .none
    }
    var usesExtendedWorkingDomain: Bool { renderRevision == 12 }
    func requiresSpatial(effects: EffectToggles) -> Bool {
        guard let flags = HNCSPresetCatalog.presets.first(where: { $0.id == presetKey })?.flags else { return false }
        let nativeSharpness = presetKey.withCString { hncs_native_sharpness_enabled($0) == 1 }
        return (effects.applyGrain && flags & 4 != 0) || (effects.applySharpness && nativeSharpness)
    }
    var presetTitle: String { HNCSPresetCatalog.presets.first { $0.id == presetKey }?.name ?? "Unavailable preset" }
    var presetWhiteBalanceKelvin: Int? {
        HNCSPresetCatalog.presets.first { $0.id == presetKey }?.whiteBalanceKelvin
    }
    var whiteBalanceExplanation: String {
        if whiteBalancePolicy == .photo {
            if let kelvin = presetWhiteBalanceKelvin {
                return "Keeps this photo's own temperature and tint. \(presetTitle)'s fixed \(kelvin) K white balance is not applied."
            }
            return "Keeps each photo's own temperature and tint while applying the preset's tone and detail settings."
        }
        if let kelvin = presetWhiteBalanceKelvin {
            return "Applies \(presetTitle)'s fixed \(kelvin) K white balance and tint."
        }
        return "\(presetTitle) has no fixed white balance, so the photo's own temperature and tint are preserved."
    }
    var isValid: Bool {
        [11, Self.currentRenderRevision].contains(renderRevision) && rawFilmCurveType == 2 &&
        (factoryKelvinOverride == nil || (factoryKelvinOverride!.isFinite && (2000...10000).contains(factoryKelvinOverride!))) &&
        HNCSPresetCatalog.presets.contains { $0.id == presetKey }
    }
}
