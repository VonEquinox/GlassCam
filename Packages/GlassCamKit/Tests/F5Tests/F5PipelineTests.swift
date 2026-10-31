import Testing
import Foundation
import ImageIO
@testable import F5
@testable import ImagingCore
@testable import Capture
import GlassCamTestSupport

private struct F5PipelineObservation {
    let context: F5TestContext
    let image: F5LinearImage
    let properties: [String: Any]
    let metadata: PhotoMetadata
    let comment: String
    static let result = Result { try F5PipelineObservation() }
    init() throws {
        context = try F5TestContext()
        image = try F5Reconstructor.reconstruct(context.fixture.source, shaderURL: F5TestContext.shader)
        comment = "GlassCam F5\n" + String(decoding: try F5Hash.json(image.provenance(context.fixture.source.manifest)), as: UTF8.self)
        metadata = image.photoMetadata.addingCaptureProvenance(comment)
        let output = context.work.url.appendingPathComponent("f5-result.heic")
        _ = try ImagePipeline.writeF5HEIF(resources: ColorResources(resourceDirectory: nil), image, metadata: metadata,
            recipe: .standard, to: output, isCancelled: { false }, progress: { _ in })
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw PipelineError.encoding }
        self.properties = properties
    }
}

@Suite(.serialized)
struct F5PipelineTests {
    @Test func reconstructedBurst_usesDoubleDensityAndRetainsProvenance() throws {
        let result = try F5PipelineObservation.result.get()
        #expect(result.image.width == 16)
        #expect(result.image.height == 12)
        #expect(result.image.quality.actualFrameCount == 5)
        #expect(result.image.color.whiteBalanceOwner == "matrix")
    }
    @Test func curvatureReport_doesNotInventSplineConvergence() throws {
        let result = try F5PipelineObservation.result.get()
        #expect(result.image.quality.objectiveEpochs.isEmpty)
        #expect(result.image.quality.solveStatus == "CURVATURE_NATIVE_FUSION")
    }
    @Test func curvatureSupport_doesNotClaimUnmeasuredSRRank() throws {
        let result = try F5PipelineObservation.result.get()
        #expect(result.image.quality.tiles.allSatisfy { $0.support != .fullSR })
    }
    @Test func finalHEIF_isTenBitAndRetainsF5Metadata() throws {
        let result = try F5PipelineObservation.result.get()
        try result.metadata.validate(in: result.properties)
        let exif = result.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect((result.properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10)
        #expect(exif?[kCGImagePropertyExifUserComment as String] as? String == result.comment)
        #expect(result.metadata.captureDate != nil)
    }
    @Test func archiveRetain_isDurableAndIdempotent() throws {
        let context = try F5TestContext(), id = UUID(), root = context.work.url.appendingPathComponent("archives")
        let first = try F5ArchiveStore.retain(context.fixture.source, captureID: id, root: root)
        let second = try F5ArchiveStore.retain(context.fixture.source, captureID: id, root: root)
        #expect(first == second)
        #expect(try F5BurstSource(directory: second).manifest.frames.count == 5)
    }
    @Test func lateConflictingDelivery_doesNotOverwriteOriginal() throws {
        let work = try TestDirectory()
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera(48), quality: .f5)
        let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "synthetic-test", root: work.url)
        try transaction.register(requestID: 900, indices: [0])
        let original = try transaction.retainDelivery(requestID: 900, sequenceCount: 1, dng: Data([0, 1, 2, 3]))
        transaction.cancel(.unsupportedRAW)
        let late = try transaction.retainDelivery(requestID: 900, sequenceCount: 1, dng: Data([4, 5, 6, 7]))
        try original.dng.verify(in: transaction.directory)
        try late.dng.verify(in: transaction.directory)
        #expect(original.dng.path != late.dng.path)
    }
}
