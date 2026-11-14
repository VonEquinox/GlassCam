import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

extension CameraBackend {
    func capture(quality: CaptureQuality, snapshot: CaptureSnapshot? = nil, f5Purpose: String = "product",
                 progress: @escaping (CameraController.CapturePhase, String) -> Void,
                 completion: @escaping (CaptureOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil, let configuration, let capability, let lifetime else {
            completion(CaptureOutcome(result: .failure(CameraFailure("Bayer RAW capture is currently unavailable.")), bundle: nil,
                                      previewReady: false, message: "Camera is unavailable. Retry the camera.")); return
        }
        let request = CaptureRequest(configuration: configuration, capability: capability,
                                     orientation: interfaceOrientation, lifetime: lifetime, quality: quality, progress: progress, completion: completion)
        currentRequest = request; phase = .preparingPhoto
        do {
            try validateRunningGraph()
            let frozen = snapshot ?? CaptureSnapshot(recipe: .standard,output: .native,quality: quality)
            try captureF5(request, snapshot: frozen, f5Purpose: f5Purpose)
        } catch {
            finishPhoto(.failure(error), request: request)
        }
    }
    func finishPhoto(_ result: Result<CapturedBayerRAW, Error>, request: CaptureRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentRequest === request, request.completion != nil else { return }
        request.result = result; f5Capture = nil
        var bundle: Bundle?
        var previewReady = false
        var previewError: String?
        if !request.lifetime.isCancelled && !failed && phase != .stopped {
            do {
                if request.restoresPreviewGraph {
                    phase = .restoringPreview
                    request.progress(.restoring, "Restoring automatic viewfinder…")
                    tearDownGraph(preservingPreview: true)
                    if let center = lensCatalog.first(where: { $0.device.uniqueID == request.capability.physicalCameraID })?.device {
                        let restored = try promotePreview(configuration: request.configuration, orientation: request.orientation,
                                                          photo: request.capability, centerDevice: center)
                        capability = restored; dimensions = restored.dimensions
                    } else {
                        var photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
                            expected: nil, includePreview: true)
                        capability = photo; dimensions = photo.dimensions
                        try waitForPreviewFrames()
                        photo = try promotePreview(configuration: request.configuration, orientation: request.orientation, photo: photo)
                        capability = photo
                    }
                }
                try validateRunningGraph()
                try request.lifetime.check()
                phase = .preview; previewReady = true
                bundle = try previewBundle()
                // Old layers remain alive through the controller's references
                // until its main-thread bundle replacement. Do not flush them.
                frozenDeliveries.removeAll()
            } catch {
                previewError = error.localizedDescription
                phase = .failed; failed = true
                tearDownGraph(preservingPreview: true)
            }
        } else {
            previewError = request.lifetime.isCancelled ? "Camera stopped." : "Camera interrupted. Retry the camera to restore preview."
            tearDownGraph(preservingPreview: true)
        }
        let message: String?
        switch result {
        case .success:
            message = previewReady ? nil : "Photo captured. Preview unavailable: \(previewError ?? "Retry the camera.")"
        case .failure(let error):
            message = previewReady ? error.localizedDescription : "\(error.localizedDescription) Preview unavailable: \(previewError ?? "Retry the camera.")"
        }
        finishRequest(request, result: result, bundle: bundle, previewReady: previewReady, message: message)
    }
    func finishRequest(_ request: CaptureRequest, result: Result<CapturedBayerRAW, Error>, bundle: Bundle?,
                               previewReady: Bool, message: String?) {
        guard currentRequest === request, let callback = request.completion else { return }
        request.completion = nil; currentRequest = nil; f5Capture = nil
        callback(CaptureOutcome(result: result, bundle: bundle, previewReady: previewReady, message: message))
    }
}
