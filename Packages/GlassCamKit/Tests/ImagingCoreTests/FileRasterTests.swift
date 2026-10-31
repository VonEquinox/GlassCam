import Testing
import Foundation
import CoreImage
import GlassCamTestSupport
@testable import ImagingCore

struct FileRasterTests {
    @Test(arguments: [1,6])
    func tiledSource_matchesBitmapAcrossEdgesCropAndOrientation(orientation: Int32) throws {
        let width = 519, height = 139
        let file = try ExportRasterFile()
        let pixels: [Float] = (0..<width * height).flatMap { i in
            [Float(i % width) / 128 - 0.25,Float(i / width) / 64,Float(i % 13) / 16,1]
        }
        try file.append(pixels)
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let bitmap = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },bytesPerRow: width * 16,
            size: CGSize(width: width,height: height),format: .RGBAf,colorSpace: linear)
        let tiled = try file.tiledImage(width: width,height: height,colorSpace: linear)
        let context = CIContext(options: [.workingColorSpace: linear,.workingFormat: CIFormat.RGBAf.rawValue,.cacheIntermediates: false])
        func render(_ source: CIImage) -> [Float] {
            let image = source.oriented(forExifOrientation: orientation)
            let rect = image.extent.insetBy(dx: 3,dy: 2)
            var output = [Float](repeating: 0,count: Int(rect.width * rect.height) * 4)
            output.withUnsafeMutableBytes {
                context.render(image,toBitmap: $0.baseAddress!,rowBytes: Int(rect.width) * 16,bounds: rect,format: .RGBAf,colorSpace: linear)
            }
            return output
        }

        let actual = render(tiled)

        #expect(actual == render(bitmap))
        try file.validateImageReads()
    }

    @Test func providerRetainsOpenFile_afterRasterOwnerIsReleased() throws {
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let pixels: [Float] = [-0.25,0.5,2,1]
        var path: URL?
        let image = try autoreleasepool {
            let file = try ExportRasterFile(); path = file.url
            try file.append(pixels)
            return try file.tiledImage(width: 1,height: 1,colorSpace: linear)
        }
        let context = CIContext(options: [.workingColorSpace: linear,.workingFormat: CIFormat.RGBAf.rawValue])
        var output = [Float](repeating: 0,count: 4)

        output.withUnsafeMutableBytes {
            context.render(image,toBitmap: $0.baseAddress!,rowBytes: 16,bounds: image.extent,format: .RGBAf,colorSpace: linear)
        }

        #expect(!FileManager.default.fileExists(atPath: try #require(path).path))
        #expect(output == pixels)
    }

    @Test func truncatedBacking_reportsReadFailureInsteadOfPublishingBlackPhoto() throws {
        let file = try ExportRasterFile()
        try file.append([0.25,0.5,2,1])
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = try file.tiledImage(width: 1,height: 1,colorSpace: linear)
        try file.handle.truncate(atOffset: 0)
        let context = CIContext(options: [.workingColorSpace: linear,.workingFormat: CIFormat.RGBAf.rawValue])
        var output = [Float](repeating: 0,count: 4)

        output.withUnsafeMutableBytes {
            context.render(image,toBitmap: $0.baseAddress!,rowBytes: 16,bounds: image.extent,format: .RGBAf,colorSpace: linear)
        }

        #expect(throws: (any Error).self) { try file.validateImageReads() }
    }
}
