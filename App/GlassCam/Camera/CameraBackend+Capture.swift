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
                 orientation: UIInterfaceOrientation,
                 progress: @escaping (CameraController.CapturePhase, String) -> Void,
                 completion: @escaping (CaptureOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil, let configuration, let capability, let lifetime else {
            completion(CaptureOutcome(result: .failure(CameraFailure("Bayer RAW capture is currently unavailable.")), bundle: nil,
                                      previewReady: false, message: String(localized: "The camera is unavailable. Tap Retry camera."))); return
        }
        let request = CaptureRequest(configuration: configuration, capability: capability,
                                     orientation: orientation, previewOrientation: interfaceOrientation, metering: metering,
                                     lifetime: lifetime, quality: quality, progress: progress, completion: completion)
        currentRequest = request; phase = .preparingPhoto
        do {
            try validateRunningGraph()
            let frozen = snapshot ?? CaptureSnapshot(recipe: .standard,output: .native,quality: quality)
            prepareMeteredCapture(request, snapshot: frozen, purpose: f5Purpose, deadline: .now() + 8)
        } catch {
            finishPhoto(.failure(error), request: request)
        }
    }
    private func prepareMeteredCapture(_ request: CaptureRequest, snapshot: CaptureSnapshot,
                                       purpose: String, deadline: DispatchTime) {
        guard currentRequest === request, request.completion != nil else { return }
        do {
            try request.lifetime.check()
            if request.metering.locked, let device = meteringDevice {
                if device.isAdjustingFocus || device.isAdjustingExposure || DispatchTime.now() < meteringChangedAt + 0.3 {
                    guard DispatchTime.now() < deadline else {
                        throw CameraFailure("AE/AF did not settle before capture handoff.",
                            userMessage: String(localized: "Focus or exposure is still changing. Hold steady and try again."))
                    }
                    queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.prepareMeteredCapture(request, snapshot: snapshot, purpose: purpose, deadline: deadline)
                    }
                    return
                }
                if let main = devices.first { lockedMetering = CameraMeteringLock(device: main) }
            }
            try captureF5(request, snapshot: snapshot, f5Purpose: purpose)
        } catch { finishPhoto(.failure(error), request: request) }
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
                    request.progress(.restoring, String(localized: "Restoring viewfinder…"))
                    tearDownGraph(preservingPreview: true)
                    if let center = lensCatalog.first(where: { $0.device.uniqueID == request.capability.physicalCameraID })?.device {
                        let restored = try promotePreview(configuration: request.configuration, orientation: request.previewOrientation,
                                                          photo: request.capability, centerDevice: center)
                        capability = restored; dimensions = restored.dimensions
                    } else {
                        var photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.previewOrientation,
                            expected: nil, includePreview: true)
                        capability = photo; dimensions = photo.dimensions
                        try waitForPreviewFrames()
                        photo = try promotePreview(configuration: request.configuration, orientation: request.previewOrientation, photo: photo)
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
            previewError = request.lifetime.isCancelled ? String(localized: "Camera stopped")
                : String(localized: "The camera was interrupted. Tap Retry camera.")
            tearDownGraph(preservingPreview: true)
        }
        let message: String?
        switch result {
        case .success:
            message = previewReady ? nil : String(localized: "Photo captured. Tap Retry camera to restore the viewfinder.")
        case .failure(let error):
            message = previewReady ? error.localizedDescription : String(localized: "The capture was interrupted. Check its status, then tap Retry camera.")
        }
        if let previewError { Self.logger.notice("Preview restoration: \(previewError, privacy: .public)") }
        finishRequest(request, result: result, bundle: bundle, previewReady: previewReady, message: message)
    }
    func finishRequest(_ request: CaptureRequest, result: Result<CapturedBayerRAW, Error>, bundle: Bundle?,
                               previewReady: Bool, message: String?) {
        guard currentRequest === request, let callback = request.completion else { return }
        request.completion = nil; currentRequest = nil; f5Capture = nil
        callback(CaptureOutcome(result: result, bundle: bundle, previewReady: previewReady, message: message))
    }
}
