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
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var centerPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var peripheralPreviewLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var geometry: CameraGeometry?
    @Published private(set) var supportedOutputOptions: [OutputOption] = []
    @Published private(set) var sourceCaptureDimensions: CGSize?
    @Published private(set) var physicalCameraID: String?
    @Published private(set) var centerPreviewDimensions: CGSize?
    @Published private(set) var peripheralPreviewDimensions: CGSize?
    private let backend = CameraBackend()
    private var generation = UUID()
    @Published private(set) var isConfiguring = false
    private var orientation: UIInterfaceOrientation = .portrait
    private var orientationRevision: UInt64 = 0

    func start(mode: Mode, centerPreviewLongEdge: Int = 1920, peripheralPreviewLongEdge: Int = 1280) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isConfiguring, !isCapturing else { return }
        let token = UUID(); generation = token
        isConfiguring = true; isReady = false; status = "Checking camera access…"
        centerPreviewLayer = nil; peripheralPreviewLayer = nil; geometry = nil
        supportedOutputOptions = []; sourceCaptureDimensions = nil; physicalCameraID = nil
        centerPreviewDimensions = nil; peripheralPreviewDimensions = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, peripheralPreviewLongEdge: peripheralPreviewLongEdge, token: token)
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
        status = "Configuring \(mode.title)…"
        backend.queue.async { [weak self, backend] in
            do {
                let bundle = try backend.configure(mode: mode, centerPreviewLongEdge: centerPreviewLongEdge, peripheralPreviewLongEdge: peripheralPreviewLongEdge, orientation: initialOrientation) { message in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.isReady = false; self.status = message
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isConfiguring = false
                    self.centerPreviewLayer = bundle.center
                    self.peripheralPreviewLayer = bundle.periphery
                    self.geometry = bundle.geometry
                    self.supportedOutputOptions = bundle.outputOptions
                    self.sourceCaptureDimensions = bundle.geometry.sensorPhotoDimensions
                    self.physicalCameraID = bundle.physicalCameraID
                    self.centerPreviewDimensions = bundle.centerPreviewDimensions
                    self.peripheralPreviewDimensions = bundle.peripheralPreviewDimensions
                    self.isReady = true
                    self.status = mode == .ultraWide ? "Apple ProRAW · black periphery" : "Apple ProRAW · separate wider live preview"
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
    func updateOrientation(_ value: UIInterfaceOrientation) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard value != .unknown else { return }
        orientation = value
        guard !isConfiguring, centerPreviewLayer != nil else { return }
        isReady = false
        orientationRevision &+= 1
        let revision = orientationRevision
        let token = generation
        backend.queue.async { [weak self, backend] in
            backend.applyOrientation(value)
            do {
                try backend.waitForPreviewFrames()
                let geometry = backend.geometry()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.orientationRevision == revision else { return }
                    self.geometry = geometry
                    self.isReady = true
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.orientationRevision == revision else { return }
                    self.isReady = false; self.status = error.localizedDescription
                }
            }
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID(); isConfiguring = false; isReady = false; isCapturing = false
        centerPreviewLayer = nil; peripheralPreviewLayer = nil; geometry = nil
        supportedOutputOptions = []; sourceCaptureDimensions = nil; physicalCameraID = nil
        centerPreviewDimensions = nil; peripheralPreviewDimensions = nil
        status = "Camera stopped"
        backend.queue.async { [backend] in backend.stop() }
    }
    /// Delivers the actual ProRAW DNG. Pass to ImagePipeline.load(data:fileExtension: "dng").
    /// No preview/peripheral buffers enter this result. At most one capture is in flight.
    func captureProRAW(completion: @escaping (Result<Data, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isReady, !isCapturing else {
            completion(.failure(CameraFailure("Camera is unavailable or a capture is already in progress."))); return
        }
        isCapturing = true
        let token = generation
        backend.queue.async { [weak self, backend] in
            backend.capture { result in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else {
                        completion(.failure(CameraFailure("Capture cancelled because the camera stopped."))); return
                    }
                    self.isCapturing = false
                    if case .failure(let error) = result { self.status = error.localizedDescription }
                    completion(result)
                }
            }
        }
    }
    deinit { let engine = backend; engine.queue.async { engine.stop() } }
}

private struct CameraFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class CameraBackend {
    struct Bundle {
        let center: AVSampleBufferDisplayLayer
        let periphery: AVSampleBufferDisplayLayer?
        let geometry: CameraController.CameraGeometry
        let outputOptions: [CameraController.OutputOption]
        let physicalCameraID: String
        let centerPreviewDimensions: CGSize
        let peripheralPreviewDimensions: CGSize?
    }
    let queue = DispatchQueue(label: "dev.glasscam.camera", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var devices: [AVCaptureDevice] = []
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var captureDelegate: ProRAWCapture?
    private var failureHandler: ((String) -> Void)?
    private var failed = false
    private var previewOutputs: [AVCaptureVideoDataOutput] = []
    private var frameDeliveries: [CameraFrameDelivery] = []
    private var previewSizes: [CMVideoDimensions] = []
    private var previewPixelFormats: [OSType] = []
    private var previewReadiness = DispatchGroup()

    func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int, peripheralPreviewLongEdge: Int, orientation: UIInterfaceOrientation,
                   failure: @escaping (String) -> Void) throws -> Bundle {
        dispatchPrecondition(condition: .onQueue(queue))
        stop(); failed = false; failureHandler = failure
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back)
        guard let center = discovery.devices.first(where: { $0.deviceType == mode.centerType }) else {
            throw CameraFailure("This device has no physical \(mode.title.lowercased()) camera.")
        }
        var chosen = [center]
        if let type = mode.peripheralType {
            guard AVCaptureMultiCamSession.isMultiCamSupported,
                  let peripheral = discovery.devices.first(where: { $0.deviceType == type }),
                  discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(center) && $0.contains(peripheral) }) else {
                throw CameraFailure("This physical camera pair does not support simultaneous capture. No substitute preview or lens was used.")
            }
            chosen.append(peripheral)
        }
        let multi = chosen.count == 2
        let newSession: AVCaptureSession = multi ? AVCaptureMultiCamSession() : AVCaptureSession()
        session = newSession; devices = chosen
        newSession.beginConfiguration()
        var committed = false
        defer { if !committed { newSession.commitConfiguration() } }
        // MultiCam is always inputPriority. Single-camera setup switches to .photo below.
        if !multi { newSession.sessionPreset = .inputPriority }
        var ports: [AVCaptureInput.Port] = []
        for (index, device) in chosen.enumerated() {
            let selection = try selectFormat(device: device, multi: multi, needsPhoto: index == 0,
                                             previewLongEdge: index == 0 ? centerPreviewLongEdge : peripheralPreviewLongEdge)
            try device.lockForConfiguration()
            device.activeFormat = selection.format
            device.videoZoomFactor = 1 // Never substitute digital telephoto or crop.
            let interval = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = interval
            device.activeVideoMaxFrameDuration = interval
            device.unlockForConfiguration()
            if index == 0 { dimensions = selection.photo }
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else { throw CameraFailure("Cannot add the requested physical camera input.") }
            newSession.addInputWithNoConnections(input)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw CameraFailure("Camera video port is unavailable.") }
            ports.append(port)
        }
        // Apple requires .photo for high-resolution single-camera capture.
        // MultiCam remains .inputPriority and exposes only its lower native ceiling.
        if !multi {
            guard newSession.canSetSessionPreset(.photo) else { throw CameraFailure("The photo preset is unavailable.") }
            newSession.sessionPreset = .photo
        }
        // A preset may select a different active format. Inspect its still ceiling;
        // independent VideoDataOutput scaling sets the preview raster below.
        let finalCenterFormat = center.activeFormat
        let nativeOptions = nativePhotoDimensions(format: finalCenterFormat, multi: multi)
        guard let largest = nativeOptions.max(by: { Self.area($0) < Self.area($1) }) else {
            throw CameraFailure("No native ProRAW photo dimensions match this configuration and framing.")
        }
        let sourceCeiling = center.formats.filter { !multi || $0.isMultiCamSupported }
            .flatMap { nativePhotoDimensions(format: $0, multi: multi) }.map(Self.area).max() ?? 0
        guard Self.area(largest) == sourceCeiling else {
            throw CameraFailure("This camera/photo configuration cannot preserve its largest native ProRAW source. Capture resolution was not lowered.")
        }
        dimensions = largest
        let output = AVCapturePhotoOutput()
        guard newSession.canAddOutput(output) else { throw CameraFailure("Photo capture is unavailable for this camera pair.") }
        newSession.addOutputWithNoConnections(output)
        let photoConnection = AVCaptureConnection(inputPorts: [ports[0]], output: output)
        guard newSession.canAddConnection(photoConnection) else { throw CameraFailure("Cannot connect the center camera to photo capture.") }
        newSession.addConnection(photoConnection)
        guard photoConnection.isVideoOrientationSupported else { throw CameraFailure("Photo orientation control is unavailable.") }
        photoOutput = output
        for (index, port) in ports.enumerated() {
            let video = AVCaptureVideoDataOutput()
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = false
            video.alwaysDiscardsLateVideoFrames = true
            guard newSession.canAddOutput(video) else { throw CameraFailure("Cannot add the independent scaled live-preview output.") }
            newSession.addOutputWithNoConnections(video)
            let connection = AVCaptureConnection(inputPorts: [port], output: video)
            guard newSession.canAddConnection(connection) else { throw CameraFailure("A physical-lens video preview connection is unavailable.") }
            newSession.addConnection(connection)
            guard connection.isVideoOrientationSupported else { throw CameraFailure("This scaled-preview connection cannot match photo orientation.") }
            // Prefer native bi-planar YCbCr rather than converting to memory-heavy BGRA.
            let supported = video.availableVideoPixelFormatTypes
            guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].first(where: { supported.contains($0) }) else {
                throw CameraFailure("The preview output exposes no supported 8-bit YCbCr format.")
            }
            let sourceVideo = CMVideoFormatDescriptionGetDimensions(chosen[index].activeFormat.formatDescription)
            let size = try Self.scaledPreviewDimensions(source: sourceVideo,
                                                       cap: index == 0 ? centerPreviewLongEdge : peripheralPreviewLongEdge)
            let delivery = CameraFrameDelivery.makeOnMainThread()
            video.setSampleBufferDelegate(delivery, queue: delivery.callbackQueue)
            previewOutputs.append(video); frameDeliveries.append(delivery)
            previewSizes.append(size); previewPixelFormats.append(pixelFormat)
        }
        guard center.activeFormat === finalCenterFormat else {
            throw CameraFailure("Adding scaled preview changed the photo source format. No lower-resolution capture was substituted.")
        }
        applyOrientation(orientation, configurationOpen: true)
        // Query only after the complete input/output graph is connected.
        guard output.isAppleProRAWSupported else {
            throw CameraFailure("Apple ProRAW is unsupported with this exact physical camera / simultaneous-preview configuration. No Bayer RAW or HEIF fallback was captured.")
        }
        output.isAppleProRAWEnabled = true
        output.maxPhotoDimensions = dimensions
        output.maxPhotoQualityPrioritization = .quality
        if output.isContentAwareDistortionCorrectionSupported { output.isContentAwareDistortionCorrectionEnabled = false }
        guard output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) else {
            throw CameraFailure("This configuration exposes no Apple ProRAW pixel format.")
        }
        newSession.commitConfiguration(); committed = true
        if let multiSession = newSession as? AVCaptureMultiCamSession,
           multiSession.hardwareCost > 1 || multiSession.systemPressureCost > 1 {
            throw CameraFailure("This full-quality camera pair exceeds the device capture budget. No lower-quality capture was substituted.")
        }
        installObservers(newSession)
        newSession.startRunning()
        guard newSession.isRunning, output.isAppleProRAWSupported, output.isAppleProRAWEnabled else {
            throw CameraFailure("The Apple ProRAW camera session could not start in this configuration.")
        }
        try waitForPreviewFrames()
        guard let geometry = geometry() else { throw CameraFailure("Photo framing is unavailable.") }
        guard center.activeFormat === finalCenterFormat else {
            throw CameraFailure("The photo preset changed the active format after configuration; this combination requires device validation.")
        }
        return Bundle(center: frameDeliveries[0].layer, periphery: frameDeliveries.count > 1 ? frameDeliveries[1].layer : nil, geometry: geometry,
                      outputOptions: Self.outputOptions(source: dimensions), physicalCameraID: center.uniqueID,
                      centerPreviewDimensions: Self.size(previewSizes[0]),
                      peripheralPreviewDimensions: previewSizes.count > 1 ? Self.size(previewSizes[1]) : nil)
    }

    private func selectFormat(device: AVCaptureDevice, multi: Bool, needsPhoto: Bool,
                              previewLongEdge: Int)
        throws -> (format: AVCaptureDevice.Format, photo: CMVideoDimensions) {
        guard (640...4096).contains(previewLongEdge) else {
            throw CameraFailure("Preview raster limit must be between 640 and 4096 pixels, independently of photo resolution.")
        }
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions)? in
            guard !multi || format.isMultiCamSupported,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return nil }
            guard let photo = nativePhotoDimensions(format: format, multi: multi).max(by: { Self.area($0) < Self.area($1) }) else { return nil }
            return (format, photo)
        }
        // Source first, preview second: reducing HEIF target never affects this choice.
        // Within the same native source ceiling prefer the smallest sensor video raster;
        // preview buffer dimensions are independently downscaled by VideoDataOutput.
        guard let chosen = candidates.max(by: {
            if needsPhoto && Self.area($0.1) != Self.area($1.1) { return Self.area($0.1) < Self.area($1.1) }
            return Self.area(CMVideoFormatDescriptionGetDimensions($0.0.formatDescription)) > Self.area(CMVideoFormatDescriptionGetDimensions($1.0.formatDescription))
        }) else {
            throw CameraFailure("No 30 fps full-photo-aspect format supports this preview limit and physical camera combination. Choose another preview limit or lens explicitly.")
        }
        return chosen
    }
    private func nativePhotoDimensions(format: AVCaptureDevice.Format, multi: Bool) -> [CMVideoDimensions] {
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard video.width > 0, video.height > 0 else { return [] }
        return format.supportedMaxPhotoDimensions.filter { photo in
            let pixels = Self.area(photo)
            guard photo.width > 0, photo.height > 0,
                  abs(Double(video.width) / Double(video.height) - Double(photo.width) / Double(photo.height)) < 0.001 else { return false }
            // Nominal MP tiers include native 4032x3024 and 8064x6048 sizes.
            // 24 MP native deferred-processed delivery is not a ProRAW source.
            let nominal = Self.nominalMegapixels(pixels)
            return nominal == 12 || (!multi && nominal == 48)
        }
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

    func applyOrientation(_ value: UIInterfaceOrientation, configurationOpen: Bool = false) {
        switch value {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return
        }
        guard let session else { return }
        if !configurationOpen { session.beginConfiguration() }
        defer { if !configurationOpen { session.commitConfiguration() } }
        // Remove explicit size keys before rotating. Otherwise the old width/height
        // can disagree with the new connection orientation and cause an Obj-C exception.
        for (index, video) in previewOutputs.enumerated() {
            video.connection(with: .video)?.isEnabled = false
            video.setSampleBufferDelegate(nil, queue: nil)
            frameDeliveries[index].callbackQueue.sync {} // Drain old-orientation callbacks.
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
            let width = Int(portrait ? size.height : size.width)
            let height = Int(portrait ? size.width : size.height)
            let readiness = previewReadiness
            readiness.enter()
            frameDeliveries[index].expect(width: width, height: height) { readiness.leave() }
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelFormats[index],
                                   kCVPixelBufferWidthKey as String: width,
                                   kCVPixelBufferHeightKey as String: height]
            video.setSampleBufferDelegate(frameDeliveries[index], queue: frameDeliveries[index].callbackQueue)
            video.connection(with: .video)?.isEnabled = true
        }
    }
    /// Each physical feed must deliver a negotiated-size frame before the shutter
    /// enables. Delegate queues signal this directly; no main-queue/frame backlog.
    func waitForPreviewFrames() throws {
        guard let session, session.isRunning, !failed,
              previewReadiness.wait(timeout: .now() + 5) == .success else {
            failed = true
            self.session?.stopRunning()
            throw CameraFailure("A physical camera preview did not deliver the negotiated frame size within 5 seconds. Capture is disabled; select the lens again to retry.")
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
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        return .init(sensorPhotoDimensions: size,
                     photoAspectRatio: portrait ? size.height / size.width : size.width / size.height,
                     centerHorizontalFieldOfView: center.activeFormat.videoFieldOfView,
                     peripheralHorizontalFieldOfView: devices.count > 1 ? devices[1].activeFormat.videoFieldOfView : nil)
    }
    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        guard !failed, captureDelegate == nil, let session, session.isRunning, !session.isInterrupted,
              let output = photoOutput, output.isAppleProRAWSupported, output.isAppleProRAWEnabled,
              let raw = output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) else {
            completion(.failure(CameraFailure("Apple ProRAW capture is currently unavailable."))); return
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        settings.maxPhotoDimensions = dimensions
        settings.photoQualityPrioritization = .quality
        settings.isAutoStillImageStabilizationEnabled = false
        settings.isAutoContentAwareDistortionCorrectionEnabled = false
        let delegate = ProRAWCapture(expectedDimensions: dimensions) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.captureDelegate = nil
                completion(result)
            }
        }
        captureDelegate = delegate
        output.capturePhoto(with: settings, delegate: delegate)
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
                        self.failed = true
                        self.failureHandler?(detail ?? "Camera interrupted. Select the lens again when available.")
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
                        self.failed = true
                        observed.stopRunning()
                        self.failureHandler?("Camera stopped due to system pressure. Let the device cool, then select the lens again. Capture quality was not reduced.")
                    }
                }
            }
        }
    }
    func stop() {
        previewOutputs.forEach { $0.setSampleBufferDelegate(nil, queue: nil) }
        frameDeliveries.forEach { $0.invalidate() }
        previewOutputs.removeAll(); frameDeliveries.removeAll(); previewSizes.removeAll(); previewPixelFormats.removeAll()
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        session?.stopRunning()
        captureDelegate?.cancel()
        captureDelegate = nil
        session = nil; photoOutput = nil; devices = []
        dimensions = CMVideoDimensions(width: 0, height: 0)
        failureHandler = nil; failed = true
    }
}

/// One request and one retained DNG. CameraFrameDelivery separately bounds previews
/// to one pending sample per lens; preview pixels never enter this photo result.
private final class ProRAWCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let lock = NSLock()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var result: Result<Data, Error>?
    private let expectedDimensions: CMVideoDimensions
    init(expectedDimensions: CMVideoDimensions, completion: @escaping (Result<Data, Error>) -> Void) {
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
        guard min(actual.width, actual.height) == min(expectedDimensions.width, expectedDimensions.height),
              max(actual.width, actual.height) == max(expectedDimensions.width, expectedDimensions.height) else {
            result = .failure(CameraFailure("The camera delivered different RAW dimensions from the requested full-quality framing. This capture was rejected.")); return
        }
        result = .success(data)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let finalResult: Result<Data, Error> = error.map { .failure($0) } ?? result ?? .failure(CameraFailure("No Apple ProRAW photo was delivered."))
        lock.unlock()
        finish(finalResult)
    }
    func cancel() { finish(.failure(CameraFailure("Camera capture cancelled."))) }
    private func finish(_ value: Result<Data, Error>) {
        lock.lock(); let callback = completion; completion = nil; result = nil; lock.unlock()
        callback?(value)
    }
}
