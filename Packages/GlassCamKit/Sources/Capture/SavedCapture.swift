import Foundation
import ImagingCore

public struct SavedCapture: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let file: TemporaryHEIFFile
    public let preview: PreviewRaster
    public let width: Int
    public let height: Int
    public let snapshot: CaptureSnapshot
    public let cameraInfo: PhotoCaptureInfo
    public let confirmedAt: Date?

    public init(id: UUID = UUID(), file: TemporaryHEIFFile, preview: PreviewRaster, width: Int, height: Int,
                snapshot: CaptureSnapshot, cameraInfo: PhotoCaptureInfo = PhotoCaptureInfo(), confirmedAt: Date? = nil) {
        self.id = id; self.file = file; self.preview = preview; self.width = width; self.height = height
        self.snapshot = snapshot; self.cameraInfo = cameraInfo
        self.confirmedAt = confirmedAt
    }
    func confirming(at date: Date) -> SavedCapture {
        SavedCapture(id: id, file: file, preview: preview, width: width, height: height, snapshot: snapshot,
                     cameraInfo: cameraInfo, confirmedAt: date)
    }

    public func loadFullPreview() async throws -> PreviewRaster {
        guard max(preview.width, preview.height) < min(4096, max(width, height)) else { return preview }
        let url = file.url
        return try await Task.detached(priority: .userInitiated) {
            try ImagePipeline.decodePreviewRaster(at: url, maximumEdge: 4096).raster
        }.value
    }

    public var resolutionDescription: String? {
        if let f5 = snapshot.f5 { return f5.resolutionDescription(width: width, height: height) }
        guard let framing = snapshot.output.framing,
              let sourceWidth = framing.decodedWidth ?? framing.deliveredWidth,
              let sourceHeight = framing.decodedHeight ?? framing.deliveredHeight,
              let effective = try? snapshot.output.effectivePixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                                                   crop: snapshot.recipe.crop) else { return nil }
        let output = Double(width) * Double(height)
        let interpolation = output > effective * 1.025 ? String(localized: " · Interpolated") : ""
        return String(format: String(localized: "Estimated source %.1f MP · Output %.1f MP"),
                      effective / 1_000_000, output / 1_000_000) + interpolation
    }
}
