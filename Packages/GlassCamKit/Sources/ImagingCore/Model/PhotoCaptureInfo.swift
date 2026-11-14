import Foundation

/// The camera settings recorded in the delivered image, without display text.
public struct PhotoCaptureInfo: Equatable, Sendable {
    public let exposureTime: Double?
    public let iso: Double?
    public let aperture: Double?
    public let focalLength: Double?
    public let equivalentFocalLength: Double?

    public init(exposureTime: Double? = nil, iso: Double? = nil, aperture: Double? = nil,
                focalLength: Double? = nil, equivalentFocalLength: Double? = nil) {
        func positive(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        self.exposureTime = positive(exposureTime); self.iso = positive(iso)
        self.aperture = positive(aperture); self.focalLength = positive(focalLength)
        self.equivalentFocalLength = positive(equivalentFocalLength)
    }
}
