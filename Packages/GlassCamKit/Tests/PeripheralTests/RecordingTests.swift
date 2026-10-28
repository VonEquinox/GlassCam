import Testing
import Foundation
import AVFoundation
import QuartzCore
import simd
@testable import Peripheral
import GlassCamTestSupport

private enum RecordingFixtures {
    static func buffer(_ format: OSType, seed: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
        let result = pixel!
        guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
        let planar = CVPixelBufferIsPlanar(result)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(result) : 1) {
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(result,plane)! : CVPixelBufferGetBaseAddress(result)!
            let bytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(result,plane)*CVPixelBufferGetHeightOfPlane(result,plane)
                               : CVPixelBufferGetBytesPerRow(result)*CVPixelBufferGetHeight(result)
            for i in 0..<bytes { base.assumingMemoryBound(to: UInt8.self)[i] = UInt8((i*17+seed+plane*31)%256) }
        }
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    static func sample(_ pixel: CVPixelBuffer) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&description)
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),
            presentationTimeStamp:CMTime(value:1234567,timescale:600),decodeTimeStamp:.invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,
            formatDescription:description!,sampleTiming:&timing,sampleBufferOut:&sample) == noErr else { throw CocoaError(.coderInvalidValue) }
        var k = simd_float3x3(SIMD3(777,0,0),SIMD3(0,778,0),SIMD3(4,3,1))
        let data = withUnsafeBytes(of: &k) { Data($0) }
        CMSetAttachment(sample!,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,value:data as CFData,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        return sample!
    }
    static func metadata(_ pixel: CVPixelBuffer, id: UInt64) throws -> PeripheralFrameMetadata {
        PeripheralFrameMetadata(try sample(pixel), id: id, clock: nil)
    }
    static func save(_ recorder: PeripheralStateRecorder, pair: PeripheralFrameSource.Pair?, pending: [PeripheralUnpairedInput] = []) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let admitted = recorder.record(pair: pair, camera: ["isReady": pair != nil, "status": "fixture", "NaN": Double.nan, "tolerance": 2.15], unpaired: pending) { continuation.resume(with: $0) }
            if !admitted { continuation.resume(throwing: CocoaError(.fileWriteUnknown)) }
        }
    }
    static func manifest(_ url: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("manifest.json"))) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return result
    }
}
private struct RecordedFixture {
    let work: TestDirectory
    let empty: [String: Any], manifest: [String: Any]
    let saved: URL
    let pair: PeripheralFrameSource.Pair
    let fieldValues: [Float], renderFieldValues: [Float], rgba: [UInt8]
    static let value = Task { try await RecordedFixture() }
    init() async throws {
        work = try TestDirectory(); let root = work.url
        let recorder = PeripheralStateRecorder(directory:root.appendingPathComponent("records"))
        let absent = try await RecordingFixtures.save(recorder,pair:nil)
        empty = try JSONSerialization.jsonObject(with:Data(contentsOf:absent.appendingPathComponent("manifest.json"))) as! [String:Any]


        let a = try RecordingFixtures.buffer(kCVPixelFormatType_32BGRA,seed:7)
        let b = try RecordingFixtures.buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,seed:23)
        let m = try RecordingFixtures.metadata(a,id:9001)
        var config = PeripheralFrameSource.Configuration(); config.epoch = 4; config.fieldOfViewRatio = 1.7
        pair = PeripheralFrameSource.Pair(center:a,outer:b,receipt:CACurrentMediaTime(),configuration:config,
            serial:18,centerMetadata:m,outerMetadata:try RecordingFixtures.metadata(b,id:9002),pairingMode:"original-fixture")
        // Same counters in a different source must not overwrite the previous pair.
        let old = PeripheralFrameSource.Pair(center:a,outer:b,receipt:pair.receipt-0.1,configuration:config,serial:18)
        rgba = (0..<8*6*4).map { UInt8($0%256) }
        fieldValues=(0..<2*2*4).map {Float($0)*0.125}
        let refinement=PeripheralDenseRefinement(id:22,epoch:4,sourcePairID:18,homography:matrix_identity_float3x3,
            width:2,height:2,rgba:fieldValues,consistentFraction:0.95,elapsedMS:120,maximumOffset:0.02)
        let snapshot = PeripheralAnalysisSnapshot(pair:old,reference:rgba,warped:[],metadata:[
            "available":true,"published":false,"reason":"expired-before-publication", "width":8,"height":6,"padding":0],
            nativeStrips:[.init(edge:0,width:8,height:6,reference:rgba,outer:rgba,nativeScale:1)],refinement:refinement)
        renderFieldValues=fieldValues.map {$0+1}
        let renderField=PeripheralDenseRefinement(id:23,epoch:4,sourcePairID:17,homography:matrix_identity_float3x3,
            width:2,height:2,rgba:renderFieldValues,consistentFraction:0.9,elapsedMS:100,maximumOffset:0.02)
        let frame=PeripheralLiveFrame(pair:pair,matrix:matrix_identity_float3x3,gains:.init(),refinement:renderField,
            refinementStrength:0.7,analysisPairID:old.serial,analysisObservedAt:old.observedAt,modelPair:old,
            mappingBasis:"live-retained-spatial-proposal",seams:.horizontal,tolerance:2.15,margin:4)
        recorder.updateRenderer(["phase":"submitted","hostTime":pair.receipt,"effectiveBlackOpacity":1.0,
            "policyReason":"evidence-expired","rejectionReasons":["measurement-expired"],"forcedBlack":false,
            "infinity":Double.infinity],pair:pair,texturePair:pair,analysis:snapshot,renderedFrame:frame)
        recorder.gpuEvent(["commandID":1,"status":4])
        saved = try await RecordingFixtures.save(recorder,pair:pair)
        manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as! [String:Any]
    }
}

struct RecordingTests {
    @Test func stoppedCameraRecord_preservesEmptyPairAndNonfiniteValue() async throws {
        let value = try await RecordedFixture.value.value
        #expect((value.empty["pairs"] as? [String: Any])?.isEmpty == true)
        #expect((value.empty["camera"] as? [String: Any])?["NaN"] as? String == "NaN")
    }
    @Test func distinctSources_preserveTheirRolesAndTolerance() async throws {
        let value = try await RecordedFixture.value.value
        let pairs = try #require(value.manifest["pairs"] as? [String: Any]), roles = try #require(value.manifest["roles"] as? [String: String])
        #expect(pairs.count == 2)
        #expect(roles["tapPair"] != roles["analysisPair"])
        #expect(roles["texturePair"] == roles["tapPair"])
        #expect(roles["renderModelPair"] == roles["analysisPair"])
        #expect((value.manifest["camera"] as? [String: Any])?["tolerance"] as? Double == 2.15)
    }
    @Test func originalMetadata_preservesCapturePTSAndIntrinsics() async throws {
        let value = try await RecordedFixture.value.value
        let pairs = try #require(value.manifest["pairs"] as? [String: [String: Any]]), roles = try #require(value.manifest["roles"] as? [String: String])
        let key = try #require(roles["tapPair"])
        let metadata = try #require(pairs[key]?["centerMetadata"] as? [String: Any])
        #expect(metadata["pts"] as? Double == 1234567.0 / 600)
        #expect((metadata["K_columns"] as? [[NSNumber]])?[0][0].floatValue == 777)
    }
    @Test(arguments: ["tapPair", "analysisPair"], ["center", "outer"])
    func originalPlanes_preserveEveryByteIncludingPadding(role: String, stream: String) async throws {
        let value = try await RecordedFixture.value.value
        let pairs = try #require(value.manifest["pairs"] as? [String: [String: Any]]), roles = try #require(value.manifest["roles"] as? [String: String])
        let key = try #require(roles[role])
        let row = try #require(pairs[key]?[stream] as? [String: Any])
        let planes = try #require(row["planes"] as? [[String: Any]])
        let bytes = try planes.map { try Data(contentsOf: value.saved.appendingPathComponent(try #require($0["file"] as? String))) }
        let expected = try planes.enumerated().map { index, plane -> Data in
            let count = try #require(plane["bytesPerRow"] as? Int) * #require(plane["height"] as? Int)
            return Data((0..<count).map { UInt8(($0 * 17 + (stream == "center" ? 7 : 23) + index * 31) % 256) })
        }
        #expect(planes.count == (stream == "center" ? 1 : 2))
        #expect(bytes == expected)
    }
    @Test(arguments: ["render-refinement.rgba32f", "dense-refinement.rgba32f", "analysis-reference.rgba", "native-edge-0-reference.rgba"])
    func analysisAndRenderedArtifacts_preserveSeparateExactBytes(filename: String) async throws {
        let value = try await RecordedFixture.value.value
        let expected: Data
        switch filename {
        case "render-refinement.rgba32f": expected = value.renderFieldValues.withUnsafeBytes { Data($0) }
        case "dense-refinement.rgba32f": expected = value.fieldValues.withUnsafeBytes { Data($0) }
        default: expected = Data(value.rgba)
        }
        #expect(try Data(contentsOf: value.saved.appendingPathComponent(filename)) == expected)
    }
    @Test func unmatchedOriginal_isVisibleAndCanBeRecorded() async throws {
        let work = try TestDirectory(), source = PeripheralFrameSource()
        source.configure(outputIndex: 1, ratio: 1.7)
        let pixel = try RecordingFixtures.buffer(kCVPixelFormatType_32BGRA, seed: 7)
        source.offer(center: try RecordingFixtures.sample(pixel), outer: nil, selection: source.selection())
        let snapshot = source.recordingSnapshot()
        let saved = try await RecordingFixtures.save(PeripheralStateRecorder(directory: work.url), pair: nil, pending: snapshot.pending)
        let manifest = try RecordingFixtures.manifest(saved)
        #expect(snapshot.pair == nil)
        #expect(snapshot.pending.count == 1)
        #expect((manifest["unpairedInputs"] as? [[String: Any]])?.count == 1)
    }
    @Test func expiredInput_retainsActualRejectionForDiagnosis() async throws {
        let fixture = try await RecordedFixture.value.value, worker = PeripheralAlignmentWorker()
        let result = worker.analyze(fixture.pair, now: { fixture.pair.observedAt + 1 })
        #expect(result == nil)
        #expect(worker.latestDiagnostic()?.metadata["reason"] as? String == "expired-input-or-no-seams")
    }
    @Test func restartedRecorder_exportsWithoutRemovingOriginals() async throws {
        let fixture = try await RecordedFixture.value.value
        let recorder = PeripheralStateRecorder(directory: fixture.work.url.appendingPathComponent("records"))
        let zip: URL = try await withCheckedThrowingContinuation { continuation in
            let admitted = recorder.export { continuation.resume(with: $0) }
            if !admitted { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(FileManager.default.fileExists(atPath: zip.path))
        #expect(FileManager.default.fileExists(atPath: fixture.saved.appendingPathComponent("manifest.json").path))
    }
    @Test func storageLimit_reportsFailureWithoutPartialDirectory() async throws {
        let work = try TestDirectory(), fixture = try await RecordedFixture.value.value
        let recorder = PeripheralStateRecorder(directory: work.url, maxBytes: 1)
        await #expect(throws: PeripheralStateRecorder.RecordingError.self) { try await RecordingFixtures.save(recorder, pair: fixture.pair) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.url.path).isEmpty)
    }
    @Test func blockedDirectory_reportsIOFailure() async throws {
        let work = try TestDirectory(), blocker = work.url.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)
        await #expect(throws: (any Error).self) { try await RecordingFixtures.save(PeripheralStateRecorder(directory: blocker), pair: nil) }
    }
}
