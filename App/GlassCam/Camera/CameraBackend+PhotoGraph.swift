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
    /// Creates only an ordinary .photo session. The previous graph must already
    /// have stopped and released all inputs/outputs; two sessions never own a lens.
    @discardableResult
    func buildSinglePhotoGraph(configuration plan: PreviewConfiguration, orientation value: UIInterfaceOrientation,
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
        if center.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { center.whiteBalanceMode = .continuousAutoWhiteBalance }
        center.unlockForConfiguration()
        if !bayer { try applyPreviewMetering(to: center) }
        let output = AVCapturePhotoOutput()
        guard newSession.canAddOutput(output) else { throw CameraFailure("Single-camera photo capture is unavailable.") }
        newSession.addOutputWithNoConnections(output)
        let photoConnection = AVCaptureConnection(inputPorts: [port], output: output)
        guard newSession.canAddConnection(photoConnection) else { throw CameraFailure("Cannot connect the physical camera to photo capture.") }
        newSession.addConnection(photoConnection)
        guard photoConnection.isVideoOrientationSupported else { throw CameraFailure("Photo orientation control is unavailable.") }
        photoOutput = output
        output.maxPhotoQualityPrioritization = .speed
        output.isAppleProRAWEnabled = false
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
        guard !bayer || output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
            throw CameraFailure("This camera exposes no Bayer RAW format.", allowsPhysicalFallback: center.isVirtualDevice)
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
              !output.isAppleProRAWEnabled else {
            throw CameraFailure("Starting the photo graph changed its source configuration. No lower-resolution capture was substituted.")
        }
        try validate(try photoCapability(center), matches: photo)
        return photo
    }
    func photoCapability(_ center: AVCaptureDevice) throws -> PhotoCapability {
        let format = center.activeFormat
        guard format.videoFieldOfView.isFinite, format.videoFieldOfView > 0, format.videoFieldOfView < 180 else {
            throw CameraFailure("The physical camera did not report a usable photo field of view.")
        }
        guard let largest = nativePhotoDimensions(format: format).max(by: { Self.area($0) < Self.area($1) }) else {
            throw CameraFailure("The photo format has no full-framing source dimensions.")
        }
        return PhotoCapability(physicalCameraID: center.uniqueID, dimensions: largest,
                               horizontalFieldOfView: format.videoFieldOfView, zoom: center.videoZoomFactor)
    }
    func validate(_ actual: PhotoCapability, matches expected: PhotoCapability) throws {
        guard actual.physicalCameraID == expected.physicalCameraID,
              actual.dimensions.width == expected.dimensions.width, actual.dimensions.height == expected.dimensions.height,
              abs(actual.horizontalFieldOfView - expected.horizontalFieldOfView) < 0.1,
              abs(actual.zoom - expected.zoom) < 0.0001 else {
            throw CameraFailure("The single-camera photo graph changed the lens, zoom, framing, or native resolution. No substitute photo was captured.")
        }
    }
    func nativePhotoDimensions(format: AVCaptureDevice.Format) -> [CMVideoDimensions] {
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return format.supportedMaxPhotoDimensions.filter { photo in
            guard Self.sameAspect(video, photo) else { return false }
            // Native 24MP deferred processed delivery is not a ProRAW source.
            let nominal = Self.nominalMegapixels(Self.area(photo))
            return nominal == 12 || nominal == 48
        }
    }
    static func sameAspect(_ a: CMVideoDimensions, _ b: CMVideoDimensions) -> Bool {
        a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 &&
        abs(Double(a.width) / Double(a.height) - Double(b.width) / Double(b.height)) < 0.001
    }
    private static func nominalMegapixels(_ pixels: Int64) -> Int? {
        [12, 24, 48].first { abs(Double(pixels) / (Double($0) * 1_000_000) - 1) <= 0.08 }
    }
    static func size(_ dimensions: CMVideoDimensions) -> CGSize {
        CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }
    static func area(_ size: CMVideoDimensions) -> Int64 { Int64(size.width) * Int64(size.height) }
}
