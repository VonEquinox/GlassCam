import Testing
import Foundation
import CoreMedia
import simd
@testable import Peripheral

struct PeripheralMailboxTests {
    typealias F = PeripheralFixtures
    @Test func pairedSamples_keepOriginalPTSAndCannotBeReused() throws {
        let source = PeripheralFrameSource(); source.configure(outputIndex: 1, ratio: 2)
        let selection = source.selection()
        source.offer(center: try F.sample(time: 1), outer: try F.sample(time: 1.004), selection: selection, receipt: 100)
        let first = try #require(source.latest())
        source.offer(center: try F.sample(time: 1), outer: try F.sample(time: 1.004), selection: selection, receipt: 100.01)
        #expect(first.serial == 1)
        #expect(abs(try #require(first.ptsDelta) - 0.004) < 0.00001)
        #expect(source.latest()?.serial == 1)
    }
    @Test func reset_rejectsOldEpochCallbacks() throws {
        let source = PeripheralFrameSource(); source.configure(outputIndex: 1, ratio: 2)
        let selection = source.selection(); source.reset()
        source.offer(center: try F.sample(time: 2), outer: try F.sample(time: 2), selection: selection, receipt: 100.02)
        #expect(source.latest() == nil)
    }
    @Test func splitCallbacks_waitForNearestNeighborWindow() throws {
        let source = PeripheralFrameSource(); source.configure(outputIndex: 1, ratio: 2)
        let selection = source.selection()
        source.offer(center: try F.sample(time: 0), outer: nil, selection: selection, receipt: 100)
        source.offer(center: nil, outer: try F.sample(time: 0.016), selection: selection, receipt: 100.001)
        #expect(source.latest() == nil)
        source.offer(center: try F.sample(time: 1 / 60), outer: nil, selection: selection, receipt: 100.016)
        #expect(abs(try #require(source.latest()?.ptsDelta)) < 0.001)
    }
    @Test(arguments: [false, true])
    func geometryChangeOrInvalidation_clearsPendingPair(invalidate: Bool) throws {
        let source = PeripheralFrameSource(); source.configure(outputIndex: 1, ratio: 2)
        source.offer(center: try F.sample(time: 1), outer: try F.sample(time: 1), selection: source.selection(), receipt: 100)
        if invalidate {
            source.invalidate()
            source.offer(center: try F.sample(time: 2), outer: try F.sample(time: 2), selection: source.selection())
        } else { source.configure(outputIndex: 1, ratio: 3) }
        #expect(source.latest() == nil)
    }
    static func metadata() throws -> (CMSampleBuffer, PeripheralFrameMetadata, simd_float3x3) {
        let sample = try F.sample(time: 3)
        let matrix = simd_float3x3(SIMD3(410, 0, 0), SIMD3(0, 420, 0), SIMD3(15.2, 16.3, 1))
        let data = withUnsafeBytes(of: matrix) { Data($0) }
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, value: data as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return (sample, PeripheralFrameMetadata(sample, id: 7, clock: nil), matrix)
    }
    static func calibration() -> PeripheralCalibration? {
        let value = simd_float4x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(-12, 3, 0.5))
        return PeripheralCalibration.decode(withUnsafeBytes(of: value) { Data($0) }, identity: "fixture", outputRotation: 0)
    }
    @Test func frameMetadata_preservesIntrinsicsPTSAndClockDomain() throws {
        let (_, metadata, matrix) = try Self.metadata()
        #expect(metadata.intrinsic == matrix)
        #expect(metadata.id == 7)
        #expect(metadata.pts == 3)
        #expect(metadata.hostCaptureTime == nil)
    }
    @Test func calibration_decodesSIMDPaddingAndRejectsMalformedMatrix() {
        #expect(Self.calibration()?.translation == SIMD3(-12, 3, 0.5))
        #expect(PeripheralCalibration.decode(Data(repeating: 0, count: 48), identity: "invalid", outputRotation: 0) == nil)
    }
    @Test func epipolarMatrix_preservesPhysicalCoordinateDirections() throws {
        let (sample, metadata, matrix) = try Self.metadata(), pixel = try #require(CMSampleBufferGetImageBuffer(sample))
        let pair = PeripheralFrameSource.Pair(center: pixel, outer: pixel, receipt: 0,
            configuration: .init(outputIndex: 1, fieldOfViewRatio: 2, epoch: 1), serial: 1,
            centerMetadata: metadata, outerMetadata: metadata, calibration: Self.calibration())
        var homography = matrix_identity_float3x3; homography[2] = SIMD3(4, -6, 1)
        let fundamental = try #require(PeripheralAlignmentWorker.analysisFundamental(pair, homography: homography, width: 192, height: 256))
        let world = SIMD3<Float>(35, -20, 1000), outerWorld = world + SIMD3(-12, 3, 0.5)
        let center = matrix * world, outer = matrix * outerWorld
        let centerPoint = SIMD3(center.x / center.z, center.y / center.z, 1), outerPoint = SIMD3(outer.x / outer.z, outer.y / outer.z, 1)
        let centerTransform = simd_float3x3(SIMD3(6, 0, 0), SIMD3(0, 8, 0), SIMD3(0, 0, 1))
        let outerTransform = simd_float3x3(SIMD3(12, 0, 0), SIMD3(0, 16, 0), SIMD3(-92, -122, 1))
        #expect(abs(simd_dot(outerTransform * outerPoint, fundamental * (centerTransform * centerPoint))) < 0.0001)
    }
}

struct LiveFrameMailboxTests {
    @Test func enabledMailbox_replacesPendingFrameAndConsumesOnce() throws {
        let source = LiveCameraFrameSource(); source.reset(generation: 7); source.setEnabled(true)
        source.offer(try PeripheralFixtures.sample(time: 1), generation: 7)
        source.offer(try PeripheralFixtures.sample(time: 2), generation: 7)
        let frame = try #require(source.takeLatest())
        #expect(CMTimeGetSeconds(frame.presentationTime) == 2)
        #expect(frame.generation == 7)
        #expect(source.takeLatest() == nil)
    }
    @Test(arguments: ["disable", "invalidate", "reset", "stale"])
    func unavailableGeneration_cannotDeliverPendingFrame(action: String) throws {
        let source = LiveCameraFrameSource(); source.reset(generation: 7); source.setEnabled(true)
        source.offer(try PeripheralFixtures.sample(time: 1), generation: 7)
        switch action {
        case "disable": source.setEnabled(false)
        case "invalidate": source.invalidate()
        case "reset": source.reset(generation: 8)
        default: _ = source.takeLatest(); source.offer(try PeripheralFixtures.sample(time: 2), generation: 6)
        }
        #expect(source.takeLatest() == nil)
    }
    @Test func defaultDisabledMailbox_doesNotAcceptFrames() throws {
        let source = LiveCameraFrameSource(); source.reset(generation: 7)
        source.offer(try PeripheralFixtures.sample(time: 1), generation: 7)
        #expect(source.takeLatest() == nil)
        #expect(!source.isCurrent(7))
    }
}
