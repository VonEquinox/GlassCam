import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

/// App-selected physical cameras with an independently uncropped wider preview.
/// Photos always use an independent ordinary .photo transaction.
/// Public methods and published state belong to main.
/// AVFoundation graph ownership belongs exclusively to CameraBackend.queue.
final class CameraController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case main
        var id: Self { self }
        var title: String {
            "Automatic camera"
        }
        fileprivate var centerType: AVCaptureDevice.DeviceType {
            .builtInTripleCamera
        }
    }
    /// HEIF target. Capture priority selects the RAW source size independently.
    struct OutputOption: Identifiable, Equatable {
        let megapixels: Int
        let width: Int
        let height: Int
        var id: String { "\(megapixels)-\(width)x\(height)" }
        static func matching(_ megapixels: Int, in options: [Self]) -> Self? {
            options.first { $0.megapixels == megapixels }
        }
    }
    struct CameraGeometry {
        let sensorPhotoDimensions: CGSize
        let photoAspectRatio: CGFloat
    }
    enum CapturePhase: String { case idle, preparing, capturing, restoring }
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isPreviewFrozen = false
    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var actualCapturedDimensions: CGSize?
    @Published private(set) var peripheralSource: PeripheralFrameSource?
    @Published private(set) var centerLiveSource: LiveCameraFrameSource?
    @Published private(set) var centerPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var geometry: CameraGeometry?
    @Published private(set) var supportedOutputOptions: [OutputOption] = []
    @Published private(set) var sourceCaptureDimensions: CGSize?
    @Published private(set) var physicalCameraID: String?
    @Published private(set) var centerPreviewDimensions: CGSize?
    @Published private(set) var centerPreviewEncoding: String?
    @Published private(set) var isConfiguring = false
    @Published private(set) var zoomRange: CameraZoomRange = .main
    @Published private(set) var requestedZoom = 1.0
    @Published private(set) var appliedZoom = 1.0
    @Published private(set) var currentFraming = CaptureFraming()
    @Published private(set) var isUpdatingZoom = false
    @Published private(set) var f5ProfileAvailable = false
    @Published private(set) var f5SampleDirectory: URL?
    private var captureReservation: UUID?
    private let backend: any CameraBackendServing
    private let cameraAccess: CameraAccess
    private var generation = UUID()
    private var lifetime = CameraLifetime()
    private var orientation: UIInterfaceOrientation = .portrait
    private var appliedOrientation: UIInterfaceOrientation = .unknown
    private var orientationRevision: UInt64 = 0
    private var isApplyingOrientation = false
    private var requestedPreviewLongEdge = 1920

    init(backend: any CameraBackendServing = CameraBackend(), cameraAccess: CameraAccess = .system) {
        self.backend = backend; self.cameraAccess = cameraAccess
    }

    func start(mode: Mode = .main, centerPreviewLongEdge: Int = 1920) {
        dispatchPrecondition(condition: .onQueue(.main))
        requestedPreviewLongEdge = centerPreviewLongEdge
        guard !isConfiguring, !isCapturing else { return }
        lifetime.cancel(); lifetime = CameraLifetime()
        let token = UUID(); generation = token
        isUpdatingZoom = false; captureReservation = nil
        isConfiguring = true; isReady = false; isPreviewFrozen = false; capturePhase = .idle
        status = "Checking camera access…"; appliedOrientation = .unknown; isApplyingOrientation = false
        clearPreview()
        switch cameraAccess.status() {
        case .authorized:
            configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, token: token)
        case .notDetermined:
            cameraAccess.request { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if allowed { self.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, token: token) }
                    else { self.isConfiguring = false; self.status = "Camera permission denied. Enable camera access in Settings." }
                }
            }
        default:
            isConfiguring = false; status = "Camera permission denied. Enable camera access in Settings."
        }
    }
    private func configure(mode: Mode, centerPreviewLongEdge: Int, token: UUID) {
        let initialOrientation = orientation
        let lifetime = lifetime
        status = "Checking camera ProRAW capability…"
        let requestedZoom = requestedZoom
        backend.queue.async { [weak self, backend] in
            do {
                let bundle = try backend.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge,
                                                   orientation: initialOrientation, lifetime: lifetime,
                                                   displayedZoom: requestedZoom, stateChanged: { bundle in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.install(bundle)
                        if !self.isCapturing && !self.isConfiguring && !self.isUpdatingZoom &&
                            !self.isApplyingOrientation && self.captureReservation == nil {
                            self.isReady = true; self.status = self.readyStatus
                        }
                    }
                }) { message in
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
                    if self.requestedPreviewLongEdge != centerPreviewLongEdge {
                        self.start(centerPreviewLongEdge: self.requestedPreviewLongEdge); return
                    }
                    self.updateOrientation(self.orientation)
                    self.applyPendingZoom()
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
        "Apple ProRAW · \(currentFraming.lensName ?? "Automatic camera")"
    }
    private func install(_ bundle: CameraBackend.Bundle) {
        centerPreviewLayer = bundle.center; centerLiveSource = bundle.liveSource
        peripheralSource = bundle.peripheralSource
        geometry = bundle.geometry
        supportedOutputOptions = bundle.outputOptions
        sourceCaptureDimensions = bundle.sourceCaptureDimensions
        physicalCameraID = bundle.physicalCameraID
        centerPreviewDimensions = bundle.centerPreviewDimensions
        centerPreviewEncoding = bundle.centerPreviewEncoding
        zoomRange = bundle.zoomRange
        appliedZoom = bundle.framing.displayZoom
        currentFraming = bundle.framing
        requestedZoom = zoomRange.clamped(requestedZoom)
        refreshF5ProfileStatus()
    }
    func refreshF5ProfileStatus() {
        guard let id = physicalCameraID else { f5ProfileAvailable = false; return }
        let hashed = F5Hash.data(Data(id.utf8))
        let main = currentFraming.lensName == "Main"
        f5ProfileAvailable = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = main && !F5ProfileStore.candidates(hardware: F5DeviceFacts.hardware, os: F5DeviceFacts.osBuild, physicalCameraID: hashed).isEmpty
            DispatchQueue.main.async { [weak self] in
                guard let self, self.physicalCameraID == id else { return }
                self.f5ProfileAvailable = available
            }
        }
    }
    func selectF5MainCamera() {
        if let main = zoomRange.stops.first(where: { $0.title == "Main" }) { requestedZoom = main.factor; applyPendingZoom() }
    }
    func recordF5Sample() {
        guard !isCapturing else { return }
        selectF5MainCamera()
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<160 {
                guard self.generation == token, !self.lifetime.isCancelled else { return }
                if self.canReserveCapture { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard self.generation == token, let reservation = self.reserveCapture() else { return }
            self.capturePhoto(reservation: reservation, quality: .f5, f5Purpose: "probe") { [weak self] result in
                guard let self, self.generation == token else { return }
                if case .success(let photo) = result { self.f5SampleDirectory = (photo.burst as? F5BurstSource)?.directory; self.status = "Five RAW samples recorded. Main-camera calibration is still required." }
                else if case .failure(let error) = result { self.status = error.localizedDescription }
            }
        }
    }
    private func clearPreview() {
        centerPreviewLayer = nil; geometry = nil; peripheralSource = nil
        centerLiveSource?.setEnabled(false); centerLiveSource = nil
        supportedOutputOptions = []; sourceCaptureDimensions = nil; physicalCameraID = nil
        f5ProfileAvailable = false
        centerPreviewDimensions = nil
        centerPreviewEncoding = nil
    }
    func updateOrientation(_ value: UIInterfaceOrientation) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard value != .unknown else { return }
        orientation = value
        // A shutter snapshot owns orientation until both the photo and restoration
        // finish. Keep the newest UI orientation, but never rotate its photo graph.
        guard !isConfiguring, !isCapturing, captureReservation == nil, !isUpdatingZoom,
              !isApplyingOrientation, value != appliedOrientation,
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
                    self.applyPendingZoom()
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
        isUpdatingZoom = false; captureReservation = nil
        isPreviewFrozen = false; capturePhase = .idle; appliedOrientation = .unknown; isApplyingOrientation = false
        clearPreview(); status = "Camera stopped"
        backend.queue.async { [backend] in backend.stop() }
    }
    /// Delivers only the validated Apple ProRAW DNG. Preview restore errors are
    /// reported through status/isReady and cannot replace a completed photo.
    func captureProRAW(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let reservation = reserveCapture() else {
            completion(.failure(CameraFailure("Wait for the camera to finish adjusting."))); return
        }
        capturePhoto(reservation: reservation) { completion($0.map(\.data)) }
    }

    var canReserveCapture: Bool {
        isReady && !isCapturing && !isConfiguring && !isUpdatingZoom &&
        !isApplyingOrientation && captureReservation == nil
    }

    /// Reserve the applied view before the Photos permission dialog can yield.
    func reserveCapture() -> UUID? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canReserveCapture else { return nil }
        let id = UUID(); captureReservation = id
        return id
    }

    func releaseCaptureReservation(_ id: UUID) {
        guard captureReservation == id, !isCapturing else { return }
        captureReservation = nil
        updateOrientation(orientation); applyPendingZoom()
    }

    func setZoom(_ factor: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard captureReservation == nil, !isCapturing, factor.isFinite else { return }
        requestedZoom = zoomRange.clamped(factor)
        if !isReady && !isConfiguring { start(centerPreviewLongEdge: requestedPreviewLongEdge) }
        else { applyPendingZoom() }
    }

    private func applyPendingZoom() {
        guard isReady, !isConfiguring, !isCapturing, captureReservation == nil,
              !isApplyingOrientation, !isUpdatingZoom, !lifetime.isCancelled,
              abs(requestedZoom - appliedZoom) > 0.0001 else { return }
        isUpdatingZoom = true
        let desired = requestedZoom, token = generation
        backend.queue.async { [weak self, backend] in
            do {
                let bundle = try backend.setZoom(desired)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    if abs(self.requestedZoom - desired) < 0.0001 { self.requestedZoom = bundle.framing.displayZoom }
                    self.install(bundle); self.isUpdatingZoom = false
                    self.updateOrientation(self.orientation); self.applyPendingZoom()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isUpdatingZoom = false; self.isReady = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func capturePhoto(reservation: UUID, quality: CaptureQuality = .quality, snapshot: CaptureSnapshot? = nil,
                      f5Purpose: String = "product",
                      completion: @escaping (Result<CapturedCameraPhoto, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard captureReservation == reservation, isReady, !isCapturing, !isConfiguring,
              !isUpdatingZoom, !isApplyingOrientation else {
            releaseCaptureReservation(reservation)
            completion(.failure(CameraFailure("Camera is unavailable or a capture is already in progress."))); return
        }
        isCapturing = true; isReady = false; isPreviewFrozen = false
        capturePhase = .preparing; actualCapturedDimensions = nil
        status = quality == .f5 ? "Preparing five Bayer RAW exposures…" : "Preparing full-resolution ProRAW…"
        let token = generation
        backend.queue.async { [weak self, backend] in
            backend.capture(quality: quality, snapshot: snapshot, f5Purpose: f5Purpose, progress: { phase, message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.capturePhase = phase; self.status = message
                }
            }) { outcome in
                DispatchQueue.main.async { [weak self] in
                    let photoResult = outcome.result.map { CapturedCameraPhoto(data: $0.data, framing: $0.framing, burst: $0.burst) }
                    // Stop/background can invalidate view state, never a completed DNG.
                    guard let self, self.generation == token else { completion(photoResult); return }
                    if let bundle = outcome.bundle { self.install(bundle) }
                    if case .success(let photo) = outcome.result { self.actualCapturedDimensions = photo.dimensions }
                    if f5Purpose == "probe", case .success(let photo) = outcome.result { self.f5SampleDirectory = photo.burst?.directory }
                    self.isCapturing = false; self.captureReservation = nil; self.capturePhase = .idle
                    self.isPreviewFrozen = false
                    self.isReady = outcome.previewReady
                    self.status = outcome.message ?? self.readyStatus
                    if outcome.previewReady { self.updateOrientation(self.orientation); self.applyPendingZoom() }
                    completion(photoResult)
                }
            }
        }
    }
    deinit { lifetime.cancel(); let engine = backend; engine.queue.async { engine.stop() } }
}

struct CameraFailure: LocalizedError {
    let message: String
    let allowsPhysicalFallback: Bool
    init(_ message: String, allowsPhysicalFallback: Bool = false) {
        self.message = message; self.allowsPhysicalFallback = allowsPhysicalFallback
    }
    var errorDescription: String? { message }
}

struct CameraAccess {
    var status: () -> AVAuthorizationStatus
    var request: (@escaping (Bool) -> Void) -> Void
    static let system = CameraAccess(status: { AVCaptureDevice.authorizationStatus(for: .video) },
                                     request: { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) })
}

protocol CameraBackendServing: AnyObject {
    var queue: DispatchQueue { get }
    func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int,
                   orientation: UIInterfaceOrientation, lifetime: CameraLifetime, displayedZoom: Double,
                   stateChanged: @escaping (CameraBackend.Bundle) -> Void,
                   failure: @escaping (String) -> Void) throws -> CameraBackend.Bundle
    func stop()
    func rotatePreview(_ value: UIInterfaceOrientation) throws
    func geometry() -> CameraController.CameraGeometry?
    func setZoom(_ displayedZoom: Double) throws -> CameraBackend.Bundle
    func capture(quality: CaptureQuality, snapshot: CaptureSnapshot?, f5Purpose: String,
                 progress: @escaping (CameraController.CapturePhase, String) -> Void,
                 completion: @escaping (CameraBackend.CaptureOutcome) -> Void)
}

/// Cross-queue cancellation only. All AVFoundation state stays on backend.queue.
final class CameraLifetime {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CameraFailure("Camera operation cancelled.") } }
}

struct CapturedProRAW {
    let data: Data
    let dimensions: CGSize
    let framing: CaptureFraming
    var burst: F5BurstSource? = nil
}

final class CameraBackend: CameraBackendServing {
    static let previewFrameRates: [Int32] = [60, 30, 15]
    private static let logger = Logger(subsystem: "dev.glasscam.prototype", category: "Camera")
    struct Bundle {
        let center: AVSampleBufferDisplayLayer
        let liveSource: LiveCameraFrameSource
        let peripheralSource: PeripheralFrameSource?
        let geometry: CameraController.CameraGeometry
        let sourceCaptureDimensions: CGSize
        let outputOptions: [CameraController.OutputOption]
        let physicalCameraID: String
        let centerPreviewDimensions: CGSize
        let centerPreviewEncoding: String
        let zoomRange: CameraZoomRange
        let framing: CaptureFraming
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
        var displayedZoom: Double
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
        var capability: PhotoCapability
        var restoresPreviewGraph = false
        let orientation: UIInterfaceOrientation
        let quality: CaptureQuality
        let lifetime: CameraLifetime
        let progress: (CameraController.CapturePhase, String) -> Void
        var completion: ((CaptureOutcome) -> Void)?
        var result: Result<CapturedProRAW, Error>?
        init(configuration: PreviewConfiguration, capability: PhotoCapability, orientation: UIInterfaceOrientation,
             lifetime: CameraLifetime, quality: CaptureQuality,
             progress: @escaping (CameraController.CapturePhase, String) -> Void,
             completion: @escaping (CaptureOutcome) -> Void) {
            self.configuration = configuration; self.capability = capability; self.orientation = orientation
            self.lifetime = lifetime; self.progress = progress; self.completion = completion
            self.quality = quality
        }
    }
    let queue = DispatchQueue(label: "dev.glasscam.camera", qos: .userInitiated)
    private var phase: Phase = .stopped
    private var lifetime: CameraLifetime?
    private var configuration: PreviewConfiguration?
    private var capability: PhotoCapability?
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var photoWarmupDeadline: DispatchTime?
    private var devices: [AVCaptureDevice] = []
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var captureDelegate: ProRAWCapture?
    private var f5Capture: F5CaptureDriver?
    private var currentRequest: CaptureRequest?
    private var failureHandler: ((String) -> Void)?
    private var failed = false
    private var recoveryBudget = CameraSessionRecovery.Budget()
    private var previewOutputs: [AVCaptureVideoDataOutput] = []
    private var frameDeliveries: [CameraFrameDelivery] = []
    private var frozenDeliveries: [CameraFrameDelivery] = []
    private var previewSizes: [CMVideoDimensions] = []
    private var previewPixelFormats: [OSType] = []
    private var previewReadiness = DispatchGroup()
    private var peripheralFrameSource: PeripheralFrameSource?
    private var previewSynchronizer: AVCaptureDataOutputSynchronizer?
    private var synchronizedDelivery: PeripheralFrameSynchronizer?
    private var previewPortDevices: [AVCaptureDevice] = []
    private var synchronizedPreviewDevice: AVCaptureDevice?
    private var nativePhotoHints: [String: CMVideoDimensions] = [:]
    private struct NativeLens {
        let device: AVCaptureDevice
        let rawZoom: Double
        let displayedZoom: Double
    }
    private var tripleCamera: AVCaptureDevice?
    private var lensCatalog: [NativeLens] = []
    private var stateChanged: ((Bundle) -> Void)?

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
        let plan = PreviewConfiguration(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, displayedZoom: displayedZoom)
        configuration = plan
        var photo = try buildSinglePhotoGraph(configuration: plan, orientation: orientation, expected: nil, includePreview: true)
        capability = photo; dimensions = photo.dimensions
        try waitForPreviewFrames()
        photo = try promotePreview(configuration: plan, orientation: orientation, photo: photo)
        capability = photo
        phase = .preview
        return try previewBundle()
    }

    /// Probe the selected physical camera in .photo first. Independent inputs
    /// keep the wider lens uncropped while the center follows the requested zoom.
    private func promotePreview(configuration plan: PreviewConfiguration, orientation value: UIInterfaceOrientation,
                                photo: PhotoCapability) throws -> PhotoCapability {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let center = devices.first, !center.isVirtualDevice,
              let centerLens = lensCatalog.first(where: { $0.device.uniqueID == center.uniqueID }) else { return photo }
        let outerChoices = lensCatalog.filter { $0.displayedZoom < centerLens.displayedZoom - 0.0001 }
            .sorted { $0.displayedZoom > $1.displayedZoom }
        guard !outerChoices.isEmpty else { return photo }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInUltraWideCamera,.builtInWideAngleCamera,.builtInTelephotoCamera],
            mediaType:.video,position:.back)
        let supportedSets = discovery.supportedMultiCamDeviceSets.map { Set($0.map(\.uniqueID)) }
        for lens in lensCatalog {
            nativePhotoHints[lens.device.uniqueID] = lens.device.formats.flatMap { nativePhotoDimensions(format: $0) }
                .max(by: { Self.area($0) < Self.area($1) })
        }
        for outerLens in outerChoices {
            let outer = outerLens.device
            let physicalPairSupported=supportedSets.contains(where: { $0.contains(center.uniqueID) && $0.contains(outer.uniqueID) })
            // Prefer hardware synchronization at the same frame rate; do not
            // choose 15 Hz constituent streams ahead of a working 60 Hz pair.
            for fps in Self.previewFrameRates {
                if abs(photo.zoom-1)<0.0001 {
                    do {
                        if try buildSynchronizedPreview(configuration:plan,orientation:value,photo:photo,center:center,outer:outer,fps:fps) {
                            try waitForPreviewFrames();try waitForPeripheralFrames()
                            return photo
                        }
                    } catch {
                        Self.logger.notice("Synchronized constituent preview unavailable: \(error.localizedDescription,privacy:.public)")
                        try checkLifetime()
                    }
                }
                guard physicalPairSupported else {continue}
                let centerFormats = independentPreviewFormats(center, aspect: photo.dimensions,
                    fieldOfView: photo.horizontalFieldOfView, cap: min(plan.centerPreviewLongEdge, 1920), fps: fps)
                let outerFormats = independentPreviewFormats(outer, aspect: photo.dimensions,
                    fieldOfView: nil, cap: min(plan.centerPreviewLongEdge, 1280), fps: fps)
                guard let firstCenter = centerFormats.first, let firstOuter = outerFormats.first else { continue }
                let smallCenter = centerFormats.min { Self.area(CMVideoFormatDescriptionGetDimensions($0.formatDescription)) < Self.area(CMVideoFormatDescriptionGetDimensions($1.formatDescription)) }!
                let smallOuter = outerFormats.min { Self.area(CMVideoFormatDescriptionGetDimensions($0.formatDescription)) < Self.area(CMVideoFormatDescriptionGetDimensions($1.formatDescription)) }!
                var candidates = [(firstCenter, firstOuter)]
                if smallCenter !== firstCenter || smallOuter !== firstOuter { candidates.append((smallCenter, smallOuter)) }
                for (centerFormat, outerFormat) in candidates {
                    tearDownGraph(preservingPreview: true)
                    do {
                        try buildMultiPreviewGraph(configuration: plan, orientation: value, photo: photo,
                            center: center, outer: outer, centerFormat: centerFormat, outerFormat: outerFormat, fps: fps)
                        try waitForPreviewFrames()
                        try waitForPeripheralFrames()
                        PeripheralDiagnostics.trace("independent preview ready: center=\(center.deviceType.rawValue) outer=\(outer.deviceType.rawValue) fps=\(fps)")
                        return PhotoCapability(physicalCameraID: center.uniqueID, dimensions: photo.dimensions,
                            horizontalFieldOfView: center.activeFormat.videoFieldOfView, zoom: center.videoZoomFactor)
                    } catch {
                        Self.logger.notice("Independent peripheral graph unavailable: \(error.localizedDescription, privacy: .public)")
                        try checkLifetime()
                    }
                }
            }
        }
        tearDownGraph(preservingPreview: true)
        let restored = try buildSinglePhotoGraph(configuration: plan, orientation: value, expected: nil, includePreview: true)
        dimensions = restored.dimensions
        try waitForPreviewFrames()
        return restored
    }

    private func independentPreviewFormats(_ device: AVCaptureDevice, aspect: CMVideoDimensions,
                                           fieldOfView: Float?, cap: Int, fps: Int32) -> [AVCaptureDevice.Format] {
        var formats = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.isMultiCamSupported && Self.sameAspect(size, aspect) && size.width >= 640 &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) } &&
                (fieldOfView.map { abs(format.videoFieldOfView - $0) < 0.1 } ?? true)
        }
        if fieldOfView == nil, let widest = formats.map(\.videoFieldOfView).max() {
            formats = formats.filter { abs($0.videoFieldOfView - widest) < 0.1 }
        }
        return formats.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            let da = abs(Int(a.width)-cap), db = abs(Int(b.width)-cap)
            if da != db { return da < db }
            if $0.isVideoBinned != $1.isVideoBinned { return $0.isVideoBinned }
            return Self.area(a) < Self.area(b)
        }
    }

    /// Only explicit constituent ports are used; the virtual device's normal
    /// switching port can never stand in for either physical camera image.
    private func buildSynchronizedPreview(configuration plan:PreviewConfiguration,orientation value:UIInterfaceOrientation,
        photo:PhotoCapability,center:AVCaptureDevice,outer:AVCaptureDevice,fps:Int32) throws -> Bool {
        let types:[AVCaptureDevice.DeviceType] = outer.deviceType == .builtInUltraWideCamera && center.deviceType == .builtInWideAngleCamera
            ? [.builtInDualWideCamera,.builtInTripleCamera]:[.builtInDualCamera,.builtInTripleCamera]
        let candidates=AVCaptureDevice.DiscoverySession(deviceTypes:types,mediaType:.video,position:.back).devices
            .filter {device in [center.uniqueID,outer.uniqueID].allSatisfy {id in device.constituentDevices.contains {$0.uniqueID==id}}}
        for virtual in candidates {
            let formats=virtual.formats.filter {format in
                let size=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return format.isMultiCamSupported && Self.sameAspect(size,photo.dimensions) && size.width>=640 &&
                    format.videoSupportedFrameRateRanges.contains {$0.minFrameRate<=Double(fps) && $0.maxFrameRate>=Double(fps)}
            }.sorted {
                abs(Int(CMVideoFormatDescriptionGetDimensions($0.formatDescription).width)-min(1920,plan.centerPreviewLongEdge)) <
                abs(Int(CMVideoFormatDescriptionGetDimensions($1.formatDescription).width)-min(1920,plan.centerPreviewLongEdge))
            }
            guard let format=formats.first else {continue}
            tearDownGraph(preservingPreview:true);try checkLifetime()
            let multi=AVCaptureMultiCamSession();session=multi;devices=[center,outer]
            synchronizedPreviewDevice=virtual
            multi.beginConfiguration();var committed=false
            defer {if !committed {multi.commitConfiguration()}}
            let input=try AVCaptureDeviceInput(device:virtual)
            guard multi.canAddInput(input) else {throw CameraFailure("Synchronized camera input unavailable.")}
            multi.addInputWithNoConnections(input)
            try virtual.lockForConfiguration()
            virtual.activeFormat=format;Self.setFrameDuration(CMTime(value:1,timescale:fps),on:virtual)
            virtual.videoZoomFactor=virtual.minAvailableVideoZoomFactor
            virtual.unlockForConfiguration()
            input.videoMinFrameDurationOverride=CMTime(value:1,timescale:fps)
            for (index,device) in [center,outer].enumerated() {
                guard let port=input.ports(for:.video,sourceDeviceType:device.deviceType,sourceDevicePosition:.back).first,
                      port.sourceDeviceType==device.deviceType else {throw CameraFailure("Synchronized constituent port unavailable.")}
                try addPreview(port:port,device:device,cap:index==0 ? plan.centerPreviewLongEdge:min(1280,plan.centerPreviewLongEdge),to:multi)
                previewPortDevices.append(device)
            }
            multi.commitConfiguration();committed=true
            guard multi.hardwareCost<=1,multi.systemPressureCost<=1 else {throw CameraFailure("Synchronized camera cost exceeds budget.")}
            peripheralFrameSource=PeripheralFrameSource()
            try negotiatePreviewPixelFormats();applyOrientation(value);installObservers(multi)
            multi.startRunning();try validateRunningGraph()
            // Do not silently change the selected physical lens or composition
            // in exchange for synchronization. Unsupported configurations fall back.
            guard abs(center.activeFormat.videoFieldOfView-photo.horizontalFieldOfView)<0.1,
                  abs(center.videoZoomFactor-1)<0.0001,abs(outer.videoZoomFactor-1)<0.0001 else {
                throw CameraFailure("Synchronized streams changed the native field of view.")
            }
            updatePeripheralSelection()
            return true
        }
        return false
    }

    private func buildMultiPreviewGraph(configuration plan: PreviewConfiguration,
                                        orientation value: UIInterfaceOrientation, photo: PhotoCapability,
                                        center: AVCaptureDevice, outer: AVCaptureDevice,
                                        centerFormat: AVCaptureDevice.Format, outerFormat: AVCaptureDevice.Format,
                                        fps: Int32) throws {
        try checkLifetime()
        guard session == nil, center.uniqueID != outer.uniqueID,
              !center.isVirtualDevice, !outer.isVirtualDevice else { throw CameraFailure("Independent cameras unavailable.") }
        let multi = AVCaptureMultiCamSession()
        session = multi; devices = [center, outer]
        multi.beginConfiguration()
        var committed = false
        defer { if !committed { multi.commitConfiguration() } }
        for (index, device, format) in [(0, center, centerFormat), (1, outer, outerFormat)] {
            let input = try AVCaptureDeviceInput(device: device)
            guard multi.canAddInput(input) else { throw CameraFailure("The selected independent camera pair is unavailable.") }
            multi.addInputWithNoConnections(input)
            try device.lockForConfiguration()
            device.activeFormat = format
            Self.setFrameDuration(CMTime(value: 1,timescale: fps),on: device)
            let zoom = index == 0 ? photo.zoom : 1
            guard zoom >= device.minAvailableVideoZoomFactor, zoom <= device.maxAvailableVideoZoomFactor else {
                device.unlockForConfiguration()
                throw CameraFailure("The independent preview cannot preserve this field of view.")
            }
            device.videoZoomFactor = zoom
            device.unlockForConfiguration()
            input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: fps)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
                throw CameraFailure("The independent camera video port is unavailable.")
            }
            try addPreview(port: port, device: device,
                cap: index == 0 ? plan.centerPreviewLongEdge : min(1280, plan.centerPreviewLongEdge), to: multi)
            previewPortDevices.append(device)
        }
        multi.commitConfiguration(); committed = true
        guard multi.hardwareCost <= 1, multi.systemPressureCost <= 1 else { throw CameraFailure("Independent camera cost exceeds budget.") }
        peripheralFrameSource = PeripheralFrameSource()
        try negotiatePreviewPixelFormats()
        applyOrientation(value)
        installObservers(multi)
        multi.startRunning()
        try validateRunningGraph()
        guard center.activeFormat === centerFormat, outer.activeFormat === outerFormat,
              multi.hardwareCost <= 1, multi.systemPressureCost <= 1 else {
            throw CameraFailure("Independent camera configuration is not sustainable.")
        }
        updatePeripheralSelection()
    }

    private func waitForPeripheralFrames() throws {
        let deadline = DispatchTime.now() + 2
        while peripheralFrameSource?.latest() == nil {
            try validateRunningGraph()
            if DispatchTime.now() >= deadline {
                PeripheralDiagnostics.trace("peripheral readiness timed out: \(peripheralFrameSource?.diagnosticState() ?? "no source")")
                throw CameraFailure("The wider camera did not deliver synchronized video.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func updatePeripheralSelection() {
        guard let source = peripheralFrameSource, let center = devices.first,
              previewPortDevices.count > 1 else {
            peripheralFrameSource?.configure(outputIndex: nil, ratio: 1); return
        }
        let index = 1, outer = previewPortDevices[1]
        func previewFieldOfView(_ device: AVCaptureDevice) -> Float {
            device.isGeometricDistortionCorrectionSupported && device.isGeometricDistortionCorrectionEnabled
                ? device.activeFormat.geometricDistortionCorrectedVideoFieldOfView : device.activeFormat.videoFieldOfView
        }
        let centerFOV = previewFieldOfView(center), outerFOV = previewFieldOfView(outer)
        let centerTangent = tan(Double(centerFOV) * .pi / 360) / Double(center.videoZoomFactor)
        let outerTangent = tan(Double(outerFOV) * .pi / 360) / Double(outer.videoZoomFactor)
        PeripheralDiagnostics.trace("independent selection center=\(center.deviceType.rawValue) centerFOV=\(centerFOV) centerZoom=\(center.videoZoomFactor) outer=\(outer.deviceType.rawValue) outerFOV=\(outerFOV) outerZoom=\(outer.videoZoomFactor) ratio=\(outerTangent / centerTangent)")
        let angle = previewOutputs.first?.connection(with: .video)?.videoRotationAngle ?? 0
        let identity = "\(center.uniqueID)|\(outer.uniqueID)|\(center.activeFormat)|\(outer.activeFormat)|\(angle)|\(center.isGeometricDistortionCorrectionEnabled)|\(outer.isGeometricDistortionCorrectionEnabled)"
        let unstabilized = previewOutputs.allSatisfy { $0.connection(with: .video)?.activeVideoStabilizationMode == .off }
        let calibration = PeripheralCalibration.decode(unstabilized ? AVCaptureDevice.extrinsicMatrix(from: center,to: outer) : nil,
            identity: identity,outputRotation: Float(angle))
        source.configure(outputIndex: index, ratio: Float(outerTangent / centerTangent),calibration: calibration,
            captureMode:synchronizedPreviewDevice == nil ? "independent-physical-inputs":"virtual-constituent-request")
    }

    private func discover(_ type: AVCaptureDevice.DeviceType) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: .back)
        guard let device = discovery.devices.first else { throw CameraFailure("The requested physical camera is unavailable.") }
        return device
    }

    private func discoverLensCatalog() {
        tripleCamera = try? discover(.builtInTripleCamera)
        if PeripheralDiagnostics.isEnabled {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualCamera,
                .builtInDualWideCamera, .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video, position: .back)
            let sets = discovery.supportedMultiCamDeviceSets.map { devices in
                devices.map { $0.deviceType.rawValue }.sorted().joined(separator: "+")
            }
            PeripheralDiagnostics.trace("supported independent camera sets: \(sets)")
            PeripheralDiagnostics.trace("virtual multi-input formats: \(tripleCamera?.formats.filter { $0.isMultiCamSupported }.count ?? 0)")
        }
        lensCatalog = []
        if let tripleCamera {
            let devices = tripleCamera.constituentDevices
            let zooms = [1.0] + tripleCamera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            let multiplier = Double(tripleCamera.displayVideoZoomFactorMultiplier)
            if devices.count == zooms.count, multiplier.isFinite, multiplier > 0,
               zooms.allSatisfy({ $0.isFinite && $0 > 0 }), zooms == zooms.sorted() {
                lensCatalog = zip(devices, zooms).map { NativeLens(device: $0, rawZoom: $1, displayedZoom: $1 * multiplier) }
                return
            }
        }
        let physical = [AVCaptureDevice.DeviceType.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
            .compactMap { try? discover($0) }
        guard let main = physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return }
        let mainFOV = Double(main.activeFormat.videoFieldOfView) * .pi / 360
        lensCatalog = physical.compactMap { device in
            let fov = Double(device.activeFormat.videoFieldOfView) * .pi / 360
            guard fov > 0, fov < .pi / 2, mainFOV > 0, mainFOV < .pi / 2 else { return nil }
            let factor = device.uniqueID == main.uniqueID ? 1 : tan(mainFOV) / tan(fov)
            return NativeLens(device: device, rawZoom: 1, displayedZoom: factor)
        }.sorted { $0.displayedZoom < $1.displayedZoom }
    }

    private func captureDevice(displayedZoom: Double) throws -> AVCaptureDevice {
        let candidates = lensCatalog.sorted { $0.displayedZoom < $1.displayedZoom }
        if let selected = candidates.last(where: { $0.displayedZoom <= displayedZoom + 0.0001 }) ?? candidates.first {
            return selected.device
        }
        return try discover(.builtInWideAngleCamera)
    }

    private func displayMultiplier(_ device: AVCaptureDevice) -> Double {
        if device.isVirtualDevice {
            let value = Double(device.displayVideoZoomFactorMultiplier)
            return value.isFinite && value > 0 ? value : 1
        }
        return lensCatalog.first { $0.device.uniqueID == device.uniqueID }?.displayedZoom ?? 1
    }

    private static func lensTitle(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: return "Ultra Wide"
        case .builtInWideAngleCamera: return "Main"
        case .builtInTelephotoCamera: return "Telephoto"
        default: return "Automatic camera"
        }
    }

    private func zoomRange(for device: AVCaptureDevice) -> CameraZoomRange {
        if !device.isVirtualDevice && !lensCatalog.isEmpty {
            let lower = lensCatalog.map { $0.displayedZoom * Double($0.device.minAvailableVideoZoomFactor) }.min()!
            let upper = lensCatalog.map { lens in
                let recommended = lens.device.activeFormat.systemRecommendedVideoZoomRange?.upperBound ?? lens.device.maxAvailableVideoZoomFactor
                return lens.displayedZoom * Double(min(recommended, lens.device.maxAvailableVideoZoomFactor))
            }.max()!
            let stops = lensCatalog.map { CameraZoomStop(id: $0.device.uniqueID, title: Self.lensTitle($0.device.deviceType), factor: $0.displayedZoom) }
            return CameraZoomRange(lowerBound: lower, upperBound: max(lower, upper), stops: stops)
        }
        let reference = device.isVirtualDevice ? device : (tripleCamera ?? device)
        let multiplier = reference.isVirtualDevice ? Double(reference.displayVideoZoomFactorMultiplier) : displayMultiplier(reference)
        let legalMin = Double(reference.minAvailableVideoZoomFactor) * multiplier
        let legalMax = Double(reference.maxAvailableVideoZoomFactor) * multiplier
        let recommendation = reference.activeFormat.systemRecommendedVideoZoomRange
        let lower = max(legalMin, recommendation.map { Double($0.lowerBound) * multiplier } ?? legalMin)
        let upper = min(legalMax, recommendation.map { Double($0.upperBound) * multiplier } ?? legalMax)
        guard lower.isFinite, upper.isFinite, lower > 0, upper >= lower else { return .main }
        let stops = lensCatalog.filter { $0.displayedZoom >= lower - 0.001 && $0.displayedZoom <= upper + 0.001 }
            .map { CameraZoomStop(id: $0.device.uniqueID, title: Self.lensTitle($0.device.deviceType), factor: $0.displayedZoom) }
        return CameraZoomRange(lowerBound: lower, upperBound: upper,
                               stops: stops.isEmpty ? [.init(id: device.uniqueID, title: Self.lensTitle(device.deviceType), factor: lower)] : stops)
    }

    private static func framing(for device: AVCaptureDevice, catalog: [NativeLens]) -> CaptureFraming {
        let primary = device.isVirtualDevice ? device.activePrimaryConstituent : device
        let lens = primary.flatMap { primary in catalog.first { $0.device.uniqueID == primary.uniqueID } }
        let multiplier = device.isVirtualDevice ? Double(device.displayVideoZoomFactorMultiplier) : (lens?.displayedZoom ?? 1)
        let count = primary?.activeFormat.supportedMaxPhotoDimensions.map(Self.area).max()
        return CaptureFraming(displayZoom: Double(device.videoZoomFactor) * multiplier,
                              deviceZoom: Double(device.videoZoomFactor),
                              nativeDeviceZoom: device.isVirtualDevice ? (lens?.rawZoom ?? 1) : 1,
                              cameraID: primary?.uniqueID, lensName: primary.map { Self.lensTitle($0.deviceType) },
                              nativePixelCount: count.flatMap { $0 > 0 && $0 <= Int64(Int.max) ? Int($0) : nil })
    }

    /// Some virtual triple cameras advertise only 12MP ProRAW even though each
    /// constituent supports 48MP. Keep automatic virtual preview/selection, then
    /// acquire from its current physical lens at the same field of view. Never
    /// choose a different lens here or clamp an unrepresentable physical zoom.
    private func highResolutionConstituent(for device: AVCaptureDevice, displayedZoom: Double) -> AVCaptureDevice? {
        guard device.isVirtualDevice, let primary = device.activePrimaryConstituent,
              let virtual = try? photoCapability(device), let physical = try? photoCapability(primary),
              Self.area(physical.dimensions) > Self.area(virtual.dimensions),
              let lens = lensCatalog.first(where: { $0.device.uniqueID == primary.uniqueID }) else { return nil }
        let zoom = displayedZoom / lens.displayedZoom
        guard zoom.isFinite, zoom >= Double(primary.minAvailableVideoZoomFactor),
              zoom <= Double(primary.maxAvailableVideoZoomFactor) else { return nil }
        return primary
    }

    func setZoom(_ displayedZoom: Double) throws -> Bundle {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil, var plan = configuration, let center = devices.first else {
            throw CameraFailure("Camera zoom is locked during capture.")
        }
        try validateRunningGraph()
        let desired = zoomRange(for: center).clamped(displayedZoom)
        plan.displayedZoom = desired; configuration = plan
        let selected = try captureDevice(displayedZoom: desired)
        if selected.uniqueID != center.uniqueID || synchronizedPreviewDevice != nil {
            phase = .configuring
            tearDownGraph(preservingPreview: true)
            var photo = try buildSinglePhotoGraph(configuration: plan, orientation: interfaceOrientation,
                                                 expected: nil, includePreview: true)
            capability = photo; dimensions = photo.dimensions
            try waitForPreviewFrames()
            photo = try promotePreview(configuration: plan, orientation: interfaceOrientation, photo: photo)
            capability = photo; phase = .preview
        } else {
            try center.lockForConfiguration()
            center.cancelVideoZoomRamp()
            center.videoZoomFactor = min(center.maxAvailableVideoZoomFactor,
                max(center.minAvailableVideoZoomFactor, CGFloat(desired / displayMultiplier(center))))
            center.unlockForConfiguration()
            if session is AVCaptureMultiCamSession {
                updatePeripheralSelection()
            } else {
                let photo = try photoCapability(center)
                capability = photo; dimensions = photo.dimensions
                photoOutput?.maxPhotoDimensions = photo.dimensions
            }
        }
        return try previewBundle()
    }
    /// Creates only an ordinary .photo session. The previous graph must already
    /// have stopped and released all inputs/outputs; two sessions never own a lens.
    @discardableResult
    private func buildSinglePhotoGraph(configuration plan: PreviewConfiguration, orientation value: UIInterfaceOrientation,
                                       expected: PhotoCapability?, includePreview: Bool,
                                       forcedDevice: AVCaptureDevice? = nil,
                                       matchingFieldOfViewTangent: Double? = nil, bayer: Bool = false) throws -> PhotoCapability {
        try checkLifetime()
        guard session == nil else { throw CameraFailure("A camera graph still owns the device.") }
        let center = try forcedDevice ?? captureDevice(displayedZoom: plan.displayedZoom)
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
        let multiplier = displayMultiplier(center)
        let desired = CGFloat(plan.displayedZoom / multiplier)
        center.videoZoomFactor = bayer ? 1 : (expected?.zoom ?? min(center.maxAvailableVideoZoomFactor, max(center.minAvailableVideoZoomFactor, desired)))
        if center.isExposureModeSupported(.continuousAutoExposure) { center.exposureMode = .continuousAutoExposure }
        if center.isFocusModeSupported(.continuousAutoFocus) { center.focusMode = .continuousAutoFocus }
        if center.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { center.whiteBalanceMode = .continuousAutoWhiteBalance }
        center.unlockForConfiguration()
        let output = AVCapturePhotoOutput()
        guard newSession.canAddOutput(output) else { throw CameraFailure("Single-camera photo capture is unavailable.") }
        newSession.addOutputWithNoConnections(output)
        let photoConnection = AVCaptureConnection(inputPorts: [port], output: output)
        guard newSession.canAddConnection(photoConnection) else { throw CameraFailure("Cannot connect the physical camera to photo capture.") }
        newSession.addConnection(photoConnection)
        guard photoConnection.isVideoOrientationSupported else { throw CameraFailure("Photo orientation control is unavailable.") }
        photoOutput = output
        output.maxPhotoQualityPrioritization = bayer ? .speed : .quality
        guard bayer || output.isAppleProRAWSupported else {
            throw CameraFailure("Apple ProRAW is unavailable on this camera. Try another focal length.", allowsPhysicalFallback: center.isVirtualDevice)
        }
        output.isAppleProRAWEnabled = !bayer
        if bayer {
            if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = false }
            if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = false }
            if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = false }
            if output.isAutoDeferredPhotoDeliverySupported { output.isAutoDeferredPhotoDeliveryEnabled = false }
            if output.isLivePhotoCaptureSupported { output.isLivePhotoCaptureEnabled = false }
        }
        if output.isContentAwareDistortionCorrectionSupported { output.isContentAwareDistortionCorrectionEnabled = false }
        if let tangent = matchingFieldOfViewTangent {
            let exactZoom = tan(Double(center.activeFormat.videoFieldOfView) * .pi / 360) / tangent
            guard exactZoom.isFinite, exactZoom >= Double(center.minAvailableVideoZoomFactor),
                  exactZoom <= Double(center.maxAvailableVideoZoomFactor) else {
                throw CameraFailure("The photo camera cannot preserve the viewfinder field of view.")
            }
            try center.lockForConfiguration()
            center.videoZoomFactor = CGFloat(exactZoom)
            center.unlockForConfiguration()
        }
        let finalFormat = center.activeFormat
        let photo = try photoCapability(center)
        if let expected { try validate(photo, matches: expected) }
        dimensions = photo.dimensions
        output.maxPhotoDimensions = dimensions
        guard output.availableRawPhotoPixelFormatTypes.contains(where: bayer ? AVCapturePhotoOutput.isBayerRAWPixelFormat : AVCapturePhotoOutput.isAppleProRAWPixelFormat) else {
            throw CameraFailure("This camera exposes no Apple ProRAW format. Try another focal length.", allowsPhysicalFallback: center.isVirtualDevice)
        }
        if includePreview { try addPreview(port: port, device: center, cap: plan.centerPreviewLongEdge, to: newSession) }
        newSession.commitConfiguration(); committed = true
        // A device reused from 60 Hz MultiCam can retain max=1/60 even after
        // .photo resets min to 1/30. That inverted range prevents startRunning.
        // Reset both bounds on every ordinary graph, including still capture;
        // preview may then select 60 Hz only when its photo format supports it.
        try center.lockForConfiguration()
        center.activeVideoMaxFrameDuration = .invalid
        center.activeVideoMinFrameDuration = .invalid
        center.unlockForConfiguration()
        if includePreview { try applyPreviewFrameRate(center) }
        try negotiatePreviewPixelFormats()
        applyOrientation(value)
        try checkLifetime()
        installObservers(newSession)
        newSession.startRunning()
        try validateRunningGraph()
        guard newSession.sessionPreset == .photo, center.activeFormat === finalFormat,
              (bayer ? !output.isAppleProRAWEnabled : (output.isAppleProRAWSupported && output.isAppleProRAWEnabled)) else {
            throw CameraFailure("Starting the photo graph changed its source configuration. No lower-resolution capture was substituted.")
        }
        try validate(try photoCapability(center), matches: photo)
        // On iOS 27, captureReadiness can report ready immediately after the
        // photo graph starts while a 48MP request can still resolve to a 12MP RAW.
        // Allow the new photo graph to settle; delivery still verifies full size.
        photoWarmupDeadline = .now() + 2
        return photo
    }
    /// Preview graphs only: capture graphs never include a preview, so this
    /// cannot cap photo exposure. activeFormat stays the .photo preset's own;
    /// a format without 60 fps keeps its default rate instead of switching.
    private func applyPreviewFrameRate(_ device: AVCaptureDevice) throws {
        let fps: Int32 = 60
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
        }) else {
            Self.logger.notice("Single-camera preview format has no 60 fps range; keeping its default rate.")
            return
        }
        try device.lockForConfiguration()
        Self.setFrameDuration(CMTime(value: 1,timescale: fps),on: device)
        device.unlockForConfiguration()
    }
    /// Move the bounds without ever temporarily producing min > max.
    /// The caller owns the configuration lock and has checked format support.
    private static func setFrameDuration(_ duration: CMTime,on device: AVCaptureDevice) {
        if CameraSessionRecovery.raisesMaximumFirst(target: CMTimeGetSeconds(duration),
            currentMaximum: CMTimeGetSeconds(device.activeVideoMaxFrameDuration)) {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }
    private func photoCapability(_ center: AVCaptureDevice) throws -> PhotoCapability {
        let format = center.activeFormat
        guard format.videoFieldOfView.isFinite, format.videoFieldOfView > 0, format.videoFieldOfView < 180 else {
            throw CameraFailure("The physical camera did not report a usable photo field of view.")
        }
        guard let largest = nativePhotoDimensions(format: format).max(by: { Self.area($0) < Self.area($1) }) else {
            throw CameraFailure("The photo format has no full-framing 12MP or 48MP ProRAW source dimensions.")
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
    private func addPreview(port: AVCaptureInput.Port, device: AVCaptureDevice, cap: Int,
                            sourceDimensions: CMVideoDimensions? = nil, to session: AVCaptureSession) throws {
        let video = AVCaptureVideoDataOutput()
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false; video.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(video) else { throw CameraFailure("Cannot add the independent scaled live-preview output.") }
        session.addOutputWithNoConnections(video)
        let connection = AVCaptureConnection(inputPorts: [port], output: video)
        guard session.canAddConnection(connection) else { throw CameraFailure("A physical-lens video preview connection is unavailable.") }
        session.addConnection(connection)
        guard connection.isVideoOrientationSupported else { throw CameraFailure("This preview cannot match photo orientation.") }
        let size = try Self.scaledPreviewDimensions(source: sourceDimensions ??
            CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription), cap: cap)
        let delivery = CameraFrameDelivery.makeOnMainThread()
        video.setSampleBufferDelegate(delivery, queue: delivery.callbackQueue)
        previewOutputs.append(video); frameDeliveries.append(delivery)
        previewSizes.append(size)
    }
    private func negotiatePreviewPixelFormats() throws {
        // Manual connections only become part of the effective graph when its
        // topology is committed. Before then the supported format list can be
        // empty even though this physical camera supports YCbCr output.
        previewPixelFormats = try previewOutputs.enumerated().map { index, video in
            let supported = video.availableVideoPixelFormatTypes
            let formats = supported.map { String(format: "0x%08X", $0) }.joined(separator: ", ")
            Self.logger.info("Preview output \(index) supported formats: \(formats, privacy: .public)")
            // Some native camera formats expose only 10-bit YCbCr. The system
            // display layer accepts those buffers directly; the experimental
            // live-color path independently checks its narrower source support.
            guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                                     kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange].first(where: { supported.contains($0) }) else {
                throw CameraFailure("The preview exposes no supported YCbCr format.")
            }
            return pixelFormat
        }
    }
    private static func nominalMegapixels(_ pixels: Int64) -> Int? {
        [12, 24, 48].first { abs(Double(pixels) / (Double($0) * 1_000_000) - 1) <= 0.08 }
    }
    private static func outputOptions(source: CMVideoDimensions) -> [CameraController.OutputOption] {
        guard source.width > 0, source.height > 0 else { return [] }
        return [24, 48].compactMap { tier in
            guard let size = try? ExportSettings.camera(tier).dimensions(sourceWidth: Int(source.width), sourceHeight: Int(source.height)) else { return nil }
            return .init(megapixels: tier, width: size.width, height: size.height)
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
        previewSynchronizer?.setDelegate(nil, queue: nil)
        synchronizedDelivery?.queue.sync {}
        previewSynchronizer = nil; synchronizedDelivery = nil
        peripheralFrameSource?.reset()
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
            if connection.isCameraIntrinsicMatrixDeliverySupported &&
                !connection.isCameraIntrinsicMatrixDeliveryEnabled && !session.isRunning {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            connection.videoScaleAndCropFactor = 1
        }
        previewReadiness = DispatchGroup()
        for (index, video) in previewOutputs.enumerated() {
            let size = previewSizes[index]
            let portrait = orientation == .portrait || orientation == .portraitUpsideDown
            let width = Int(portrait ? size.height : size.width), height = Int(portrait ? size.width : size.height)
            let readiness = previewReadiness
            if index == 0 { readiness.enter() }
            frameDeliveries[index].expect(width: width, height: height, pixelFormat: previewPixelFormats[index]) {
                if index == 0 { readiness.leave() }
            }
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelFormats[index],
                                   kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
            video.setSampleBufferDelegate(frameDeliveries[index], queue: frameDeliveries[index].callbackQueue)
            video.connection(with: .video)?.isEnabled = true
        }
        if let source = peripheralFrameSource, previewOutputs.count > 1 {
            let receiver = PeripheralFrameSynchronizer(source: source, outputs: previewOutputs, deliveries: frameDeliveries, clock: { [weak session] in session?.synchronizationClock })
            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: previewOutputs)
            synchronizedDelivery = receiver; previewSynchronizer = synchronizer
            synchronizer.setDelegate(receiver, queue: receiver.queue)
            updatePeripheralSelection()
        }
    }
    private func checkLifetime() throws {
        guard let lifetime else { throw CameraFailure("Camera stopped.") }
        try lifetime.check()
    }
    private func validateRunningGraph() throws {
        try checkLifetime()
        guard let session, session.isRunning, !session.isInterrupted, !failed else {
            PeripheralDiagnostics.trace("graph invalid phase=\(phase) running=\(session?.isRunning ?? false) interrupted=\(session?.isInterrupted ?? false) failed=\(failed) cameras=\(devices.map { "\($0.deviceType.rawValue) pressure=\($0.systemPressureState.level.rawValue) format=\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)) min=\(CMTimeGetSeconds($0.activeVideoMinFrameDuration)) max=\(CMTimeGetSeconds($0.activeVideoMaxFrameDuration))" })")
            throw CameraFailure("The camera session is stopped or interrupted.")
        }
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
        try CameraPreviewReadiness.wait(next: { self.previewReadiness.wait(timeout: .now() + 0.05) },
                                        expired: { DispatchTime.now() >= deadline }, validate: validateRunningGraph)
        let encodings = previewPixelFormats.map(Self.previewEncoding).joined(separator: ", ")
        Self.logger.info("Preview ready after matching frames: \(encodings, privacy: .public)")
    }
    private static func previewEncoding(_ format: OSType) -> String {
        // Published only after the first frame matches the requested OSType.
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "8-bit YCbCr420 (420f)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "8-bit YCbCr420 (420v)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return "10-bit YCbCr420 (xf20)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "10-bit YCbCr420 (x420)"
        default: return String(format: "Pixel format 0x%08X", format)
        }
    }

    static func scaledPreviewDimensions(source: CMVideoDimensions, cap: Int) throws -> CMVideoDimensions {
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
        guard dimensions.width > 0, dimensions.height > 0, !devices.isEmpty else { return nil }
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let size = Self.size(dimensions)
        return .init(sensorPhotoDimensions: size, photoAspectRatio: portrait ? size.height / size.width : size.width / size.height)
    }
    private func previewBundle() throws -> Bundle {
        guard let photo = capability, let geometry = geometry(), let center = devices.first,
              !frameDeliveries.isEmpty, previewSizes.count == frameDeliveries.count else {
            throw CameraFailure("The preview graph is incomplete.")
        }
        updatePeripheralSelection()
        var framing = Self.framing(for: center, catalog: lensCatalog)
        let physical = highResolutionConstituent(for: center, displayedZoom: framing.displayZoom)
        let source: CMVideoDimensions
        if session is AVCaptureMultiCamSession, let id = framing.cameraID, let hint = nativePhotoHints[id] {
            source = hint; framing.nativePixelCount = Int(Self.area(hint))
        } else { source = physical.flatMap { try? photoCapability($0).dimensions } ?? photo.dimensions }
        return Bundle(center: frameDeliveries[0].layer, liveSource: frameDeliveries[0].liveSource,
                      peripheralSource: peripheralFrameSource,
                      geometry: geometry,
                      sourceCaptureDimensions: Self.size(source),
                      outputOptions: Self.outputOptions(source: source), physicalCameraID: framing.cameraID ?? photo.physicalCameraID,
                      centerPreviewDimensions: Self.size(previewSizes[0]),
                      centerPreviewEncoding: Self.previewEncoding(previewPixelFormats[0]),
                      zoomRange: zoomRange(for: center), framing: framing)
    }
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
                guard let main = lensCatalog.first(where:{$0.device.deviceType == .builtInWideAngleCamera && !$0.device.isVirtualDevice}),
                      abs(request.configuration.displayedZoom-main.displayedZoom)<0.0001 else {
                    throw F5Failure(.mainCameraOnly, "Select the main camera's native view for F5.")
                }
                let current=main.device
                request.restoresPreviewGraph = true
                request.progress(.preparing, "Preparing five Bayer RAW exposures…")
                tearDownGraph(preservingPreview: true)
                let photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
                    expected: nil, includePreview: false, forcedDevice: current, bayer: true)
                self.capability = photo; dimensions = photo.dimensions; request.capability = photo
                guard let output = photoOutput else { throw F5Failure(.unsupportedRAW, "Missing Bayer photo output.") }
                let catalog = lensCatalog
                let driver = try F5CaptureDriver(queue: queue, camera: current, output: output,
                    snapshot: snapshot, purpose: f5Purpose, framing: { Self.framing(for: current, catalog: catalog) },
                    cancelled: { request.lifetime.isCancelled }, progress: { request.progress(.capturing, $0) }) { [weak self, weak request] result in
                    guard let self, let request else { return }
                    self.queue.async { [weak self, weak request] in
                        guard let self, let request, self.currentRequest === request else { return }
                        self.finishPhoto(result.map(Self.burstPhoto), request: request)
                    }
                }
                f5Capture = driver; phase = .capturing; driver.start()
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
    private func finishPhoto(_ result: Result<CapturedProRAW, Error>, request: CaptureRequest) {
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
    private func finishRequest(_ request: CaptureRequest, result: Result<CapturedProRAW, Error>, bundle: Bundle?,
                               previewReady: Bool, message: String?) {
        guard currentRequest === request, let callback = request.completion else { return }
        request.completion = nil; currentRequest = nil; captureDelegate = nil; f5Capture = nil
        callback(CaptureOutcome(result: result, bundle: bundle, previewReady: previewReady, message: message))
    }
    private func failSession(_ message: String, stopRunning: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        PeripheralDiagnostics.trace("session failure: \(message) phase=\(phase)")
        failed = true; phase = .failed
        frameDeliveries.forEach { $0.freeze() }
        if stopRunning { session?.stopRunning() }
        failureHandler?(message)
        if let request = currentRequest {
            let result = request.result ?? f5Capture?.cancel().map(Self.burstPhoto) ?? captureDelegate?.cancel(reason: message) ?? .failure(CameraFailure(message))
            // Preserve only a successfully committed terminal photo result, even
            // if its queued callback or preview restoration has not run yet.
            finishPhoto(result, request: request)
        }
    }
    private func installObservers(_ observed: AVCaptureSession) {
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
                        self.failSession("Camera stopped due to system pressure. Let the device cool, then select the lens again. Capture quality was not reduced.", stopRunning: true)
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
    private func tearDownGraph(preservingPreview: Bool) {
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
        session = nil; photoOutput = nil; photoWarmupDeadline = nil; devices = []
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        lifetime?.cancel(); phase = .stopped; failed = true
        let request = currentRequest
        let result = request?.result ?? f5Capture?.cancel().map(Self.burstPhoto) ?? captureDelegate?.cancel() ?? .failure(CameraFailure("Camera capture cancelled."))
        tearDownGraph(preservingPreview: false)
        frozenDeliveries.forEach { $0.invalidate() }; frozenDeliveries.removeAll()
        if let request { finishRequest(request, result: result, bundle: nil, previewReady: false, message: "Camera stopped.") }
        captureDelegate = nil; f5Capture = nil; configuration = nil; capability = nil; lifetime = nil
        dimensions = CMVideoDimensions(width: 0, height: 0); failureHandler = nil
        stateChanged = nil; tripleCamera = nil; lensCatalog = []; nativePhotoHints.removeAll()
    }
    private static func burstPhoto(_ source: F5BurstSource) -> CapturedProRAW {
        let frame = source.manifest.frames.first(where: { $0.burstIndex == 1 }) ?? source.manifest.frames[0]
        var framing = source.manifest.framing
        framing.deliveredWidth = frame.raster.activeArea.width; framing.deliveredHeight = frame.raster.activeArea.height
        framing.nativePixelCount = frame.raster.activeArea.width * frame.raster.activeArea.height
        return .init(data: Data(), dimensions: CGSize(width: frame.raster.activeArea.width, height: frame.raster.activeArea.height), framing: framing, burst: source)
    }
}

/// Exactly one committed DNG per request. Processing bytes are provisional until
/// didFinishCaptureFor succeeds. A stop preserves that terminal result, including
/// when its backend-queue callback has not run yet; late callbacks cannot restore.
final class ProRAWCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private static let logger = Logger(subsystem: "dev.glasscam.prototype", category: "Capture")
    private let lock = NSLock()
    private var completion: ((Result<CapturedProRAW, Error>) -> Void)?
    private var result: Result<CapturedProRAW, Error>?
    private var terminalResult: Result<CapturedProRAW, Error>?
    private let expectedDimensions: CMVideoDimensions
    private let framingProvider: () -> CaptureFraming
    private var framing = CaptureFraming()
    init(expectedDimensions: CMVideoDimensions, framing: @escaping () -> CaptureFraming,
         completion: @escaping (Result<CapturedProRAW, Error>) -> Void) {
        self.expectedDimensions = expectedDimensions; self.completion = completion; self.framingProvider = framing
        self.framing = framing()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        lock.lock(); defer { lock.unlock() }
        framing = framingProvider()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        receivePhoto(isRaw: photo.isRawPhoto, buffer: photo.pixelBuffer,
                     data: { photo.fileDataRepresentation() }, actual: photo.resolvedSettings.rawPhotoDimensions,
                     metadata: photo.metadata, error: error)
    }
    func receivePhoto(isRaw: Bool, buffer: CVPixelBuffer?, data: () -> Data?, actual: CMVideoDimensions,
                      metadata: [String: Any], error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard completion != nil else { return }
        if let error { result = .failure(error); return }
        guard isRaw, let buffer,
              AVCapturePhotoOutput.isAppleProRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer)),
              let data = data(), !data.isEmpty else {
            result = .failure(CameraFailure("The camera did not return an Apple ProRAW DNG.")); return
        }
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        func number(_ key: CFString) -> Double? {
            guard let value = (exif?[key as String] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        framing.exifDigitalZoom = number(kCGImagePropertyExifDigitalZoomRatio)
        framing.exifFocalLength = number(kCGImagePropertyExifFocalLength)
        framing.exifEquivalentFocalLength = number(kCGImagePropertyExifFocalLenIn35mmFilm)
        framing.exifLensModel = exif?[kCGImagePropertyExifLensModel as String] as? String
        Self.logger.notice("ProRAW dimensions: requested=\(self.expectedDimensions.width)x\(self.expectedDimensions.height), resolved=\(actual.width)x\(actual.height), buffer=\(bufferWidth)x\(bufferHeight)")
        guard framing.acceptsRAWDimensions(requestedWidth: Int(expectedDimensions.width), requestedHeight: Int(expectedDimensions.height),
            deliveredWidth: Int(actual.width), deliveredHeight: Int(actual.height), bufferWidth: bufferWidth, bufferHeight: bufferHeight) else {
            result = .failure(CameraFailure("The camera did not deliver a valid full-framing RAW for this focal length. Wait for it to settle and try again.")); return
        }
        framing.deliveredWidth = Int(actual.width); framing.deliveredHeight = Int(actual.height)
        Self.logger.notice("Capture zoom=\(self.framing.displayZoom), lens=\(self.framing.lensName ?? "unknown", privacy: .public), RAW=\(actual.width)x\(actual.height)")
        result = .success(CapturedProRAW(data: data, dimensions: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height)), framing: framing))
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finishCapture(error: error)
    }
    func finishCapture(error: Error?) {
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

/// The session queue waits for an actual frame; lifecycle and timeout checks stay
/// separate so tests can advance either event without a wall-clock delay.
enum CameraPreviewReadiness {
    static func wait(next: () -> DispatchTimeoutResult, expired: () -> Bool, validate: () throws -> Void) throws {
        while next() != .success {
            try validate()
            if expired() {
                throw CameraFailure("A physical camera preview did not deliver its negotiated frame within 5 seconds. Select the lens again to retry.")
            }
        }
        try validate()
    }
}
