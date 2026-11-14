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
    func captureF5(_ request: CaptureRequest, snapshot: CaptureSnapshot?, f5Purpose: String) throws {
        guard let main = lensCatalog.first(where:{$0.device.deviceType == .builtInWideAngleCamera && !$0.device.isVirtualDevice}),
              abs(request.configuration.displayedZoom-main.displayedZoom)<0.0001 else {
            throw F5Failure(.mainCameraOnly, "Select the main camera's native view for Bayer RAW.")
        }
        let current=main.device
        request.restoresPreviewGraph = true
        request.progress(.preparing, String(localized: "Preparing RAW capture. Hold steady…"))
        tearDownGraph(preservingPreview: true)
        let photo = try buildSinglePhotoGraph(configuration: request.configuration, orientation: request.orientation,
            expected: nil, includePreview: false, forcedDevice: current, bayer: true)
        self.capability = photo; dimensions = photo.dimensions; request.capability = photo
        guard let output = photoOutput else { throw F5Failure(.unsupportedRAW, "Missing Bayer photo output.") }
        let catalog = lensCatalog
        let driver = try F5CaptureDriver(queue: queue, camera: current, output: output,
            snapshot: snapshot, purpose: f5Purpose, metering: request.metering, lockedMetering: lockedMetering,
            framing: { Self.framing(for: current, catalog: catalog) },
            exposureCompleted: {
                request.progress(.captured, String(localized: "Capture complete. You can move the camera."))
            },
            cancelled: { request.lifetime.isCancelled }, progress: { request.progress(.capturing, $0) }) { [weak self, weak request] result in
            guard let self, let request else { return }
            self.queue.async { [weak self, weak request] in
                guard let self, let request, self.currentRequest === request else { return }
                self.finishPhoto(result.map(Self.burstPhoto), request: request)
            }
        }
        f5Capture = driver; phase = .capturing; driver.start()
    }
    static func burstPhoto(_ source: F5BurstSource) -> CapturedBayerRAW {
        let frame = source.manifest.frames.first(where: { $0.burstIndex == 1 }) ?? source.manifest.frames[0]
        var framing = source.manifest.framing
        framing.deliveredWidth = frame.raster.activeArea.width; framing.deliveredHeight = frame.raster.activeArea.height
        framing.nativePixelCount = frame.raster.activeArea.width * frame.raster.activeArea.height
        return .init(data: Data(), dimensions: CGSize(width: frame.raster.activeArea.width, height: frame.raster.activeArea.height), framing: framing, burst: source)
    }
}
