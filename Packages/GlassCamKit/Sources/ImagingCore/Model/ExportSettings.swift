import Foundation
import CoreGraphics

/// Capture and color processing are independent choices. Bayer modes enter the
/// common color pipeline after their own sensor reconstruction.
public enum CaptureQuality: String, CaseIterable, Codable, Sendable {
    case f5, balanced, quality, speed
    public static var allCases: [CaptureQuality] { [.speed, .balanced, .quality] }
    public var bayerFrameCount: Int? {
        switch self { case .speed: return 1; case .balanced: return 4; case .f5: return 5; case .quality: return nil }
    }
    public var usesBayer: Bool { bayerFrameCount != nil }
    public var title: String {
        switch self {
        case .f5: return "F5"
        case .speed: return "Speed"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }
    public func outputMegapixels(preferred: Int) -> Int { self == .speed ? 12 : preferred }
    public func sourceDimensions(available: [CGSize]) -> CGSize? {
        available.filter { size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return false }
            return !usesBayer || abs(Double(size.width * size.height) / 12_000_000 - 1) <= 0.08
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// Crop coordinates are resolved in oriented source pixels, never UI points.
/// The reference and decoded bitmaps use floor offsets from the top-left.
/// CI rectangles use a lower-left origin; ciY converts only those coordinates.
public enum ImageCrop: String, Codable, Equatable, Sendable {
    case none, centeredSquare

    public func resolve(width: Int, height: Int) throws -> PixelCrop {
        guard width > 0, height > 0 else { throw PipelineError.invalidImage }
        let side = min(width, height)
        let cropWidth = self == .centeredSquare ? side : width
        let cropHeight = self == .centeredSquare ? side : height
        return PixelCrop(x: (width - cropWidth) / 2,
                         top: (height - cropHeight) / 2,
                         width: cropWidth, height: cropHeight, sourceHeight: height)
    }
}

public struct PixelCrop: Equatable, Sendable {
    public let x: Int
    public let top: Int
    public let width: Int
    public let height: Int
    public let sourceHeight: Int
    var ciY: Int { sourceHeight - top - height }
    var ciRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(ciY), width: CGFloat(width), height: CGFloat(height))
    }
}

/// Explicit targets retain their no-upscale contract. Quality uses the selected
/// 24/48 MP policy; Bayer producers supply their own native output grid.
public struct ExportSettings: Codable, Equatable, Sendable {
    public let targetWidth: Int?
    public let targetHeight: Int?
    package let cameraMegapixels: Int?
    public let framing: CaptureFraming?
    public static let native = ExportSettings(targetWidth: nil, targetHeight: nil)

    public init(targetWidth: Int?, targetHeight: Int?, cameraMegapixels: Int? = nil,
         framing: CaptureFraming? = nil) {
        self.targetWidth = targetWidth; self.targetHeight = targetHeight
        self.cameraMegapixels = cameraMegapixels; self.framing = framing
    }

    public static func camera(_ megapixels: Int, framing: CaptureFraming? = nil) -> ExportSettings {
        ExportSettings(targetWidth: nil, targetHeight: nil, cameraMegapixels: megapixels, framing: framing)
    }

    public func withFraming(_ value: CaptureFraming) -> ExportSettings {
        ExportSettings(targetWidth: targetWidth, targetHeight: targetHeight,
                       cameraMegapixels: cameraMegapixels, framing: value)
    }

    package func effectivePixels(sourceWidth: Int, sourceHeight: Int, crop: ImageCrop = .none) throws -> Double {
        let area = try crop.resolve(width: sourceWidth, height: sourceHeight)
        return (framing ?? CaptureFraming()).effectivePixels(decodedWidth: sourceWidth, decodedHeight: sourceHeight,
                                                             cropWidth: area.width, cropHeight: area.height)
    }

    public func selectedOutputMegapixels(sourceWidth: Int, sourceHeight: Int, crop: ImageCrop = .none) throws -> Int? {
        guard let cameraMegapixels else { return nil }
        guard [12, 24, 48].contains(cameraMegapixels), framing?.isValid != false else { throw PipelineError.unsupportedOutput }
        if cameraMegapixels == 12 { return 12 }
        let effective = try effectivePixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: crop)
        return cameraMegapixels == 48 && effective >= 24_000_000 ? 48 : 24
    }

    public func dimensions(sourceWidth: Int, sourceHeight: Int,
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
