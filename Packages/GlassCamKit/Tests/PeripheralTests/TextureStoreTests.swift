import Testing
import Foundation
import CoreImage
import Metal
import simd
@testable import Peripheral

private struct TextureFixture {
    let device: MTLDevice, queue: MTLCommandQueue, context: CIContext
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let pair: PeripheralFrameSource.Pair
    var alignment: PeripheralAlignmentResult
    init(partial: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        self.device = device; self.queue = queue; context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let pixels = try PeripheralFixtures.pixelBuffer(rgba: PeripheralFixtures.texture(width: 192, height: 256, seed: 79), width: 192, height: 256)
        pair = PeripheralFrameSource.Pair(center: pixels, outer: pixels, receipt: 10,
            configuration: .init(outputIndex: 1, fieldOfViewRatio: 2, epoch: 8), serial: 1)
        alignment = PeripheralAlignmentResult(epoch: 8, receipt: 10, photoAspectRatio: 0.75,
            photoToOuter: matrix_identity_float3x3, residual: .nan, gain: SIMD3(repeating: 1), seams: .all, expiresAt: 10.2)
        alignment.inputPair = pair; alignment.pairID = pair.serial
        if partial {
            alignment.nativeSeam = PeripheralNativeSeam.evaluate([
                .init(edge: 0, width: 192, height: 20, reference: NativeSeamTests.flat, outer: NativeSeamTests.flat, nativeScale: 1),
                .init(edge: 1, width: 192, height: 20, reference: NativeSeamTests.line(x: 70), outer: NativeSeamTests.flat, nativeScale: 1)],
                gains: .init(), segments: [], analysisWidth: 192, analysisHeight: 256, geometryVerified: false, severe: nil)
        }
    }
    func prepare(_ store: PeripheralTextureStore, commandID: UInt64 = 1, at time: Double = 10) throws -> (PeripheralTextureStore.Bundle, CIRenderTask, MTLCommandBuffer) {
        guard let command = queue.makeCommandBuffer(),
              let prepared = try store.prepare(alignment: alignment, revision: 2, epoch: 8, commandID: commandID,
                at: time, device: device, context: context, command: command, colorSpace: space, samplingLegal: true) else { throw CocoaError(.coderInvalidValue) }
        return (prepared.0, prepared.1, command)
    }
    static func finish(_ upload: (PeripheralTextureStore.Bundle, CIRenderTask, MTLCommandBuffer)) async {
        await withCheckedContinuation { continuation in upload.2.addCompletedHandler { _ in continuation.resume() }; upload.2.commit() }
        withExtendedLifetime(upload.1) {}
    }
}

struct TextureStoreTests {
    @Test(arguments: [false, true])
    func temporalAppearance_requiresUnchangedNativeBoundary(changed: Bool) throws {
        let pixels = PeripheralFixtures.texture(width: 192, height: 256, seed: 79)
        let original = try PeripheralFixtures.pixelBuffer(rgba: pixels, width: 192, height: 256)
        let other = try PeripheralFixtures.pixelBuffer(rgba: changed ? [UInt8](repeating: 255, count: pixels.count) : pixels, width: 192, height: 256)
        #expect(PeripheralTemporalAppearance.compatible(original, other, seams: .all) == !changed)
    }
    @Test func unknownUpload_isPreparedWithoutPrematurePublication() async throws {
        let fixture = try TextureFixture(), store = PeripheralTextureStore(), upload = try fixture.prepare(store)
        #expect(store.completed == nil)
        await TextureFixture.finish(upload)
        #expect(upload.2.status == .completed)
        #expect(store.complete(upload.0, success: true, revision: 2, epoch: 8, at: 10.01))
        #expect(store.completed?.pair === fixture.pair)
        #expect(store.completed?.alignment.pairID == 1)
    }
    @Test func uploadedUnknown_doesNotAuthorizeDisplay() async throws {
        let fixture = try TextureFixture(), store = PeripheralTextureStore(), upload = try fixture.prepare(store)
        await TextureFixture.finish(upload)
        store.complete(upload.0, success: true, revision: 2, epoch: 8, at: 10.01)
        #expect(try #require(store.completed).alignment.evidence.permitsDisplay == false)
    }
    @Test func reset_rejectsLateCompletion() async throws {
        let fixture = try TextureFixture(), store = PeripheralTextureStore(), upload = try fixture.prepare(store)
        store.reset(); await TextureFixture.finish(upload)
        #expect(!store.complete(upload.0, success: true, revision: 2, epoch: 8, at: 10.02))
        #expect(store.completed == nil)
    }
    @Test func failedGPUUpload_isConsumedAndBacksOff() async throws {
        let fixture = try TextureFixture(), store = PeripheralTextureStore(), upload = try fixture.prepare(store, at: 10.03)
        await TextureFixture.finish(upload)
        #expect(store.complete(upload.0, success: false, revision: 2, epoch: 8, at: 10.04))
        #expect(store.completed == nil)
        #expect(store.nextAttempt >= 10.09)
    }
    @Test func partialNativeEvidence_doesNotFabricateWholeBoundaryCertificate() throws {
        let fixture = try TextureFixture(partial: true)
        #expect(!fixture.alignment.evidence.permitsDisplay)
        #expect(fixture.alignment.evidence(forEdge: 0).permitsDisplay)
        #expect(!fixture.alignment.evidence(forEdge: 1).permitsDisplay)
    }
    @Test func independentlyCertifiedPane_canBecomeDisplayable() async throws {
        let fixture = try TextureFixture(partial: true), store = PeripheralTextureStore(), upload = try fixture.prepare(store, at: 10.05)
        await TextureFixture.finish(upload)
        #expect(store.complete(upload.0, success: upload.2.status == .completed, revision: 2, epoch: 8, at: 10.06))
        #expect(store.displayable === upload.0)
    }
    @Test func changedTolerance_createsBundleWithItsOwnEvidenceIdentity() async throws {
        var fixture = try TextureFixture(partial: true)
        let store = PeripheralTextureStore(), first = try fixture.prepare(store, at: 10.05)
        await TextureFixture.finish(first)
        store.complete(first.0, success: true, revision: 2, epoch: 8, at: 10.06)
        fixture.alignment.tolerance = 2
        let tuned = try fixture.prepare(store, commandID: 2, at: 10.07)
        await TextureFixture.finish(tuned)
        #expect(store.complete(tuned.0, success: tuned.2.status == .completed, revision: 2, epoch: 8, at: 10.08))
        #expect(store.displayable?.alignment.tolerance == 2)
    }
}
