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
    func recordScene(quality: CaptureQuality, id: UUID, recipe: ProcessingRecipe,
                     archiveInputs: Bool) async throws {
        let reservation = try await reserveMainForTest()
        defer { releaseCaptureReservation(reservation) }
        let output: ExportSettings = quality == .balanced ? .native.withFraming(currentFraming) : .camera(48,framing: currentFraming)
        let snapshot = CaptureSnapshot(recipe: recipe,output: output,quality: quality,
            archiveF5RAW: archiveInputs,rawArchiveID: id)
        let photo: CapturedCameraPhoto = try await withCheckedThrowingContinuation { continuation in
            capturePhoto(reservation: reservation,quality: quality,snapshot: snapshot,f5Purpose: "scene") {
                continuation.resume(with: $0)
            }
        }
        try await Task.detached(priority: .userInitiated) {
            if quality == .balanced {
                guard let source = photo.burst as? F5BurstSource else { throw F5Failure(.frameMissing,"Balanced RAW is missing.") }
                _ = try F5CaptureFormat.archiveRAW(source,snapshot: snapshot)
                // The published merged archive is durable before its input
                // transaction is retired. A failed operation keeps all inputs.
                if !archiveInputs { try? FileManager.default.removeItem(at: source.directory) }
            } else {
                let source = try SourceImageFile(data: photo.data,fileExtension: "dng")
                let frozen = CaptureSnapshot(recipe: recipe,output: output.withFraming(photo.framing),quality: quality,rawArchiveID: id)
                try CaptureRAWStore.retainProRAW(source.url,id: id,snapshot: frozen)
            }
        }.value
    }
}
