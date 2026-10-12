import AVFoundation
import Combine
import UIKit

/// Physical-lens capture only. Public methods and published state belong to main.
/// AVFoundation graph ownership belongs exclusively to CameraBackend.queue.
final class CameraController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case ultraWide, main, telephoto
        var id: Self { self }
        var title: String {
            switch self { case .ultraWide: return "Ultra wide"; case .main: return "Main"; case .telephoto: return "Telephoto" }
        }
        fileprivate var centerType: AVCaptureDevice.DeviceType {
            switch self { case .ultraWide: return .builtInUltraWideCamera; case .main: return .builtInWideAngleCamera; case .telephoto: return .builtInTelephotoCamera }
        }
        fileprivate var peripheralType: AVCaptureDevice.DeviceType? {
            switch self { case .ultraWide: return nil; case .main: return .builtInUltraWideCamera; case .telephoto: return .builtInWideAngleCamera }
        }
    }
    /// Processed HEIF target; never a request to lower native ProRAW capture size.
    struct OutputOption: Identifiable, Equatable {
        let megapixels: Int
        let width: Int
        let height: Int
        var id: String { "\(megapixels)-\(width)x\(height)" }
    }
    struct CameraGeometry {
        let sensorPhotoDimensions: CGSize
        let photoAspectRatio: CGFloat
        let centerHorizontalFieldOfView: Float
        let peripheralHorizontalFieldOfView: Float?
    }
    enum CapturePhase: String { case idle, preparing, capturing, restoring }
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isPreviewFrozen = false
    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var actualCapturedDimensions: CGSize?
    @Published private(set) var centerLiveSource: LiveCameraFrameSource?
    @Published private(set) var centerPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var peripheralPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var geometry: CameraGeometry?
    @Published private(set) var supportedOutputOptions: [OutputOption] = []
    @Published private(set) var sourceCaptureDimensions: CGSize?
    @Published private(set) var physicalCameraID: String?
    @Published private(set) var centerPreviewDimensions: CGSize?
    @Published private(set) var peripheralPreviewDimensions: CGSize?
    @Published private(set) var centerPreviewEncoding: String?
    @Published private(set) var peripheralPreviewEncoding: String?
    @Published private(set) var isConfiguring = false
    private let backend = CameraBackend()
    private var generation = UUID()
    private var lifetime = CameraLifetime()
    private var usesCaptureHandoff = false
    private var orientation: UIInterfaceOrientation = .portrait
    private var appliedOrientation: UIInterfaceOrientation = .unknown
    private var orientationRevision: UInt64 = 0
    private var isApplyingOrientation = false

    func start(mode: Mode, centerPreviewLongEdge: Int = 1920, peripheralPreviewLongEdge: Int = 1280) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isConfiguring, !isCapturing else { return }
        lifetime.cancel(); lifetime = CameraLifetime()
        let token = UUID(); generation = token
        isConfiguring = true; isReady = false; isPreviewFrozen = false; capturePhase = .idle
        status = "Checking camera access…"; appliedOrientation = .unknown; isApplyingOrientation = false
        clearPreview()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, peripheralPreviewLongEdge: peripheralPreviewLongEdge, token: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if allowed { self.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, peripheralPreviewLongEdge: peripheralPreviewLongEdge, token: token) }
                    else { self.isConfiguring = false; self.status = "Camera permission denied. Enable camera access in Settings." }
                }
            }
        default:
            isConfiguring = false; status = "Camera permission denied. Enable camera access in Settings."
        }
    }
    private func configure(mode: Mode, centerPreviewLongEdge: Int, peripheralPreviewLongEdge: Int, token: UUID) {
        let initialOrientation = orientation
        let lifetime = lifetime
        status = "Checking \(mode.title) single-camera ProRAW capability…"
        backend.queue.async { [weak self, backend] in
            do {
                let bundle = try backend.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge,
                                                   peripheralPreviewLongEdge: peripheralPreviewLongEdge,
                                                   orientation: initialOrientation, lifetime: lifetime) { message in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.isReady = false; self.status = message
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.install(bundle)
                    self.isConfiguring = false; self.isReady = true
                    self.appliedOrientation = initialOrientation
                    self.status = self.readyStatus
                    self.updateOrientation(self.orientation)
                }
            } catch {
                backend.stop()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isConfiguring = false; self.isReady = false; self.status = error.localizedDescription
                }
            }
        }
    }
    private var readyStatus: String {
        usesCaptureHandoff ? "Apple ProRAW · wider live preview · preview freezes for full-resolution capture" : "Apple ProRAW · black periphery"
    }
    private func install(_ bundle: CameraBackend.Bundle) {
        centerPreviewLayer = bundle.center; centerLiveSource = bundle.liveSource
        peripheralPreviewLayer = bundle.periphery; geometry = bundle.geometry
        supportedOutputOptions = bundle.outputOptions
        sourceCaptureDimensions = bundle.geometry.sensorPhotoDimensions
        physicalCameraID = bundle.physicalCameraID
        centerPreviewDimensions = bundle.centerPreviewDimensions
        peripheralPreviewDimensions = bundle.peripheralPreviewDimensions
        centerPreviewEncoding = bundle.centerPreviewEncoding
        peripheralPreviewEncoding = bundle.peripheralPreviewEncoding
        usesCaptureHandoff = bundle.usesCaptureHandoff
    }
    private func clearPreview() {
        centerPreviewLayer = nil; peripheralPreviewLayer = nil; geometry = nil
        centerLiveSource?.setEnabled(false); centerLiveSource = nil
        supportedOutputOptions = []; sourceCaptureDimensions = nil; physicalCameraID = nil
        centerPreviewDimensions = nil; peripheralPreviewDimensions = nil
        centerPreviewEncoding = nil; peripheralPreviewEncoding = nil
    }
    func updateOrientation(_ value: UIInterfaceOrientation) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard value != .unknown else { return }
        orientation = value
        // A shutter snapshot owns orientation until both the photo and restoration
        // finish. Keep the newest UI orientation, but never rotate its photo graph.
        guard !isConfiguring, !isCapturing, !isApplyingOrientation, value != appliedOrientation,
              centerPreviewLayer != nil, !lifetime.isCancelled else { return }
        isReady = false; isApplyingOrientation = true; centerLiveSource?.setEnabled(false)
        orientationRevision &+= 1
        let revision = orientationRevision, token = generation
        backend.queue.async { [weak self, backend] in
            do {
                try backend.rotatePreview(value)
                let geometry = backend.geometry()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.orientationRevision == revision, !self.isCapturing else { return }
                    self.geometry = geometry; self.appliedOrientation = value; self.isApplyingOrientation = false; self.isReady = true
                    // Coalesce rotations arriving during negotiation, including a
                    // turn back to the previously applied orientation.
                    self.updateOrientation(self.orientation)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.orientationRevision == revision else { return }
                    self.isApplyingOrientation = false; self.isReady = false; self.status = error.localizedDescription
                }
            }
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        // This cancellation is synchronous even if AVFoundation currently blocks
        // its serial queue in startRunning or first-frame negotiation.
        lifetime.cancel(); generation = UUID()
        isConfiguring = false; isReady = false; isCapturing = false
        isPreviewFrozen = false; capturePhase = .idle; appliedOrientation = .unknown; isApplyingOrientation = false
        clearPreview(); status = "Camera stopped"
        backend.queue.async { [backend] in backend.stop() }
    }
    /// Delivers only the validated Apple ProRAW DNG. Preview restore errors are
    /// reported through status/isReady and cannot replace a completed photo.
    func captureProRAW(completion: @escaping (Result<Data, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isReady, !isCapturing, !isConfiguring else {
            completion(.failure(CameraFailure("Camera is unavailable or a capture is already in progress."))); return
        }
        isCapturing = true; isReady = false; isPreviewFrozen = usesCaptureHandoff
        capturePhase = .preparing; actualCapturedDimensions = nil
        if usesCaptureHandoff { centerLiveSource?.setEnabled(false) }
        status = usesCaptureHandoff ? "Preview frozen · preparing full-resolution ProRAW…" : "Preparing ProRAW…"
        let token = generation
        backend.queue.async { [weak self, backend] in
            backend.capture(progress: { phase, message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.capturePhase = phase; self.status = message
                }
            }) { outcome in
                DispatchQueue.main.async { [weak self] in
                    let photoResult = outcome.result.map { $0.data }
                    // Stop/background can invalidate view state, never a completed DNG.
                    guard let self, self.generation == token else { completion(photoResult); return }
                    if let bundle = outcome.bundle { self.install(bundle) }
                    if case .success(let photo) = outcome.result { self.actualCapturedDimensions = photo.dimensions }
                    self.isCapturing = false; self.capturePhase = .idle
                    self.isPreviewFrozen = !outcome.previewReady && self.usesCaptureHandoff
                    self.isReady = outcome.previewReady
                    self.status = outcome.message ?? self.readyStatus
                    if outcome.previewReady { self.updateOrientation(self.orientation) }
                    completion(photoResult)
                }
            }
        }
    }
    deinit { lifetime.cancel(); let engine = backend; engine.queue.async { engine.stop() } }
}

private struct CameraFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Cross-queue cancellation only. All AVFoundation state stays on backend.queue.
private final class CameraLifetime {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CameraFailure("Camera operation cancelled.") } }
}

private struct CapturedProRAW {
    let data: Data
    let dimensions: CGSize
}

private final class CameraBackend {
    struct Bundle {
        let center: AVSampleBufferDisplayLayer
        let liveSource: LiveCameraFrameSource
        let periphery: AVSampleBufferDisplayLayer?
        let geometry: CameraController.CameraGeometry
        let outputOptions: [CameraController.OutputOption]
        let physicalCameraID: String
        let centerPreviewDimensions: CGSize
        let peripheralPreviewDimensions: CGSize?
        let centerPreviewEncoding: String
        let peripheralPreviewEncoding: String?
        let usesCaptureHandoff: Bool
    }
    struct CaptureOutcome {
        let result: Result<CapturedProRAW, Error>
        let bundle: Bundle?
        let previewReady: Bool
        let message: String?
    }
    private enum Phase { case stopped, configuring, preview, preparingPhoto, capturing, restoringPreview, failed }
    private struct PreviewConfiguration {
        let mode: CameraController.Mode
        let centerPreviewLongEdge: Int
        let peripheralPreviewLongEdge: Int
        var usesCaptureHandoff: Bool { mode.peripheralType != nil }
    }
    private struct PhotoCapability {
        let physicalCameraID: String
        let dimensions: CMVideoDimensions
        let horizontalFieldOfView: Float
        let zoom: CGFloat
    }
    private final class CaptureRequest {
        let id = UUID()
        let configuration: PreviewConfiguration
        let capability: PhotoCapability
        let orientation: UIInterfaceOrientation
        let lifetime: CameraLifetime
        let progress: (CameraController.CapturePhase, String) -> Void
        var completion: ((CaptureOutcome) -> Void)?
        var result: Result<CapturedProRAW, Error>?
        init(configuration: PreviewConfiguration, capability: PhotoCapability, orientation: UIInterfaceOrientation,
             lifetime: CameraLifetime, progress: @escaping (CameraController.CapturePhase, String) -> Void,
             completion: @escaping (CaptureOutcome) -> Void) {
            self.configuration = configuration; self.capability = capability; self.orientation = orientation
            self.lifetime = lifetime; self.progress = progress; self.completion = completion
        }
    }
    let queue = DispatchQueue(label: "dev.glasscam.camera", qos: .userInitiated)
    private var phase: Phase = .stopped
    private var lifetime: CameraLifetime?
    private var configuration: PreviewConfiguration?
    private var capability: PhotoCapability?
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var devices: [AVCaptureDevice] = []
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var captureDelegate: ProRAWCapture?
    private var currentRequest: CaptureRequest?
    private var failureHandler: ((String) -> Void)?
    private var failed = false
    private var previewOutputs: [AVCaptureVideoDataOutput] = []
    private var frameDeliveries: [CameraFrameDelivery] = []
    private var frozenDeliveries: [CameraFrameDelivery] = []
    private var previewSizes: [CMVideoDimensions] = []
    private var previewPixelFormats: [OSType] = []
    private var previewReadiness = DispatchGroup()

    func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int, peripheralPreviewLongEdge: Int,
                   orientation: UIInterfaceOrientation, lifetime: CameraLifetime,
                   failure: @escaping (String) -> Void) throws -> Bundle {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        self.lifetime = lifetime; try lifetime.check()
        failed = false; phase = .configuring; failureHandler = failure
        let plan = PreviewConfiguration(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge,
                                        peripheralPreviewLongEdge: peripheralPreviewLongEdge)
        configuration = plan
        // Probe a real ordinary .photo graph independently. A MultiCam active
        // format, ProRAW flag, or 12MP ceiling is never used as source capability.
        let photo = try buildSinglePhotoGraph(configuration: plan, orientation: orientation,
                                             expected: nil, includePreview: !plan.usesCaptureHandoff)
        capability = photo; dimensions = photo.dimensions
        if plan.usesCaptureHandoff {
            tearDownGraph(preservingPreview: false)
            try lifetime.check()
            try buildMultiPreview(configuration: plan, capability: photo, orientation: orientation)
        }
        try waitForPreviewFrames()
        phase = .preview
        return try previewBundle()
    }

    private func discover(_ type: AVCaptureDevice.DeviceType) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: .back)
        guard let device = discovery.devices.first else { throw CameraFailure("The requested physical camera is unavailable.") }
        return device
    }
    /// Creates only an ordinary .photo session. The previous graph must already
    /// have stopped and released all inputs/outputs; two sessions never own a lens.
    @discardableResult
    private func buildSinglePhotoGraph(configuration plan: PreviewConfiguration, orientation value: UIInterfaceOrientation,
                                       expected: PhotoCapability?, includePreview: Bool) throws -> PhotoCapability {
        try checkLifetime()
        guard session == nil else { throw CameraFailure("A camera graph still owns the device.") }
        let center = try discover(plan.mode.centerType)
        if let expected, center.uniqueID != expected.physicalCameraID { throw CameraFailure("The physical photo camera changed. Capture was cancelled.") }
        let newSession = AVCaptureSession()
        session = newSession; devices = [center]
        newSession.beginConfiguration()
        var committed = false
        defer { if !committed { newSession.commitConfiguration() } }
        guard newSession.canSetSessionPreset(.photo) else { throw CameraFailure("The photo preset is unavailable.") }
        newSession.sessionPreset = .photo
        let port = try addInput(center, to: newSession)
        // Do not set activeFormat here: it would switch the ordinary session to
        // inputPriority and invalidate Apple's high-resolution .photo requirement.
        try center.lockForConfiguration()
        center.videoZoomFactor = expected?.zoom ?? 1
        center.unlockForConfiguration()
        let output = AVCapturePhotoOutput()
        guard newSession.canAddOutput(output) else { throw CameraFailure("Single-camera photo capture is unavailable.") }
        newSession.addOutputWithNoConnections(output)
        let photoConnection = AVCaptureConnection(inputPorts: [port], output: output)
        guard newSession.canAddConnection(photoConnection) else { throw CameraFailure("Cannot connect the physical camera to photo capture.") }
        newSession.addConnection(photoConnection)
        guard photoConnection.isVideoOrientationSupported else { throw CameraFailure("Photo orientation control is unavailable.") }
        photoOutput = output
        output.maxPhotoQualityPrioritization = .quality
        guard output.isAppleProRAWSupported else { throw CameraFailure("Apple ProRAW is unavailable on this physical camera in a single-camera photo session.") }
        output.isAppleProRAWEnabled = true
        if output.isContentAwareDistortionCorrectionSupported { output.isContentAwareDistortionCorrectionEnabled = false }
        let finalFormat = center.activeFormat
        let photo = try photoCapability(center)
        if let expected { try validate(photo, matches: expected) }
        dimensions = photo.dimensions
        output.maxPhotoDimensions = dimensions
        guard output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) else {
            throw CameraFailure("The single-camera photo graph exposes no Apple ProRAW pixel format.")
        }
        if includePreview { try addPreview(port: port, device: center, cap: plan.centerPreviewLongEdge, to: newSession) }
        applyOrientation(value, configurationOpen: true)
        newSession.commitConfiguration(); committed = true
        try checkLifetime()
        installObservers(newSession)
        newSession.startRunning()
        try validateRunningGraph()
        guard newSession.sessionPreset == .photo, center.activeFormat === finalFormat,
              output.isAppleProRAWSupported, output.isAppleProRAWEnabled else {
            throw CameraFailure("Starting the photo graph changed its source configuration. No lower-resolution capture was substituted.")
        }
        try validate(try photoCapability(center), matches: photo)
        return photo
    }
    private func photoCapability(_ center: AVCaptureDevice) throws -> PhotoCapability {
        let format = center.activeFormat
        guard format.videoFieldOfView.isFinite, format.videoFieldOfView > 0, format.videoFieldOfView < 180 else {
            throw CameraFailure("The physical camera did not report a usable photo field of view.")
        }
        guard let largest = nativePhotoDimensions(format: format).max(by: { Self.area($0) < Self.area($1) }) else {
            throw CameraFailure("The photo format has no full-framing 12MP or 48MP ProRAW source dimensions.")
        }
        let sourceCeiling = center.formats.flatMap { nativePhotoDimensions(format: $0) }.map(Self.area).max() ?? 0
        guard Self.area(largest) == sourceCeiling else {
            throw CameraFailure("The photo preset did not expose this lens's largest native source. Capture resolution was not lowered.")
        }
        return PhotoCapability(physicalCameraID: center.uniqueID, dimensions: largest,
                               horizontalFieldOfView: format.videoFieldOfView, zoom: center.videoZoomFactor)
    }
    private func validate(_ actual: PhotoCapability, matches expected: PhotoCapability) throws {
        guard actual.physicalCameraID == expected.physicalCameraID,
              actual.dimensions.width == expected.dimensions.width, actual.dimensions.height == expected.dimensions.height,
              abs(actual.horizontalFieldOfView - expected.horizontalFieldOfView) < 0.1,
              abs(actual.zoom - expected.zoom) < 0.0001 else {
            throw CameraFailure("The single-camera photo graph changed the lens, zoom, framing, or native resolution. No substitute photo was captured.")
        }
    }
    private func buildMultiPreview(configuration plan: PreviewConfiguration, capability photo: PhotoCapability,
                                   orientation value: UIInterfaceOrientation) throws {
        try checkLifetime()
        guard session == nil, let type = plan.mode.peripheralType else { throw CameraFailure("Invalid preview handoff state.") }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [plan.mode.centerType, type], mediaType: .video, position: .back)
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let center = discovery.devices.first(where: { $0.uniqueID == photo.physicalCameraID }),
              let peripheral = discovery.devices.first(where: { $0.deviceType == type }),
              discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(center) && $0.contains(peripheral) }) else {
            throw CameraFailure("This physical camera pair does not support simultaneous preview. No substitute lens was used.")
        }
        let newSession = AVCaptureMultiCamSession()
        session = newSession; devices = [center, peripheral]; dimensions = photo.dimensions
        newSession.beginConfiguration()
        var committed = false
        defer { if !committed { newSession.commitConfiguration() } }
        // MultiCam is inputPriority and VIDEO ONLY. It has no ProRAW requirement.
        for (index, device) in devices.enumerated() {
            let cap = index == 0 ? plan.centerPreviewLongEdge : plan.peripheralPreviewLongEdge
            let format = try selectPreviewFormat(device: device, matching: index == 0 ? photo : nil, previewLongEdge: cap)
            try device.lockForConfiguration()
            device.activeFormat = format; device.videoZoomFactor = index == 0 ? photo.zoom : 1
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            let port = try addInput(device, to: newSession)
            try addPreview(port: port, device: device, cap: cap, to: newSession)
        }
        applyOrientation(value, configurationOpen: true)
        newSession.commitConfiguration(); committed = true
        guard newSession.hardwareCost <= 1, newSession.systemPressureCost <= 1 else {
            throw CameraFailure("This preview pair exceeds the device capture budget. Choose another lens or preview limit.")
        }
        try checkLifetime()
        installObservers(newSession); newSession.startRunning()
        try validateRunningGraph()
        try validatePreviewFraming(photo)
    }
    private func validatePreviewFraming(_ photo: PhotoCapability) throws {
        guard let center = devices.first else { throw CameraFailure("The physical preview camera is unavailable.") }
        let video = CMVideoFormatDescriptionGetDimensions(center.activeFormat.formatDescription)
        guard center.uniqueID == photo.physicalCameraID,
              abs(center.videoZoomFactor - photo.zoom) < 0.0001,
              abs(center.activeFormat.videoFieldOfView - photo.horizontalFieldOfView) < 0.1,
              Self.sameAspect(video, photo.dimensions) else {
            throw CameraFailure("The preview cannot preserve the single-camera photo lens, zoom, and field of view.")
        }
    }
    private func selectPreviewFormat(device: AVCaptureDevice, matching photo: PhotoCapability?, previewLongEdge: Int) throws -> AVCaptureDevice.Format {
        guard (640...4096).contains(previewLongEdge) else { throw CameraFailure("Preview raster limit must be between 640 and 4096 pixels.") }
        let candidates = device.formats.filter { format in
            guard format.isMultiCamSupported,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return false }
            let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard video.width > 0, video.height > 0 else { return false }
            if let photo {
                return Self.sameAspect(video, photo.dimensions) && abs(format.videoFieldOfView - photo.horizontalFieldOfView) < 0.1
            }
            // A genuine wider full-aspect video format; never require RAW support.
            return format.supportedMaxPhotoDimensions.contains { Self.sameAspect(video, $0) }
        }
        guard let chosen = candidates.min(by: {
            Self.area(CMVideoFormatDescriptionGetDimensions($0.formatDescription)) < Self.area(CMVideoFormatDescriptionGetDimensions($1.formatDescription))
        }) else { throw CameraFailure("No 30 fps MultiCam preview format preserves this lens's photo framing.") }
        return chosen
    }
    private func nativePhotoDimensions(format: AVCaptureDevice.Format) -> [CMVideoDimensions] {
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return format.supportedMaxPhotoDimensions.filter { photo in
            guard Self.sameAspect(video, photo) else { return false }
            // Native 24MP deferred processed delivery is not a ProRAW source.
            let nominal = Self.nominalMegapixels(Self.area(photo))
            return nominal == 12 || nominal == 48
        }
    }
    private static func sameAspect(_ a: CMVideoDimensions, _ b: CMVideoDimensions) -> Bool {
        a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 &&
        abs(Double(a.width) / Double(a.height) - Double(b.width) / Double(b.height)) < 0.001
    }
    private func addInput(_ device: AVCaptureDevice, to session: AVCaptureSession) throws -> AVCaptureInput.Port {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraFailure("Cannot add the requested physical camera input.") }
        session.addInputWithNoConnections(input)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw CameraFailure("Camera video port is unavailable.") }
        return port
    }
    private func addPreview(port: AVCaptureInput.Port, device: AVCaptureDevice, cap: Int, to session: AVCaptureSession) throws {
        let video = AVCaptureVideoDataOutput()
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false; video.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(video) else { throw CameraFailure("Cannot add the independent scaled live-preview output.") }
        session.addOutputWithNoConnections(video)
        let connection = AVCaptureConnection(inputPorts: [port], output: video)
        guard session.canAddConnection(connection) else { throw CameraFailure("A physical-lens video preview connection is unavailable.") }
        session.addConnection(connection)
        guard connection.isVideoOrientationSupported else { throw CameraFailure("This preview cannot match photo orientation.") }
        let supported = video.availableVideoPixelFormatTypes
        guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].first(where: { supported.contains($0) }) else {
            throw CameraFailure("The preview exposes no supported 8-bit YCbCr format.")
        }
        let size = try Self.scaledPreviewDimensions(source: CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription), cap: cap)
        let delivery = CameraFrameDelivery.makeOnMainThread()
        video.setSampleBufferDelegate(delivery, queue: delivery.callbackQueue)
        previewOutputs.append(video); frameDeliveries.append(delivery)
        previewSizes.append(size); previewPixelFormats.append(pixelFormat)
    }
    private static func nominalMegapixels(_ pixels: Int64) -> Int? {
        [12, 24, 48].first { abs(Double(pixels) / (Double($0) * 1_000_000) - 1) <= 0.08 }
    }
    private static func outputOptions(source: CMVideoDimensions) -> [CameraController.OutputOption] {
        let pixels = area(source)
        guard let sourceTier = nominalMegapixels(pixels) else { return [] }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let width = Int(source.width), height = Int(source.height)
        let divisor = gcd(width, height), unitWidth = width / divisor, unitHeight = height / divisor
        return [12, 24, 48].filter { $0 <= sourceTier }.map { tier in
            // Preserve native dimensions for its own nominal tier. Smaller exports
            // use integer aspect-ratio units, never crop, stretch, or upscale.
            let units = tier == sourceTier ? divisor : min(divisor, Int(sqrt(Double(tier) * 1_000_000 / Double(unitWidth * unitHeight))))
            return .init(megapixels: tier, width: unitWidth * units, height: unitHeight * units)
        }
    }
    private static func size(_ dimensions: CMVideoDimensions) -> CGSize {
        CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }
    private static func area(_ size: CMVideoDimensions) -> Int64 { Int64(size.width) * Int64(size.height) }

    func rotatePreview(_ value: UIInterfaceOrientation) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil else { throw CameraFailure("Camera orientation is locked during capture.") }
        do {
            try checkLifetime()
            applyOrientation(value)
            try waitForPreviewFrames()
        } catch {
            failSession(error.localizedDescription, stopRunning: true)
            throw error
        }
    }
    private func applyOrientation(_ value: UIInterfaceOrientation, configurationOpen: Bool = false) {
        switch value {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return
        }
        interfaceOrientation = value
        guard let session else { return }
        if !configurationOpen { session.beginConfiguration() }
        defer { if !configurationOpen { session.commitConfiguration() } }
        for (index, video) in previewOutputs.enumerated() {
            video.connection(with: .video)?.isEnabled = false
            video.setSampleBufferDelegate(nil, queue: nil)
            frameDeliveries[index].callbackQueue.sync {}
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelFormats[index]]
        }
        for connection in session.connections {
            if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            connection.videoScaleAndCropFactor = 1
        }
        previewReadiness = DispatchGroup()
        for (index, video) in previewOutputs.enumerated() {
            let size = previewSizes[index]
            let portrait = orientation == .portrait || orientation == .portraitUpsideDown
            let width = Int(portrait ? size.height : size.width), height = Int(portrait ? size.width : size.height)
            let readiness = previewReadiness
            readiness.enter()
            frameDeliveries[index].expect(width: width, height: height, pixelFormat: previewPixelFormats[index]) { readiness.leave() }
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelFormats[index],
                                   kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
            video.setSampleBufferDelegate(frameDeliveries[index], queue: frameDeliveries[index].callbackQueue)
            video.connection(with: .video)?.isEnabled = true
        }
    }
    private func checkLifetime() throws {
        guard let lifetime else { throw CameraFailure("Camera stopped.") }
        try lifetime.check()
    }
    private func validateRunningGraph() throws {
        try checkLifetime()
        guard let session, session.isRunning, !session.isInterrupted, !failed else { throw CameraFailure("The camera session is stopped or interrupted.") }
        for device in devices {
            let level = device.systemPressureState.level
            if level == .serious || level == .critical || level == .shutdown {
                throw CameraFailure("Camera unavailable due to system pressure. Let the device cool, then retry. Capture quality was not reduced.")
            }
        }
    }
    /// First-frame readiness means a matching frame was actually enqueued on
    /// each main-thread display layer. Cancellation is checked while waiting.
    private func waitForPreviewFrames() throws {
        let deadline = DispatchTime.now() + 5
        while previewReadiness.wait(timeout: .now() + 0.05) != .success {
            try validateRunningGraph()
            if DispatchTime.now() >= deadline {
                throw CameraFailure("A physical camera preview did not deliver its negotiated frame within 5 seconds. Select the lens again to retry.")
            }
        }
        try validateRunningGraph()
    }
    private static func previewEncoding(_ format: OSType) -> String {
        // Published only after the first frame matches the requested OSType.
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "8-bit YCbCr420 (420f)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "8-bit YCbCr420 (420v)"
        default: return String(format: "Pixel format 0x%08X", format)
        }
    }

    private static func scaledPreviewDimensions(source: CMVideoDimensions, cap: Int) throws -> CMVideoDimensions {
        guard source.width > 0, source.height > 0, (640...4096).contains(cap) else {
            throw CameraFailure("Invalid source dimensions or preview long-edge limit.")
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let width = Int(source.width), height = Int(source.height)
        let divisor = gcd(width, height), unitWidth = width / divisor, unitHeight = height / divisor
        var units = min(divisor, cap / max(unitWidth, unitHeight))
        // YCbCr420 needs even dimensions. Preserve the exact native aspect ratio.
        if (unitWidth * units) % 2 != 0 || (unitHeight * units) % 2 != 0 { units -= 1 }
        guard units > 0 else { throw CameraFailure("The requested preview cannot preserve the source aspect ratio.") }
        return CMVideoDimensions(width: Int32(unitWidth * units), height: Int32(unitHeight * units))
    }
    func geometry() -> CameraController.CameraGeometry? {
        guard dimensions.width > 0, dimensions.height > 0, let center = devices.first else { return nil }
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let size = Self.size(dimensions)
        return .init(sensorPhotoDimensions: size, photoAspectRatio: portrait ? size.height / size.width : size.width / size.height,
                     centerHorizontalFieldOfView: center.activeFormat.videoFieldOfView,
                     peripheralHorizontalFieldOfView: devices.count > 1 ? devices[1].activeFormat.videoFieldOfView : nil)
    }
    private func previewBundle() throws -> Bundle {
        guard let photo = capability, let configuration, let geometry = geometry(),
              !frameDeliveries.isEmpty, previewSizes.count == frameDeliveries.count else {
            throw CameraFailure("The preview graph is incomplete.")
        }
        return Bundle(center: frameDeliveries[0].layer, liveSource: frameDeliveries[0].liveSource,
                      periphery: frameDeliveries.count > 1 ? frameDeliveries[1].layer : nil, geometry: geometry,
                      outputOptions: Self.outputOptions(source: photo.dimensions), physicalCameraID: photo.physicalCameraID,
                      centerPreviewDimensions: Self.size(previewSizes[0]),
                      peripheralPreviewDimensions: previewSizes.count > 1 ? Self.size(previewSizes[1]) : nil,
                      centerPreviewEncoding: Self.previewEncoding(previewPixelFormats[0]),
                      peripheralPreviewEncoding: previewPixelFormats.count > 1 ? Self.previewEncoding(previewPixelFormats[1]) : nil,
                      usesCaptureHandoff: configuration.usesCaptureHandoff)
    }
    func capture(progress: @escaping (CameraController.CapturePhase, String) -> Void,
                 completion: @escaping (CaptureOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil, let configuration, let capability, let lifetime else {
            completion(CaptureOutcome(result: .failure(CameraFailure("Apple ProRAW capture is currently unavailable.")), bundle: nil,
                                      previewReady: false, message: "Camera is unavailable. Retry the camera.")); return
        }
        let request = CaptureRequest(configuration: configuration, capability: capability,
                                     orientation: interfaceOrientation, lifetime: lifetime, progress: progress, completion: completion)
        currentRequest = request; phase = .preparingPhoto
        do {
            try validateRunningGraph()
            if configuration.usesCaptureHandoff {
                try validatePreviewFraming(capability)
                // Freeze displayed pixels first, then stop and release the entire
                // MultiCam graph before constructing an ordinary .photo graph.
                frameDeliveries.forEach { $0.freeze() }
                tearDownGraph(preservingPreview: true)
                try request.lifetime.check()
                try buildSinglePhotoGraph(configuration: configuration, orientation: request.orientation,
                                          expected: capability, includePreview: false)
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
                  let session, !(session is AVCaptureMultiCamSession), session.sessionPreset == .photo,
                  output.isAppleProRAWSupported, output.isAppleProRAWEnabled else {
                throw CameraFailure("The ordinary photo session cannot capture Apple ProRAW.")
            }
            try validate(try photoCapability(center), matches: request.capability)
            guard interfaceOrientation == request.orientation,
                  output.connection(with: .video)?.videoOrientation == orientation else {
                throw CameraFailure("Photo orientation changed during the shutter handoff.")
            }
            if output.captureReadiness == .ready {
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
        settings.maxPhotoDimensions = request.capability.dimensions
        settings.photoQualityPrioritization = .quality
        settings.isAutoStillImageStabilizationEnabled = false
        settings.isAutoContentAwareDistortionCorrectionEnabled = false
        let delegate = ProRAWCapture(expectedDimensions: request.capability.dimensions) { [weak self, weak request] result in
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
    private func finishPhoto(_ result: Result<CapturedProRAW, Error>, request: CaptureRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentRequest === request, request.completion != nil else { return }
        request.result = result; captureDelegate = nil
        var bundle: Bundle?
        var previewReady = false
        var previewError: String?
        if !request.lifetime.isCancelled && !failed && phase != .stopped {
            do {
                if request.configuration.usesCaptureHandoff {
                    phase = .restoringPreview
                    request.progress(.restoring, "Restoring wider live preview…")
                    tearDownGraph(preservingPreview: true)
                    try request.lifetime.check()
                    try buildMultiPreview(configuration: request.configuration, capability: request.capability,
                                          orientation: request.orientation)
                    try waitForPreviewFrames()
                    bundle = try previewBundle()
                } else {
                    try validateRunningGraph()
                }
                try request.lifetime.check()
                phase = .preview; previewReady = true
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
    private func finishRequest(_ request: CaptureRequest, result: Result<CapturedProRAW, Error>, bundle: Bundle?,
                               previewReady: Bool, message: String?) {
        guard currentRequest === request, let callback = request.completion else { return }
        request.completion = nil; currentRequest = nil; captureDelegate = nil
        callback(CaptureOutcome(result: result, bundle: bundle, previewReady: previewReady, message: message))
    }
    private func failSession(_ message: String, stopRunning: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        failed = true; phase = .failed
        frameDeliveries.forEach { $0.freeze() }
        if stopRunning { session?.stopRunning() }
        failureHandler?(message)
        if let request = currentRequest {
            let result = request.result ?? captureDelegate?.cancel(reason: message) ?? .failure(CameraFailure(message))
            // Preserve only a successfully committed terminal photo result, even
            // if its queued callback or preview restoration has not run yet.
            finishPhoto(result, request: request)
        }
    }
    private func installObservers(_ observed: AVCaptureSession) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            notifications.append(center.addObserver(forName: name, object: observed, queue: nil) { [weak self, weak observed] notification in
                let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed else { return }
                    if name == AVCaptureSession.interruptionEndedNotification {
                        self.failureHandler?("Camera interruption ended. Select the lens again to revalidate Apple ProRAW.")
                    } else {
                        self.failSession(detail ?? "Camera interrupted. Select the lens again when available.", stopRunning: true)
                    }
                }
            })
        }
        observations = devices.map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self, weak observed] device, _ in
                let level = device.systemPressureState.level
                self?.queue.async { [weak self, weak observed] in
                    guard let self, let observed, self.session === observed else { return }
                    if level == .serious || level == .critical || level == .shutdown {
                        self.failSession("Camera stopped due to system pressure. Let the device cool, then select the lens again. Capture quality was not reduced.", stopRunning: true)
                    }
                }
            }
        }
    }
    /// Owns graph disposal only, never a request completion. Stop and remove every
    /// input/output before another graph can acquire the same physical device.
    private func tearDownGraph(preservingPreview: Bool) {
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
        let result = request?.result ?? captureDelegate?.cancel() ?? .failure(CameraFailure("Camera capture cancelled."))
        tearDownGraph(preservingPreview: false)
        frozenDeliveries.forEach { $0.invalidate() }; frozenDeliveries.removeAll()
        if let request { finishRequest(request, result: result, bundle: nil, previewReady: false, message: "Camera stopped.") }
        captureDelegate = nil; configuration = nil; capability = nil; lifetime = nil
        dimensions = CMVideoDimensions(width: 0, height: 0); failureHandler = nil
    }
}

/// Exactly one committed DNG per request. Processing bytes are provisional until
/// didFinishCaptureFor succeeds. A stop preserves that terminal result, including
/// when its backend-queue callback has not run yet; late callbacks cannot restore.
private final class ProRAWCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let lock = NSLock()
    private var completion: ((Result<CapturedProRAW, Error>) -> Void)?
    private var result: Result<CapturedProRAW, Error>?
    private var terminalResult: Result<CapturedProRAW, Error>?
    private let expectedDimensions: CMVideoDimensions
    init(expectedDimensions: CMVideoDimensions, completion: @escaping (Result<CapturedProRAW, Error>) -> Void) {
        self.expectedDimensions = expectedDimensions; self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard completion != nil else { return }
        if let error { result = .failure(error); return }
        guard photo.isRawPhoto, let buffer = photo.pixelBuffer,
              AVCapturePhotoOutput.isAppleProRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer)),
              let data = photo.fileDataRepresentation(), !data.isEmpty else {
            result = .failure(CameraFailure("The camera did not return an Apple ProRAW DNG.")); return
        }
        let actual = photo.resolvedSettings.rawPhotoDimensions
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        guard min(actual.width, actual.height) == min(expectedDimensions.width, expectedDimensions.height),
              max(actual.width, actual.height) == max(expectedDimensions.width, expectedDimensions.height),
              min(bufferWidth, bufferHeight) == Int(min(actual.width, actual.height)),
              max(bufferWidth, bufferHeight) == Int(max(actual.width, actual.height)) else {
            result = .failure(CameraFailure("The camera delivered different RAW dimensions from the requested full-quality framing. This capture was rejected; no lower-resolution photo was substituted.")); return
        }
        result = .success(CapturedProRAW(data: data, dimensions: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height))))
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        let finalResult: Result<CapturedProRAW, Error> = error.map { .failure($0) } ?? result ?? .failure(CameraFailure("No Apple ProRAW photo was delivered."))
        let callback = completion; completion = nil; terminalResult = finalResult; result = nil
        lock.unlock()
        callback?(finalResult)
    }
    @discardableResult
    func cancel(reason: String = "Camera capture cancelled.") -> Result<CapturedProRAW, Error> {
        lock.lock()
        let value: Result<CapturedProRAW, Error>
        if let terminalResult { value = terminalResult }
        else { value = .failure(CameraFailure(reason)) }
        let callback = completion; completion = nil; result = nil
        lock.unlock()
        callback?(value)
        return value
    }
}
