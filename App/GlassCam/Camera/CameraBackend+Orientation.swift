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
    func applyOrientation(_ value: UIInterfaceOrientation, configurationOpen: Bool = false) {
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
    func geometry() -> CameraController.CameraGeometry? {
        guard dimensions.width > 0, dimensions.height > 0, !devices.isEmpty else { return nil }
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let size = Self.size(dimensions)
        return .init(sensorPhotoDimensions: size, photoAspectRatio: portrait ? size.height / size.width : size.width / size.height)
    }
}
