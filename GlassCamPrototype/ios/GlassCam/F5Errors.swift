import Foundation

enum F5Code: String, Codable, Error, Sendable, CaseIterable {
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

struct F5Failure: LocalizedError, Sendable {
    let code: F5Code
    let detail: String
    init(_ code: F5Code, _ detail: String) { self.code = code; self.detail = detail }
    var errorDescription: String? {
        switch code {
        case .isoChanged:
            return String(localized:"The five RAW frames have inconsistent exposure settings. Fusion could not finish; the originals were kept.")
        case .shortExposureLimited:
            return String(localized:"The current exposure is too short for F5. Try a scene with less light.")
        default: return "F5 · \(code.rawValue): \(detail)"
        }
    }
}

