import AVFoundation
import Testing
import UIKit
@testable import GlassCam

struct CameraMeteringTests {
    static let source = CGRect(x: 30, y: 80, width: 300, height: 400)

    @Test(arguments: [
        (UIInterfaceOrientation.portrait, CGPoint(x: 0.75, y: 0.75)),
        (.portraitUpsideDown, CGPoint(x: 0.25, y: 0.25)),
        (.landscapeLeft, CGPoint(x: 0.75, y: 0.25)),
        (.landscapeRight, CGPoint(x: 0.25, y: 0.75))
    ])
    func displayedPoint_mapsToNativeSensorAxes(orientation: UIInterfaceOrientation, expected: CGPoint) {
        let tapped = CGPoint(x: Self.source.minX + 75, y: Self.source.minY + 300)

        let result = CameraMeteringGeometry.devicePoint(tapped, source: Self.source, orientation: orientation)

        #expect(result == expected)
    }

    @Test(arguments: [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight])
    func rotatingDisplay_keepsTargetAtTheSameSensorPoint(orientation: UIInterfaceOrientation) {
        let sensor = CGPoint(x: 0.25, y: 0.75)
        let displayed = CameraMeteringGeometry.viewPoint(sensor, source: Self.source, orientation: orientation)

        let recovered = CameraMeteringGeometry.devicePoint(displayed, source: Self.source, orientation: orientation)

        #expect(recovered == sensor)
    }

    @Test(arguments: [CGPoint(x: 10, y: 100), CGPoint(x: CGFloat.nan, y: 100), CGPoint(x: 100, y: 600)])
    func pointOutsideSource_doesNotRetargetMetering(point: CGPoint) {
        #expect(CameraMeteringGeometry.devicePoint(point, source: Self.source, orientation: .portrait) == nil)
    }

    @Test(arguments: [(Float(-4), Float(-1)), (Float(4), Float(1.5)), (Float(0.5), Float(0.5))])
    func exposureBias_respectsCameraAndUserBounds(requested: Float, expected: Float) {
        let result = CameraMetering(exposureBias: requested).clamped(minimum: -1, maximum: 1.5)

        #expect(result.exposureBias == expected)
    }

    @Test func resumingContinuous_clearsTargetAndLockWhileKeepingExposureBias() {
        let targeted = CameraMetering(point: CGPoint(x: 0.2, y: 0.3), locked: true, exposureBias: 0.7)

        let resumed = targeted.resumingContinuous()

        #expect(resumed == CameraMetering(exposureBias: 0.7))
    }
}

struct CameraGravityTests {
    @Test(arguments: [
        (Double(0), Double(-1), UIInterfaceOrientation.portrait),
        (Double(0), Double(1), .portraitUpsideDown),
        (Double(-1), Double(0), .landscapeRight),
        (Double(1), Double(0), .landscapeLeft)
    ])
    func stableGravity_selectsPhysicalOrientation(x: Double, y: Double, expected: UIInterfaceOrientation) {
        var detector = CameraGravityOrientation()
        _ = detector.update(x: x, y: y, z: 0)
        _ = detector.update(x: x, y: y, z: 0)

        let changed = detector.update(x: x, y: y, z: 0)

        #expect(changed == expected)
    }

    @Test(arguments: [(0.0, 0.0, -1.0), (0.7, 0.7, 0.0), (2.0, 0.0, 0.0), (Double.nan, 0.0, 0.0)])
    func flatDiagonalOrUnreliableMotion_preservesOrientation(x: Double, y: Double, z: Double) {
        var detector = CameraGravityOrientation()
        for _ in 0..<3 { _ = detector.update(x: 0, y: -1, z: 0) }

        let changed = detector.update(x: x, y: y, z: z)

        #expect(changed == nil)
        #expect(detector.orientation == .portrait)
    }

    @Test func interruptedCandidate_doesNotRotateOnTwoTransientSamples() {
        var detector = CameraGravityOrientation()
        _ = detector.update(x: -1, y: 0, z: 0)
        _ = detector.update(x: 0, y: 0, z: -1)
        _ = detector.update(x: -1, y: 0, z: 0)

        let changed = detector.update(x: -1, y: 0, z: 0)

        #expect(changed == nil)
        #expect(detector.orientation == nil)
    }
}

@Suite(.serialized) @MainActor
struct CameraCaptureControlTests {
    @Test func reservedCapture_freezesPhysicalOrientationWhileInterfaceRemainsPortrait() async throws {
        let harness = CameraHarness()
        await harness.ready()
        harness.controller.updatePhysicalOrientation(.landscapeRight)
        let reservation = try #require(harness.controller.reserveCapture())
        harness.controller.updatePhysicalOrientation(.portraitUpsideDown)

        harness.controller.capturePhoto(reservation: reservation) { _ in }
        await harness.drain()

        #expect(harness.backend.captureOrientation == .landscapeRight)
        #expect(harness.backend.rotations.isEmpty)
    }

    @Test func exposureCompletion_stopsHoldSteadyBeforeViewfinderRestoration() async throws {
        let harness = CameraHarness()
        await harness.ready()
        try await harness.begin { _ in }

        harness.backend.captureProgress?(.captured, "Captured")
        harness.backend.captureProgress?(.restoring, "Restoring")
        await harness.drain()

        #expect(harness.controller.exposureCompletionID != nil)
        #expect(!harness.controller.isExposing)
        #expect(harness.controller.isCapturing)
    }

    @Test func reservedCapture_rejectsLateMeteringChanges() async throws {
        let harness = CameraHarness()
        await harness.ready()
        _ = try #require(harness.controller.reserveCapture())

        harness.controller.setMetering(CameraMetering(point: CGPoint(x: 0.2, y: 0.3), locked: true))
        await harness.drain()

        #expect(harness.backend.metering.isEmpty)
    }
}
