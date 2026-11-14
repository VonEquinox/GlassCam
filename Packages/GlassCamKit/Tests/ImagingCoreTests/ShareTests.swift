import Testing
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import ImagingCore
import GlassCamTestSupport

struct ShareTests {
    func encodedFile(hdr: Bool) throws -> (TemporaryHEIFFile, Int, Int) {
        let work = try TestDirectory()
        let input = try hdr ? ImagePipelineTests.hdrFixture(work.url) : ImagePipelineTests.fixture(work.url, width: 257, height: 389)
        let file = TemporaryHEIFFile()
        let processed = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        try ImagePipeline.writeHEIF(resources: TestResources.colors, processed, to: file.url)
        return (file, input.width, input.height)
    }
    @Test(arguments: [false, true])
    func heicRepresentation_preservesOriginalBytes(hdr: Bool) async throws {
        let (file, _, _) = try encodedFile(hdr: hdr)
        let original = try Data(contentsOf: file.url)
        let bytes = try await shareData(ShareDelivery.makeProvider(for: file), type: .heic)
        #expect(bytes == original)
    }
    @Test(arguments: [false, true])
    func compatibilityJPEG_preservesFullDimensionsAtEightBits(hdr: Bool) async throws {
        let (file, width, height) = try encodedFile(hdr: hdr)
        let bytes = try await shareData(ShareDelivery.makeProvider(for: file), type: .jpeg)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == width)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == height)
        #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 8)
    }
    @Test func hdrJPEG_toneMapsDistinctHighlights() async throws {
        let (file, width, height) = try encodedFile(hdr: true)
        let bytes = try await shareData(ShareDelivery.makeProvider(for: file), type: .jpeg)
        let image = try #require(CIImage(data: bytes))
        let decoded = ImagePipelineTests.pixels(image)
        let last = ((height - 32) * width + width / 2) * 4
        let middle = ((height - 96) * width + width / 2) * 4
        // Original HDR marker fixture keeps these two highlights distinct after JPEG loss and color conversion.
        #expect(decoded[middle] < 0.95)
        #expect(decoded[last] - decoded[middle] > 0.05)
    }
}

extension ShareTests {
    private func request(_ storage: ShareRepresentationStorage, compatibility: Bool = true) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = storage.requestFile(compatibility: compatibility) { continuation.resume(with: $0) }
        }
    }
    @Test(arguments: [false, true])
    func simultaneousJPEGRequests_encodeOnceAndReuseSameFile(hdr: Bool) async throws {
        let (original,_,_) = try encodedFile(hdr: hdr)
        var encodes = 0
        let storage = ShareRepresentationStorage(original: original,encodeJPEG: { context,image,url,space,options in
            encodes += 1
            try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
        })
        let first = try await request(storage)

        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 { group.addTask { try await request(storage) } }
            var results: [URL] = []
            for try await url in group { results.append(url) }
            return results
        }

        #expect(encodes == 1)
        #expect(Set(urls) == [first])
        #expect(urls.count == 4)
    }
    @Test func cancellationBeforeWork_doesNotEncodeOrDeliverJPEG() async throws {
        let (original,_,_) = try encodedFile(hdr: false)
        let queue = DispatchQueue(label: "ShareTests.before")
        var encodes = 0
        let storage = ShareRepresentationStorage(original: original,queue: queue,encodeJPEG: { context,image,url,space,options in
            encodes += 1; try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
        })
        queue.suspend()
        let result: Result<URL,Error> = await withCheckedContinuation { continuation in
            let progress = storage.requestFile(compatibility: true) { continuation.resume(returning: $0) }
            progress.cancel(); queue.resume()
        }
        #expect(throws: CocoaError(.userCancelled)) { try result.get() }
        #expect(encodes == 0)
    }
    @Test(arguments: [false, true])
    func unsuccessfulEncoding_discardsPartialFileAndAllowsFreshRetry(cancelled: Bool) async throws {
        let (original,_,_) = try encodedFile(hdr: false)
        let queue = DispatchQueue(label: "ShareTests.after")
        var encodes = 0
        var firstProgress: Progress?
        var paths: [URL] = []
        let storage = ShareRepresentationStorage(original: original,queue: queue,encodeJPEG: { context,image,url,space,options in
            encodes += 1; paths.append(url)
            try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
            if encodes == 1 {
                if cancelled { firstProgress?.cancel() }
                else { throw CocoaError(.fileWriteUnknown) }
            }
        })
        queue.suspend()
        let failure: Result<URL,Error> = await withCheckedContinuation { continuation in
            firstProgress = storage.requestFile(compatibility: true) { continuation.resume(returning: $0) }
            queue.resume()
        }

        let retry = try await request(storage)

        #expect(throws: CocoaError(cancelled ? .userCancelled : .fileWriteUnknown)) { try failure.get() }
        #expect(encodes == 2)
        #expect(!FileManager.default.fileExists(atPath: try #require(paths.first).path))
        #expect(retry == paths.last)
    }
    @Test func pendingCallback_ownsOriginalAfterProviderRelease() async throws {
        let queue = DispatchQueue(label: "ShareTests.ownership")
        var original = Data()
        var storage: ShareRepresentationStorage? = try {
            let (file,_,_) = try encodedFile(hdr: false)
            original = try Data(contentsOf: file.url)
            return ShareRepresentationStorage(original: file,queue: queue)
        }()
        queue.suspend()
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            _ = storage?.requestFile(compatibility: false) { result in
                continuation.resume(with: result.flatMap { url in Result { try Data(contentsOf: url) } })
            }
            storage = nil
            queue.resume()
        }
        #expect(bytes == original)
    }
}
