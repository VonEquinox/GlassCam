import ImagingCore
import Capture
import F5
import Peripheral
import Foundation
import Photos
import SwiftUI
import UIKit

/// Saving is an original-HEIF-only path. Sharing compatibility never enters here.
enum HEIFSaveDelivery {
    enum Error: LocalizedError {
        case permissionDenied, saveFailed, inactive
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Allow adding photos in Settings to automatically save your captured HDR photos."
            case .saveFailed: return "Photos could not save this HEIF. The original export was not replaced with another format."
            case .inactive: return "Return to GlassCam to finish saving this photo."
            }
        }
    }
    struct PhotoImport {
        let type: PHAssetResourceType
        let url: URL
        let options: PHAssetResourceCreationOptions
        let captureDate: Date?
    }
    struct Dependencies {
        var authorize: (PHAccessLevel) async -> PHAuthorizationStatus
        var status: (PHAccessLevel) -> PHAuthorizationStatus
        var isActive: @MainActor () -> Bool
        var importPhoto: (PhotoImport, @escaping (Bool, Swift.Error?) -> Void) -> Void
        static let system = Dependencies(
            authorize: { await PHPhotoLibrary.requestAuthorization(for: $0) },
            status: { PHPhotoLibrary.authorizationStatus(for: $0) },
            isActive: { UIApplication.shared.applicationState != .background && UIApplication.shared.isProtectedDataAvailable },
            importPhoto: { photo, completion in
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    if let date = photo.captureDate { request.creationDate = date }
                    request.addResource(with: photo.type, fileURL: photo.url, options: photo.options)
                }, completionHandler: completion)
            })
    }
    static func authorizePhotos(dependencies: Dependencies = .system) async throws {
        let status = await dependencies.authorize(.addOnly)
        guard status == .authorized || status == .limited else { throw Error.permissionDenied }
    }
    @MainActor static func saveToPhotos(_ file: TemporaryHEIFFile, dependencies: Dependencies = .system) async throws {
        guard dependencies.status(.addOnly) == .authorized ||
              dependencies.status(.addOnly) == .limited else { throw Error.permissionDenied }
        guard dependencies.isActive() else { throw Error.inactive }
        let captureDate: Date?
        if let date = file.captureDate { captureDate = date }
        else {
            captureDate = try await Task.detached(priority: .userInitiated) {
                try PhotoMetadata.read(from: file.url).captureDate
            }.value
        }
        guard dependencies.isActive() else { throw Error.inactive }
        // Keep the original HEIF owner alive until Photos finishes importing it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.url.lastPathComponent
            options.shouldMoveFile = false
            let photo = PhotoImport(type: .photo, url: file.url, options: options, captureDate: captureDate)
            dependencies.importPhoto(photo, { [file] success, error in
                withExtendedLifetime(file) {
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: Error.saveFailed) }
                }
            })
        }
    }
}

/// Copies only the already verified HEIF; the document picker owns its destination.
struct HEIFFileSaveSheet: UIViewControllerRepresentable {
    let file: TemporaryHEIFFile
    let completed: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(file: file, completed: completed) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let file: TemporaryHEIFFile
        private var completed: ((Bool) -> Void)?
        init(file: TemporaryHEIFFile, completed: @escaping (Bool) -> Void) {
            self.file = file; self.completed = completed
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
        private func finish(_ saved: Bool) { let callback = completed; completed = nil; callback?(saved) }
    }
}
