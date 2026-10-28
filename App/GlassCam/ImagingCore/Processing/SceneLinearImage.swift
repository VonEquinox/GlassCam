import CoreImage

/// Scene-linear, characterized input. Its producer owns validation and errors.
protocol SceneLinearImage {
    func validatedWhiteBalance() throws -> PhotoWhiteBalance
    var sourceISO: Int { get }
    var image: CIImage { get throws }
}
