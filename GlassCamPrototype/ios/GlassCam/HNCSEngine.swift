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
        guard let context = hncs_create(exposureEV, illuminantKelvin) else {
            throw Error.invalidSettings
        }
        defer { hncs_destroy(context) }
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
