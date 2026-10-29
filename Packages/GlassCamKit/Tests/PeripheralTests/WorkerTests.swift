import Testing
import Foundation
import QuartzCore
import CoreGraphics
import simd
@testable import Peripheral
import GlassCamTestSupport

private struct WorkerFixture {
    let outer = PeripheralFixtures.texture(width: 384, height: 512, seed: 2619)
    let tolerance = 1.0
    var center: [UInt8] { PeripheralFixtures.crop(outer, sourceWidth: 384, x: 100, y: 126, width: 192, height: 256) }
    func pair(_ pixels: [UInt8]? = nil, time: Double = 100, serial: UInt64 = 1, epoch: UInt64 = 7) throws -> PeripheralFrameSource.Pair {
        .init(center: try PeripheralFixtures.pixelBuffer(rgba: pixels ?? center, width: 192, height: 256),
            outer: try PeripheralFixtures.pixelBuffer(rgba: outer, width: 384, height: 512), receipt: time,
            configuration: .init(outputIndex: 1, fieldOfViewRatio: 2, epoch: epoch), serial: serial)
    }
    func aligned() throws -> PeripheralAlignmentResult {
        guard let result = PeripheralAlignmentWorker().analyze(try pair(), seams: .horizontal, now: { 100 }, tolerance: tolerance) else { throw CocoaError(.coderInvalidValue) }
        return result
    }
}

@Suite(.serialized)
struct WorkerTests {
    @Test func directSeamAnalysis_preservesKnownCropOffset() throws {
        let result = try WorkerFixture().aligned()
        #expect(result.evidence.reliable)
        #expect((0.02...0.04).contains(result.residual))
    }
    @Test(arguments: [(UInt64(7), 100.1, true), (UInt64(7), 100.21, false), (UInt64(8), 100.1, false)])
    func resultFreshness_requiresMatchingEpochAndDeadline(input: (UInt64, Double, Bool)) throws {
        #expect(try WorkerFixture().aligned().isFresh(for: input.0, at: input.1) == input.2)
    }
    @Test func directStitch_doesNotApplySceneFittedCorrection() throws {
        let result = try WorkerFixture().aligned()
        let point = try #require(PeripheralAlignmentWorker.project(SIMD2(0.5, 0.5), using: result.photoToOuter))
        #expect(simd_length(point - SIMD2(0.5, 0.5)) < 0.00001)
        #expect(result.directStitch)
        #expect(result.refinement == nil)
    }
    @Test func expiredInput_isRejected() throws {
        #expect(PeripheralAlignmentWorker().analyze(try WorkerFixture().pair(), seams: .horizontal, now: { 101 }) == nil)
    }
    @Test func boundaryOcclusion_isRejectedThenFreshSceneRecovers() throws {
        let fixture = WorkerFixture(), worker = PeripheralAlignmentWorker()
        var pixels = fixture.center
        for y in 0..<30 { for x in 50..<76 { for channel in 0..<3 { pixels[(y * 192 + x) * 4 + channel] = 0 } } }
        let unknown = worker.analyze(try fixture.pair(pixels, time: 100.1, serial: 2), seams: .horizontal, now: { 100.1 }, tolerance: fixture.tolerance)
        let incorrectlyCertified = [unknown].compactMap { $0 }.map(\.evidence).filter(\.reliable).filter { $0.appearance != .mismatch }
        #expect(incorrectlyCertified.isEmpty)
        let restored = worker.analyze(try fixture.pair(time: 100.2, serial: 3), seams: .horizontal, now: { 100.2 }, tolerance: fixture.tolerance)
        #expect(restored?.evidence.reliable == true)
    }
    @Test func asyncWorker_publishesOnceWithinCaptureDeadline() async throws {
        let fixture = WorkerFixture()
        let receipt = 100.0, completion = receipt + 0.1
        let worker = PeripheralAlignmentWorker(clock: { completion }), pair = try fixture.pair(time: receipt, epoch: 8)
        let admitted = worker.request(pair, seams: .horizontal), duplicate = worker.request(pair, seams: .horizontal)
        await withCheckedContinuation { continuation in worker.queue.async { continuation.resume() } }
        let result = try #require(worker.latest())
        #expect(admitted)
        #expect(!duplicate)
        #expect(!worker.isAnalyzing)
        #expect(result.completedAt - result.receipt <= 0.20)
        #expect(result.epoch == 8)
        #expect(result.tolerance == 0.1)
    }
    @Test func expiredQueuedFrame_isNotPublished() async throws {
        let receipt = 100.0, deadline = receipt + 0.2
        let worker = PeripheralAlignmentWorker(clock: { deadline }), pair = try WorkerFixture().pair(time: receipt)
        #expect(worker.request(pair, seams: .horizontal))
        await withCheckedContinuation { continuation in worker.queue.async { continuation.resume() } }
        #expect(worker.latest() == nil)
        #expect(!worker.isAnalyzing)
    }
    @Test(arguments: [false, true])
    func fullWindowCoverage_rejectsOutOfTextureMapping(shifted: Bool) throws {
        var matrix = try WorkerFixture().aligned().photoToOuter
        if shifted { matrix[2].x -= 1 }
        let margin = try #require(PeripheralProjection.margin(matrix, window: CGRect(x: 0, y: -0.25, width: 1, height: 1.5), width: 384, height: 512))
        #expect((margin >= 2) == !shifted)
    }
}
