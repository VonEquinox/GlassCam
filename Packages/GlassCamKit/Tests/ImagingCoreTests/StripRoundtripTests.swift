import Testing
import CoreImage
import CoreGraphics
import Foundation

@Suite struct StripRoundtripTests {
    @Test(arguments: [1, 29, 64, 131])
    func floatBitmap_partitionPreservesTopDownPixels(stripRows: Int) throws {
        let width = 7, height = 131
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf.rawValue])
        var marker = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            marker[i] = Float(y) / Float(height - 1)
            marker[i + 1] = Float(x) / Float(width - 1)
            marker[i + 2] = y < 64 ? 0.125 : y < 128 ? 0.5 : 0.875
        } }
        func image(_ pixels: [Float]) -> CIImage {
            CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        }
        func render(_ image: CIImage, y: Int, rows: Int) -> [Float] {
            var result = [Float](repeating: 0, count: width * rows * 4)
            result.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: y, width: width, height: rows), format: .RGBAf, colorSpace: space)
            }
            return result
        }
        let source = image(marker)
        let full = render(source, y: 0, rows: height)

        let strips = stride(from: 0, to: height, by: stripRows).flatMap { start in
            let rows = min(stripRows, height - start)
            return render(source, y: height - start - rows, rows: rows)
        }
        let reconstructed = render(image(strips), y: 0, rows: height)

        #expect(full == marker)
        #expect(strips == full)
        // Float32 Core Image round-trip tolerance retained from the original marker fixture.
        let floatRoundtripTolerance: Float = 1e-6
        let maximumError = zip(full, reconstructed).map { abs($0 - $1) }.max() ?? .infinity
        #expect(maximumError <= floatRoundtripTolerance)
    }
}
