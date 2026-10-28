import AVFoundation
import Combine
import ImageIO
import Testing
import UIKit
import ImagingCore
import Capture
import Peripheral
@testable import GlassCam

struct CameraTestFailure: Error {}

@MainActor
final class CameraHarness {
    final class Backend: CameraBackendServing {
        let queue = DispatchQueue(label: "CameraTests.backend")
        let bundle: CameraBackend.Bundle
        var rotations: [UIInterfaceOrientation] = []
        var rotate: ((UIInterfaceOrientation) throws -> Void)?
        var captureCompletion: ((CameraBackend.CaptureOutcome) -> Void)?
        init(bundle: CameraBackend.Bundle) { self.bundle = bundle }
        func configure(mode: CameraController.Mode, centerPreviewLongEdge: Int,
                       orientation: UIInterfaceOrientation, lifetime: CameraLifetime, displayedZoom: Double,
                       stateChanged: @escaping (CameraBackend.Bundle) -> Void,
                       failure: @escaping (String) -> Void) throws -> CameraBackend.Bundle { bundle }
        func stop() {}
        func rotatePreview(_ value: UIInterfaceOrientation) throws { rotations.append(value); try rotate?(value) }
        func geometry() -> CameraController.CameraGeometry? { bundle.geometry }
        func setZoom(_ displayedZoom: Double) throws -> CameraBackend.Bundle { bundle }
        func capture(quality: CaptureQuality, snapshot: CaptureSnapshot?, f5Purpose: String,
                     progress: @escaping (CameraController.CapturePhase, String) -> Void,
                     completion: @escaping (CameraBackend.CaptureOutcome) -> Void) { captureCompletion = completion }
    }
    let backend: Backend
    let controller: CameraController
    var observations: [AnyCancellable] = []
    init() {
        let bundle = CameraBackend.Bundle(center: AVSampleBufferDisplayLayer(), liveSource: LiveCameraFrameSource(),
            peripheralSource: nil, geometry: .init(sensorPhotoDimensions: CGSize(width: 8064, height: 6048), photoAspectRatio: 0.75),
            sourceCaptureDimensions: CGSize(width: 8064, height: 6048),
            outputOptions: [.init(megapixels: 24, width: 5712, height: 4284), .init(megapixels: 48, width: 8064, height: 6048)],
            physicalCameraID: "fixture-main", centerPreviewDimensions: CGSize(width: 1920, height: 1440),
            centerPreviewEncoding: "fixture", zoomRange: .main, framing: .init())
        backend = Backend(bundle: bundle)
        controller = CameraController(backend: backend, cameraAccess: .init(status: { .authorized }, request: { $0(true) }))
    }
    func ready() async {
        await withCheckedContinuation { continuation in
            let subscription = controller.$isReady.filter { $0 }.prefix(1).sink { _ in
                // Published emits before storage; resume on the next main turn.
                DispatchQueue.main.async { continuation.resume() }
            }
            observations.append(subscription)
            controller.start()
        }
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            backend.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
    func begin(completion: @escaping (Result<CapturedCameraPhoto, Error>) -> Void) async throws {
        let reservation = try #require(controller.reserveCapture())
        controller.capturePhoto(reservation: reservation, completion: completion)
        await drain()
    }
    func finish(previewReady: Bool) {
        backend.captureCompletion?(.init(result: .success(.init(data: Data([1,2,3]), dimensions: CGSize(width: 8064,height: 6048), framing: .init())),
                                        bundle: nil, previewReady: previewReady, message: nil))
    }
}

@Suite(.serialized) @MainActor
struct CameraLifecycleTests {
    @Test(arguments: [false, true])
    func committedPhoto_survivesStoppedViewOrPreviewFailure(stopped: Bool) async throws {
        let harness = CameraHarness()
        await harness.ready()
        var results: [Result<CapturedCameraPhoto, Error>] = []
        try await harness.begin { results.append($0) }
        if stopped { harness.controller.stop() }

        harness.finish(previewReady: false)
        await harness.drain()

        #expect(results.count == 1)
        #expect(try results.first?.get().data == Data([1,2,3]))
        #expect(!harness.controller.isReady)
    }

    @Test func capture_defersAndCoalescesOrientationUntilRestoration() async throws {
        let harness = CameraHarness()
        await harness.ready()
        try await harness.begin { _ in }

        harness.controller.updateOrientation(.landscapeLeft)
        harness.controller.updateOrientation(.portraitUpsideDown)
        await harness.drain()
        #expect(harness.backend.rotations.isEmpty)

        harness.finish(previewReady: true)
        await harness.drain(); await harness.drain()
        #expect(harness.backend.rotations == [.portraitUpsideDown])
    }

    @Test func rotationFailure_disablesShutter() async {
        let harness = CameraHarness()
        await harness.ready()
        harness.backend.rotate = { _ in throw CameraTestFailure() }

        harness.controller.updateOrientation(.landscapeLeft)
        await harness.drain()

        #expect(!harness.controller.isReady)
        #expect(!harness.controller.canReserveCapture)
    }

    @Test func reservation_freezesOrientationBeforeAuthorization() async throws {
        let harness = CameraHarness()
        await harness.ready()
        let reservation = try #require(harness.controller.reserveCapture())

        harness.controller.updateOrientation(.landscapeRight)
        await harness.drain()
        #expect(harness.backend.rotations.isEmpty)

        harness.controller.releaseCaptureReservation(reservation)
        await harness.drain()
        #expect(harness.backend.rotations == [.landscapeRight])
    }

    @Test func lifetimeCancellation_isImmediateAndRejectsFurtherWork() {
        let lifetime = CameraLifetime()
        lifetime.cancel()
        #expect(lifetime.isCancelled)
        #expect(throws: CameraFailure.self) { try lifetime.check() }
    }

    @Test func previewTimeout_failsWithoutAcceptingAnAbsentFrame() {
        #expect(throws: CameraFailure.self) {
            try CameraPreviewReadiness.wait(next: { .timedOut }, expired: { true }, validate: {})
        }
    }

    @Test func previewWait_observesCancellationBeforeTimeout() {
        let lifetime = CameraLifetime(); lifetime.cancel()
        #expect(throws: CameraFailure.self) {
            try CameraPreviewReadiness.wait(next: { .timedOut }, expired: { false }, validate: lifetime.check)
        }
    }

    @Test func previewFrame_stillValidatesSessionBeforeReadiness() {
        #expect(throws: CameraTestFailure.self) {
            try CameraPreviewReadiness.wait(next: { .success }, expired: { false }, validate: { throw CameraTestFailure() })
        }
    }

    @Test(arguments: [12,48])
    func unavailableSavedOutput_doesNotSelectLowerOrHigherTier(saved: Int) {
        let available = [CameraController.OutputOption(megapixels: 24,width: 5712,height: 4284)]
        #expect(CameraController.OutputOption.matching(saved,in: available) == nil)
    }
    @Test func exactSavedOutput_keepsPhysicalCameraDimensions() {
        let available = [CameraController.OutputOption(megapixels: 48,width: 8064,height: 6048)]
        #expect(CameraController.OutputOption.matching(48,in: available) == available.first)
    }

    @Test func previewCadence_prefers60Then30Then15() {
        #expect(CameraBackend.previewFrameRates == [60,30,15])
    }

    @Test(arguments: [640,1280,1920])
    func previewSize_doesNotChangeSourceDimensions(cap: Int) throws {
        let source = CMVideoDimensions(width: 8064,height: 6048)
        let preview = try CameraBackend.scaledPreviewDimensions(source: source, cap: cap)
        #expect(preview.width <= cap)
        #expect(Int(preview.width) * 3 == Int(preview.height) * 4)
        #expect(source.width == 8064)
    }
}

struct ProRAWCaptureTests {
    private let dimensions = CMVideoDimensions(width: 8, height: 6)
    private func buffer(format: OSType = kCVPixelFormatType_64RGBALE) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Int(dimensions.width), Int(dimensions.height), format, nil, &pixelBuffer)
        try #require(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }
    private func receive(_ capture: ProRAWCapture, raw: Bool = true, bytes: Data = Data([1,2,3]),
                         dimensions: CMVideoDimensions? = nil, format: OSType = kCVPixelFormatType_64RGBALE) throws {
        capture.receivePhoto(isRaw: raw, buffer: try buffer(format: format), data: { bytes },
                             actual: dimensions ?? self.dimensions, metadata: [:], error: nil)
    }
    @Test func processingResult_waitsForTerminalSuccess() throws {
        var received: [Result<CapturedProRAW, Error>] = []
        let capture = ProRAWCapture(expectedDimensions: dimensions, framing: { .init() }) { received.append($0) }
        try receive(capture)
        #expect(received.isEmpty)
        capture.finishCapture(error: nil)
        #expect(try received.first?.get().data == Data([1,2,3]))
    }
    @Test func cancellationBeforeTerminal_doesNotDeliverProvisionalPhoto() throws {
        var received: [Result<CapturedProRAW, Error>] = []
        let capture = ProRAWCapture(expectedDimensions: dimensions, framing: { .init() }) { received.append($0) }
        try receive(capture)
        capture.cancel()
        capture.finishCapture(error: nil)
        #expect(received.count == 1)
        #expect(throws: CameraFailure.self) { try received.first?.get() }
    }
    @Test func cancellationAfterTerminal_preservesPhotoAndCompletesOnce() throws {
        var received: [Result<CapturedProRAW, Error>] = []
        let capture = ProRAWCapture(expectedDimensions: dimensions, framing: { .init() }) { received.append($0) }
        try receive(capture)
        capture.finishCapture(error: nil)
        let afterStop = capture.cancel()
        capture.finishCapture(error: CameraTestFailure())
        #expect(received.count == 1)
        #expect(try afterStop.get().data == Data([1,2,3]))
    }
    @Test func terminalFailure_overridesProvisionalPhoto() throws {
        var received: Result<CapturedProRAW, Error>?
        let capture = ProRAWCapture(expectedDimensions: dimensions, framing: { .init() }) { received = $0 }
        try receive(capture)
        capture.finishCapture(error: CameraTestFailure())
        #expect(throws: CameraTestFailure.self) { try received?.get() }
    }
    @Test(arguments: ["not-raw","empty","wrong-format","resolved-size"])
    func invalidRAW_failsInsteadOfDeliveringSubstitute(kind: String) throws {
        var received: Result<CapturedProRAW, Error>?
        let capture = ProRAWCapture(expectedDimensions: dimensions, framing: { .init() }) { received = $0 }
        try receive(capture, raw: kind != "not-raw", bytes: kind == "empty" ? Data() : Data([1]),
                    dimensions: kind == "resolved-size" ? .init(width: 4, height: 3) : nil,
                    format: kind == "wrong-format" ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64RGBALE)
        capture.finishCapture(error: nil)
        #expect(throws: CameraFailure.self) { try received?.get() }
    }
}
