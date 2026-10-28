import Foundation
import CoreGraphics

/// F5 owns a five-frame Bayer transaction. The legacy speed value is retained
/// only to decode unfinished old photos; it is no longer offered in the UI.
enum CaptureQuality: String, CaseIterable, Codable, Sendable {
    case f5, balanced, quality, speed
    static var allCases: [CaptureQuality] { [.f5, .balanced, .quality] }
    var title: String {
        switch self {
        case .f5: return "F5"
        case .speed: return "Speed"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }
    func outputMegapixels(preferred: Int) -> Int { self == .speed ? 12 : preferred }
    func sourceDimensions(available: [CGSize]) -> CGSize? {
        available.filter { size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return false }
            return self != .speed || abs(Double(size.width * size.height) / 12_000_000 - 1) <= 0.08
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
}

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

/// Explicit legacy targets retain their original no-upscale contract. Camera
/// captures use 12MP for Speed, or the selected 24/48MP policy after recipe crop.
struct ExportSettings: Codable, Equatable, Sendable {
    let targetWidth: Int?
    let targetHeight: Int?
    let cameraMegapixels: Int?
    let framing: CaptureFraming?
    static let native = ExportSettings(targetWidth: nil, targetHeight: nil)

    init(targetWidth: Int?, targetHeight: Int?, cameraMegapixels: Int? = nil,
         framing: CaptureFraming? = nil) {
        self.targetWidth = targetWidth; self.targetHeight = targetHeight
        self.cameraMegapixels = cameraMegapixels; self.framing = framing
    }

    static func camera(_ megapixels: Int, framing: CaptureFraming? = nil) -> ExportSettings {
        ExportSettings(targetWidth: nil, targetHeight: nil, cameraMegapixels: megapixels, framing: framing)
    }

    func withFraming(_ value: CaptureFraming) -> ExportSettings {
        ExportSettings(targetWidth: targetWidth, targetHeight: targetHeight,
                       cameraMegapixels: cameraMegapixels, framing: value)
    }

    func effectivePixels(sourceWidth: Int, sourceHeight: Int, crop: ImageCrop = .none) throws -> Double {
        let area = try crop.resolve(width: sourceWidth, height: sourceHeight)
        return (framing ?? CaptureFraming()).effectivePixels(decodedWidth: sourceWidth, decodedHeight: sourceHeight,
                                                             cropWidth: area.width, cropHeight: area.height)
    }

    func selectedOutputMegapixels(sourceWidth: Int, sourceHeight: Int, crop: ImageCrop = .none) throws -> Int? {
        guard let cameraMegapixels else { return nil }
        guard [12, 24, 48].contains(cameraMegapixels), framing?.isValid != false else { throw PipelineError.unsupportedOutput }
        if cameraMegapixels == 12 { return 12 }
        let effective = try effectivePixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: crop)
        return cameraMegapixels == 48 && effective >= 24_000_000 ? 48 : 24
    }

    func dimensions(sourceWidth: Int, sourceHeight: Int,
                    crop: ImageCrop = .none) throws -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { throw PipelineError.invalidImage }
        if let megapixels = try selectedOutputMegapixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: crop) {
            let area = try crop.resolve(width: sourceWidth, height: sourceHeight)
            let pixels = Double(area.width) * Double(area.height)
            // Keep native nominal 12/24/48MP grids instead of resampling solely to
            // turn a manufacturer's nominal MP count into an exact round number.
            if abs(pixels / (Double(megapixels) * 1_000_000) - 1) <= 0.025 {
                return (area.width, area.height)
            }
            let scale = sqrt(Double(megapixels) * 1_000_000 / pixels)
            let width = max(2, Int((Double(area.width) * scale / 2).rounded()) * 2)
            let height = max(2, Int((Double(area.height) * scale / 2).rounded()) * 2)
            guard abs(Double(width) * Double(height) / (Double(megapixels) * 1_000_000) - 1) < 0.02,
                  abs((Double(width) / Double(height)) / (Double(area.width) / Double(area.height)) - 1) < 0.01 else {
                throw PipelineError.unsupportedOutput
            }
            return (width, height)
        }
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
