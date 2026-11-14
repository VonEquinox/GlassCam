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
        var centerType: AVCaptureDevice.DeviceType {
            .builtInTripleCamera
        }
    }
    struct CameraGeometry {
        let sensorPhotoDimensions: CGSize
        let photoAspectRatio: CGFloat
    }
    enum CapturePhase: String { case idle, preparing, capturing, captured, restoring }
    @Published private(set) var status = String(localized: "Camera stopped")
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var peripheralSource: PeripheralFrameSource?
    @Published private(set) var centerLiveSource: LiveCameraFrameSource?
    @Published private(set) var centerPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var geometry: CameraGeometry?
    @Published private(set) var physicalCameraID: String?
    @Published private(set) var isConfiguring = false
    @Published private(set) var zoomRange: CameraZoomRange = .main
    @Published private(set) var requestedZoom = 1.0
    @Published private(set) var appliedZoom = 1.0
    @Published private(set) var currentFraming = CaptureFraming()
    @Published private(set) var isUpdatingZoom = false
    @Published private(set) var f5SampleDirectory: URL?
    @Published private(set) var metering = CameraMetering.automatic
    @Published private(set) var meteringAdjusting = false
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -2...2
    @Published private(set) var exposureCompletionID: UUID?
    private(set) var captureQuality: CaptureQuality = .balanced
    @Published private(set) var physicalOrientation: UIInterfaceOrientation?
    private var reservedOrientation: UIInterfaceOrientation?
    private var meteringRevision: UInt64 = 0
    private var nativeMainZoom = 1.0
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
        isConfiguring = true; isReady = false; capturePhase = .idle
        status = String(localized: "Checking camera access…"); appliedOrientation = .unknown; isApplyingOrientation = false
        clearPreview()
        switch cameraAccess.status() {
        case .authorized:
            configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, token: token)
        case .notDetermined:
            cameraAccess.request { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if allowed { self.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, token: token) }
                    else { self.isConfiguring = false; self.status = String(localized: "Camera permission denied. Enable camera access in Settings.") }
                }
            }
        default:
            isConfiguring = false; status = String(localized: "Camera permission denied. Enable camera access in Settings.")
        }
    }
    private func configure(mode: Mode, centerPreviewLongEdge: Int, token: UUID) {
        let initialOrientation = orientation
        let lifetime = lifetime
        status = String(localized: "Checking camera RAW capability…")
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
                    self.requestedZoom = bundle.nativeMainZoom
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
        String(localized: "Bayer RAW · \(currentFraming.lensName ?? String(localized: "Main"))")
    }
    private func install(_ bundle: CameraBackend.Bundle) {
        centerPreviewLayer = bundle.center; centerLiveSource = bundle.liveSource
        peripheralSource = bundle.peripheralSource
        geometry = bundle.geometry
        physicalCameraID = bundle.physicalCameraID
        zoomRange = bundle.zoomRange
        appliedZoom = bundle.framing.displayZoom
        currentFraming = bundle.framing
        requestedZoom = zoomRange.clamped(requestedZoom)
        metering = bundle.metering; meteringAdjusting = bundle.meteringAdjusting
        exposureBiasRange = bundle.exposureBiasRange
        nativeMainZoom = bundle.nativeMainZoom
    }
    var previewOrientation: UIInterfaceOrientation {
        appliedOrientation == .unknown ? orientation : appliedOrientation
    }
    var isExposing: Bool { capturePhase == .preparing || capturePhase == .capturing }

    func updatePhysicalOrientation(_ value: UIInterfaceOrientation?) {
        guard let value, value != .unknown else { return }
        physicalOrientation = value
    }

    func setMetering(_ requested: CameraMetering) {
        guard canReserveCapture, requested.isValid else { return }
        meteringRevision &+= 1
        let revision = meteringRevision, token = generation
        metering = requested; meteringAdjusting = true
        backend.queue.async { [weak self, backend] in
            let result = Result { try backend.setMetering(requested) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.meteringRevision == revision else { return }
                switch result {
                case .success(let applied): self.metering = applied; self.meteringAdjusting = false
                case .failure(let error):
                    self.metering = .automatic; self.meteringAdjusting = false
                    self.status = error.localizedDescription
                }
            }
        }
    }
    func selectF5MainCamera() {
        requestedZoom = nativeMainZoom
        applyPendingZoom()
    }
    @MainActor
    func reserveMainForTest() async throws -> UUID {
        let token = generation
        selectF5MainCamera()
        for _ in 0..<160 {
            try Task.checkCancellation()
            guard generation == token, !lifetime.isCancelled else { throw CancellationError() }
            if let reservation = reserveCapture() { return reservation }
            guard isReady || isConfiguring || isUpdatingZoom else { throw CameraFailure(status) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CameraFailure("The main camera did not become ready for recording.")
    }

    private func clearPreview() {
        centerPreviewLayer = nil; geometry = nil; peripheralSource = nil
        centerLiveSource?.setEnabled(false); centerLiveSource = nil
        physicalCameraID = nil
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
        capturePhase = .idle; appliedOrientation = .unknown; isApplyingOrientation = false
        reservedOrientation = nil; metering = .automatic; meteringAdjusting = false
        clearPreview(); status = String(localized: "Camera stopped")
        backend.queue.async { [backend] in backend.stop() }
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
        reservedOrientation = physicalOrientation ?? previewOrientation
        return id
    }

    func releaseCaptureReservation(_ id: UUID) {
        guard captureReservation == id, !isCapturing else { return }
        captureReservation = nil
        reservedOrientation = nil
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

    func capturePhoto(reservation: UUID, quality: CaptureQuality = .balanced, snapshot: CaptureSnapshot? = nil,
                      f5Purpose: String = "product",
                      completion: @escaping (Result<CapturedCameraPhoto, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard captureReservation == reservation, isReady, !isCapturing, !isConfiguring,
              !isUpdatingZoom, !isApplyingOrientation else {
            releaseCaptureReservation(reservation)
            completion(.failure(CameraFailure("Camera is unavailable or a capture is already in progress."))); return
        }
        isCapturing = true; isReady = false
        captureQuality = quality
        capturePhase = .preparing
        status = String(localized: "Preparing RAW capture. Hold steady…")
        let token = generation
        let captureOrientation = reservedOrientation ?? previewOrientation
        backend.queue.async { [weak self, backend] in
            backend.capture(quality: quality, snapshot: snapshot, f5Purpose: f5Purpose, orientation: captureOrientation, progress: { phase, message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.capturePhase = phase; self.status = message
                    if phase == .captured, self.exposureCompletionID != reservation {
                        self.exposureCompletionID = reservation
                    }
                }
            }) { outcome in
                DispatchQueue.main.async { [weak self] in
                    let photoResult = outcome.result.map { CapturedCameraPhoto(data: $0.data, framing: $0.framing, burst: $0.burst) }
                    // Stop/background can invalidate view state, never a completed DNG.
                    guard let self, self.generation == token else { completion(photoResult); return }
                    if let bundle = outcome.bundle { self.install(bundle) }
                    if f5Purpose == "probe", case .success(let photo) = outcome.result { self.f5SampleDirectory = photo.burst?.directory }
                    self.isCapturing = false; self.captureReservation = nil; self.reservedOrientation = nil; self.capturePhase = .idle
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
