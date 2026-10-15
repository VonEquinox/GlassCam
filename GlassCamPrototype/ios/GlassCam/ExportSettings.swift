import Foundation
import CoreGraphics

/// Crop coordinates are resolved in oriented source pixels, never UI points.
/// The reference and decoded bitmaps use floor offsets from the top-left.
/// CI rectangles use a lower-left origin; ciY converts only those coordinates.
enum ImageCrop: String, Codable, Equatable, Sendable {
    case none, centeredSquare

    func resolve(width: Int, height: Int) throws -> PixelCrop {
        guard width > 0, height > 0 else { throw PipelineError.invalidImage }
        let side = min(width, height)
        let cropWidth = self == .centeredSquare ? side : width
        let cropHeight = self == .centeredSquare ? side : height
        return PixelCrop(x: (width - cropWidth) / 2,
                         top: (height - cropHeight) / 2,
                         width: cropWidth, height: cropHeight, sourceHeight: height)
    }
}

struct PixelCrop: Equatable, Sendable {
    let x: Int
    let top: Int
    let width: Int
    let height: Int
    let sourceHeight: Int
    var ciY: Int { sourceHeight - top - height }
    var ciRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(ciY), width: CGFloat(width), height: CGFloat(height))
    }
}

/// Physical-lens capability selection supplies an allowed uncropped output size.
/// Crop keeps its scale: a 4:3 48MP source becomes a 1:1 crop, never a 48MP upscale.
struct ExportSettings: Equatable, Sendable {
    let targetWidth: Int?
    let targetHeight: Int?
    static let native = ExportSettings(targetWidth: nil, targetHeight: nil)

    func dimensions(sourceWidth: Int, sourceHeight: Int,
                    crop: ImageCrop = .none) throws -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { throw PipelineError.invalidImage }
        guard targetWidth != nil || targetHeight != nil else {
            let result = try crop.resolve(width: sourceWidth, height: sourceHeight)
            return (result.width, result.height)
        }
        guard let selectedWidth = targetWidth, let selectedHeight = targetHeight,
              selectedWidth > 0, selectedHeight > 0 else { throw PipelineError.unsupportedOutput }
        let swap = (sourceWidth < sourceHeight) != (selectedWidth < selectedHeight)
        let width = swap ? selectedHeight : selectedWidth
        let height = swap ? selectedWidth : selectedHeight
        guard width <= sourceWidth, height <= sourceHeight,
              abs(Double(width) / Double(height) - Double(sourceWidth) / Double(sourceHeight)) < 1e-12 else {
            throw PipelineError.unsupportedOutput
        }
        let result = try crop.resolve(width: width, height: height)
        return (result.width, result.height)
    }
}
