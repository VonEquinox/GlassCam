import ImagingCore
import Capture
import F5
import Peripheral
#if os(iOS)
import AVFoundation
import ImageIO
import Darwin

enum F5DeviceFacts {
    static func sysctl(_ key: String) -> String {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &buffer, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
    static var hardware: String { sysctl("hw.machine") }
    static var osBuild: String { sysctl("kern.osversion") }
    static func cameraID(_ camera: AVCaptureDevice) -> String { F5Hash.data(Data(camera.uniqueID.utf8)) }
    static func signature(_ camera: AVCaptureDevice) throws -> String {
        let f = camera.activeFormat, dimensions = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let value: [String: Any] = ["deviceType": camera.deviceType.rawValue,
            "subtype": CMFormatDescriptionGetMediaSubType(f.formatDescription),
            "width": dimensions.width, "height": dimensions.height, "fieldOfView": f.videoFieldOfView,
            "minISO": f.minISO, "maxISO": f.maxISO,
            "minExposure": CMTimeGetSeconds(f.minExposureDuration), "maxExposure": CMTimeGetSeconds(f.maxExposureDuration),
            "photoDimensions": f.supportedMaxPhotoDimensions.map { [Int($0.width), Int($0.height)] }]
        return F5Hash.data(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}

/// The serial camera backend owns this driver and its ordinary photo session.
/// The delegate copies sensor integers before returning to AVFoundation.
final class F5CaptureDriver: NSObject, AVCapturePhotoCaptureDelegate {
    private let queue: DispatchQueue, camera: AVCaptureDevice, output: AVCapturePhotoOutput
    private let transaction: F5BurstTransaction
    private let snapshot: CaptureSnapshot?, purpose: String
    private let metering: CameraMetering, lockedMetering: CameraMeteringLock?
    private let exposureCompleted: () -> Void
    private let progress: (String) -> Void, framing: () -> CaptureFraming
    private let cancelled: () -> Bool
    private var completion: ((Result<F5BurstSource, Error>) -> Void)?
    private var settings: [AVCapturePhotoBracketSettings] = []
    private var groupIndex = 0
    private var flags = Set<F5Code>(), profile: F5DeviceProfile?
    private var originalSignature = "", rawType: OSType = 0, lockedISO: Float = 0
    private var lockedAperture: Float = 0, lockedFocus: Float = 0, oisPolicy = "unavailable"
    private var exposurePlan: F5ExposurePlan?
    private var settleNotBefore=DispatchTime.now(),stableMeterSince:DispatchTime?
    private let terminalLock = NSLock()
    private var terminal: Result<F5BurstSource, Error>?

    init(queue: DispatchQueue, camera: AVCaptureDevice, output: AVCapturePhotoOutput,
         snapshot: CaptureSnapshot?, purpose: String = "product", metering: CameraMetering,
         lockedMetering: CameraMeteringLock?, framing: @escaping () -> CaptureFraming,
         exposureCompleted: @escaping () -> Void,
         cancelled: @escaping () -> Bool, progress: @escaping (String) -> Void,
         completion: @escaping (Result<F5BurstSource, Error>) -> Void) throws {
        self.queue = queue; self.camera = camera; self.output = output; self.snapshot = snapshot; self.purpose = purpose
        self.metering = metering; self.lockedMetering = lockedMetering; self.exposureCompleted = exposureCompleted
        self.framing = framing; self.cancelled = cancelled; self.progress = progress; self.completion = completion
        transaction = try F5BurstTransaction(snapshot: snapshot, purpose: purpose)
        super.init()
    }
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            guard camera.deviceType == .builtInWideAngleCamera, !camera.isVirtualDevice,
                  abs(camera.videoZoomFactor - 1) < 0.00001,
                  output.connection(with: .video).map({ abs($0.videoScaleAndCropFactor - 1) < 0.00001 }) == true else {
                throw F5Failure(.mainCameraOnly, "F5 currently uses the physical main camera at its native field of view.")
            }
            guard !output.isAppleProRAWEnabled,
                  let raw = output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat),
                  camera.isExposureModeSupported(.custom), camera.isFocusModeSupported(.locked), camera.isWhiteBalanceModeSupported(.locked) else {
                throw F5Failure(.unsupportedRAW, "This configuration cannot deliver manually exposed, independent Bayer RAW.")
            }
            rawType = raw; originalSignature = try F5DeviceFacts.signature(camera)
            _ = try F5ExposurePlan.groups(maxBracketCount: output.maxBracketedCapturePhotoCount, frameCount: transaction.frameCount)
            oisPolicy = output.isLensStabilizationDuringBracketedCaptureSupported ? "on" : "unavailable"
            if purpose == "product", transaction.frameCount == 5 {
                profile = F5ProfileStore.candidates(hardware: F5DeviceFacts.hardware, os: F5DeviceFacts.osBuild,
                    physicalCameraID: F5DeviceFacts.cameraID(camera)).first {
                    $0.formatSignature == originalSignature && $0.rawFourCC == raw && $0.oisPolicy == oisPolicy
                }
                guard profile != nil else { throw F5Failure(.unqualified, "Import the accepted iPhone 18 Pro Max main-camera profile before making F5 photographs. The sample recorder remains available.") }
            }
            progress(String(localized: "Focusing and metering. Hold steady…"))
            try camera.lockForConfiguration()
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {camera.whiteBalanceMode = .continuousAutoWhiteBalance}
            camera.unlockForConfiguration()
            settleNotBefore = .now()+0.3;stableMeterSince=nil
            if let lockedMetering {
                try lockedMetering.validate(on: camera)
                try camera.lockForConfiguration()
                camera.setFocusModeLocked(lensPosition: lockedMetering.lensPosition) { [weak self] _ in
                    self?.queue.async { [weak self] in self?.restoreLockedExposure() }
                }
                camera.unlockForConfiguration()
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.completion != nil, self.exposurePlan == nil else { return }
                    self.finish(.failure(F5Failure(.motionUncertain, "The camera could not restore the exposure lock.")))
                }
            } else {
                try metering.apply(to: camera)
                waitForMeter(deadline: .now() + 8)
            }
        } catch { finish(.failure(error)) }
    }
    private func restoreLockedExposure() {
        guard completion != nil, let lockedMetering else { return }
        do {
            try check()
            try camera.lockForConfiguration()
            camera.setExposureModeCustom(duration: lockedMetering.duration, iso: lockedMetering.iso) { [weak self] _ in
                self?.queue.async { [weak self] in self?.waitForMeter(deadline: .now() + 8) }
            }
            camera.unlockForConfiguration()
        } catch { finish(.failure(error)) }
    }
    private func check() throws {
        if cancelled() { throw F5Failure(.cancelled, "Capture cancelled; existing frames were retained.") }
        if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious {
            throw F5Failure(.thermalLimit, "Allow the camera to cool before a Bayer RAW capture.")
        }
        guard try F5DeviceFacts.signature(camera) == originalSignature, camera.deviceType == .builtInWideAngleCamera,
              camera.videoZoomFactor == 1, !output.isAppleProRAWEnabled else { throw F5Failure(.physicalCameraChanged, "The Bayer source configuration changed.") }
    }
    private func waitForMeter(deadline: DispatchTime) {
        guard completion != nil else { return }
        do {
            try check()
            let adjusting=camera.isAdjustingExposure || camera.isAdjustingFocus || camera.isAdjustingWhiteBalance
            if adjusting {stableMeterSince=nil}
            else if stableMeterSince==nil {stableMeterSince = .now()}
            if adjusting || DispatchTime.now()<settleNotBefore || DispatchTime.now() < (stableMeterSince ?? .now())+0.15 {
                guard DispatchTime.now() < deadline else { throw F5Failure(.motionUncertain, "Main-camera metering or focus did not settle.") }
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitForMeter(deadline: deadline) }
                return
            }
            let format = camera.activeFormat, iso = camera.iso
            let plan = try transaction.frameCount == 5 ? F5ExposurePlan.make(ae: CMTimeGetSeconds(camera.exposureDuration), iso: Double(iso),
                minimum: CMTimeGetSeconds(format.minExposureDuration), maximum: CMTimeGetSeconds(format.maxExposureDuration),
                // CMTime precision is not a calibrated sensor exposure quantum.
                // Delivery is audited independently against the request.
                quantum: 1e-9, certifiedMotionCap: profile?.handheldMaxExposure, allowClampedProbe: purpose == "probe") :
                F5ExposurePlan.equal(ae: CMTimeGetSeconds(camera.exposureDuration), iso: Double(iso),
                    minimum: CMTimeGetSeconds(format.minExposureDuration), maximum: CMTimeGetSeconds(format.maxExposureDuration))
            if let profile {
                guard (profile.isoRange[0]...profile.isoRange[1]).contains(Double(iso)),
                      (profile.focusRange[0]...profile.focusRange[1]).contains(Double(camera.lensPosition)),
                      abs(profile.aperture - Double(camera.lensAperture)) <= 0.001 else {
                    throw F5Failure(.profileMismatch, "Metered ISO, focus, or aperture lies outside the calibrated main-camera profile.")
                }
            }
            exposurePlan = plan; flags = plan.flags; lockedISO = iso
            lockedAperture = camera.lensAperture; lockedFocus = camera.lensPosition
            try camera.lockForConfiguration()
            camera.focusMode = .locked; camera.whiteBalanceMode = .locked
            camera.setExposureModeCustom(duration: CMTime(seconds: plan.main, preferredTimescale: 1_000_000_000), iso: iso) { [weak self] _ in
                self?.queue.async { [weak self] in self?.prepareRequests() }
            }
            camera.unlockForConfiguration()
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.completion != nil, self.settings.isEmpty else { return }
                self.finish(.failure(F5Failure(.frameMissing, "Exposure lock timed out; no replacement exposures were made.")))
            }
        } catch { finish(.failure(error)) }
    }
    private func prepareRequests() {
        guard completion != nil, settings.isEmpty, let plan = exposurePlan else { return }
        do {
            try check()
            let groups = try F5ExposurePlan.groups(maxBracketCount: output.maxBracketedCapturePhotoCount, frameCount: transaction.frameCount)
            let durations = transaction.frameCount == 5 ? plan.durations : Array(repeating: plan.main, count: transaction.frameCount)
            guard let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.filter({
                abs(Double($0.width) * Double($0.height) / 12_000_000 - 1) <= 0.08
            }).max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else {
                throw F5Failure(.unsupportedRAW, "This camera does not expose a 12 MP Bayer capture size.")
            }
            for indices in groups {
                let exposures = indices.map { AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(seconds: durations[$0], preferredTimescale: 1_000_000_000), iso: lockedISO) }
                let request = AVCapturePhotoBracketSettings(rawPixelFormatType: rawType, processedFormat: nil, bracketedSettings: exposures)
                request.photoQualityPrioritization = .speed
                request.maxPhotoDimensions = dimensions
                // A RAW-only bracket intrinsically excludes flash and Live Photo;
                // assigning those unsupported bracket properties can throw in AVF.
                request.isAutoContentAwareDistortionCorrectionEnabled = false
                if output.isLensStabilizationDuringBracketedCaptureSupported { request.isLensStabilizationEnabled = true }
                try transaction.register(requestID: request.uniqueID, indices: indices)
                settings.append(request)
            }
            output.setPreparedPhotoSettingsArray(settings) { [weak self] prepared, error in
                self?.queue.async { [weak self] in
                    guard let self, self.completion != nil else { return }
                    if let error { self.finish(.failure(error)); return }
                    guard prepared else { self.finish(.failure(F5Failure(.memoryPressure, "AVFoundation could not preallocate the Bayer bracket."))); return }
                    self.submitWhenReady(deadline: .now() + 8)
                }
            }
        } catch { finish(.failure(error)) }
    }
    private func submitWhenReady(deadline: DispatchTime) {
        guard completion != nil, groupIndex < settings.count else { return }
        do {
            try check()
            guard output.captureReadiness == .ready else {
                guard DispatchTime.now() < deadline else { throw F5Failure(.frameMissing, "Bayer capture readiness timed out.") }
                queue.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.submitWhenReady(deadline: deadline) }
                return
            }
            let current = groupIndex
            progress(String(localized: "Capturing \(transaction.frameCount) Bayer RAW frame(s)…"))
            output.capturePhoto(with: settings[current], delegate: self)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.completion != nil, self.groupIndex == current else { return }
                self.finish(.failure(F5Failure(.frameMissing, "A bracket did not finish. Delivered frames were kept; no replacement was requested.")))
            }
        } catch { finish(.failure(error)) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard photo.isRawPhoto else { return }
        do {
            guard let dng=photo.fileDataRepresentation(),!dng.isEmpty else {throw F5Failure(.unsupportedRAW,"The callback did not contain an original RAW file.")}
            let requestID=photo.resolvedSettings.uniqueID,sequence=photo.sequenceCount
            let extractedBuffer: Result<(mosaic: Data, width: Int, height: Int, stride: Int, format: OSType), Error>
            if let error {
                extractedBuffer = .failure(error)
            } else if let buffer = photo.pixelBuffer, AVCapturePhotoOutput.isBayerRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer)) {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
                let format = CVPixelBufferGetPixelFormatType(buffer)
                if [kCVPixelFormatType_14Bayer_RGGB, kCVPixelFormatType_14Bayer_GRBG, kCVPixelFormatType_14Bayer_BGGR, kCVPixelFormatType_14Bayer_GBRG].contains(format),
                   !CVPixelBufferIsPlanar(buffer), width > 0, height > 0, stride >= width * 2,
                   height <= Int.max / stride, stride * height <= 128 * 1024 * 1024 {
                    if CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess {
                        if let address = CVPixelBufferGetBaseAddress(buffer) {
                            let mosaic = Data(bytes: address, count: stride * height)
                            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                            extractedBuffer = .success((mosaic, width, height, stride, format))
                        } else {
                            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                            extractedBuffer = .failure(F5Failure(.unsupportedRAW, "Missing Bayer plane."))
                        }
                    } else {
                        extractedBuffer = .failure(F5Failure(.memoryPressure, "Cannot map the Bayer buffer."))
                    }
                } else {
                    extractedBuffer = .failure(F5Failure(.unsupportedRAW, "Unqualified Bayer buffer layout."))
                }
            } else {
                extractedBuffer = .failure(F5Failure(.unsupportedRAW, "The callback did not contain a standard Bayer buffer."))
            }
            let timestamp = CMTimeGetSeconds(photo.timestamp), callback = ProcessInfo.processInfo.systemUptime
            let lens = F5DeviceFacts.cameraID(camera), aperture = Double(camera.lensAperture), focus = Double(camera.lensPosition)
            let ois = photo.lensStabilizationStatus
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let (mosaic, width, height, stride, format): (Data, Int, Int, Int, OSType)
                    switch extractedBuffer {
                    case .success(let payload):
                        (mosaic, width, height, stride, format) = payload
                    case .failure(let failure):
                        _ = try? self.transaction.retainDelivery(requestID: requestID, sequenceCount: sequence, dng: dng)
                        throw failure
                    }
                    let delivery = try self.transaction.retainDelivery(requestID: requestID, sequenceCount: sequence, dng: dng, mosaic: mosaic)
                    guard self.completion != nil else { return }
                    try self.check()
                    let index = try self.transaction.plannedIndex(requestID: requestID, sequenceCount: sequence)
                    let metadata = try F5DNGMetadata.read(dng)
                    try F5BayerLayout.validate(fourCC:format,metadata:metadata)
                    guard metadata.width == width, metadata.height == height, let actualTime = metadata.exposureTime,
                          let actualISO = metadata.iso, let actualAperture = metadata.aperture,
                          abs(actualAperture - aperture) <= 0.001 else { throw F5Failure(.damagedBundle, "Actual RAW exposure, ISO, aperture, or dimensions are missing or inconsistent.") }
                    if abs(focus - Double(self.lockedFocus)) > 0.001 { self.flags.insert(.focusChanged) }
                    if abs(aperture - Double(self.lockedAperture)) > 0.001 { self.flags.insert(.apertureChanged) }
                    if self.oisPolicy == "on", ois == .off || ois == .unsupported { self.flags.insert(.profileMismatch) }
                    let raster = F5RasterDescriptor(width: width, height: height, rowBytes: stride, byteOrder: .little,
                        activeArea: metadata.activeArea, cfa: metadata.cfa, orientation: metadata.orientation, bitsPerSample: metadata.bits)
                    let frame = F5FrameRecord(id: "\(self.transaction.id.uuidString)-\(index)", requestID: requestID, burstIndex: index,
                        sequenceCount: sequence, role: self.transaction.frameCount == 5 && index == 2 ? .short : .main, physicalCameraID: lens,
                        formatSignature: self.originalSignature, rawFourCC: format,
                        dng: delivery.dng, mosaic: delivery.mosaic!, raster: raster,
                        requestedExposure: self.transaction.frameCount == 5 ? self.exposurePlan!.durations[index] : self.exposurePlan!.main, actualExposure: actualTime, actualISO: actualISO,
                        aperture: actualAperture, focus: focus, oisPolicy: self.oisPolicy,
                        timestamp: timestamp, callbackUptime: callback, clockID: "AVCapturePhoto.sessionClock", rollingShutterLineTime: nil, metadata: metadata,
                        requestedISO: Double(self.lockedISO))
                    if let profile = self.profile, !profile.matches(frame, hardware: F5DeviceFacts.hardware, os: F5DeviceFacts.osBuild) {
                        self.flags.insert(.profileMismatch)
                    }
                    try self.transaction.append(frame, dng: dng, mosaic: mosaic)
                    self.progress(String(localized: "Retained RAW \(index + 1) of \(self.transaction.frameCount)"))
                } catch { self.finish(.failure(error)) }
            }
        } catch { queue.async { [weak self] in self?.finish(.failure(error)) } }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        queue.async { [weak self] in
            guard let self, self.completion != nil, self.groupIndex < self.settings.count,
                  self.settings[self.groupIndex].uniqueID == id else { return }
            do {
                try self.transaction.finishRequest(id, error: error); self.groupIndex += 1
                if self.groupIndex == self.settings.count {
                    self.exposureCompleted()
                    let source = try self.transaction.commit(hardware: F5DeviceFacts.hardware, osBuild: F5DeviceFacts.osBuild,
                        synthetic: false, flags: self.flags, profile: self.profile, framing: self.framing())
                    self.finish(.success(source))
                } else { self.submitWhenReady(deadline: .now() + 8) }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<F5BurstSource, Error>) {
        guard let callback = completion else { return }
        completion = nil
        if case .failure(let error) = result { transaction.cancel((error as? F5Failure)?.code ?? .frameMissing) }
        terminalLock.lock(); terminal = result; terminalLock.unlock()
        callback(result)
    }
    @discardableResult func cancel() -> Result<F5BurstSource, Error> {
        terminalLock.lock(); let value = terminal; terminalLock.unlock()
        if let value { return value }
        let failure: Result<F5BurstSource, Error> = .failure(F5Failure(.cancelled, "F5 capture cancelled; delivered frames were retained."))
        finish(failure); return failure
    }
}
#endif
