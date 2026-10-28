import Foundation

/// The source look is independent of a color engine's native render revision.
/// Missing policy in a saved photo preserves the original input for retries.
public enum RAWInputPolicy: String, Codable, Sendable { case legacy, cameraNeutral }

/// Immutable RAW input policy. Camera-neutral input removes Apple's global
/// contrast curve while retaining this photo's exposure and local tone mapping.
/// HNCS disables decoder sharpening before its own native sharpness stage.
public struct RAWDecodeRecipe: Codable, Equatable, Sendable {
    enum Rendering: String, Codable, Sendable { case appleRendered, sceneLinear, cameraNeutral }
    let rendering: Rendering
    let decoderVersion: String?
    let linearExposureEV: Double
    let decoderExposureEV: Float
    let edrAmount: Float?
    /// nil keeps the decoder default; HNCS explicitly requests zero before its
    /// own sharpness stage. BaselineSharpness belongs to this RAW, not a preset.
    let sharpnessAmount: Float?
    let baselineSharpness: Double?

    init(rendering: Rendering = .appleRendered, decoderVersion: String? = nil,
         linearExposureEV: Double = 0, decoderExposureEV: Float = 0, edrAmount: Float? = nil,
         sharpnessAmount: Float? = nil, baselineSharpness: Double? = nil) {
        self.rendering = rendering; self.decoderVersion = decoderVersion
        self.linearExposureEV = linearExposureEV; self.decoderExposureEV = decoderExposureEV
        self.edrAmount = edrAmount
        self.sharpnessAmount = sharpnessAmount; self.baselineSharpness = baselineSharpness
    }
    public static let current = RAWDecodeRecipe()
    static let sceneLinear = RAWDecodeRecipe(rendering: .sceneLinear)
    var cameraNeutralInput: RAWDecodeRecipe {
        RAWDecodeRecipe(rendering: .cameraNeutral, decoderVersion: decoderVersion,
            linearExposureEV: linearExposureEV, decoderExposureEV: decoderExposureEV,
            edrAmount: edrAmount, sharpnessAmount: sharpnessAmount, baselineSharpness: baselineSharpness)
    }
    var withoutDecoderSharpness: RAWDecodeRecipe {
        RAWDecodeRecipe(rendering: rendering, decoderVersion: decoderVersion,
            linearExposureEV: linearExposureEV, decoderExposureEV: decoderExposureEV,
            edrAmount: edrAmount, sharpnessAmount: 0, baselineSharpness: baselineSharpness)
    }
    var sceneLinearInput: RAWDecodeRecipe {
        RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: decoderVersion,
            linearExposureEV: linearExposureEV, decoderExposureEV: decoderExposureEV,
            edrAmount: nil, sharpnessAmount: nil, baselineSharpness: baselineSharpness)
    }
    public var isValid: Bool {
        linearExposureEV.isFinite && (-10...10).contains(linearExposureEV) &&
        decoderExposureEV.isFinite && (-10...10).contains(decoderExposureEV) &&
        (edrAmount == nil || (edrAmount!.isFinite && (0...2).contains(edrAmount!))) &&
        (sharpnessAmount == nil || (sharpnessAmount!.isFinite && (0...1).contains(sharpnessAmount!))) &&
        (baselineSharpness == nil || (baselineSharpness!.isFinite && baselineSharpness! >= 0))
    }
}
