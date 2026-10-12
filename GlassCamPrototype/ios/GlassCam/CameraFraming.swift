import CoreGraphics
import Foundation

/// Presentation geometry only. These rectangles never crop or transform captured data.
struct CameraFraming {
    let window: CGRect
    let photo: CGRect
    let perimeter: [CGRect]
    let usesVerticalControls: Bool
    let peripheral: CGRect?
    let hasPeripheralCoverage: Bool

    init(size: CGSize, photoAspectRatio: CGFloat,
         centerHorizontalFieldOfView: Float? = nil,
         peripheralHorizontalFieldOfView: Float? = nil,
         peripheralAspectRatio: CGFloat? = nil) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        window = CGRect(x: 0, y: 0, width: width, height: height)
        // The photograph is always the largest aspect-fit rectangle in the actual
        // window. Controls must adapt to the remaining space, never the reverse.
        let aspect = photoAspectRatio.isFinite && photoAspectRatio > 0 ? photoAspectRatio : 1
        let photoWidth = min(width, height * aspect)
        let photoHeight = photoWidth / aspect
        photo = CGRect(x: (width - photoWidth) / 2, y: (height - photoHeight) / 2,
                       width: photoWidth, height: photoHeight)
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
        // First-order pinhole mapping only, NOT calibrated cross-camera alignment.
        // The lenses have distinct optical centers, distortion and parallax. FOV
        // scales a genuine wider image without inventing or stretching pixels.
        if let centerFOV = centerHorizontalFieldOfView,
           let widerFOV = peripheralHorizontalFieldOfView,
           let widerAspect = peripheralAspectRatio,
           centerFOV.isFinite, widerFOV.isFinite,
           centerFOV > 0, widerFOV > centerFOV, widerFOV < 180,
           widerAspect.isFinite, widerAspect > 0, photoWidth > 0, photoHeight > 0 {
            let ratio = CGFloat(tan(Double(widerFOV) * .pi / 360) /
                                tan(Double(centerFOV) * .pi / 360))
            // AVFoundation's horizontal FOV is in the unrotated sensor axes:
            // in portrait that sensor-horizontal extent is the displayed height.
            let extent: CGSize
            if aspect < 1 {
                let sensorHorizontalExtent = photoHeight * ratio
                extent = CGSize(width: sensorHorizontalExtent * widerAspect,
                                height: sensorHorizontalExtent)
            } else {
                let sensorHorizontalExtent = photoWidth * ratio
                extent = CGSize(width: sensorHorizontalExtent,
                                height: sensorHorizontalExtent / widerAspect)
            }
            let rect = CGRect(x: (width - extent.width) / 2,
                              y: (height - extent.height) / 2,
                              width: extent.width, height: extent.height)
            peripheral = rect
            // No fill-cropping, scaling-to-cover, mirroring, or synthetic margins.
            // A finite real lens cannot cover every arbitrary window aspect.
            hasPeripheralCoverage = extent.width.isFinite && extent.height.isFinite &&
                rect.minX <= 0 && rect.minY <= 0 && rect.maxX >= width && rect.maxY >= height
        } else {
            peripheral = nil
            hasPeripheralCoverage = false
        }
    }
}
