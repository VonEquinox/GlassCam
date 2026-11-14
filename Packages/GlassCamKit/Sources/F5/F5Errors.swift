import ImagingCore
import Capture
import Foundation
import OSLog

public enum F5Code: String, Codable, Error, Sendable, CaseIterable {
    case unsupportedRAW = "UNSUPPORTED_RAW", unsupportedOpcode = "UNSUPPORTED_OPCODE"
    case profileMismatch = "PROFILE_MISMATCH", frameMissing = "FRAME_MISSING", duplicateFrame = "DUPLICATE_FRAME"
    case nonuniformMains = "NONUNIFORM_MAINS", physicalCameraChanged = "PHYSICAL_CAMERA_CHANGED"
    case isoChanged = "ISO_CHANGED", exposureAdjusted = "EXPOSURE_ADJUSTED", shortExposureLimited = "SHORT_EXPOSURE_LIMITED"
    case apertureChanged = "APERTURE_CHANGED", focusChanged = "FOCUS_CHANGED"
    case meteringUncertain = "METERING_UNCERTAIN", motionUncertain = "MOTION_UNCERTAIN"
    case highlightNotGuaranteed = "HIGHLIGHT_NOT_GUARANTEED", highlightMissing = "HIGHLIGHT_MISSING"
    case longCaptureWindow = "LONG_CAPTURE_WINDOW", ambiguousRegistration = "AMBIGUOUS_REGISTRATION"
    case occlusion = "OCCLUSION", responseModelMismatch = "RESPONSE_MODEL_MISMATCH", flicker = "FLICKER"
    case numericalStall = "NUMERICAL_STALL", nonfinite = "NONFINITE", budgetStop = "BUDGET_STOP"
    case memoryPressure = "MEMORY_PRESSURE", thermalLimit = "THERMAL_LIMIT"
    case colorTransformInvalid = "COLOR_TRANSFORM_INVALID", encodeMetadataInvalid = "ENCODE_METADATA_INVALID"
    case damagedBundle = "DAMAGED_BUNDLE", cancelled = "CANCELLED", unqualified = "UNQUALIFIED_BAYER"
    case mainCameraOnly = "MAIN_CAMERA_ONLY"
}

public struct F5Failure: LocalizedError, Sendable {
    public let code: F5Code
    public let detail: String
    private static let logger = Logger(subsystem: "dev.glasscam.prototype", category: "F5")
    public init(_ code: F5Code, _ detail: String) {
        self.code = code; self.detail = detail
        Self.logger.notice("\(code.rawValue, privacy: .public): \(detail, privacy: .public)")
    }
    public var errorDescription: String? {
        switch code {
        case .thermalLimit:
            return String(localized: "The camera is too hot. Let it cool, then try again.")
        case .memoryPressure, .budgetStop:
            return String(localized: "There is not enough memory to finish this photo. The originals were kept. Try again later.")
        case .frameMissing, .duplicateFrame, .cancelled:
            return String(localized: "The capture was interrupted. Any delivered originals were kept. You can discard the incomplete capture.")
        case .isoChanged, .exposureAdjusted, .nonuniformMains, .apertureChanged, .physicalCameraChanged, .flicker:
            return String(localized: "The RAW frames have inconsistent exposure settings. Fusion could not finish; the originals were kept.")
        case .motionUncertain, .ambiguousRegistration, .longCaptureWindow, .occlusion, .focusChanged, .meteringUncertain:
            return String(localized: "Focus or alignment was uncertain. Hold steady and try again.")
        case .unsupportedRAW, .unqualified, .mainCameraOnly:
            return String(localized: "RAW capture is unavailable for this camera configuration. Return to the main camera and try again.")
        case .damagedBundle:
            return String(localized: "The retained RAW files could not be verified. They have been kept for recovery.")
        case .colorTransformInvalid, .encodeMetadataInvalid, .profileMismatch, .responseModelMismatch, .unsupportedOpcode:
            return String(localized: "This RAW capture could not be processed with its camera information. The originals were kept.")
        case .shortExposureLimited:
            return String(localized: "The current exposure is too short for F5. Try a scene with less light.")
        case .highlightNotGuaranteed, .highlightMissing, .numericalStall, .nonfinite:
            return String(localized: "This photo could not be reconstructed. The originals were kept; you can retry or discard it.")
        }
    }
}

