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
    /// Probe the selected physical camera in .photo first. Independent inputs
    /// keep the wider lens uncropped while the center follows the requested zoom.
    func promotePreview(configuration plan: PreviewConfiguration, orientation value: UIInterfaceOrientation,
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

    func updatePeripheralSelection() {
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

    /// Preview graphs only: capture graphs never include a preview, so this
    /// cannot cap photo exposure. activeFormat stays the .photo preset's own;
    /// a format without 60 fps keeps its default rate instead of switching.
    func applyPreviewFrameRate(_ device: AVCaptureDevice) throws {
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
    func addInput(_ device: AVCaptureDevice, to session: AVCaptureSession) throws -> AVCaptureInput.Port {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraFailure("Cannot add the requested physical camera input.") }
        session.addInputWithNoConnections(input)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw CameraFailure("Camera video port is unavailable.") }
        return port
    }
    func addPreview(port: AVCaptureInput.Port, device: AVCaptureDevice, cap: Int,
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
    func negotiatePreviewPixelFormats() throws {
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
    static func previewEncoding(_ format: OSType) -> String {
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
    func previewBundle() throws -> Bundle {
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
}
