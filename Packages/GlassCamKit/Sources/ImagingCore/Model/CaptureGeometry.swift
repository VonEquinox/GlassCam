import Foundation

/// Displayed camera zoom is distinct from the zoom factor of an AVCaptureDevice.
public struct CameraZoomStop: Identifiable, Equatable, Sendable {
    public init(id: String,
         title: String,
         factor: Double) {
        self.id = id
        self.title = title
        self.factor = factor
    }

    public let id: String
    public let title: String
    public let factor: Double
}

public struct CameraZoomRange: Equatable, Sendable {
    public init(lowerBound: Double,
         upperBound: Double,
         stops: [CameraZoomStop]) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.stops = stops
    }

    public let lowerBound: Double
    public let upperBound: Double
    public let stops: [CameraZoomStop]

    public static let main = CameraZoomRange(lowerBound: 1, upperBound: 1,
                                     stops: [.init(id: "main", title: "Main", factor: 1)])

    public func clamped(_ factor: Double) -> Double {
        guard factor.isFinite, lowerBound.isFinite, upperBound.isFinite,
              lowerBound > 0, upperBound >= lowerBound else { return lowerBound }
        return min(upperBound, max(lowerBound, factor))
    }

    public static func label(_ factor: Double) -> String {
        let number = factor.formatted(.number.precision(.fractionLength(0...1)))
        return "\(number)×"
    }
}

/// Acquisition evidence, not an instruction to crop the RAW again. Camera zoom
/// is already applied by AVFoundation and interpreted by the RAW decoder.
public struct CaptureFraming: Codable, Equatable, Sendable {
    public init(displayZoom: Double = 1,
         deviceZoom: Double = 1,
         nativeDeviceZoom: Double = 1,
         cameraID: String? = nil,
         lensName: String? = nil,
         nativePixelCount: Int? = nil,
         deliveredWidth: Int? = nil,
         deliveredHeight: Int? = nil,
         decodedWidth: Int? = nil,
         decodedHeight: Int? = nil,
         exifDigitalZoom: Double? = nil,
         exifFocalLength: Double? = nil,
         exifEquivalentFocalLength: Double? = nil,
         exifLensModel: String? = nil) {
        self.displayZoom = displayZoom
        self.deviceZoom = deviceZoom
        self.nativeDeviceZoom = nativeDeviceZoom
        self.cameraID = cameraID
        self.lensName = lensName
        self.nativePixelCount = nativePixelCount
        self.deliveredWidth = deliveredWidth
        self.deliveredHeight = deliveredHeight
        self.decodedWidth = decodedWidth
        self.decodedHeight = decodedHeight
        self.exifDigitalZoom = exifDigitalZoom
        self.exifFocalLength = exifFocalLength
        self.exifEquivalentFocalLength = exifEquivalentFocalLength
        self.exifLensModel = exifLensModel
    }

    public var displayZoom: Double = 1
    public var deviceZoom: Double = 1
    public var nativeDeviceZoom: Double = 1
    public var cameraID: String?
    public var lensName: String?
    public var nativePixelCount: Int?
    public var deliveredWidth: Int?
    public var deliveredHeight: Int?
    package var decodedWidth: Int?
    package var decodedHeight: Int?
    public var exifDigitalZoom: Double?
    public var exifFocalLength: Double?
    public var exifEquivalentFocalLength: Double?
    public var exifLensModel: String?

    public var isValid: Bool {
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

    public func acceptsRAWDimensions(requestedWidth: Int, requestedHeight: Int,
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

    package func effectivePixels(decodedWidth: Int, decodedHeight: Int,
                         cropWidth: Int, cropHeight: Int) -> Double {
        let decoded = Double(decodedWidth) * Double(decodedHeight)
        guard decoded > 0 else { return 0 }
        let ceiling = min(decoded, estimatedEffectivePixelCeiling ?? decoded)
        return ceiling * Double(cropWidth) * Double(cropHeight) / decoded
    }
}

/// Lets lifecycle changes stop work at the pipeline's existing safe boundaries.
package final class CaptureProcessingControl: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var stopped = false
    package var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    package func stop() { lock.lock(); stopped = true; lock.unlock() }
}
