import Foundation

/// Persisted selections describe the render, not just labels in a menu. Apple
/// inputs have no Phocus FilmCurve metadata: As Shot resolves explicitly to type 2.
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

struct HNCSSettings: Codable, Equatable, Sendable {
    static let currentRenderRevision = 8
    var renderRevision = currentRenderRevision
    var presetKey = "standard"
    var filmCurve: HNCSFilmCurve = .asShot
    var rawFilmCurveType = 2
    var workingSpace: HNCSWorkingSpace = .legacy
    var intent: HNCSIntent = .standard
    // This selects factory matrix/LUT interpolation only. It does not replace
    // capture CCT or the preset's absolute target-camera white-balance gains.
    var factoryKelvinOverride: Double? = nil
    var applyToneCurve = true
    static let standard = HNCSSettings()

    init() {}
    private enum CodingKeys: String, CodingKey {
        case renderRevision, presetKey, filmCurve, rawFilmCurveType, workingSpace, intent
        case factoryKelvinOverride, applyToneCurve
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        renderRevision = try values.decodeIfPresent(Int.self, forKey: .renderRevision) ?? Self.currentRenderRevision
        presetKey = try values.decodeIfPresent(String.self, forKey: .presetKey) ?? "standard"
        filmCurve = try values.decodeIfPresent(HNCSFilmCurve.self, forKey: .filmCurve) ?? .asShot
        rawFilmCurveType = try values.decodeIfPresent(Int.self, forKey: .rawFilmCurveType) ?? 2
        workingSpace = try values.decodeIfPresent(HNCSWorkingSpace.self, forKey: .workingSpace) ?? .legacy
        intent = try values.decodeIfPresent(HNCSIntent.self, forKey: .intent) ?? .standard
        factoryKelvinOverride = try values.decodeIfPresent(Double.self, forKey: .factoryKelvinOverride)
        applyToneCurve = try values.decodeIfPresent(Bool.self, forKey: .applyToneCurve) ?? true
    }

    func crop(effects: EffectToggles) -> ImageCrop {
        effects.applyExtraCrop && presetKey == "square-crop" ? .centeredSquare : .none
    }
    var isLegacyLiveCompatible: Bool { self == .standard }
    func requiresSpatial(effects: EffectToggles) -> Bool {
        guard presetKey != "standard", let flags = HNCSEngine.presets.first(where: { $0.id == presetKey })?.flags else { return false }
        return (effects.applyGrain && flags & 4 != 0) || (effects.applySharpness && flags & (8 | 16) != 0)
    }
    var presetTitle: String { HNCSEngine.presets.first { $0.id == presetKey }?.name ?? "Unavailable preset" }
    var isValid: Bool {
        renderRevision == Self.currentRenderRevision && rawFilmCurveType == 2 &&
        (factoryKelvinOverride == nil || (factoryKelvinOverride!.isFinite && (2000...10000).contains(factoryKelvinOverride!))) &&
        HNCSEngine.presets.contains { $0.id == presetKey }
    }
}

/// Thin Swift ownership/buffer bridge. All color processing lives in portable C++17.
/// Revision-8 presets, film curves and working spaces use an experimental source
/// adapter. This does not claim a calibrated iPhone/Apple RAW-to-X2D camera profile.
enum HNCSEngine {
    enum Quality { case exactReference, fastPreview }

    struct Preset: Identifiable, Sendable {
        let id: String
        let name: String
        let flags: UInt32
        var hasOptionalSharpness: Bool { flags & 16 != 0 }
    }

    /// Catalog names come from the exact backend assets. Source-defined no-op
    /// tools are not presented as fake effects; spatial looks use a separate pass.
    static let presets: [Preset] = (0..<Int(hncs_preset_count())).compactMap { index in
        guard let key = hncs_preset_key(index), let name = hncs_preset_name(index) else { return nil }
        let flags = hncs_preset_flags(key)
        let id = String(cString: key)
        guard id == "standard" || flags & (1 | 2 | 4 | 8) != 0 else { return nil }
        return Preset(id: id, name: String(cString: name), flags: flags)
    }

    private struct ContextKey: Equatable {
        let exposure: Double
        let captureKelvin: Double
        let settings: HNCSSettings
        let effects: EffectToggles
    }

    enum Error: LocalizedError {
        case invalidDimensions, invalidSettings, invalidPixels, spatialIO, spatialRequiresFloat
        var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "The image dimensions or RGB buffer are invalid."
            case .invalidSettings: return "The color processor could not initialize with these settings."
            case .invalidPixels: return "The image contains invalid or non-finite color values."
            case .spatialRequiresFloat: return "Spatial HNCS presets require the full-precision photo route."
            case .spatialIO: return "HNCS grain or sharpening could not finish its temporary-file pass. Check available storage and retry."
            }
        }
    }

    /// Immutable C++ contexts are reused across full-resolution export strips.
    /// A one-entry cache bounds memory; in-flight calls retain their own owner.
    private final class ContextOwner: @unchecked Sendable {
        let pointer: OpaquePointer
        let key: ContextKey
        init(key: ContextKey) throws {
            guard key.settings.isValid else { throw Error.invalidSettings }
            let settings = key.settings
            // Decoded linear sRGB has no calibrated sensor WB. The backend's
            // documented synthetic capture baseline is independent of desired
            // preset target gains; never multiply those gains into decoded RGB.
            let pointer = settings.presetKey.withCString { preset in
                hncs_create_preset(key.exposure, key.captureKelvin,
                    settings.factoryKelvinOverride ?? 0,
                    settings.workingSpace == .lstar ? 1 : 0,
                    settings.intent == .reproduction ? 1 : 0,
                    Int32(settings.filmCurve.rawValue), Int32(settings.rawFilmCurveType),
                    preset, settings.applyToneCurve ? 1 : 0, nil, nil)
            }
            guard let pointer else { throw Error.invalidSettings }
            self.pointer = pointer; self.key = key
        }
        deinit { hncs_destroy(pointer) }
    }
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?
        func context(exposure: Double, kelvin: Double, settings: HNCSSettings, effects: EffectToggles) throws -> ContextOwner {
            lock.lock(); defer { lock.unlock() }
            let key = ContextKey(exposure: exposure, captureKelvin: kelvin, settings: settings, effects: effects)
            if let cached, cached.key == key { return cached }
            let owner = try ContextOwner(key: key)
            cached = owner
            return owner
        }
    }
    private static let contextCache = ContextCache()

    /// Bounded CPU concurrency shared by preview and exact Float export.
    /// A device performance/energy claim still requires hardware measurement.
    private static func workerCount() -> UInt32 {
        let info = ProcessInfo.processInfo
        var workers = min(4, max(1, info.activeProcessorCount))
        if info.isLowPowerModeEnabled { workers = min(workers, 2) }
        switch info.thermalState {
        case .fair: workers = min(workers, 2)
        case .serious, .critical: workers = 1
        default: break
        }
        return UInt32(workers)
    }

    static func process(linearSRGB: [Float], width: Int, height: Int,
                        exposureEV: Double, illuminantKelvin: Double,
                        settings: HNCSSettings = .standard, effects: EffectToggles = .standard, quality: Quality = .fastPreview) throws -> [UInt8] {
        guard !settings.requiresSpatial(effects: effects) else { throw Error.spatialRequiresFloat }
        guard width > 0, height > 0, width <= Int.max / height else {
            throw Error.invalidDimensions
        }
        let count = width * height
        guard count <= Int.max / 4, linearSRGB.count == count * 3 else {
            throw Error.invalidDimensions
        }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin, settings: settings, effects: effects)
        let context = owner.pointer
        defer { withExtendedLifetime(owner) {} }
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                switch quality {
                case .exactReference:
                    return hncs_process_srgb(context, source.baseAddress, destination.baseAddress, count)
                case .fastPreview:
                    // HNCS UInt16 core stays exact. Only final 8-bit display OETF
                    // uses a validated table (maximum error one byte level).
                    return hncs_process_srgb_fast_parallel(context, source.baseAddress,
                                                          destination.baseAddress, count, workerCount())
                }
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return rgba
    }

    /// Full-precision export bridge. The original UInt16 HNCS core remains
    /// unchanged; display-linear sRGB is returned before any 8-bit encoder.
    /// The HEIF encoder applies the output transfer function and quantization.
    static func exportLinearRGBA(linearSRGB: [Float], width: Int, height: Int,
                                 exposureEV: Double, illuminantKelvin: Double,
                                 settings: HNCSSettings = .standard, effects: EffectToggles = .standard) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / height else {
            throw Error.invalidDimensions
        }
        let count = width * height
        // Bound bytes, not merely element count, before multiplying. The RGBA
        // output bound also protects the smaller RGB source's count and bytes.
        guard count <= Int.max / MemoryLayout<Float>.stride / 4,
              linearSRGB.count == count * 3 else {
            throw Error.invalidDimensions
        }
        if settings.requiresSpatial(effects: effects) {
            let work = try presetWork(linearSRGB: linearSRGB, width: width, height: height,
                                      exposureEV: exposureEV, captureKelvin: illuminantKelvin, settings: settings, effects: effects)
            let file = try HNCSPresetWorkFile(width: width, height: height)
            try file.writeBottomUpRows(work, originY: 0, rows: height)
            try applySpatial(to: file, settings: settings, effects: effects, isCancelled: { Task.isCancelled })
            let adjusted = try file.readBottomUpRows(originY: 0, rows: height)
            return try finishPresetWork(adjusted, width: width, height: height,
                                        exposureEV: exposureEV, captureKelvin: illuminantKelvin, settings: settings, effects: effects)
        }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin, settings: settings, effects: effects)
        let context = owner.pointer
        defer { withExtendedLifetime(owner) {} }
        var rgba = [Float](repeating: 0, count: count * 4)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                hncs_process_linear_rgba_parallel(context, source.baseAddress, destination.baseAddress, count, workerCount())
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return rgba
    }

    /// Unquantized working-space Float32 boundary, before grain and USM.
    /// CI bottom-up row ordering is preserved here; the temporary-file owner
    /// performs the single row reversal required by the NumPy spatial reference.
    static func presetWork(linearSRGB: [Float], width: Int, height: Int,
                           exposureEV: Double, captureKelvin: Double, settings: HNCSSettings, effects: EffectToggles = .standard) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              linearSRGB.count == width * height * 3 else { throw Error.invalidDimensions }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: captureKelvin, settings: settings, effects: effects)
        defer { withExtendedLifetime(owner) {} }
        var result = [Float](repeating: 0, count: width * height * 3)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { output in
                hncs_process_preset_work_float(owner.pointer, source.baseAddress, output.baseAddress, width * height)
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return result
    }

    static func finishPresetWork(_ work: [Float], width: Int, height: Int,
                                 exposureEV: Double, captureKelvin: Double, settings: HNCSSettings, effects: EffectToggles = .standard) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              work.count == width * height * 3 else { throw Error.invalidDimensions }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: captureKelvin, settings: settings, effects: effects)
        defer { withExtendedLifetime(owner) {} }
        var result = [Float](repeating: 0, count: width * height * 4)
        let status = work.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { output in
                hncs_finish_preset_work_linear(owner.pointer, source.baseAddress, output.baseAddress, width * height)
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return result
    }

    private final class SpatialCancellation {
        let isCancelled: () -> Bool
        init(_ isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }
    }

    static func applySpatial(to file: HNCSPresetWorkFile, settings: HNCSSettings, effects: EffectToggles = .standard,
                             isCancelled: @escaping () -> Bool) throws {
        try file.prepareForSpatialPass()
        if isCancelled() { throw CancellationError() }
        let cancellation = SpatialCancellation(isCancelled)
        let opaque = Unmanaged.passUnretained(cancellation).toOpaque()
        let status = file.url.path.withCString { path in
            settings.presetKey.withCString { key in
                FileManager.default.temporaryDirectory.path.withCString { scratch in
                    hncs_apply_spatial_preset_file(path, file.width, file.height, key,
                        effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0,
                        scratch, { context in
                            guard let context else { return 0 }
                            return Unmanaged<SpatialCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled() ? 1 : 0
                        }, opaque)
                }
            }
        }
        withExtendedLifetime(cancellation) {}
        if status == -3 || isCancelled() { throw CancellationError() }
        guard status == 0 else { throw status == -2 ? Error.spatialIO : Error.invalidPixels }
    }

    /// Golden-test boundary: packed white-balanced native X2D RGB doubles in;
    /// packed original 16-bit legacy RGB codes out. No adapter or display conversion.
    static func renderNative(native: [Double], illuminantKelvin: Double) throws -> [UInt16] {
        guard native.count % 3 == 0 else { throw Error.invalidDimensions }
        guard let context = hncs_create(0, illuminantKelvin) else { throw Error.invalidSettings }
        defer { hncs_destroy(context) }
        var codes = [UInt16](repeating: 0, count: native.count)
        let status = native.withUnsafeBufferPointer { source in
            codes.withUnsafeMutableBufferPointer { destination in
                hncs_render_native(context, source.baseAddress, destination.baseAddress, native.count / 3)
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return codes
    }
}
