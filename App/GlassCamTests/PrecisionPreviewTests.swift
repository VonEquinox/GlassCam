import CoreImage
import Testing
import ImagingCore
@testable import GlassCam

struct PrecisionPreviewTests {
    private func raster(_ gray: Float, width: Int = 4) throws -> PreviewRaster {
        try PreviewRaster(linearRGBA: (0..<width*2).flatMap { _ in [gray,gray,gray,1] },width: width,height: 2)
    }
    private func pixels(_ image: CIImage) -> [Float] {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space,.workingFormat: CIFormat.RGBAf.rawValue])
        var pixels = [Float](repeating: 0,count: 4*2*4)
        context.render(image,toBitmap: &pixels,rowBytes: 4*16,bounds: CGRect(x:0,y:0,width:4,height:2),format:.RGBAf,colorSpace:space)
        return pixels
    }
    @Test(arguments: [(CGFloat(0),[Float(0.25),0.25,0.25,0.25]),
                      (CGFloat(0.5),[Float(2),2,0.25,0.25]),
                      (CGFloat(1),[Float(2),2,2,2])])
    func comparisonFraction_compositesExistingFloatRasters(fraction: CGFloat, expected: [Float]) throws {
        let source = try raster(0.25), processed = try raster(2)
        let image = PrecisionPreview.Renderer.composition(source: source,processed: processed,fraction: fraction,size: CGSize(width:4,height:2))
        let actual = pixels(image)
        // Float color-space conversion is accurate to the existing preview tolerance.
        let floatTolerance: Float = 1e-5
        #expect(zip(stride(from:0,to:16,by:4).map { actual[$0] },expected).map { abs($0-$1) }.max()! < floatTolerance)
        #expect(source.width == processed.width)
    }
    @Test func mismatchedResult_keepsUndistortedSource() throws {
        let source = try raster(0.25), processed = try raster(2,width: 2)
        let image = PrecisionPreview.Renderer.composition(source: source,processed: processed,fraction: nil,size: CGSize(width:4,height:2))
        let reference = PrecisionPreview.Renderer.composition(source: source,processed: nil,fraction: nil,size: CGSize(width:4,height:2))
        #expect(pixels(image) == pixels(reference))
    }
}
