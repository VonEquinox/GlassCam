import Foundation

/// Thin Swift ownership/buffer bridge. All color processing lives in portable C++17.
/// The app uses original legacy / standard / V1 gamma and an experimental source
/// adapter. This does not claim a calibrated iPhone/Apple RAW-to-X2D camera profile.
enum HNCSEngine {
    enum Quality { case exactReference, fastPreview }

    enum Error: LocalizedError {
        case invalidDimensions, invalidSettings, invalidPixels
        var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "The image dimensions or RGB buffer are invalid."
            case .invalidSettings: return "The color processor could not initialize with these settings."
            case .invalidPixels: return "The image contains invalid or non-finite color values."
            }
        }
    }

    /// Immutable C++ contexts are reused across full-resolution export strips.
    /// A one-entry cache bounds memory; in-flight calls retain their own owner.
    private final class ContextOwner: @unchecked Sendable {
        let pointer: OpaquePointer
        let exposure: Double
        let kelvin: Double
        init(exposure: Double, kelvin: Double) throws {
            guard let pointer = hncs_create(exposure, kelvin) else { throw Error.invalidSettings }
            self.pointer = pointer; self.exposure = exposure; self.kelvin = kelvin
        }
        deinit { hncs_destroy(pointer) }
    }
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?
        func context(exposure: Double, kelvin: Double) throws -> ContextOwner {
            lock.lock(); defer { lock.unlock() }
            if let cached, cached.exposure == exposure, cached.kelvin == kelvin { return cached }
            let owner = try ContextOwner(exposure: exposure, kelvin: kelvin)
            cached = owner
            return owner
        }
    }
    private static let contextCache = ContextCache()

    static func process(linearSRGB: [Float], width: Int, height: Int,
                        exposureEV: Double, illuminantKelvin: Double,
                        quality: Quality = .fastPreview) throws -> [UInt8] {
        guard width > 0, height > 0, width <= Int.max / height else {
            throw Error.invalidDimensions
        }
        let count = width * height
        guard count <= Int.max / 4, linearSRGB.count == count * 3 else {
            throw Error.invalidDimensions
        }
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin)
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
                    let info = ProcessInfo.processInfo
                    var workers = min(4, max(1, info.activeProcessorCount))
                    if info.isLowPowerModeEnabled { workers = min(workers, 2) }
                    switch info.thermalState {
                    case .fair: workers = min(workers, 2)
                    case .serious, .critical: workers = 1
                    default: break
                    }
                    return hncs_process_srgb_fast_parallel(context, source.baseAddress,
                                                          destination.baseAddress, count, UInt32(workers))
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
                                 exposureEV: Double, illuminantKelvin: Double) throws -> [Float] {
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
        let owner = try contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin)
        let context = owner.pointer
        defer { withExtendedLifetime(owner) {} }
        var rgba = [Float](repeating: 0, count: count * 4)
        let status = linearSRGB.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                hncs_process_linear_rgba(context, source.baseAddress, destination.baseAddress, count)
            }
        }
        guard status == 0 else { throw Error.invalidPixels }
        return rgba
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
