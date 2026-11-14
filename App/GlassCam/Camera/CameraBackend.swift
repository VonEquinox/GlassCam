import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

final class CameraBackend: CameraBackendServing {
    static let previewFrameRates: [Int32] = [60, 30, 15]
    static let logger = Logger(subsystem: "dev.glasscam.prototype", category: "Camera")
    struct Bundle {
        let center: AVSampleBufferDisplayLayer
        let liveSource: LiveCameraFrameSource
        let peripheralSource: PeripheralFrameSource?
        let geometry: CameraController.CameraGeometry
        let sourceCaptureDimensions: CGSize
        let physicalCameraID: String
        let centerPreviewDimensions: CGSize
        let centerPreviewEncoding: String
        let zoomRange: CameraZoomRange
        let framing: CaptureFraming
        var metering: CameraMetering = .automatic
        var meteringAdjusting = false
        var nativeMainZoom = 1.0
        var exposureBiasRange: ClosedRange<Float> = -2...2
    }
    struct CaptureOutcome {
        let result: Result<CapturedBayerRAW, Error>
        let bundle: Bundle?
        let previewReady: Bool
        let message: String?
    }
    enum Phase { case stopped, configuring, preview, preparingPhoto, capturing, restoringPreview, failed }
    struct PreviewConfiguration {
        let mode: CameraController.Mode
        let centerPreviewLongEdge: Int
        var displayedZoom: Double
    }
    struct PhotoCapability {
        let physicalCameraID: String
        let dimensions: CMVideoDimensions
        let horizontalFieldOfView: Float
        let zoom: CGFloat
    }
    final class CaptureRequest {
        let id = UUID()
        let configuration: PreviewConfiguration
        var capability: PhotoCapability
        var restoresPreviewGraph = false
        let orientation: UIInterfaceOrientation
        let previewOrientation: UIInterfaceOrientation
        let metering: CameraMetering
        let quality: CaptureQuality
        let lifetime: CameraLifetime
        let progress: (CameraController.CapturePhase, String) -> Void
        var completion: ((CaptureOutcome) -> Void)?
        var result: Result<CapturedBayerRAW, Error>?
        init(configuration: PreviewConfiguration, capability: PhotoCapability, orientation: UIInterfaceOrientation,
             previewOrientation: UIInterfaceOrientation, metering: CameraMetering,
             lifetime: CameraLifetime, quality: CaptureQuality,
             progress: @escaping (CameraController.CapturePhase, String) -> Void,
             completion: @escaping (CaptureOutcome) -> Void) {
            self.configuration = configuration; self.capability = capability; self.orientation = orientation
            self.previewOrientation = previewOrientation; self.metering = metering
            self.lifetime = lifetime; self.progress = progress; self.completion = completion
            self.quality = quality
        }
    }
    let queue = DispatchQueue(label: "dev.glasscam.camera", qos: .userInitiated)
    var phase: Phase = .stopped
    var lifetime: CameraLifetime?
    var configuration: PreviewConfiguration?
    var capability: PhotoCapability?
    var session: AVCaptureSession?
    var photoOutput: AVCapturePhotoOutput?
    var devices: [AVCaptureDevice] = []
    var dimensions = CMVideoDimensions(width: 0, height: 0)
    var orientation: AVCaptureVideoOrientation = .portrait
    var interfaceOrientation: UIInterfaceOrientation = .portrait
    var metering = CameraMetering.automatic
    var lockedMetering: CameraMeteringLock?
    var meteringChangedAt = DispatchTime.now()
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    var f5Capture: F5CaptureDriver?
    var currentRequest: CaptureRequest?
    private var failureHandler: ((String) -> Void)?
    var failed = false
    private var recoveryBudget = CameraSessionRecovery.Budget()
    var previewOutputs: [AVCaptureVideoDataOutput] = []
    var frameDeliveries: [CameraFrameDelivery] = []
    var frozenDeliveries: [CameraFrameDelivery] = []
    var previewSizes: [CMVideoDimensions] = []
    var previewPixelFormats: [OSType] = []
    var previewReadiness = DispatchGroup()
    var peripheralFrameSource: PeripheralFrameSource?
    var previewSynchronizer: AVCaptureDataOutputSynchronizer?
    var synchronizedDelivery: PeripheralFrameSynchronizer?
    var previewPortDevices: [AVCaptureDevice] = []
    var synchronizedPreviewDevice: AVCaptureDevice?
    var nativePhotoHints: [String: CMVideoDimensions] = [:]
    struct NativeLens {
        let device: AVCaptureDevice
        let rawZoom: Double
        let displayedZoom: Double
    }
    var tripleCamera: AVCaptureDevice?
    var lensCatalog: [NativeLens] = []
    var stateChanged: ((Bundle) -> Void)?

    func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int,
                   orientation: UIInterfaceOrientation, lifetime: CameraLifetime,
                   displayedZoom: Double,
                   stateChanged: @escaping (Bundle) -> Void,
                   failure: @escaping (String) -> Void) throws -> Bundle {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        recoveryBudget = CameraSessionRecovery.Budget()
        self.lifetime = lifetime; try lifetime.check()
        failed = false; phase = .configuring; failureHandler = failure
        self.stateChanged = stateChanged
        discoverLensCatalog()
        let mainZoom = lensCatalog.first { $0.device.deviceType == .builtInWideAngleCamera }?.displayedZoom ?? displayedZoom
        let plan = PreviewConfiguration(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, displayedZoom: mainZoom)
        configuration = plan
        var photo = try buildSinglePhotoGraph(configuration: plan, orientation: orientation, expected: nil, includePreview: true)
        capability = photo; dimensions = photo.dimensions
        try waitForPreviewFrames()
        photo = try promotePreview(configuration: plan, orientation: orientation, photo: photo)
        capability = photo
        phase = .preview
        return try previewBundle()
    }

    func checkLifetime() throws {
        guard let lifetime else { throw CameraFailure("Camera stopped.") }
        try lifetime.check()
    }
    func validateRunningGraph() throws {
        try checkLifetime()
        guard let session, session.isRunning, !session.isInterrupted, !failed else {
            PeripheralDiagnostics.trace("graph invalid phase=\(phase) running=\(session?.isRunning ?? false) interrupted=\(session?.isInterrupted ?? false) failed=\(failed) cameras=\(devices.map { "\($0.deviceType.rawValue) pressure=\($0.systemPressureState.level.rawValue) format=\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)) min=\(CMTimeGetSeconds($0.activeVideoMinFrameDuration)) max=\(CMTimeGetSeconds($0.activeVideoMaxFrameDuration))" })")
            throw CameraFailure("The camera session is stopped or interrupted.")
        }
        for device in devices {
            let level = device.systemPressureState.level
            if level == .serious || level == .critical || level == .shutdown {
                throw CameraFailure("Device system pressure exceeded the capture budget.",
                    userMessage: String(localized: "The camera is too hot. Let it cool, then try again."))
            }
        }
    }
    /// First-frame readiness means a matching frame was actually enqueued on
    /// each main-thread display layer. Cancellation is checked while waiting.
    func waitForPreviewFrames() throws {
        let deadline = DispatchTime.now() + 5
        try CameraPreviewReadiness.wait(next: { self.previewReadiness.wait(timeout: .now() + 0.05) },
                                        expired: { DispatchTime.now() >= deadline }, validate: validateRunningGraph)
        let encodings = previewPixelFormats.map(Self.previewEncoding).joined(separator: ", ")
        Self.logger.info("Preview ready after matching frames: \(encodings, privacy: .public)")
    }
    func failSession(_ message: String, stopRunning: Bool = false,
                     userMessage: String = String(localized: "The camera was interrupted. Tap Retry camera.")) {
        dispatchPrecondition(condition: .onQueue(queue))
        PeripheralDiagnostics.trace("session failure: \(message) phase=\(phase)")
        failed = true; phase = .failed
        frameDeliveries.forEach { $0.freeze() }
        if stopRunning { session?.stopRunning() }
        Self.logger.error("\(message, privacy: .public)")
        failureHandler?(userMessage)
        if let request = currentRequest {
            let result = request.result ?? f5Capture?.cancel().map(Self.burstPhoto) ?? .failure(CameraFailure(message))
            // Preserve only a successfully committed terminal photo result, even
            // if its queued callback or preview restoration has not run yet.
            finishPhoto(result, request: request)
        }
    }
    func installObservers(_ observed: AVCaptureSession) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            notifications.append(center.addObserver(forName: name, object: observed, queue: nil) { [weak self, weak observed] notification in
                let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                let detail = avError?.localizedDescription
                PeripheralDiagnostics.trace("session notification \(name.rawValue) detail=\(String(describing: notification.userInfo))")
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed else { return }
                    if name == AVCaptureSession.interruptionEndedNotification {
                        if CameraSessionRecovery.action(for: .interruptionEnded,currentGeneration: true,
                            cancelled: self.lifetime?.isCancelled ?? true,capturing: self.currentRequest != nil,
                            multiCam: observed is AVCaptureMultiCamSession) == .rebuild {
                            self.recoverPreview(reason: "interruption-ended")
                        }
                    } else if name == AVCaptureSession.runtimeErrorNotification, avError?.code == .mediaServicesWereReset {
                        let action = CameraSessionRecovery.action(for: .mediaServicesReset,currentGeneration: true,
                            cancelled: self.lifetime?.isCancelled ?? true,capturing: self.currentRequest != nil,
                            multiCam: observed is AVCaptureMultiCamSession)
                        if action == .rebuild { self.recoverPreview(reason: "media-services-reset") }
                        else if action == .finishCapture { self.failSession(detail ?? "Camera service reset during capture.",stopRunning: true) }
                    } else {
                        self.failSession(detail ?? "Camera interrupted. Waiting for the camera to become available.", stopRunning: name != AVCaptureSession.wasInterruptedNotification)
                    }
                }
            })
        }
        observations = devices.map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self, weak observed] device, _ in
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed else { return }
                    let level = device.systemPressureState.level
                    if level == .serious, CameraSessionRecovery.action(for: .seriousPressure,currentGeneration: true,
                        cancelled: self.lifetime?.isCancelled ?? true,capturing: self.currentRequest != nil,
                        multiCam: observed is AVCaptureMultiCamSession) == .rebuildCenterOnly {
                        self.recoverPreview(reason: "system-pressure",centralOnly: true)
                    } else if level == .critical || level == .shutdown || level == .serious {
                        self.failSession("Camera system pressure: \(level.rawValue)", stopRunning: true,
                            userMessage: String(localized: "The camera is too hot. Let it cool, then try again."))
                    }
                }
            }
        }
        if let device = devices.first, device.isVirtualDevice {
            observations.append(device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self, weak observed] _, _ in
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed, self.phase == .preview, let bundle = try? self.previewBundle() else { return }
                    self.stateChanged?(bundle)
                }
            })
        }
        if let device = meteringDevice {
            notifications.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                     object: device, queue: nil) { [weak self, weak observed] _ in
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed else { return }
                    self.resumeContinuousMetering()
                }
            })
            for keyPath in [\AVCaptureDevice.isAdjustingFocus, \AVCaptureDevice.isAdjustingExposure] {
                observations.append(device.observe(keyPath, options: [.new]) { [weak self, weak observed] _, _ in
                    self?.queue.async { [weak self, weak observed] in
                        guard let self, let observed, self.session === observed else { return }
                        self.publishMetering()
                    }
                })
            }
        }
    }
    /// At most two automatic recoveries in a 30-second window. A request that
    /// owns a photo result always finishes through its existing exactly-once path.
    private func recoverPreview(reason: String, centralOnly: Bool = false) {
        guard currentRequest == nil, let plan = configuration,
              let lifetime, !lifetime.isCancelled else { return }
        guard recoveryBudget.admit(at: CACurrentMediaTime()) else {
            failSession("Camera recovery failed repeatedly. Select the lens to retry.",stopRunning: true); return
        }
        phase = .configuring; failed = false
        PeripheralDiagnostics.trace("recovering camera reason=\(reason) attempt=\(recoveryBudget.attempts)")
        tearDownGraph(preservingPreview: true)
        do {
            try checkLifetime()
            var photo = try buildSinglePhotoGraph(configuration: plan,orientation: interfaceOrientation,expected: nil,includePreview: true)
            capability = photo; dimensions = photo.dimensions
            try waitForPreviewFrames()
            if !centralOnly { photo = try promotePreview(configuration: plan,orientation: interfaceOrientation,photo: photo) }
            capability = photo; phase = .preview
            stateChanged?(try previewBundle())
        } catch { failSession(error.localizedDescription,stopRunning: true) }
    }
    /// Owns graph disposal only, never a request completion. Stop and remove every
    /// input/output before another graph can acquire the same physical device.
    func tearDownGraph(preservingPreview: Bool) {
        previewSynchronizer?.setDelegate(nil, queue: nil)
        synchronizedDelivery?.queue.sync {}
        previewSynchronizer = nil; synchronizedDelivery = nil
        peripheralFrameSource?.invalidate(); peripheralFrameSource = nil
        synchronizedPreviewDevice=nil
        previewPortDevices.removeAll()
        previewOutputs.forEach { $0.setSampleBufferDelegate(nil, queue: nil) }
        frameDeliveries.forEach { delivery in
            if preservingPreview { delivery.freeze() } else { delivery.invalidate() }
            delivery.callbackQueue.sync {}
        }
        if preservingPreview && !frameDeliveries.isEmpty { frozenDeliveries = frameDeliveries }
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        if let old = session {
            old.stopRunning()
            old.beginConfiguration()
            old.connections.forEach { old.removeConnection($0) }
            old.outputs.forEach { old.removeOutput($0) }
            old.inputs.forEach { old.removeInput($0) }
            old.commitConfiguration()
        }
        previewOutputs.removeAll(); frameDeliveries.removeAll(); previewSizes.removeAll(); previewPixelFormats.removeAll()
        session = nil; photoOutput = nil; devices = []
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        lifetime?.cancel(); phase = .stopped; failed = true
        let request = currentRequest
        let result = request?.result ?? f5Capture?.cancel().map(Self.burstPhoto) ?? .failure(CameraFailure("Camera capture cancelled."))
        tearDownGraph(preservingPreview: false)
        frozenDeliveries.forEach { $0.invalidate() }; frozenDeliveries.removeAll()
        if let request { finishRequest(request, result: result, bundle: nil, previewReady: false, message: String(localized: "Camera stopped")) }
        f5Capture = nil; configuration = nil; capability = nil; lifetime = nil
        dimensions = CMVideoDimensions(width: 0, height: 0); failureHandler = nil
        stateChanged = nil; tripleCamera = nil; lensCatalog = []; nativePhotoHints.removeAll()
        metering = .automatic; lockedMetering = nil
    }
}
