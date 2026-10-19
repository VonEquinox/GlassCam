import Foundation
import Combine

/// One persistent source of truth for the settings page and shutter snapshots.
final class CameraSettingsStore: ObservableObject {
    static let centerPreviewCaps = [1280, 1920, 2560, 3840, 4096]
    @Published var colorMode: ColorMode = .hncs { didSet { persistRecipe() } }
    @Published var simulationIndex = 0 { didSet { persistRecipe() } }
    @Published var exposure = 0.0 { didSet { persistRecipe() } }
    @Published var hncs = HNCSSettings.standard { didSet { persistRecipe() } }
    @Published var effects = EffectToggles.standard { didSet { persistRecipe() } }
    @Published var ffcs = FFCSSettings.standard { didSet { persistRecipe() } }
    @Published var gridVisible: Bool { didSet { defaults.set(gridVisible, forKey: "camera.grid.visible") } }
    @Published var experimentalLiveColor: Bool { didSet { defaults.set(experimentalLiveColor, forKey: "camera.liveColor.enabled") } }
    @Published var centerPreviewLongEdge: Int {
        didSet { defaults.set(centerPreviewLongEdge, forKey: "camera.preview.center.longEdge") }
    }
    @Published private(set) var outputSelections: [String: Int]
    @Published private(set) var preferredOutputMegapixels: Int
    private let defaults: UserDefaults
    private static let outputsKey = "camera.output.megapixels.byPhysicalLens.v1"
    // Reuse the existing key and decoder to preserve all previously saved effects.
    private static let recipeKey = "editor.processingRecipe.revision8.v1"

    // The compatibility CCT field is unresolved here. ImagePipeline replaces it
    // with this photo's decoder white point; old manual values are not restored.
    var recipe: ProcessingRecipe {
        ProcessingRecipe(mode: colorMode, exposureEV: exposure, illuminantKelvin: 6500,
                         simulationIndex: simulationIndex, seed: 0, hncs: hncs, effects: effects, ffcs: ffcs)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let center = defaults.integer(forKey: "camera.preview.center.longEdge")
        centerPreviewLongEdge = Self.centerPreviewCaps.contains(center) ? center : 1920
        gridVisible = defaults.object(forKey: "camera.grid.visible") as? Bool ?? true
        experimentalLiveColor = defaults.bool(forKey: "camera.liveColor.enabled")
        let savedOutputs = defaults.dictionary(forKey: Self.outputsKey) as? [String: Int] ?? [:]
        outputSelections = savedOutputs.mapValues { $0 == 12 ? 24 : $0 }
        let preferred = defaults.integer(forKey: "camera.output.preferred.v2")
        preferredOutputMegapixels = [24, 48].contains(preferred) ? preferred :
            (savedOutputs.count == 1 && savedOutputs.values.first == 48 ? 48 : 24)
        if let data = defaults.data(forKey: Self.recipeKey),
           let saved = try? JSONDecoder().decode(ProcessingRecipe.self, from: data), saved.isValid {
            colorMode = saved.mode; simulationIndex = saved.simulationIndex
            exposure = saved.exposureEV; hncs = saved.hncs
            effects = saved.effects; ffcs = saved.ffcs
            // Only future-camera preferences adopt the new automatic default.
            // Decoding an old journal elsewhere retains its fixed-preset WB.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let savedHNCS = object?["hncs"] as? [String: Any]
            if savedHNCS?["whiteBalancePolicy"] as? String == nil {
                hncs.whiteBalancePolicy = .photo
            }
        }
        defaults.set(outputSelections, forKey: Self.outputsKey)
        persistRecipe()
    }

    private func persistRecipe() {
        guard recipe.isValid, let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: Self.recipeKey)
    }

    func outputMegapixels(physicalCameraID: String, mode: String) -> Int {
        outputSelections[key(physicalCameraID: physicalCameraID, mode: mode)] ?? preferredOutputMegapixels
    }

    func setOutputMegapixels(_ value: Int, physicalCameraID: String, mode: String) {
        guard [24, 48].contains(value) else { return }
        outputSelections[key(physicalCameraID: physicalCameraID, mode: mode)] = value
        preferredOutputMegapixels = value
        defaults.set(value, forKey: "camera.output.preferred.v2")
        defaults.set(outputSelections, forKey: Self.outputsKey)
    }

    private func key(physicalCameraID: String, mode: String) -> String {
        "\(mode):\(Data(physicalCameraID.utf8).base64EncodedString())"
    }
}
