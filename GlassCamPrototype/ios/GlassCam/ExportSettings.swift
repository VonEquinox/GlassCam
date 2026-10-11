import Foundation

/// Physical-lens capability selection supplies an allowed output size. This
/// backend never invents larger pixels. Nil means the genuine source size.
struct ExportSettings: Equatable, Sendable {
    let targetWidth: Int?
    let targetHeight: Int?
    static let native = ExportSettings(targetWidth: nil, targetHeight: nil)

    func dimensions(sourceWidth: Int, sourceHeight: Int) throws -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { throw PipelineError.invalidImage }
        guard targetWidth != nil || targetHeight != nil else { return (sourceWidth, sourceHeight) }
        guard let selectedWidth = targetWidth, let selectedHeight = targetHeight,
              selectedWidth > 0, selectedHeight > 0 else { throw PipelineError.unsupportedOutput }
        let swap = (sourceWidth < sourceHeight) != (selectedWidth < selectedHeight)
        let width = swap ? selectedHeight : selectedWidth
        let height = swap ? selectedWidth : selectedHeight
        guard width <= sourceWidth, height <= sourceHeight,
              abs(Double(width) / Double(height) - Double(sourceWidth) / Double(sourceHeight)) < 1e-12 else {
            throw PipelineError.unsupportedOutput
        }
        return (width, height)
    }
}
