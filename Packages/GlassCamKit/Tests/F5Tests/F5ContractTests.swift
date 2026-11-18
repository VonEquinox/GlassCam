import Testing
import Foundation
@testable import F5
@testable import Capture
@testable import ImagingCore
import GlassCamTestSupport

struct F5ContractTests {
    @Test func sceneRecording_usesSevenFramesAndDoesNotBecomePendingPhoto() throws {
        let work = try TestDirectory()
        let snapshot = CaptureSnapshot(recipe: .standard,output: .native,quality: .balanced,rawArchiveID: UUID())

        let transaction = try F5BurstTransaction(snapshot: snapshot,purpose: "scene",root: work.url)

        #expect(transaction.frameCount == 7)
        #expect(try F5BurstTransaction.pendingProduct(root: work.url) == nil)
    }

    @Test func sampleProbe_retainsElevenEqualExposureOriginals() throws {
        let work = try TestDirectory()

        let fixture = try F5Fixtures.make(directory: work.url,purpose: "probe")

        #expect(fixture.source.manifest.frames.count == 11)
        #expect(Set(fixture.source.manifest.frames.map(\.actualExposure)) == [0.008])
        #expect(try fixture.source.manifest.validate(directory: fixture.source.directory).isEmpty)
    }

    @Test func elevenFrameProbe_groupsWithoutExceedingHardwareLimit() throws {
        #expect(try F5ExposurePlan.groups(maxBracketCount: 3,frameCount: 11) == [[0,1,2],[3,4,5],[6,7,8],[9,10]])
    }
    @Test(arguments: [(1,3,[[0]]),(7,3,[[0,1,2],[3,4,5],[6]]),
                      (7,2,[[0,1],[2,3],[4,5],[6]]),(7,1,[[0],[1],[2],[3],[4],[5],[6]]),
                      (7,11,[[0,1,2,3,4,5,6]])])
    func bayerFrameBudget_obeysBracketLimit(input: (Int,Int,[[Int]])) throws {
        #expect(try F5ExposurePlan.groups(maxBracketCount: input.1,frameCount: input.0) == input.2)
    }

    @Test func equalExposurePlan_keepsMeteredExposureAndISO() throws {
        let ae = 1.0 / 50, iso = 400.0

        let plan = try F5ExposurePlan.equal(ae: ae,iso: iso,minimum: 1e-5,maximum: 1)

        #expect(plan.main == ae)
        #expect(plan.iso == iso)
        #expect(plan.flags.isEmpty)
    }
    @Test func balancedBurst_retainsSevenEqualExposureFrames() throws {
        let context = try F5TestContext(quality: .balanced)
        defer { withExtendedLifetime(context) {} }
        let manifest = context.fixture.source.manifest

        #expect(try manifest.validate(directory: context.fixture.source.directory).isEmpty)
        #expect(manifest.requestOrder == [0, 1, 2, 3, 4, 5, 6])
        #expect(Set(manifest.frames.map(\.actualExposure)) == [0.008])
    }
    @Test func balancedBurst_missingLastBracketDoesNotPublish() throws {
        let context = try F5TestContext(quality: .balanced)
        defer { withExtendedLifetime(context) {} }
        let fixture = context.fixture, snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .balanced)
        let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: context.work.url)
        for (index, group) in try F5ExposurePlan.groups(maxBracketCount: 3, frameCount: 7).enumerated() {
            try transaction.register(requestID: Int64(101 + index), indices: group)
        }
        for frame in fixture.source.manifest.frames.prefix(6) {
            try transaction.append(frame, dng: Data(contentsOf: frame.dng.url(in: fixture.source.directory)),
                                   mosaic: Data(contentsOf: frame.mosaic.url(in: fixture.source.directory)))
        }
        try transaction.finishRequest(101, error: nil)
        try transaction.finishRequest(102, error: nil)

        let error = #expect(throws: F5Failure.self) {
            try transaction.commit(hardware: fixture.profile.hardwareModel, osBuild: fixture.profile.osBuild,
                synthetic: true, flags: [], profile: fixture.profile, framing: fixture.source.manifest.framing)
        }

        #expect(error?.code == .frameMissing)
        #expect(!FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("burst.json").path))
    }
    @Test func identicalCallback_isDeduplicatedAndCommitReusesSource() throws {
        let context = try F5TestContext()
        #expect(context.fixture.duplicateAppendResults == [false])
        #expect(context.fixture.source === context.fixture.repeatedSource)
    }
    @Test(arguments: [(3, [[0, 1, 2], [3, 4, 5], [6]]), (2, [[0, 1], [2, 3], [4, 5], [6]])])
    func defaultBracketPlan_preservesSevenFrameSequence(input: (Int, [[Int]])) throws {
        #expect(try F5ExposurePlan.groups(maxBracketCount: input.0) == input.1)
    }
    @Test func uncalibratedExposurePlan_marksMeteringAndMotionUncertainty() throws {
        let plan = try F5ExposurePlan.make(ae: 0.02, iso: 100, minimum: 1e-5, maximum: 1, quantum: 1e-6)
        #expect(plan.main <= 1 / 120)
        #expect(plan.short < plan.main)
        #expect(plan.flags.contains(.meteringUncertain))
        #expect(plan.flags.contains(.motionUncertain))
    }
    @Test func hardwareMinimumExposure_rejectsClampedProductPlan() {
        let error = #expect(throws: F5Failure.self) {
            try F5ExposurePlan.make(ae: 136e-6, iso: 80, minimum: 14e-6, maximum: 1, quantum: 1e-9)
        }
        #expect(error?.code == .shortExposureLimited)
    }
    @Test func clampedProbe_reportsLimitedShortExposure() throws {
        let plan = try F5ExposurePlan.make(ae: 136e-6, iso: 80, minimum: 14e-6, maximum: 1, quantum: 1e-9, allowClampedProbe: true)
        #expect(plan.flags.contains(.shortExposureLimited))
    }
    @Test func syntheticProfile_cannotQualifyRealHardware() throws {
        let context = try F5TestContext()
        let error = #expect(throws: F5Failure.self) { try context.fixture.profile.validate(synthetic: false) }
        #expect(error?.code == .unqualified)
    }
    @Test func oddActiveArea_keepsCFAOriginAtPixelCenter() throws {
        let context = try F5TestContext()
        let event = context.fixture.canonical[0].event(x: 0, y: 0)
        #expect(event.color == 0)
        #expect(event.phase == 0)
        #expect(event.x == 0.5)
        #expect(event.y == 0.5)
    }
    @Test func paddedMosaic_keepsQuantizationInterval() throws {
        let context = try F5TestContext()
        let frame = context.fixture.canonical[0], event = frame.event(x: 0, y: 0)
        #expect(event.lower < event.upper)
        #expect(frame.record.raster.rowBytes == 24)
    }
    @Test func colorBridge_ownsWhiteBalanceAndKeepsSignedLinearValues() throws {
        let context = try F5TestContext()
        let color = try F5ColorBridge.make(metadata: context.fixture.canonical[0].record.metadata, profile: context.fixture.profile)
        let output = color.cameraToLinearSRGB.apply([-0.1, 0.4, 2.0])
        #expect(color.whiteBalanceOwner == "matrix")
        #expect(color.decodeRevision == F5Version.decoder)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(output.contains { $0 < 0 })
    }
    @Test func bayerFourCC_mustMatchOddActiveAreaCFA() throws {
        let context = try F5TestContext()
        let metadata = context.fixture.canonical[0].record.metadata
        try F5BayerLayout.validate(fourCC: 0x62676734, metadata: metadata)
        let error = #expect(throws: F5Failure.self) { try F5BayerLayout.validate(fourCC: 0x72676734, metadata: metadata) }
        #expect(error?.code == .unsupportedRAW)
    }
    @Test func captureModes_useFixed24MPOutput() {
        #expect(CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .f5).output.cameraMegapixels == 24)
        #expect(CaptureQuality.allCases == [.speed,.balanced])
    }
    @Test func changedISO_isRetainedAsEvidenceAndStopsReconstruction() throws {
        let work = try TestDirectory()
        let fixture = try F5Fixtures.make(directory: work.url, deliveredISOs: [100, 100, 64, 100, 100])
        #expect(fixture.source.manifest.flags.contains(.isoChanged))
        #expect(fixture.source.manifest.flags.contains(.exposureAdjusted))
        let error = #expect(throws: F5Failure.self) { try F5Reconstructor.reconstruct(fixture.source, shaderURL: F5TestContext.shader) }
        #expect(error?.code == .isoChanged)
    }
}
