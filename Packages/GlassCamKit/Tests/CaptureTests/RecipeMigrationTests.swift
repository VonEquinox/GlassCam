import Testing
import Foundation
@testable import Capture
@testable import ImagingCore

struct RecipeMigrationTests {
    var settings: HNCSSettings {
        var value = HNCSSettings.standard
        value.presetKey = "nature"; value.filmCurve = .linear; value.workingSpace = .lstar
        value.intent = .reproduction; value.whiteBalancePolicy = .preset
        value.factoryKelvinOverride = 4000; value.applyToneCurve = false
        return value
    }
    func recipe(_ settings: HNCSSettings, effects: EffectToggles = .init(applyGrain: false, applySharpness: false, applyExtraCrop: false)) -> ProcessingRecipe {
        ProcessingRecipe(mode: .hncs, exposureEV: -0.3, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: settings, effects: effects)
    }
    func legacyData(revision: Int?) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe(settings))) as? [String: Any])
        var hncs = try #require(object["hncs"] as? [String: Any])
        hncs.removeValue(forKey: "whiteBalancePolicy")
        hncs["renderRevision"] = revision
        object["hncs"] = hncs
        return try JSONSerialization.data(withJSONObject: object)
    }
    @Test(arguments: [8, 9, 10, 11])
    func oldPhoto_keepsPresetWhiteBalanceAndSelections(revision: Int) throws {
        var historical = settings; historical.renderRevision = 11
        let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: legacyData(revision: revision))
        #expect(restored == recipe(historical))
        #expect(restored.hncs.renderRevision == 11)
        #expect(restored.hncs.whiteBalancePolicy == .preset)
    }
    @Test(arguments: [8, 9, 10, 11])
    func oldCameraPreferences_adoptPhotoWhiteBalanceIndependently(revision: Int) throws {
        try SettingsTests().withDefaults { defaults in
            defaults.set(try legacyData(revision: revision), forKey: "editor.processingRecipe.revision8.v1")
            var current = settings; current.whiteBalancePolicy = .photo
            #expect(CameraSettingsStore(defaults: defaults).recipe == recipe(current))
        }
    }
    @Test(arguments: HNCSWhiteBalancePolicy.allCases)
    func explicitWhiteBalancePolicy_survivesPhotoAndCameraReload(policy: HNCSWhiteBalancePolicy) throws {
        try SettingsTests().withDefaults { defaults in
            var selected = settings; selected.whiteBalancePolicy = policy
            let expected = recipe(selected), data = try JSONEncoder().encode(expected)
            defaults.set(data, forKey: "editor.processingRecipe.revision8.v1")
            #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: data) == expected)
            #expect(CameraSettingsStore(defaults: defaults).recipe == expected)
            #expect(CameraSettingsStore(defaults: defaults).recipe == expected)
        }
    }
    @Test(arguments: [true, false])
    func savedSquarePhoto_keepsItsHistoricalCrop(cropEnabled: Bool) throws {
        var historical = settings; historical.renderRevision = 11; historical.presetKey = "square-crop"
        let expected = recipe(historical, effects: .init(applyGrain: false, applySharpness: true, applyExtraCrop: cropEnabled))
        let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(expected))
        #expect(restored == expected)
        #expect(restored.crop == (cropEnabled ? .centeredSquare : .none))
    }
    @Test(arguments: [true, false])
    func savedSquareCameraPreference_migratesAndPersistsStandard(cropEnabled: Bool) throws {
        try SettingsTests().withDefaults { defaults in
            var historical = settings; historical.renderRevision = 11; historical.presetKey = "square-crop"
            let effects = EffectToggles(applyGrain: false, applySharpness: true, applyExtraCrop: cropEnabled)
            defaults.set(try JSONEncoder().encode(recipe(historical, effects: effects)), forKey: "editor.processingRecipe.revision8.v1")
            var migrated = settings; migrated.presetKey = "standard"
            let expected = recipe(migrated, effects: effects)
            #expect(CameraSettingsStore(defaults: defaults).recipe == expected)
            #expect(CameraSettingsStore(defaults: defaults).recipe == expected)
        }
    }
    @Test func injectedSquareCameraPreference_cannotCreateNewSquarePhoto() throws {
        try SettingsTests().withDefaults { defaults in
            let camera = CameraSettingsStore(defaults: defaults)
            camera.hncs.presetKey = "square-crop"
            #expect(camera.recipe.crop == .none)
        }
    }
    @Test func cameraCatalog_excludesSquareWhilePhotoCatalogRetainsIt() {
        #expect(!HNCSEngine.cameraPresets.contains { $0.id == "square-crop" })
        #expect(HNCSEngine.presets.contains { $0.id == "square-crop" })
    }
    @Test func unversionedPhoto_keepsLegacyHDRDomain() throws {
        let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: legacyData(revision: nil))
        #expect(restored.hncs.renderRevision == 11)
        #expect(!restored.usesExtendedHNCSWorkingDomain)
    }
    @Test(arguments: [7, 14, 99])
    func unknownHNCSRevision_isInvalid(revision: Int) throws {
        #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: legacyData(revision: revision)).isValid == false)
    }
}
