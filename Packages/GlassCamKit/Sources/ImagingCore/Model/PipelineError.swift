import Foundation

public enum PipelineError: LocalizedError {
    case invalidImage, rendering, encoding, unsupportedOutput, metadata
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return String(localized: "This image could not be decoded. Try a JPEG, PNG, HEIC, or supported DNG.")
        case .rendering: return String(localized: "The photo could not be processed. Its source was kept; try again.")
        case .unsupportedOutput: return String(localized: "This photo cannot use the requested output dimensions. Its source was kept.")
        case .encoding: return String(localized: "The HDR photo could not be encoded. Its source was kept; try again.")
        case .metadata: return String(localized: "The photo's capture information could not be preserved. Its source has been retained for retry.")
        }
    }
}
