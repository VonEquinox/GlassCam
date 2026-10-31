import Testing
import Foundation
@testable import Capture
@testable import ImagingCore

struct SettingsTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "glasscam-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
    @Test func newSettings_liveColorIsDisabled() throws {
        try withDefaults { defaults in
            #expect(!CameraSettingsStore(defaults: defaults).experimentalLiveColor)
            #expect(CameraSettingsStore(defaults: defaults).captureQuality == .balanced)
        }
    }
    @Test func invalidSavedRecipe_restoresValidatedDefaults() throws {
        try withDefaults { defaults in
            let invalid = ProcessingRecipe(mode: .hncs, exposureEV: 12, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: .standard)
            defaults.set(try JSONEncoder().encode(invalid), forKey: "editor.processingRecipe.revision8.v1")
            #expect(CameraSettingsStore(defaults: defaults).recipe == .standard)
        }
    }
    @Test func legacyManualWhiteBalanceMigration_preservesExposure() throws {
        try withDefaults { defaults in
            let legacy = ProcessingRecipe(mode: .hncs, exposureEV: 0.25, illuminantKelvin: 2850, simulationIndex: 0, seed: 0, hncs: .standard)
            defaults.set(try JSONEncoder().encode(legacy), forKey: "editor.processingRecipe.revision8.v1")
            let store = CameraSettingsStore(defaults: defaults)
            #expect(store.recipe.photoWhiteBalance == nil)
            #expect(store.recipe.illuminantKelvin == 6500)
            #expect(store.exposure == 0.25)
        }
    }
    @Test(arguments: (0..<8))
    func effectChoices_persistUnderOriginalRecipeKey(mask: Int) throws {
        try withDefaults { defaults in
            let settings = CameraSettingsStore(defaults: defaults)
            settings.effects = .init(applyGrain: mask & 1 != 0, applySharpness: mask & 2 != 0, applyExtraCrop: mask & 4 != 0)
            let data = try #require(defaults.data(forKey: "editor.processingRecipe.revision8.v1"))
            #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: data).effects == settings.effects)
            #expect(CameraSettingsStore(defaults: defaults).effects == settings.effects)
        }
    }
    @Test(arguments: ["grain", "sharpness", "crop"])
    func changingOneEffect_preservesOtherEffectsAndColor(field: String) throws {
        try withDefaults { defaults in
            let settings = CameraSettingsStore(defaults: defaults)
            settings.exposure = 0.5; settings.simulationIndex = 2; settings.hncs.presetKey = "nature"
            let before = settings.recipe
            switch field {
            case "grain": settings.effects.applyGrain = false
            case "sharpness": settings.effects.applySharpness = false
            default: settings.effects.applyExtraCrop = false
            }
            #expect(settings.effects == EffectToggles(applyGrain: field != "grain", applySharpness: field != "sharpness", applyExtraCrop: field != "crop"))
            #expect(settings.recipe.hncs == before.hncs)
            #expect(settings.recipe.exposureEV == before.exposureEV)
            #expect(settings.recipe.simulationIndex == before.simulationIndex)
        }
    }
    @Test(arguments: ColorMode.allCases)
    func selectingModePresetAndSimulation_preservesEffects(mode: ColorMode) throws {
        try withDefaults { defaults in
            let settings = CameraSettingsStore(defaults: defaults)
            let effects = EffectToggles(applyGrain: false, applySharpness: true, applyExtraCrop: false)
            settings.effects = effects
            settings.colorMode = mode; settings.hncs.presetKey = "nature"; settings.simulationIndex = 3
            #expect(settings.recipe.effects == effects)
            #expect(CameraSettingsStore(defaults: defaults).recipe.effects == effects)
        }
    }
    @Test func persistedControls_surviveStoreReconstruction() throws {
        try withDefaults { defaults in
            let settings = CameraSettingsStore(defaults: defaults)
            settings.exposure = 0.5; settings.gridVisible = false; settings.experimentalLiveColor = true
            settings.centerPreviewLongEdge = 2560; settings.captureQuality = .balanced
            let restored = CameraSettingsStore(defaults: defaults)
            #expect(restored.recipe == settings.recipe)
            #expect(!restored.gridVisible)
            #expect(restored.experimentalLiveColor)
            #expect(restored.centerPreviewLongEdge == 2560)
            #expect(restored.captureQuality == .balanced)
        }
    }
    @Test(arguments: ["quality", "unknown"])
    func unavailableSavedMode_usesBalanced(value: String) throws {
        try withDefaults { defaults in
            defaults.set(value, forKey: "camera.capture.quality.v1")

            let settings = CameraSettingsStore(defaults: defaults)

            #expect(settings.captureQuality == .balanced)
        }
    }
    @Test func speedPreference_preservesSingleRAWMode() throws {
        try withDefaults { defaults in
            CameraSettingsStore(defaults: defaults).captureQuality = .speed
            #expect(CameraSettingsStore(defaults: defaults).captureQuality == .speed)
        }
    }
}
