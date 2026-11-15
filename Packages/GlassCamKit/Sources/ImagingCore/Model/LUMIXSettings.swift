import Foundation

/// The selected original Photo Style is part of the durable photo recipe.
/// Missing fields in older HNCS/FFCS recipes adopt Standard without changing mode.
public struct LUMIXSettings: Codable, Equatable, Sendable {
    package static let currentRenderRevision = 5
    package var renderRevision = currentRenderRevision
    public var photoStyle = "standard"
    public var contrast = 0.0
    public var saturation = 0.0
    /// Bound from this photo's EXIF once, then retained for retries/export.
    package var sourceISO: Int? = nil
    public static let standard = LUMIXSettings()
    public var isValid: Bool {
        [1, 2, 3, 4, Self.currentRenderRevision].contains(renderRevision) &&
        contrast.isFinite && (-5...5).contains(contrast) &&
        saturation.isFinite && (-5...5).contains(saturation) &&
        (sourceISO == nil || (1...1_000_000).contains(sourceISO!)) &&
        (renderRevision != 1 || (contrast == 0 && saturation == 0 && sourceISO == nil)) &&
        LUMIXPhotoStyleCatalog.looks.contains { $0.id == photoStyle }
    }
    public var title: String { LUMIXPhotoStyleCatalog.looks.first { $0.id == photoStyle }?.name ?? "Unavailable Photo Style" }
    public init(photoStyle: String = "standard", contrast: Double = 0, saturation: Double = 0) {
        self.photoStyle = photoStyle; self.contrast = contrast; self.saturation = saturation
    }
    private enum CodingKeys: String, CodingKey { case renderRevision, photoStyle, contrast, saturation, sourceISO }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        renderRevision = try values.decodeIfPresent(Int.self, forKey: .renderRevision) ?? 1
        photoStyle = try values.decodeIfPresent(String.self, forKey: .photoStyle) ?? "standard"
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sourceISO = try values.decodeIfPresent(Int.self, forKey: .sourceISO)
    }
}
