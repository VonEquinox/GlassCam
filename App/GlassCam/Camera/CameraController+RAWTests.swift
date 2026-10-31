import Foundation
import Capture
import F5
import ImagingCore

extension CameraController {
    @MainActor
    func recordBayerSamples() async throws -> URL {
        let reservation = try await reserveMainForTest()
        defer { releaseCaptureReservation(reservation) }
        let photo: CapturedCameraPhoto = try await withCheckedThrowingContinuation { continuation in
            capturePhoto(reservation: reservation,quality: .f5,f5Purpose: "probe") { continuation.resume(with: $0) }
        }
        guard let source = photo.burst as? F5BurstSource, source.manifest.frames.count == 11 else {
            throw F5Failure(.frameMissing,"The eleven-frame RAW set is incomplete.")
        }
        return source.directory
    }

    @MainActor
    func recordScene(id: UUID, recipe: ProcessingRecipe,
                     archiveInputs: Bool) async throws {
        let reservation = try await reserveMainForTest()
        defer { releaseCaptureReservation(reservation) }
        let output = ExportSettings.native.withFraming(currentFraming)
        let snapshot = CaptureSnapshot(recipe: recipe,output: output,quality: .balanced,
            archiveF5RAW: archiveInputs,rawArchiveID: id)
        let photo: CapturedCameraPhoto = try await withCheckedThrowingContinuation { continuation in
            capturePhoto(reservation: reservation,quality: .balanced,snapshot: snapshot,f5Purpose: "scene") {
                continuation.resume(with: $0)
            }
        }
        try await Task.detached(priority: .userInitiated) {
            guard let source = photo.burst as? F5BurstSource else { throw F5Failure(.frameMissing,"Balanced RAW is missing.") }
            _ = try F5CaptureFormat.archiveRAW(source,snapshot: snapshot)
            // Keep the inputs until the merged archive is durable.
            if !archiveInputs { try? FileManager.default.removeItem(at: source.directory) }
        }.value
    }
}
