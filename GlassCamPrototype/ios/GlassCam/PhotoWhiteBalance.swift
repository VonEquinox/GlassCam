import Foundation
import CoreImage

/// The decoder's as-shot white point, before evaluating either reduced or full
/// RAW output. Apple applies the RAW WB; HNCS uses xy to construct its virtual
/// capture baseline, never iPhone sensor gains or a second temperature filter.
struct PhotoWhiteBalance: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case appleRAW, renderedD65, fallbackD65 }
    let origin: Origin
    let temperature: Double
    let tint: Double
    let x: Double
    let y: Double

    static let renderedD65 = PhotoWhiteBalance(origin: .renderedD65, temperature: 6504,
                                              tint: 0, x: 0.3127, y: 0.3290)
    static let fallbackD65 = PhotoWhiteBalance(origin: .fallbackD65, temperature: 6504,
                                              tint: 0, x: 0.3127, y: 0.3290)

    static func asShot(_ raw: CIRAWFilter) -> PhotoWhiteBalance {
        let point = raw.neutralChromaticity
        let value = PhotoWhiteBalance(origin: .appleRAW, temperature: Double(raw.neutralTemperature),
                                     tint: Double(raw.neutralTint), x: point.x, y: point.y)
        return value.isValid ? value : .fallbackD65
    }

    var isValid: Bool {
        temperature.isFinite && (2000...50000).contains(temperature) &&
        tint.isFinite && (-150...150).contains(tint) && modelKelvin != nil
    }

    /// Robertson CCT is used only for the virtual factory LUT/matrix selection.
    /// Full xy, including the off-locus tint, drives the RGB adaptation.
    var modelKelvin: Double? {
        var gains = [Double](repeating: 0, count: 3)
        var kelvin = 0.0
        let status = gains.withUnsafeMutableBufferPointer {
            hncs_whitepoint_parameters(x, y, $0.baseAddress, &kelvin)
        }
        return status == 0 ? kelvin : nil
    }

    var description: String {
        switch origin {
        case .appleRAW: return String(format: "Auto WB · %.0f K · Tint %+.1f", temperature, tint)
        case .renderedD65: return "White balance baked into source"
        case .fallbackD65: return "Source white point unavailable · D65 fallback"
        }
    }
}
