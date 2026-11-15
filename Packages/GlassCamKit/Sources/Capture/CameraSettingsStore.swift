import ImagingCore
import Foundation
import Combine

/// One persistent source of truth for the settings page and shutter snapshots.
public final class CameraSettingsStore: ObservableObject {
    public static let centerPreviewCaps = [1280, 1920, 2560, 3840, 4096]
    @Published public var captureQuality: CaptureQuality {
        didSet { if captureQuality != oldValue { defaults.set(captureQuality.rawValue, forKey: "camera.capture.quality.v1") } }
    }
    @Published public var archiveF5RAW: Bool {
        didSet { if archiveF5RAW != oldValue { defaults.set(archiveF5RAW, forKey:"camera.f5.keepRaw") } }
    }
    @Published public var archiveBalancedPreColorRAW: Bool {
        didSet { if archiveBalancedPreColorRAW != oldValue { defaults.set(archiveBalancedPreColorRAW, forKey: "camera.balanced.keepPreColorRAW") } }
    }
    @Published public var colorMode: ColorMode = .hncs { didSet { if colorMode != oldValue { persistRecipe() } } }
    @Published public var simulationIndex = 0 { didSet { if simulationIndex != oldValue { persistRecipe() } } }
    @Published public var exposure = 0.0 { didSet { if exposure != oldValue { persistRecipe() } } }
    @Published public var hncs = HNCSSettings.standard { didSet { if hncs != oldValue { persistRecipe() } } }
    @Published public var effects = EffectToggles.standard { didSet { if effects != oldValue { persistRecipe() } } }
    @Published public var ffcs = FFCSSettings.standard { didSet { if ffcs != oldValue { persistRecipe() } } }
    @Published public var lumix = LUMIXSettings.standard { didSet { if lumix != oldValue { persistRecipe() } } }
    @Published public var gridVisible: Bool { didSet { if gridVisible != oldValue { defaults.set(gridVisible, forKey: "camera.grid.visible") } } }
    @Published public var experimentalLiveColor: Bool { didSet { if experimentalLiveColor != oldValue { defaults.set(experimentalLiveColor, forKey: "camera.liveColor.enabled") } } }
    @Published public var centerPreviewLongEdge: Int {
        didSet { if centerPreviewLongEdge != oldValue { defaults.set(centerPreviewLongEdge, forKey: "camera.preview.center.longEdge") } }
    }
    private let defaults: UserDefaults
    private var lastPersistedRecipeData: Data?
    // Reuse the existing key and decoder to preserve all previously saved effects.
    private static let recipeKey = "editor.processingRecipe.revision8.v1"

    // The compatibility CCT field is unresolved here. ImagePipeline replaces it
    // with this photo's decoder white point; old manual values are not restored.
    public var recipe: ProcessingRecipe {
        var cameraHNCS = hncs
        cameraHNCS.renderRevision = HNCSSettings.currentRenderRevision
        if cameraHNCS.presetKey == "square-crop" { cameraHNCS.presetKey = "standard" }
        var cameraLUMIX = lumix
        cameraLUMIX.renderRevision = LUMIXSettings.currentRenderRevision
        cameraLUMIX.sourceISO = nil
        var cameraFFCS = ffcs
        cameraFFCS.renderRevision = FFCSSettings.currentRenderRevision
        return ProcessingRecipe(mode: colorMode, exposureEV: exposure, illuminantKelvin: 6500,
                                simulationIndex: simulationIndex, seed: 0, hncs: cameraHNCS, effects: effects, ffcs: cameraFFCS, lumix: cameraLUMIX)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archiveF5RAW = defaults.bool(forKey:"camera.f5.keepRaw")
        archiveBalancedPreColorRAW = defaults.bool(forKey: "camera.balanced.keepPreColorRAW")
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
        ffcs.renderRevision = FFCSSettings.currentRenderRevision
        lumix.renderRevision = LUMIXSettings.currentRenderRevision
        lumix.sourceISO = nil
        defaults.set(captureQuality.rawValue, forKey: "camera.capture.quality.v1")
        persistRecipe()
    }

    /// Resets post-exposure and the active engine's tuning parameters while
    /// keeping the selected color engine, preset/simulation, family, and output gates.
    public func resetCurrentEffectAdjustments() {
        exposure = 0
        switch colorMode {
        case .hncs:
            var reset = HNCSSettings.standard
            reset.presetKey = hncs.presetKey
            reset.whiteBalancePolicy = hncs.whiteBalancePolicy
            hncs = reset
        case .ffcs:
            var reset = ffcs
            reset.applyReferenceAdjustments = false
            reset.sharpenRadius = 1.0
            ffcs = reset
        case .lumix:
            var reset = lumix
            reset.contrast = 0
            reset.saturation = 0
            lumix = reset
        }
    }

    private func persistRecipe() {
        guard recipe.isValid, let data = try? JSONEncoder().encode(recipe),
              data != lastPersistedRecipeData else { return }
        lastPersistedRecipeData = data
        defaults.set(data, forKey: Self.recipeKey)
    }

}
