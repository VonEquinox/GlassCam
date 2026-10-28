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
    func repeatedJPEGRequests_reuseCachedRepresentation(hdr: Bool) async throws {
        let (file, _, _) = try encodedFile(hdr: hdr)
        let provider = ShareDelivery.makeProvider(for: file)
        let first = try await shareData(provider, type: .jpeg)
        let second = try await shareData(provider, type: .jpeg)
        #expect(first == second)
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
