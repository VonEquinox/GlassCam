import CoreImage

/// Scene-linear, characterized input. Its producer owns validation and errors.
package protocol SceneLinearImage {
    func validatedWhiteBalance() throws -> PhotoWhiteBalance
    var sourceISO: Int { get }
    var baselineSharpness: Double { get }
    var image: CIImage { get throws }
    func validateImageReads() throws
}
extension SceneLinearImage {
    package var baselineSharpness: Double { 0 }
    package func validateImageReads() throws {}
}
