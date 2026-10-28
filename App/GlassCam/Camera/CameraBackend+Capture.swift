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
            completion(CaptureOutcome(result: .failure(CameraFailure("Apple ProRAW capture is currently unavailable.")), bundle: nil,
                                      previewReady: false, message: "Camera is unavailable. Retry the camera.")); return
        }
        let request = CaptureRequest(configuration: configuration, capability: capability,
                                     orientation: interfaceOrientation, lifetime: lifetime, quality: quality, progress: progress, completion: completion)
        currentRequest = request; phase = .preparingPhoto
        do {
            try validateRunningGraph()
            if quality == .f5 {
                try captureF5(request, snapshot: snapshot, f5Purpose: f5Purpose)
                return
            }
            if session is AVCaptureMultiCamSession {
                guard let center = devices.first else { throw CameraFailure("The selected physical camera is unavailable.") }
                let primary = center
                let tangent = tan(Double(center.activeFormat.videoFieldOfView) * .pi / 360) / Double(center.videoZoomFactor)
                request.restoresPreviewGraph = true
                request.progress(.preparing, "Preparing full-resolution photo…")
                tearDownGraph(preservingPreview: true)
                let photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
                    expected: nil, includePreview: false, forcedDevice: primary, matchingFieldOfViewTangent: tangent)
                self.capability = photo; dimensions = photo.dimensions; request.capability = photo
            } else if let center = devices.first,
               let physical = highResolutionConstituent(for: center, displayedZoom: configuration.displayedZoom) {
                request.restoresPreviewGraph = true
                request.progress(.preparing, "Preparing full-resolution photo…")
                tearDownGraph(preservingPreview: true)
                let photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
                    expected: nil, includePreview: false, forcedDevice: physical)
                self.capability = photo; dimensions = photo.dimensions; request.capability = photo
            }
            waitUntilPhotoReady(request, deadline: .now() + 8)
        } catch {
            finishPhoto(.failure(error), request: request)
        }
    }
    private func waitUntilPhotoReady(_ request: CaptureRequest, deadline: DispatchTime) {
        // Old timers/delegates may never touch a newer graph or restore a lens.
        guard currentRequest === request, phase == .preparingPhoto else { return }
        do {
            try request.lifetime.check(); try validateRunningGraph()
            guard let output = photoOutput, let center = devices.first,
                  let session, session.sessionPreset == .photo,
                  output.isAppleProRAWSupported, output.isAppleProRAWEnabled else {
                throw CameraFailure("The ordinary photo session cannot capture Apple ProRAW.")
            }
            try validate(try photoCapability(center), matches: request.capability)
            guard interfaceOrientation == request.orientation,
                  output.connection(with: .video)?.videoOrientation == orientation else {
                throw CameraFailure("Photo orientation changed during capture preparation.")
            }
            guard let photoWarmupDeadline else { throw CameraFailure("The photo session has not started.") }
            // The extra settling delay protects 48MP delivery. Speed explicitly
            // requests 12MP and only needs the output's own readiness signal.
            if (request.quality == .speed || DispatchTime.now() >= photoWarmupDeadline), output.captureReadiness == .ready {
                try submitPhoto(request, output: output)
            } else if DispatchTime.now() >= deadline {
                throw CameraFailure("The full-resolution photo output did not become ready within 8 seconds. No lower-resolution capture was substituted.")
            } else {
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self, weak request] in
                    guard let self, let request else { return }; self.waitUntilPhotoReady(request, deadline: deadline)
                }
            }
        } catch { finishPhoto(.failure(error), request: request) }
    }
    private func submitPhoto(_ request: CaptureRequest, output: AVCapturePhotoOutput) throws {
        guard currentRequest === request, phase == .preparingPhoto else { return }
        try request.lifetime.check()
        guard let raw = output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) else {
            throw CameraFailure("The photo graph no longer exposes Apple ProRAW.")
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        guard let camera = devices.first else { throw CameraFailure("Camera stopped before capture.") }
        let available = nativePhotoDimensions(format: camera.activeFormat).map(Self.size)
        guard let selected = request.quality.sourceDimensions(available: available) else {
            throw CameraFailure("Speed requires a 12 MP ProRAW format on this camera.")
        }
        let captureDimensions = CMVideoDimensions(width: Int32(selected.width), height: Int32(selected.height))
        settings.maxPhotoDimensions = captureDimensions
        switch request.quality {
        case .f5: throw F5Failure(.unsupportedRAW, "F5 must use its independent Bayer transaction.")
        case .speed: settings.photoQualityPrioritization = .speed
        case .balanced: settings.photoQualityPrioritization = .balanced
        case .quality: settings.photoQualityPrioritization = .quality
        }
        settings.isAutoContentAwareDistortionCorrectionEnabled = false
        let catalog = lensCatalog
        let delegate = ProRAWCapture(expectedDimensions: captureDimensions,
                                     framing: { Self.framing(for: camera, catalog: catalog) }) { [weak self, weak request] result in
            guard let self, let request else { return }
            self.queue.async { [weak self, weak request] in
                guard let self, let request, self.currentRequest === request else { return }
                self.finishPhoto(result, request: request)
            }
        }
        captureDelegate = delegate; phase = .capturing
        request.progress(.capturing, "Capturing full-resolution Apple ProRAW…")
        output.capturePhoto(with: settings, delegate: delegate)
        // AVFoundation normally finishes via its delegate. A watchdog prevents a
        // missing terminal callback from leaving the shutter owned forever.
        queue.asyncAfter(deadline: .now() + 45) { [weak self, weak request] in
            guard let self, let request, self.currentRequest === request, self.phase == .capturing else { return }
            self.failSession("Photo capture timed out. Retry the camera.", stopRunning: true)
        }
    }
    func finishPhoto(_ result: Result<CapturedProRAW, Error>, request: CaptureRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentRequest === request, request.completion != nil else { return }
        request.result = result; captureDelegate = nil; f5Capture = nil
        var bundle: Bundle?
        var previewReady = false
        var previewError: String?
        if !request.lifetime.isCancelled && !failed && phase != .stopped {
            do {
                if request.restoresPreviewGraph {
                    phase = .restoringPreview
                    request.progress(.restoring, "Restoring automatic viewfinder…")
                    tearDownGraph(preservingPreview: true)
                    var photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
                        expected: nil, includePreview: true)
                    capability = photo; dimensions = photo.dimensions
                    try waitForPreviewFrames()
                    photo = try promotePreview(configuration: request.configuration, orientation: request.orientation, photo: photo)
                    capability = photo
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
    func finishRequest(_ request: CaptureRequest, result: Result<CapturedProRAW, Error>, bundle: Bundle?,
                               previewReady: Bool, message: String?) {
        guard currentRequest === request, let callback = request.completion else { return }
        request.completion = nil; currentRequest = nil; captureDelegate = nil; f5Capture = nil
        callback(CaptureOutcome(result: result, bundle: bundle, previewReady: previewReady, message: message))
    }
}
