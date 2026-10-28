import Foundation

public enum PipelineError: LocalizedError {
    case invalidImage, rendering, encoding, unsupportedOutput, metadata
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image could not be decoded. Try a JPEG, PNG, HEIC, or supported DNG."
        case .rendering: return "The image renderer could not create an output."
        case .unsupportedOutput: return "The selected sensor output exceeds the genuine source or changes its uncropped aspect ratio. Capture at a supported resolution; upsampling is disabled."
        case .encoding: return "The processed image could not be encoded as 10-bit HDR HEIF. No lower-bit-depth fallback was saved."
        case .metadata: return "The photo's capture information could not be preserved. Its source has been retained for retry."
        }
    }
}
