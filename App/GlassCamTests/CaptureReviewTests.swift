import CoreGraphics
import Testing
@testable import GlassCam

struct CaptureReviewTests {
    @Test func landscapePhotoInPortrait_limitsPanToScaledImageInsteadOfLetterbox() {
        let limits = CaptureReviewGeometry.panLimits(viewport: CGSize(width: 300, height: 600),
            image: CGSize(width: 4000, height: 3000), scale: 2)

        #expect(limits == CGSize(width: 150, height: 0))
    }

    @Test(arguments: [(CGFloat(1), CGSize(width: 10, height: 140), true),
                      (CGFloat(2), CGSize(width: 10, height: 140), false),
                      (CGFloat(1), CGSize(width: 200, height: 140), false),
                      (CGFloat(1), CGSize(width: 0, height: -140), false)])
    func onlyDownwardUnzoomedDrag_dismisses(scale: CGFloat, translation: CGSize, expected: Bool) {
        let result = CaptureReviewGeometry.shouldDismiss(scale: scale, translation: translation, predicted: translation)

        #expect(result == expected)
    }

    @Test func quickDownwardFlick_dismissesAfterMeaningfulTravel() {
        let result = CaptureReviewGeometry.shouldDismiss(scale: 1, translation: CGSize(width: 0, height: 30),
                                                         predicted: CGSize(width: 0, height: 260))

        #expect(result)
    }
}
