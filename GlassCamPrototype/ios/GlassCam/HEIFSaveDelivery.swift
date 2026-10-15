import Foundation
import Photos
import SwiftUI
import UIKit

/// Saving is an original-HEIF-only path. Sharing compatibility never enters here.
enum HEIFSaveDelivery {
    enum Error: LocalizedError {
        case permissionDenied, saveFailed
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Allow adding photos in Settings to automatically save your captured HDR photos."
            case .saveFailed: return "Photos could not save this HEIF. The original export was not replaced with another format."
            }
        }
    }
    static func authorizePhotos() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Error.permissionDenied }
    }
    static func saveToPhotos(_ file: TemporaryHEIFFile) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized ||
              PHPhotoLibrary.authorizationStatus(for: .addOnly) == .limited else { throw Error.permissionDenied }
        // Keep the original HEIF owner alive until Photos finishes importing it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.url.lastPathComponent
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file.url, options: options)
            }, completionHandler: { [file] success, error in
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
