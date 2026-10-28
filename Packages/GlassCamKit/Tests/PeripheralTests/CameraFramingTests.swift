import Testing
import Foundation
@testable import Peripheral

struct CameraFramingTests {
    static let sizes: [CGSize] = [CGSize(width: 440, height: 956), CGSize(width: 956, height: 440),
        CGSize(width: 512, height: 512), CGSize(width: 1, height: 5000), CGSize(width: 5000, height: 1),
        CGSize(width: 0.01, height: 0.02)]
    @Test(arguments: sizes, [CGFloat(0.75), 1, 4.0 / 3, 0.01, 100])
    func photograph_isMaximalCenteredAspectFit(size: CGSize, aspect: CGFloat) {
        let framing = CameraFraming(size: size, photoAspectRatio: aspect)
        #expect(abs(framing.photo.midX - framing.window.midX) < 1e-9)
        #expect(abs(framing.photo.midY - framing.window.midY) < 1e-9)
        #expect(abs(framing.photo.width / framing.photo.height - aspect) < 1e-9)
        #expect(abs(framing.photo.width - size.width) < 1e-9 || abs(framing.photo.height - size.height) < 1e-9)
    }
    @Test(arguments: sizes, [CGFloat(0.75), 1, 4.0 / 3, 0.01, 100])
    func perimeter_exactlyPartitionsWindowOutsidePhotograph(size: CGSize, aspect: CGFloat) {
        let framing = CameraFraming(size: size, photoAspectRatio: aspect)
        let area = framing.perimeter.reduce(framing.photo.width * framing.photo.height) { $0 + $1.width * $1.height }
        let overlap = framing.perimeter.flatMap { a in framing.perimeter.filter { $0 != a }.map { a.intersection($0) } }
        #expect(abs(area - size.width * size.height) < max(1e-9, size.width * size.height * 1e-12))
        #expect(framing.perimeter.filter { $0.width <= 0 || $0.height <= 0 }.isEmpty)
        #expect(framing.perimeter.filter { !$0.intersection(framing.photo).isNull && !$0.intersection(framing.photo).isEmpty }.isEmpty)
        #expect(overlap.filter { !$0.isNull && !$0.isEmpty }.isEmpty)
    }
    @Test(arguments: sizes, [CGFloat(0.25), 2, 10])
    func uniformResize_preservesNormalizedPhotoAndPerimeter(size: CGSize, scale: CGFloat) {
        let original = CameraFraming(size: size, photoAspectRatio: 0.75)
        let resized = CameraFraming(size: CGSize(width: size.width * scale, height: size.height * scale), photoAspectRatio: 0.75)
        let actual = ([resized.photo] + resized.perimeter).flatMap { [$0.minX / scale, $0.minY / scale, $0.width / scale, $0.height / scale] }
        let expected = ([original.photo] + original.perimeter).flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
        #expect(actual.count == expected.count)
        #expect(zip(actual, expected).map { abs($0 - $1) }.max()! < 1e-9)
    }
    @Test(arguments: [CGSize.zero, CGSize(width: -1, height: -2), CGSize(width: CGFloat.infinity, height: 32), CGSize(width: 32, height: CGFloat.nan)])
    func invalidWindow_hasEmptyFinitePhoto(size: CGSize) {
        let framing = CameraFraming(size: size, photoAspectRatio: 0.75)
        #expect(framing.photo.isEmpty)
        #expect([framing.photo.minX, framing.photo.minY, framing.photo.width, framing.photo.height].allSatisfy { $0.isFinite })
    }
    @Test(arguments: [CGFloat.nan, .infinity, 0, -1])
    func invalidAspect_fallsBackToMaximalSquare(aspect: CGFloat) {
        let framing = CameraFraming(size: CGSize(width: 440, height: 956), photoAspectRatio: aspect)
        #expect(framing.photo == CGRect(x: 0, y: 258, width: 440, height: 440))
    }
    @Test(arguments: [CGFloat(0.75), 4.0 / 3], sizes)
    func historicalSquareFrame_preservesSensorAspectCenterAndScale(aspect: CGFloat, size: CGSize) {
        let framing = CameraFraming(size: size, photoAspectRatio: aspect, cropToSquare: true)
        #expect(framing.photo.width == framing.photo.height)
        #expect(framing.sourcePhoto.midX == framing.photo.midX)
        #expect(framing.sourcePhoto.midY == framing.photo.midY)
        #expect(abs(framing.sourcePhoto.width / framing.sourcePhoto.height - aspect) < 1e-9)
        #expect(min(framing.sourcePhoto.width, framing.sourcePhoto.height) == framing.photo.width)
    }
}
