import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore

/// Retains the original tagged buffer and timing. AVCapture has already applied
/// rotation/mirroring to the delivered raster; never rotate or flip it again.
final class LiveCameraFrame {
    let pixelBuffer: CVPixelBuffer
    let formatDescription: CMVideoFormatDescription
    let presentationTime: CMTime
    // Local monotonic receipt time is only a freshness watchdog. Keep the real
    // capture presentationTime separately; never substitute this for capture PTS.
    let receivedHostTime: CFTimeInterval
    let generation: UInt64
    let cleanRect: CGRect
    init?(sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        self.pixelBuffer = pixelBuffer
        self.formatDescription = format
        self.presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        self.receivedHostTime = CACurrentMediaTime()
        self.generation = generation
        self.cleanRect = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: false)
    }
}

/// One REPLACEABLE pending frame, distinct from the raw fallback display layer.
/// Only the renderer takes frames. Capture never waits for a drawable/the GPU.
final class LiveCameraFrameSource {
    private let lock = NSLock()
    private var latestFrame: LiveCameraFrame?
    private var generation: UInt64 = 0
    private var active = true
    private var enabled = false

    func reset(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; active = true; latestFrame = nil
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; generation &+= 1; latestFrame = nil
    }
    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
        if !enabled { latestFrame = nil }
    }
    func offer(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard active, enabled, self.generation == generation else { return }
        latestFrame = LiveCameraFrame(sampleBuffer: sampleBuffer, generation: generation)
    }
    func takeLatest() -> LiveCameraFrame? {
        lock.lock(); defer { lock.unlock() }
        guard active, enabled else { latestFrame = nil; return nil }
        let frame = latestFrame; latestFrame = nil
        return frame
    }
    func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return generation
    }
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active && enabled && self.generation == generation
    }
}
