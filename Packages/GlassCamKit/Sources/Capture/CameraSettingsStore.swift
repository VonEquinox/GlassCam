import ImagingCore
import Foundation
import Combine

/// One persistent source of truth for the settings page and shutter snapshots.
public final class CameraSettingsStore: ObservableObject {
    public static let centerPreviewCaps = [1280, 1920, 2560, 3840, 4096]
    @Published public var captureQuality: CaptureQuality {
        didSet { defaults.set(captureQuality.rawValue, forKey: "camera.capture.quality.v1") }
    }
    @Published public var archiveF5RAW: Bool {
        didSet { defaults.set(archiveF5RAW, forKey:"camera.f5.keepRaw") }
    }
    @Published public var colorMode: ColorMode = .hncs { didSet { persistRecipe() } }
    @Published public var simulationIndex = 0 { didSet { persistRecipe() } }
    @Published public var exposure = 0.0 { didSet { persistRecipe() } }
    @Published public var hncs = HNCSSettings.standard { didSet { persistRecipe() } }
    @Published public var effects = EffectToggles.standard { didSet { persistRecipe() } }
    @Published public var ffcs = FFCSSettings.standard { didSet { persistRecipe() } }
    @Published public var lumix = LUMIXSettings.standard { didSet { persistRecipe() } }
    @Published public var gridVisible: Bool { didSet { defaults.set(gridVisible, forKey: "camera.grid.visible") } }
    @Published public var experimentalLiveColor: Bool { didSet { defaults.set(experimentalLiveColor, forKey: "camera.liveColor.enabled") } }
    @Published public var centerPreviewLongEdge: Int {
        didSet { defaults.set(centerPreviewLongEdge, forKey: "camera.preview.center.longEdge") }
    }
    private let defaults: UserDefaults
    // Reuse the existing key and decoder to preserve all previously saved effects.
    private static let recipeKey = "editor.processingRecipe.revision8.v1"

    // The compatibility CCT field is unresolved here. ImagePipeline replaces it
    // with this photo's decoder white point; old manual values are not restored.
    public var recipe: ProcessingRecipe {
        var cameraHNCS = hncs
        if cameraHNCS.renderRevision == 11 { cameraHNCS.renderRevision = HNCSSettings.currentRenderRevision }
        if cameraHNCS.presetKey == "square-crop" { cameraHNCS.presetKey = "standard" }
        var cameraLUMIX = lumix
        cameraLUMIX.renderRevision = LUMIXSettings.currentRenderRevision
        cameraLUMIX.sourceISO = nil
        return ProcessingRecipe(mode: colorMode, exposureEV: exposure, illuminantKelvin: 6500,
                                simulationIndex: simulationIndex, seed: 0, hncs: cameraHNCS, effects: effects, ffcs: ffcs, lumix: cameraLUMIX)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archiveF5RAW = defaults.bool(forKey:"camera.f5.keepRaw")
        let storedQuality = defaults.string(forKey: "camera.capture.quality.v1")
            .flatMap(CaptureQuality.init(rawValue:)) ?? .balanced
        captureQuality = storedQuality == .f5 ? .balanced : storedQuality
        let center = defaults.integer(forKey: "camera.preview.center.longEdge")
        centerPreviewLongEdge = Self.centerPreviewCaps.contains(center) ? center : 1920
        gridVisible = defaults.object(forKey: "camera.grid.visible") as? Bool ?? true
        experimentalLiveColor = defaults.bool(forKey: "camera.liveColor.enabled")
        if let data = defaults.data(forKey: Self.recipeKey),
           let saved = try? JSONDecoder().decode(ProcessingRecipe.self, from: data), saved.isValid {
            colorMode = saved.mode; simulationIndex = saved.simulationIndex
            exposure = saved.exposureEV; hncs = saved.hncs
            effects = saved.effects; ffcs = saved.ffcs; lumix = saved.lumix
            // Only future-camera preferences adopt the new automatic default.
            // Decoding an old journal elsewhere retains its fixed-preset WB.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let savedHNCS = object?["hncs"] as? [String: Any]
            if savedHNCS?["whiteBalancePolicy"] as? String == nil {
                hncs.whiteBalancePolicy = .photo
            }
        }
        // Only future camera selections migrate. Decoding a durable photo's
        // ProcessingRecipe still preserves its original square composition.
        if hncs.presetKey == "square-crop" { hncs.presetKey = "standard" }
        hncs.renderRevision = HNCSSettings.currentRenderRevision
        lumix.renderRevision = LUMIXSettings.currentRenderRevision
        lumix.sourceISO = nil
        defaults.set(captureQuality.rawValue, forKey: "camera.capture.quality.v1")
        persistRecipe()
    }

    private func persistRecipe() {
        guard recipe.isValid, let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: Self.recipeKey)
    }

}
