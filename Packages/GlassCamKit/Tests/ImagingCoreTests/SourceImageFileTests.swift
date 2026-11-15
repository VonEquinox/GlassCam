import Testing
import Foundation
import CoreImage
import GlassCamTestSupport
@testable import ImagingCore

@Suite(.serialized) struct SourceImageFileTests {
    private static let rawExtensions = ["dng", "RAW", "3fr", "RAF", "rw2", "ARW"]

    private static func imageData() throws -> Data {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 3, height: 2))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
                                                        colorSpace: colorSpace, options: [:]))
    }

    @Test(arguments: rawExtensions)
    func rawSource_keepsExtensionAndOriginalBytes(fileExtension: String) throws {
        let data = try Self.imageData()

        let source = try SourceImageFile(data: data, fileExtension: fileExtension)

        #expect(source.url.pathExtension == fileExtension.lowercased())
        #expect(try Data(contentsOf: source.url) == data)
    }

    @Test(arguments: [nil, "", "png", "../source.dng", "dng/../raw", ".3fr"] as [String?])
    func otherExtension_doesNotContributeToTemporaryPath(fileExtension: String?) throws {
        let data = try Self.imageData()

        let source = try SourceImageFile(data: data, fileExtension: fileExtension)

        #expect(source.url.pathExtension.isEmpty)
        #expect(source.url.deletingLastPathComponent().standardizedFileURL ==
                FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test(arguments: rawExtensions)
    func renderedBytesWithRAWExtension_areRejected(fileExtension: String) throws {
        let data = try Self.imageData()

        #expect(throws: PipelineError.invalidImage) {
            try ImagePipeline.load(data: data, fileExtension: fileExtension)
        }
    }

    @Test func ownedSource_releaseRemovesTemporaryFile() throws {
        let data = try Self.imageData()

        let url = try autoreleasepool {
            let source = try SourceImageFile(data: data, fileExtension: "3fr")
            return source.url
        }

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func retainedSource_releasePreservesJournalFile() throws {
        let directory = try TestDirectory()
        let url = directory.url.appendingPathComponent("capture.dng")
        let data = try Self.imageData()
        try data.write(to: url)

        try autoreleasepool {
            let source = try SourceImageFile(retainedURL: url, fileExtension: "dng")
            #expect(source.url == url)
        }

        #expect(try Data(contentsOf: url) == data)
    }
}
