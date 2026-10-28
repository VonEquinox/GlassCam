import CHNCS
import Foundation

/// Persisted selections describe the render, not just labels in a menu. Apple
/// inputs have no Phocus FilmCurve metadata: As Shot resolves explicitly to type 2.
/// Thin Swift ownership/buffer bridge. All color processing lives in portable C++17.
/// Binary-verified presets, film curves and working spaces use an experimental source
/// adapter. This does not claim a calibrated iPhone/Apple RAW-to-X2D camera profile.
enum HNCSEngine {
    enum Quality { case exactReference, fastPreview }

    typealias Preset = HNCSPresetCatalog.Preset
    static let presets = HNCSPresetCatalog.presets
    static var cameraPresets: [Preset] { HNCSPresetCatalog.cameraPresets }

    private struct ContextKey: Equatable {
        let exposure: Double
        let captureKelvin: Double
        let whiteBalance: PhotoWhiteBalance?
        let settings: HNCSSettings
        let effects: EffectToggles
        let workScale: Double
    }

    enum Error: LocalizedError {
        case invalidDimensions, invalidSettings, invalidPixels, spatialIO, spatialRequiresFloat
        var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "The image dimensions or RGB buffer are invalid."
            case .invalidSettings: return "The color processor could not initialize with these settings."
            case .invalidPixels: return "The image contains invalid or non-finite color values."
            case .spatialRequiresFloat: return "This HNCS recipe requires the full-precision photo route."
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
            let pointer = settings.presetKey.withCString { preset in
                if let white = key.whiteBalance {
                    guard white.isValid else { return OpaquePointer?.none }
                    return hncs_create_preset_whitepoint_with_policy(key.exposure, white.x, white.y,
                        settings.factoryKelvinOverride ?? 0,
                        settings.workingSpace == .lstar ? 1 : 0,
                        settings.intent == .reproduction ? 1 : 0,
                        Int32(settings.filmCurve.rawValue), Int32(settings.rawFilmCurveType),
                        preset, settings.applyToneCurve ? 1 : 0,
                        settings.whiteBalancePolicy == .photo ? 1 : 0)
                }
                // Legacy reference/test clients retain the original CCT adapter.
                return hncs_create_preset(key.exposure, key.captureKelvin,
                    settings.factoryKelvinOverride ?? 0,
                    settings.workingSpace == .lstar ? 1 : 0,
                    settings.intent == .reproduction ? 1 : 0,
                    Int32(settings.filmCurve.rawValue), Int32(settings.rawFilmCurveType),
                    preset, settings.applyToneCurve ? 1 : 0, nil, nil)
            }
            guard let pointer else { throw Error.invalidSettings }
            if key.workScale == 1 {
                self.pointer = pointer
            } else {
                let scaled = hncs_clone_with_apple_hdr_work_scale(pointer, key.workScale)
                hncs_destroy(pointer)
                guard let scaled else { throw Error.invalidSettings }
                self.pointer = scaled
            }
            self.key = key
        }
        deinit { hncs_destroy(pointer) }
    }
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?
        func context(exposure: Double, kelvin: Double, settings: HNCSSettings, effects: EffectToggles, whiteBalance: PhotoWhiteBalance?, workScale: Double = 1) throws -> ContextOwner {
            lock.lock(); defer { lock.unlock() }
            let key = ContextKey(exposure: exposure, captureKelvin: kelvin, whiteBalance: whiteBalance, settings: settings, effects: effects, workScale: workScale)
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
                        settings: HNCSSettings = .standard, effects: EffectToggles = .standard, quality: Quality = .fastPreview, whiteBalance: PhotoWhiteBalance? = nil) throws -> [UInt8] {
        guard !settings.usesExtendedWorkingDomain, !settings.requiresSpatial(effects: effects) else { throw Error.spatialRequiresFloat }
        guard width > 0, height > 0, width <= Int.max / height else {
            throw Error.invalidDimensions
        }
        let count = width * height
        guard count <= Int.max / 4, linearSRGB.count == count * 3 else {
            throw Error.invalidDimensions
        }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance)
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
    /// unchanged; extended-linear sRGB is returned before any 8-bit encoder.
    /// The HEIF encoder applies the output transfer function and quantization.
    static func exportLinearRGBA(linearSRGB: [Float], width: Int, height: Int,
                                 exposureEV: Double, illuminantKelvin: Double,
                                 settings: HNCSSettings = .standard, effects: EffectToggles = .standard, whiteBalance: PhotoWhiteBalance? = nil,
                                 baselineSharpness: Double = 0) throws -> [Float] {
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
        if settings.usesExtendedWorkingDomain || settings.requiresSpatial(effects: effects) {
            let work = try presetWork(linearSRGB: linearSRGB, width: width, height: height,
                                      exposureEV: exposureEV, captureKelvin: illuminantKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance)
            let file = try HNCSPresetWorkFile(width: width, height: height)
            try file.writeTopDownRows(work, originY: 0, rows: height)
            let workScale = settings.usesExtendedWorkingDomain ? try workingScale(maximum: work.max() ?? 0) : 1
            try applySpatial(to: file, settings: settings, effects: effects, baselineSharpness: baselineSharpness, workScale: workScale,
                             isCancelled: { Task.isCancelled })
            let adjusted = try file.readTopDownRows(originY: 0, rows: height)
            return try finishPresetWork(adjusted, width: width, height: height,
                                        exposureEV: exposureEV, captureKelvin: illuminantKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance, workScale: workScale)
        }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance)
        let context = owner.pointer
        defer { withExtendedLifetime(owner) {} }
        var rgba = [Float](repeating: 0, count: count * 4)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                hncs_process_phocus_linear_rgba_parallel(context, source.baseAddress, destination.baseAddress, count, workerCount())
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return rgba
    }

    static func workingScale(maximum: Float) throws -> Double {
        let scale = hncs_apple_hdr_work_scale(Double(maximum))
        guard scale.isFinite, (1...64).contains(scale) else { throw Error.invalidPixels }
        return scale
    }

    /// Working-space Float32 boundary, before native USM and portable grain.
    /// Revision 12 accepts intact HDR input and emits unscaled extended work.
    /// Top-to-bottom bitmap rows pass unchanged to the temporary-file owner and
    /// NumPy spatial reference, so grain coordinates do not depend on strip size.
    static func presetWork(linearSRGB: [Float], width: Int, height: Int,
                           exposureEV: Double, captureKelvin: Double, settings: HNCSSettings, effects: EffectToggles = .standard, whiteBalance: PhotoWhiteBalance? = nil) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              linearSRGB.count == width * height * 3 else { throw Error.invalidDimensions }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: captureKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance)
        defer { withExtendedLifetime(owner) {} }
        var result = [Float](repeating: 0, count: width * height * 3)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { output in
                if settings.usesExtendedWorkingDomain {
                    return hncs_process_apple_hdr_work_float_parallel(owner.pointer, source.baseAddress, output.baseAddress, width * height, workerCount())
                }
                return hncs_process_phocus_work_float_parallel(owner.pointer, source.baseAddress, output.baseAddress, width * height, workerCount())
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return result
    }

    static func finishPresetWork(_ work: [Float], width: Int, height: Int,
                                 exposureEV: Double, captureKelvin: Double, settings: HNCSSettings, effects: EffectToggles = .standard, whiteBalance: PhotoWhiteBalance? = nil, workScale: Double = 1) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              work.count == width * height * 3 else { throw Error.invalidDimensions }
        guard settings.usesExtendedWorkingDomain || workScale == 1 else { throw Error.invalidSettings }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: captureKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance, workScale: workScale)
        defer { withExtendedLifetime(owner) {} }
        var result = [Float](repeating: 0, count: width * height * 4)
        let status = work.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { output in
                if settings.usesExtendedWorkingDomain {
                    return hncs_finish_apple_hdr_work_linear_parallel(owner.pointer, source.baseAddress, output.baseAddress, width * height, workScale, workerCount())
                }
                return hncs_finish_phocus_work_linear_parallel(owner.pointer, source.baseAddress, output.baseAddress, width * height, workerCount())
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
                             baselineSharpness: Double = 0,
                             workScale: Double = 1,
                             isCancelled: @escaping () -> Bool) throws {
        guard baselineSharpness.isFinite, baselineSharpness >= 0 else { throw Error.invalidSettings }
        try file.prepareForSpatialPass()
        if isCancelled() { throw CancellationError() }
        let cancellation = SpatialCancellation(isCancelled)
        let opaque = Unmanaged.passUnretained(cancellation).toOpaque()
        let status = file.url.path.withCString { path in
            settings.presetKey.withCString { key in
                FileManager.default.temporaryDirectory.path.withCString { scratch in
                    if settings.usesExtendedWorkingDomain {
                        return hncs_prepare_apple_hdr_spatial_file(path, file.width, file.height, key,
                            effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0,
                            baselineSharpness, workScale, scratch, { context in
                                guard let context else { return 0 }
                                return Unmanaged<SpatialCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled() ? 1 : 0
                            }, opaque)
                    }
                    return hncs_apply_spatial_native_sharpness_file(path, file.width, file.height, key,
                        effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0,
                        baselineSharpness, scratch, { context in
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
