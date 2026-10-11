import AVFoundation
import CoreMedia
import CoreVideo

/// One retained frame per physical lens; no per-frame ObservableObject updates.
/// Capture delegates run on their own serial queues. Layer access is main-only.
final class CameraFrameDelivery: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let layer: AVSampleBufferDisplayLayer
    let liveSource = LiveCameraFrameSource()
    let callbackQueue = DispatchQueue(label: "dev.glasscam.preview.\(UUID().uuidString)", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = false
    private var active = true
    private var generation: UInt64 = 0
    private var expectedWidth = 0
    private var expectedHeight = 0
    private var expectedPixelFormat: OSType = 0
    private var firstFrame: (() -> Void)?

    @MainActor private init(makeLayer: Void) {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        super.init()
    }
    /// Only called by the session queue, which never blocks the main queue waiting
    /// for a session operation. CALayer creation remains explicitly main-isolated.
    static func makeOnMainThread() -> CameraFrameDelivery {
        DispatchQueue.main.sync { MainActor.assumeIsolated { CameraFrameDelivery(makeLayer: ()) } }
    }
    func expect(width: Int, height: Int, pixelFormat: OSType, onFirstValidFrame: @escaping () -> Void) {
        lock.lock()
        expectedWidth = width; expectedHeight = height; expectedPixelFormat = pixelFormat; generation &+= 1
        firstFrame = onFirstValidFrame
        let ticket = generation
        lock.unlock()
        liveSource.reset(generation: ticket)
        DispatchQueue.main.async { [weak self] in
            self?.layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
    func invalidate() {
        lock.lock(); active = false; generation &+= 1; lock.unlock()
        liveSource.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard active, CVPixelBufferGetPixelFormatType(image) == expectedPixelFormat,
              CVPixelBufferGetWidth(image) == expectedWidth,
              CVPixelBufferGetHeight(image) == expectedHeight else { lock.unlock(); return }
        let first = firstFrame; firstFrame = nil
        // The GPU mailbox replaces stale pending frames even while the raw
        // fallback has a main closure queued. No CPU color work on this queue.
        liveSource.offer(sampleBuffer, generation: generation)
        guard !pending else { lock.unlock(); first?(); return }
        pending = true
        let ticket = generation
        lock.unlock()
        first?()
        // The sample attachment, rather than a buffer-level attachment, makes
        // live frames display immediately without introducing a playback timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // The pending gate means there can be only ONE queued main closure and
        // retained sample per lens. New frames are discarded while it is pending.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.active && self.generation == ticket
            self.lock.unlock()
            defer { self.lock.lock(); self.pending = false; self.lock.unlock() }
            guard valid else { return }
            let renderer = self.layer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            guard renderer.isReadyForMoreMediaData else { return }
            renderer.enqueue(sampleBuffer)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // No retry/backlog. The next live frame replaces a dropped frame.
    }
}
