import AVFoundation
import Foundation
import OSLog

extension CameraBackend {
    var meteringDevice: AVCaptureDevice? { synchronizedPreviewDevice ?? devices.first }

    func setMetering(_ requested: CameraMetering) throws -> CameraMetering {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .preview, currentRequest == nil, requested.isValid,
              let device = meteringDevice else {
            throw CameraFailure("Metering request rejected outside an active preview.",
                userMessage: String(localized: "Wait for the camera before adjusting focus."))
        }
        try validateRunningGraph()
        let value = requested.clamped(minimum: device.minExposureTargetBias, maximum: device.maxExposureTargetBias)
        let refocus = value.point != metering.point || value.locked != metering.locked
        try value.apply(to: device, refocus: refocus)
        metering = value; lockedMetering = nil; meteringChangedAt = .now()
        return value
    }

    func applyPreviewMetering(to device: AVCaptureDevice) throws {
        guard metering.locked, let lockedMetering else {
            try metering.apply(to: device)
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isVirtualDevice {
            // The primary main lens retains the just-used RAW focus and
            // exposure while the virtual input regains its constituent ports.
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        } else {
            try lockedMetering.validate(on: device)
            device.setFocusModeLocked(lensPosition: lockedMetering.lensPosition, completionHandler: nil)
            device.setExposureModeCustom(duration: lockedMetering.duration, iso: lockedMetering.iso, completionHandler: nil)
        }
        device.isSubjectAreaChangeMonitoringEnabled = false
    }

    func resumeContinuousMetering() {
        guard phase == .preview, !metering.locked, metering.point != nil else { return }
        do {
            _ = try setMetering(metering.resumingContinuous())
            publishMetering()
        } catch { Self.logger.notice("Could not resume camera metering: \(error.localizedDescription, privacy: .public)") }
    }

    func publishMetering() {
        guard phase == .preview, let bundle = try? previewBundle() else { return }
        stateChanged?(bundle)
    }
}
