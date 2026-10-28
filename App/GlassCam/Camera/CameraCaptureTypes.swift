import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

struct CameraFailure: LocalizedError {
    let message: String
    let allowsPhysicalFallback: Bool
    init(_ message: String, allowsPhysicalFallback: Bool = false) {
        self.message = message; self.allowsPhysicalFallback = allowsPhysicalFallback
    }
    var errorDescription: String? { message }
}

struct CameraAccess {
    var status: () -> AVAuthorizationStatus
    var request: (@escaping (Bool) -> Void) -> Void
    static let system = CameraAccess(status: { AVCaptureDevice.authorizationStatus(for: .video) },
                                     request: { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) })
}

protocol CameraBackendServing: AnyObject {
    var queue: DispatchQueue { get }
    func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int,
                   orientation: UIInterfaceOrientation, lifetime: CameraLifetime, displayedZoom: Double,
                   stateChanged: @escaping (CameraBackend.Bundle) -> Void,
                   failure: @escaping (String) -> Void) throws -> CameraBackend.Bundle
    func stop()
    func rotatePreview(_ value: UIInterfaceOrientation) throws
    func geometry() -> CameraController.CameraGeometry?
    func setZoom(_ displayedZoom: Double) throws -> CameraBackend.Bundle
    func capture(quality: CaptureQuality, snapshot: CaptureSnapshot?, f5Purpose: String,
                 progress: @escaping (CameraController.CapturePhase, String) -> Void,
                 completion: @escaping (CameraBackend.CaptureOutcome) -> Void)
}

/// Cross-queue cancellation only. All AVFoundation state stays on backend.queue.
final class CameraLifetime {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CameraFailure("Camera operation cancelled.") } }
}

struct CapturedProRAW {
    let data: Data
    let dimensions: CGSize
    let framing: CaptureFraming
    var burst: F5BurstSource? = nil
}
