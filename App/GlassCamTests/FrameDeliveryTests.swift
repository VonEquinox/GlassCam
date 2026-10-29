import AVFoundation
import CoreMedia
import CoreVideo
import Testing
@testable import GlassCam
@testable import Peripheral

struct SampleFixture {
    static let width = 16, height = 12
    static func sample(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       pts: Int64 = 120, tagged: Bool = true,
                       configure: (CVPixelBuffer) -> Void = { _ in }) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, width, height, format, nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        if tagged {
            CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        configure(image)
        var description: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description) == noErr)
        let descriptionValue = try #require(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: pts, timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: descriptionValue,
                                                           sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

@Suite(.serialized) @MainActor
struct FrameDeliveryTests {
    @MainActor final class Display {
        var tasks: [@MainActor () -> Void] = []
        var received: [CMSampleBuffer] = []
        var firstFrames = 0, flushes = 0
        var ready = true
        lazy var delivery = CameraFrameDelivery(makeLayer: (), renderer: .init(needsFlush: { false }, ready: { self.ready },
            flush: { self.flushes += 1 }, enqueue: { self.received.append($0) }), scheduleMain: { self.tasks.append($0) })
        func configure() {
            delivery.expect(width: SampleFixture.width, height: SampleFixture.height,
                            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { self.firstFrames += 1 }
        }
        func drain() { let pending = tasks; tasks.removeAll(); pending.forEach { $0() } }
    }
    @Test func readiness_waitsForActualEnqueue() throws {
        let display = Display(); display.configure(); display.drain()
        display.delivery.receive(try SampleFixture.sample())
        #expect(display.firstFrames == 0)
        display.drain()
        #expect(display.firstFrames == 1)
        #expect(display.received.count == 1)
    }
    @Test func blockedRenderer_doesNotDeclarePreviewReady() throws {
        let display = Display(); display.configure(); display.ready = false
        display.delivery.receive(try SampleFixture.sample()); display.drain()
        #expect(display.firstFrames == 0)
        #expect(display.received.isEmpty)
    }
    @Test func freeze_revokesQueuedEnqueueAndFlush() throws {
        let display = Display(); display.configure()
        display.delivery.receive(try SampleFixture.sample())
        display.delivery.freeze(); display.drain()
        #expect(display.received.isEmpty)
        #expect(display.flushes == 0)
        #expect(display.firstFrames == 0)
    }
    @Test func queuedPreview_usesNewestFrameAndOriginalPTS() throws {
        let display = Display(); display.configure(); display.drain()
        display.delivery.receive(try SampleFixture.sample(pts: 120))
        display.delivery.receive(try SampleFixture.sample(pts: 180))
        display.drain()
        #expect(display.received.count == 1)
        let sample = try #require(display.received.first)
        #expect(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) == 3)
    }
    @Test func missingPeripheralSample_doesNotBlockCenterSubmission() throws {
        let display = Display(); display.configure(); display.drain()
        let source = PeripheralFrameSource(); source.configure(outputIndex: 1,ratio: 2)
        let delivery = PeripheralFrameSynchronizer(source: source,
            outputs: [AVCaptureVideoDataOutput(),AVCaptureVideoDataOutput()],deliveries: [display.delivery],clock: { nil })
        let center = try SampleFixture.sample(pts: 120)

        delivery.receiveSamples { $0 == 0 ? center : nil }
        display.drain()

        #expect(display.received.count == 1)
        #expect(display.firstFrames == 1)
    }

    @Test func mismatchedFormat_neverSignalsReadiness() throws {
        let display = Display(); display.configure()
        display.delivery.receive(try SampleFixture.sample(format: kCVPixelFormatType_32BGRA)); display.drain()
        #expect(display.received.isEmpty)
        #expect(display.firstFrames == 0)
    }
}
