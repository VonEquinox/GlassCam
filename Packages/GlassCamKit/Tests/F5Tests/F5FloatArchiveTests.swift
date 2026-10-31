import Testing
import Foundation
import CoreImage
import ImageIO
import CMetalF5
import GlassCamTestSupport
@testable import F5
@testable import ImagingCore
@testable import Capture

@Suite(.serialized)
struct F5FloatArchiveTests {
    @Test func rawSceneRecording_finishesWithoutBrandResourcesOrHEIF() throws {
        let context = try F5TestContext(width: 32,height: 24)
        let fixture = try F5Fixtures.make(directory: context.work.url,width: 32,height: 24,quality: .balanced)
        let id = UUID(), archives = context.work.url.appendingPathComponent("archives")
        let snapshot = CaptureSnapshot(recipe: .standard,output: .native,quality: .balanced,rawArchiveID: id)

        let saved = try F5ImagePipeline.archiveRAW(fixture.source,snapshot: snapshot,progress: { _ in },isCancelled: { false },
            shaderURL: F5TestContext.shader,archiveRoot: archives)

        let names = try FileManager.default.contentsOfDirectory(atPath: saved.path).sorted()
        #expect(names == ["archive.json","balanced-camera.dng","balanced-linear.tiff","capture.json","color-transform.json","source-metadata.json"])
        #expect(saved == archives.appendingPathComponent(id.uuidString + "/balanced"))
    }

    @Test func boundedRGBPacking_preservesSignedHDRAndFinalStripBitExactly() throws {
        let work = try TestDirectory(), width = 8, height = 19
        let expected: [Float] = (0..<width * height).flatMap { _ -> [Float] in [-0.125,0.25,2.5] }
        let input = try ExportRasterFile()
        try input.append((0..<width * height).flatMap { _ in [Float(-0.125),0.25,2.5,1] })
        try input.handle.synchronize()
        let output = work.url.appendingPathComponent("packed.rgb")
        try Data(repeating: 0xA7,count: 32).write(to: output)
        let source = try FileHandle(forReadingFrom: input.url), target = try FileHandle(forWritingTo: output)
        defer { try? source.close(); try? target.close() }
        var error = gc_f5_curve_error()

        let status = gc_f5_curve_write_rgb(source.fileDescriptor,target.fileDescriptor,UInt32(width),UInt32(height),32,nil,&error)

        let data = try Data(contentsOf: output)
        #expect(status == 0)
        #expect(data.prefix(32) == Data(repeating: 0xA7,count: 32))
        #expect(data.dropFirst(32).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } == expected)
    }

    @Test(arguments: [true,false])
    func floatArchive_retainsShapeAndExposureMetadata(cameraDNG: Bool) throws {
        let width = 256, height = 192
        let context = try F5TestContext(width: width,height: height)
        let reference = context.fixture.canonical[0].record
        let input = try ExportRasterFile()
        try input.append((0..<width * height).flatMap { _ in [Float(0.2),0.3,0.4,1] })
        try input.handle.synchronize()
        let output = context.work.url.appendingPathComponent(cameraDNG ? "merged.dng" : "linear.tiff")

        try F5FloatArchive.write(input: input.url,to: output,width: width,height: height,reference: reference,
            cameraDNG: cameraDNG,whiteScale: context.fixture.profile.whiteScale)

        let properties: [String:Any]
        if cameraDNG {
            let decoder = try #require(CIRAWFilter(imageURL: output))
            properties = decoder.properties as? [String:Any] ?? [:]
        } else {
            let image = try #require(CGImageSourceCreateWithURL(output as CFURL,nil))
            properties = try #require(CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any])
        }
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
        #expect((exif[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue == width)
        #expect((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue == 100)
        #expect(abs(((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0) - 0.008) < 1e-9)
        if !cameraDNG {
            #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 32)
        }
    }

    @Test func colorFailure_keepsMergedDNGAndLinearSourceBeforeGrading() throws {
        let context = try F5TestContext(width: 32,height: 24)
        let sourceFixture = try F5Fixtures.make(directory: context.work.url, width: 32,height: 24,quality: .balanced)
        let id = UUID(), archives = context.work.url.appendingPathComponent("archives")
        let recipe = ProcessingRecipe(mode: .ffcs,exposureEV: 0,illuminantKelvin: 6500,simulationIndex: 0,seed: 0,hncs: .standard)
        let snapshot = CaptureSnapshot(recipe: recipe,output: .native,quality: .balanced,rawArchiveID: id)
        let empty = ColorResources(resourceDirectory: context.work.url.appendingPathComponent("missing-resources"))

        #expect(throws: (any Error).self) {
            try F5ImagePipeline.render(resources: empty,sourceFixture.source,snapshot: snapshot,progress: { _ in },isCancelled: { false },
                shaderURL: F5TestContext.shader,archiveRoot: archives)
        }

        let saved = archives.appendingPathComponent(id.uuidString + "/balanced")
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("archive.json").path))
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("balanced-camera.dng").path))
        #expect(CGImageSourceCreateWithURL(saved.appendingPathComponent("balanced-linear.tiff") as CFURL,nil) != nil)
    }
}
