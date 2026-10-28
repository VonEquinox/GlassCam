import CoreImage

/// Scene-linear, characterized input. Its producer owns validation and errors.
package protocol SceneLinearImage {
    func validatedWhiteBalance() throws -> PhotoWhiteBalance
    var sourceISO: Int { get }
    var image: CIImage { get throws }
}
