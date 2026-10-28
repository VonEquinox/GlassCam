import CoreImage

extension PhotoWhiteBalance {
    static func asShot(_ raw: CIRAWFilter) -> PhotoWhiteBalance {
        let point = raw.neutralChromaticity
        let value = PhotoWhiteBalance(origin: .appleRAW, temperature: Double(raw.neutralTemperature),
                                     tint: Double(raw.neutralTint), x: point.x, y: point.y)
        return value.isValid ? value : .fallbackD65
    }

}
