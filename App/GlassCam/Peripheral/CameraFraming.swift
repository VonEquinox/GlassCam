import CoreGraphics
import Foundation

/// Presentation geometry only. These rectangles never crop or transform captured data.
struct CameraFraming {
    let window: CGRect
    let photo: CGRect
    // Uncropped sensor view at exactly the same scale as the final photo crop.
    // The photo frame clips this rect when the selected recipe crops to square.
    let sourcePhoto: CGRect
    let perimeter: [CGRect]
    let usesVerticalControls: Bool

    init(size: CGSize, photoAspectRatio: CGFloat, cropToSquare: Bool = false) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        window = CGRect(x: 0, y: 0, width: width, height: height)
        // The photograph is always the largest aspect-fit rectangle in the actual
        // window. Controls must adapt to the remaining space, never the reverse.
        let aspect = photoAspectRatio.isFinite && photoAspectRatio > 0 ? photoAspectRatio : 1
        let outputAspect: CGFloat = cropToSquare ? 1 : aspect
        let photoWidth = min(width, height * outputAspect)
        let photoHeight = photoWidth / outputAspect
        photo = CGRect(x: (width - photoWidth) / 2, y: (height - photoHeight) / 2,
                       width: photoWidth, height: photoHeight)
        let sourceWidth = cropToSquare ? photoWidth * max(1, aspect) : photoWidth
        let sourceHeight = cropToSquare ? photoHeight * max(1, 1 / aspect) : photoHeight
        sourcePhoto = CGRect(x: (width - sourceWidth) / 2, y: (height - sourceHeight) / 2,
                             width: sourceWidth, height: sourceHeight)
        // A landscape window can still have horizontal spare regions (and vice
        // versa): derive chrome placement from the fitted photo, not orientation.
        usesVerticalControls = photo.minX > photo.minY
        // Four disjoint rectangular panes: their union is exactly window minus photo.
        perimeter = [
            CGRect(x: 0, y: 0, width: width, height: photo.minY),
            CGRect(x: 0, y: photo.maxY, width: width, height: height - photo.maxY),
            CGRect(x: 0, y: photo.minY, width: photo.minX, height: photo.height),
            CGRect(x: photo.maxX, y: photo.minY, width: width - photo.maxX, height: photo.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
