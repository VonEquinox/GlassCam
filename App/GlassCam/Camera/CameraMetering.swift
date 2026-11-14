import AVFoundation
import CoreGraphics
import UIKit

struct CameraMetering: Equatable {
    var point: CGPoint?
    var locked = false
    var exposureBias: Float = 0

    static let automatic = CameraMetering()

    var isValid: Bool {
        exposureBias.isFinite && (point.map {
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        } ?? !locked)
    }

    func clamped(minimum: Float, maximum: Float) -> CameraMetering {
        var result = self
        let limits = Self.biasRange(minimum: minimum, maximum: maximum) ?? 0...0
        result.exposureBias = min(limits.upperBound, max(limits.lowerBound, exposureBias))
        return result
    }
    static func biasRange(minimum: Float, maximum: Float) -> ClosedRange<Float>? {
        guard minimum.isFinite, maximum.isFinite, max(-2, minimum) <= min(2, maximum) else { return nil }
        return max(-2, minimum)...min(2, maximum)
    }

    func resumingContinuous() -> CameraMetering {
        CameraMetering(exposureBias: exposureBias)
    }

    func apply(to device: AVCaptureDevice, refocus: Bool = true) throws {
        guard Self.biasRange(minimum: device.minExposureTargetBias, maximum: device.maxExposureTargetBias) != nil else {
            throw CameraFailure("No supported exposure bias range.", userMessage: String(localized: "Exposure adjustment is unavailable on this camera."))
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let target = point ?? CGPoint(x: 0.5, y: 0.5)
        if refocus {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target }
            let focus: AVCaptureDevice.FocusMode = point == nil ? .continuousAutoFocus : .autoFocus
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
        }
        let exposure: AVCaptureDevice.ExposureMode = point == nil ? .continuousAutoExposure : .autoExpose
        if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
        let value = clamped(minimum: device.minExposureTargetBias, maximum: device.maxExposureTargetBias)
        device.setExposureTargetBias(value.exposureBias, completionHandler: nil)
        device.isSubjectAreaChangeMonitoringEnabled = point != nil && !locked
    }
}

/// Device points always use the unmirrored, home-button-on-the-right sensor
/// coordinates. The display layer contains already rotated sample buffers.
enum CameraMeteringGeometry {
    static func devicePoint(_ point: CGPoint, source: CGRect,
                            orientation: UIInterfaceOrientation) -> CGPoint? {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0,
              point.x.isFinite, point.y.isFinite, source.contains(point) else { return nil }
        let x = (point.x - source.minX) / source.width
        let y = (point.y - source.minY) / source.height
        switch orientation {
        case .portrait: return CGPoint(x: y, y: 1 - x)
        case .portraitUpsideDown: return CGPoint(x: 1 - y, y: x)
        case .landscapeLeft: return CGPoint(x: 1 - x, y: 1 - y)
        case .landscapeRight: return CGPoint(x: x, y: y)
        default: return nil
        }
    }

    static func viewPoint(_ point: CGPoint, source: CGRect,
                          orientation: UIInterfaceOrientation) -> CGPoint {
        let normalized: CGPoint
        switch orientation {
        case .portrait: normalized = CGPoint(x: 1 - point.y, y: point.x)
        case .portraitUpsideDown: normalized = CGPoint(x: point.y, y: 1 - point.x)
        case .landscapeLeft: normalized = CGPoint(x: 1 - point.x, y: 1 - point.y)
        default: normalized = point
        }
        return CGPoint(x: source.minX + normalized.x * source.width,
                       y: source.minY + normalized.y * source.height)
    }
}

struct CameraMeteringLock {
    let duration: CMTime
    let iso: Float
    let lensPosition: Float

    init(device: AVCaptureDevice) {
        duration = device.exposureDuration
        iso = device.iso
        lensPosition = device.lensPosition
    }

    func validate(on device: AVCaptureDevice) throws {
        let format = device.activeFormat
        guard iso.isFinite, (format.minISO...format.maxISO).contains(iso),
              duration.isNumeric, duration >= format.minExposureDuration, duration <= format.maxExposureDuration,
              device.isLockingFocusWithCustomLensPositionSupported,
              device.isExposureModeSupported(.custom) else {
            throw CameraFailure("Unsupported locked lens position, duration or ISO.",
                userMessage: String(localized: "The camera cannot keep this exposure lock. Unlock AE/AF and try again."))
        }
    }
}
