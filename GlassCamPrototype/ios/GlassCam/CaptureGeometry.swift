import Foundation

/// Displayed camera zoom is distinct from the zoom factor of an AVCaptureDevice.
struct CameraZoomStop: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let factor: Double
}

struct CameraZoomRange: Equatable, Sendable {
    let lowerBound: Double
    let upperBound: Double
    let stops: [CameraZoomStop]

    static let main = CameraZoomRange(lowerBound: 1, upperBound: 1,
                                     stops: [.init(id: "main", title: "Main", factor: 1)])

    func clamped(_ factor: Double) -> Double {
        guard factor.isFinite, lowerBound.isFinite, upperBound.isFinite,
              lowerBound > 0, upperBound >= lowerBound else { return lowerBound }
        return min(upperBound, max(lowerBound, factor))
    }

    static func label(_ factor: Double) -> String {
        let number = factor.formatted(.number.precision(.fractionLength(0...1)))
        return "\(number)×"
    }
}

/// Acquisition evidence, not an instruction to crop the RAW again. Camera zoom
/// is already applied by AVFoundation and interpreted by the RAW decoder.
struct CaptureFraming: Codable, Equatable, Sendable {
    var displayZoom: Double = 1
    var deviceZoom: Double = 1
    var nativeDeviceZoom: Double = 1
    var cameraID: String?
    var lensName: String?
    var nativePixelCount: Int?
    var deliveredWidth: Int?
    var deliveredHeight: Int?
    var decodedWidth: Int?
    var decodedHeight: Int?
    var exifDigitalZoom: Double?
    var exifFocalLength: Double?
    var exifEquivalentFocalLength: Double?
    var exifLensModel: String?

    var isValid: Bool {
        displayZoom.isFinite && displayZoom > 0 &&
        deviceZoom.isFinite && deviceZoom > 0 &&
        nativeDeviceZoom.isFinite && nativeDeviceZoom > 0 &&
        (nativePixelCount.map { $0 > 0 } ?? true) &&
        (deliveredWidth.map { $0 > 0 } ?? true) &&
        (deliveredHeight.map { $0 > 0 } ?? true) &&
        (decodedWidth.map { $0 > 0 } ?? true) &&
        (decodedHeight.map { $0 > 0 } ?? true) &&
        ((decodedWidth == nil) == (decodedHeight == nil))
    }

    var relativeDigitalZoom: Double {
        let geometric = max(1, deviceZoom / nativeDeviceZoom)
        // The physical constituent may change while the photo is acquired.
        // Valid photo metadata can lower the estimated detail ceiling, but a
        // missing/default EXIF value must not erase known geometric cropping.
        guard let exifDigitalZoom, exifDigitalZoom.isFinite, exifDigitalZoom >= 1 else { return geometric }
        return max(geometric, exifDigitalZoom)
    }

    /// A conservative center-crop estimate. A virtual camera can use additional
    /// sensor sampling/fusion, so this must be labelled estimated, not measured
    /// independent detail. The decoded RAW always supplies the other ceiling.
    var estimatedEffectivePixelCeiling: Double? {
        guard isValid, let nativePixelCount else { return nil }
        return Double(nativePixelCount) / (relativeDigitalZoom * relativeDigitalZoom)
    }

    func acceptsRAWDimensions(requestedWidth: Int, requestedHeight: Int,
                              deliveredWidth: Int, deliveredHeight: Int, bufferWidth: Int, bufferHeight: Int) -> Bool {
        let requested = [requestedWidth, requestedHeight].sorted()
        let delivered = [deliveredWidth, deliveredHeight].sorted()
        guard requested[0] > 0, delivered[0] > 0, delivered[0] <= requested[0], delivered[1] <= requested[1],
              [bufferWidth, bufferHeight].sorted() == delivered,
              abs((Double(delivered[1]) / Double(delivered[0])) / (Double(requested[1]) / Double(requested[0])) - 1) < 0.001 else { return false }
        // Output interpolation does not excuse a lower-than-requested RAW at a
        // known lens's uncropped native view. Cropped zoom delivery may be smaller.
        if cameraID != nil, relativeDigitalZoom <= 1.0001,
           let nativePixelCount, Double(nativePixelCount) >= Double(requested[0]) * Double(requested[1]) * 0.99 {
            return delivered == requested
        }
        return true
    }

    func effectivePixels(decodedWidth: Int, decodedHeight: Int,
                         cropWidth: Int, cropHeight: Int) -> Double {
        let decoded = Double(decodedWidth) * Double(decodedHeight)
        guard decoded > 0 else { return 0 }
        let ceiling = min(decoded, estimatedEffectivePixelCeiling ?? decoded)
        return ceiling * Double(cropWidth) * Double(cropHeight) / decoded
    }
}

struct CapturedCameraPhoto: Sendable {
    let data: Data
    let framing: CaptureFraming
}

/// Lets lifecycle changes stop work at the pipeline's existing safe boundaries.
final class CaptureProcessingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
