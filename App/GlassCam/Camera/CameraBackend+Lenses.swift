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
    private func discover(_ type: AVCaptureDevice.DeviceType) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: .back)
        guard let device = discovery.devices.first else { throw CameraFailure("The requested physical camera is unavailable.") }
        return device
    }

    func discoverLensCatalog() {
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

    func captureDevice(displayedZoom: Double) throws -> AVCaptureDevice {
        let candidates = lensCatalog.sorted { $0.displayedZoom < $1.displayedZoom }
        if let selected = candidates.last(where: { $0.displayedZoom <= displayedZoom + 0.0001 }) ?? candidates.first {
            return selected.device
        }
        return try discover(.builtInWideAngleCamera)
    }

    func displayMultiplier(_ device: AVCaptureDevice) -> Double {
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

    func zoomRange(for device: AVCaptureDevice) -> CameraZoomRange {
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

    static func framing(for device: AVCaptureDevice, catalog: [NativeLens]) -> CaptureFraming {
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
    func highResolutionConstituent(for device: AVCaptureDevice, displayedZoom: Double) -> AVCaptureDevice? {
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
}
