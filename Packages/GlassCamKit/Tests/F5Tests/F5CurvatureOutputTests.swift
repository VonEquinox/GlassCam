import Testing
import Foundation
import ImagingCore
import GlassCamTestSupport
@testable import F5

@Suite(.serialized)
struct F5CurvatureOutputTests {
    private let identity: [Double] = [1,0,0,0,1,0,0,0,1]
    private func device(cancelled: @escaping () -> Bool = { false }) throws -> F5MetalDevice {
        try F5MetalDevice(maximumBytes: 64 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: cancelled)
    }
    private func input(width: Int, height: Int, scale: Int = 1, pixel: (Int, Int) -> SIMD4<Float>) throws -> F5CurvatureRaster.Result {
        let file = try ExportRasterFile()
        let pixels = (0..<width * height * scale * scale).flatMap { index -> [Float] in
            let value = pixel(index % (width * scale), index / (width * scale))
            return [value.x,value.y,value.z,value.w]
        }
        try file.append(pixels)
        return .init(file: file, width: width * scale, height: height * scale)
    }

    @Test(arguments: ["gain_rgb", "gain_before_warp", "gain_after_warp", "gain_warp_gain", "partial_planes_broadcast", "hdr_extension"])
    func orderedPostOperations_matchFrozenReference(name: String) throws {
        let directory = TestResources.fixtures.appendingPathComponent("f5-post-operations")
        let metadata = try F5DNGMetadata.read(Data(contentsOf: directory.appendingPathComponent(name + ".dng")))
        let width = metadata.activeArea.width, height = metadata.activeArea.height
        let source = try input(width: width, height: height) { _,_ in .init(0.02,0.04,0.06,1) }
        let reference = try Data(contentsOf: directory.appendingPathComponent(name + ".rgba32f"))
        try #require(reference.count == width * height * 16)
        let expected = reference.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let device = try device()

        let output = try F5CurvatureOutput.write(source, nativeWidth: width, nativeHeight: height, metadata: metadata, matrix: identity, device: device)

        let camera = try #require(output.camera)
        let data = try camera.mappedData(expectedBytes: width * height * 16)
        let maximum = data.withUnsafeBytes { bytes in
            zip(bytes.bindMemory(to: Float.self), expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        }
        let linearTolerance: Float = 2e-5 // Shared FP32 post-op linear-light budget, including HDR gain.
        #expect(maximum < linearTolerance)
        #expect(device.allocatedBytes == 0)
    }

    @Test(arguments: ["gain_rgb", "gain_before_warp", "gain_after_warp", "gain_warp_gain", "partial_planes_broadcast", "hdr_extension"])
    func stage3Operations_doNotAlsoEnterRAWPrediction(name: String) throws {
        let file = TestResources.fixtures.appendingPathComponent("f5-post-operations/" + name + ".dng")
        let metadata = try F5DNGMetadata.read(Data(contentsOf: file))

        let raw = try F5RAWCorrections(metadata: metadata)

        #expect(raw.gains.isEmpty)
    }

    @Test func fullWidthStrips_preservePixelOrderAndRemainderWithoutOperations() throws {
        let context = try F5TestContext(width: 520, height: 18), metadata = context.fixture.canonical[0].record.metadata
        let source = try input(width: 520, height: 18, scale: 2) { x,y in
            .init(-0.002 + Float(x) * 0.0001, 0.3 + Float(y) * 0.001, 1.2, 1)
        }
        let device = try device()

        let output = try F5CurvatureOutput.write(source, nativeWidth: 520, nativeHeight: 18, metadata: metadata, matrix: identity, device: device)

        let expected = try source.file.mappedData(expectedBytes: source.width * source.height * 16)
        let camera = try #require(output.camera)
        #expect(try camera.mappedData(expectedBytes: expected.count) == expected)
        #expect(try output.linear.mappedData(expectedBytes: expected.count) == expected)
    }

    @Test func cameraMatrix_appliesOnceAndKeepsSignedHDR() throws {
        let context = try F5TestContext(), metadata = context.fixture.canonical[0].record.metadata
        let source = try input(width: 8, height: 6, scale: 2) { _,_ in .init(0.2,0.3,1.2,1) }
        let matrix: [Double] = [-2,1,0, 0,3,0, 0,0,5], device = try device()

        let output = try F5CurvatureOutput.write(source, nativeWidth: 8, nativeHeight: 6, metadata: metadata, matrix: matrix, device: device)

        let data = try output.linear.mappedData(expectedBytes: 16 * 12 * 16)
        let maximum = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: SIMD4<Float>.self).reduce(Float(0)) { error,pixel in
                max(error, abs(pixel.x + 0.1), abs(pixel.y - 0.9), abs(pixel.z - 6), abs(pixel.w - 1))
            }
        }
        #expect(maximum < 1e-6) // A single FP32 3×3 transform, without range clipping.
    }

    @Test func cancelledOutput_releasesGPUWorkspaceAndPreservesSource() throws {
        let context = try F5TestContext(), metadata = context.fixture.canonical[0].record.metadata
        let source = try input(width: 8, height: 6) { _,_ in .init(0.2,0.3,0.4,1) }
        let expected = try source.file.mappedData(expectedBytes: 8 * 6 * 16), device = try device(cancelled: { true })

        #expect(throws: CancellationError.self) {
            try F5CurvatureOutput.write(source, nativeWidth: 8, nativeHeight: 6, metadata: metadata, matrix: identity, device: device)
        }

        #expect(device.allocatedBytes == 0)
        #expect(try source.file.mappedData(expectedBytes: expected.count) == expected)
    }
}
