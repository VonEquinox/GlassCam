import Testing
import Foundation
import CoreImage
import simd
@testable import Peripheral

struct PeripheralGeometryTests {
    @Test(arguments: [(SIMD2<Float>(0.5, 0.5), SIMD2<Float>(0.5, 0.5)), (SIMD2<Float>(0, 0), SIMD2<Float>(0.25, 0.25))])
    func fixedFOVTransform_preservesCenterAndCrop(input: (SIMD2<Float>, SIMD2<Float>)) throws {
        let transform = PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3, width: 192, height: 256, ratio: 2)
        let point = try #require(PeripheralAlignmentWorker.project(input.0, using: transform))
        #expect(simd_length(point - input.1) < 0.00001)
    }
    @Test func imageTranslation_isInvertedWithTopLeftTextureCoordinates() throws {
        var homography = matrix_identity_float3x3; homography.columns.2 = SIMD3(12, 16, 1)
        let transform = PeripheralAlignmentWorker.samplingTransform(homography: homography, width: 192, height: 256, ratio: 2)
        let point = try #require(PeripheralAlignmentWorker.project(SIMD2(0.5, 0.5), using: transform))
        #expect(abs(Double(point.x) - (0.5 - 12.0 / 384)) < 0.00001)
        #expect(abs(Double(point.y) - (0.5 + 16.0 / 512)) < 0.00001)
    }
    @Test func degenerateProjection_isRejected() {
        #expect(PeripheralAlignmentWorker.project(.zero, using: simd_float3x3()) == nil)
    }
    @Test func portraitSeams_onlyUseAdjacentHorizontalPanes() {
        #expect(PeripheralSeams(photo: CGRect(x: 0, y: 185, width: 440, height: 586), window: CGSize(width: 440, height: 956)) == .horizontal)
    }
    @Test func landscapeSeams_onlyUseAdjacentVerticalPanes() {
        #expect(PeripheralSeams(photo: CGRect(x: 185, y: 0, width: 586, height: 440), window: CGSize(width: 956, height: 440)) == .vertical)
    }
    @Test func fullWindowPhoto_hasNoPeripheralSeam() {
        #expect(PeripheralSeams(photo: CGRect(x: 0, y: 0, width: 440, height: 956), window: CGSize(width: 440, height: 956)).isEmpty)
    }
    @Test func nonzeroExtentRaster_keepsRowsAndStride() throws {
        let width = 5, height = 3
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            pixels[(y * width + x) * 4] = UInt8(20 + x * 30)
            pixels[(y * width + x) * 4 + 1] = UInt8(20 + y * 60)
            pixels[(y * width + x) * 4 + 2] = UInt8(10 + x * 9 + y * 11)
        } }
        let image = CIImage(cvPixelBuffer: try PeripheralFixtures.pixelBuffer(rgba: pixels, width: width, height: height))
            .transformed(by: CGAffineTransform(translationX: 17, y: 23))
        let actual = PeripheralAlignmentWorker().bitmap(image, bounds: CGRect(x: 17, y: 23, width: width, height: height), width: width, height: height)
        #expect(actual == pixels)
    }
}
