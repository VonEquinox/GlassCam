import CoreGraphics

enum CaptureReviewGeometry {
    static func panLimits(viewport: CGSize, image: CGSize, scale: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
              scale.isFinite, scale >= 1 else { return .zero }
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: max(0, (image.width * fit * scale - viewport.width) / 2),
                      height: max(0, (image.height * fit * scale - viewport.height) / 2))
    }
    static func clamp(_ pan: CGSize, to limits: CGSize) -> CGSize {
        CGSize(width: min(limits.width, max(-limits.width, pan.width)),
               height: min(limits.height, max(-limits.height, pan.height)))
    }
    static func shouldDismiss(scale: CGFloat, translation: CGSize, predicted: CGSize) -> Bool {
        scale <= 1 && translation.height > abs(translation.width) * 1.25 &&
            (translation.height >= 100 || (translation.height >= 25 && predicted.height >= 240))
    }
}
