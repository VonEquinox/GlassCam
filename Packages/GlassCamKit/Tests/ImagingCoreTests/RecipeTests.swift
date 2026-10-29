import Testing
import Foundation
@testable import ImagingCore

struct RecipeTests {
    static let effectCombinations = (0..<8).map { mask in
        EffectToggles(applyGrain: mask & 1 != 0, applySharpness: mask & 2 != 0, applyExtraCrop: mask & 4 != 0)
    }
    func decode(_ object: [String: Any]) throws -> ProcessingRecipe {
        try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @Test(arguments: ["mode", "exposureEV", "illuminantKelvin", "simulationIndex", "seed", "hncs", "ffcs", "lumix", "effects", "photoWhiteBalance", "rawInputPolicy", "pipelineRevision"])
    func changedRecipeField_changesIdentityAndSurvivesCodable(field: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProcessingRecipe.standard)) as? [String: Any])
        let replacements: [String: Any] = ["mode": "ffcs", "exposureEV": 0.75, "illuminantKelvin": 4500,
            "simulationIndex": 1, "seed": 73, "hncs": ["presetKey": "nature"],
            "ffcs": ["cameraFamily": "XA3", "sharpenRadius": 2.3], "lumix": ["photoStyle": "vivid"],
            "effects": ["applyGrain": false], "photoWhiteBalance": ["origin": "appleRAW", "temperature": 4500, "tint": 4, "x": 0.36, "y": 0.37],
            "rawInputPolicy": "legacy", "pipelineRevision": 1]
        object[field] = replacements[field]

        let recipe = try decode(object)
        let replay = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(recipe))

        #expect(recipe != .standard)
        #expect(replay == recipe)
    }
    @Test func newHNCS_defaultsUseStandardAsShotAndNativeFilmCurve() {
        let settings = HNCSSettings.standard
        #expect(settings.presetKey == "standard")
        #expect(settings.filmCurve == .asShot)
        #expect(settings.rawFilmCurveType == 2)
        #expect(settings.factoryKelvinOverride == nil)
    }
    @Test func unversionedRecipe_retainsLegacyDecodePolicy() throws {
        let recipe = try decode([:])
        #expect(recipe.pipelineRevision == 1)
        #expect(recipe.hncs.renderRevision == 11)
        #expect(recipe.rawInputPolicy == .legacy)
        #expect(recipe.effects == .standard)
    }
    @Test(arguments: ["applyGrain", "applySharpness", "applyExtraCrop"], [false, true])
    func missingOrNullEffect_defaultsIndependently(field: String, null: Bool) throws {
        var effects: [String: Any] = ["applyGrain": false, "applySharpness": false, "applyExtraCrop": false]
        if null { effects[field] = NSNull() } else { effects.removeValue(forKey: field) }
        let recipe = try decode(["effects": effects])
        let actual = ["applyGrain": recipe.effects.applyGrain, "applySharpness": recipe.effects.applySharpness, "applyExtraCrop": recipe.effects.applyExtraCrop]
        #expect(actual[field] == true)
        #expect(actual.filter { $0.key != field }.values.allSatisfy { !$0 })
    }
    @Test(arguments: ["applyGrain", "applySharpness", "applyExtraCrop"], ["false", "0", "yes"])
    func nonBooleanEffect_isRejected(field: String, value: String) {
        #expect(throws: DecodingError.self) { try decode(["effects": [field: value]]) }
    }
    @Test(arguments: ["applyGrain", "applySharpness", "applyExtraCrop"])
    func numericEffect_isRejected(field: String) {
        #expect(throws: DecodingError.self) { try decode(["effects": [field: 1]]) }
    }
    @Test(arguments: effectCombinations)
    func explicitEffects_overrideLegacyFlagsAndRoundtrip(effects: EffectToggles) throws {
        let values: [String: Any] = ["applyGrain": effects.applyGrain, "applySharpness": effects.applySharpness, "applyExtraCrop": effects.applyExtraCrop]
        let recipe = try decode(["mode": "hncs", "effects": values, "hncs": ["applyGrain": !effects.applyGrain, "applySharpness": !effects.applySharpness]])
        let bytes = try JSONEncoder().encode(recipe)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let hncs = try #require(object["hncs"] as? [String: Any])
        #expect(recipe.effects == effects)
        #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: bytes).effects == effects)
        #expect(hncs["applyGrain"] == nil)
        #expect(hncs["applySharpness"] == nil)
    }
    @Test(arguments: [false, true], [false, true])
    func legacyHNCS_flagsMigrateIndependently(grain: Bool, sharpness: Bool) throws {
        let recipe = try decode(["mode": "hncs", "hncs": ["applyGrain": grain, "applySharpness": sharpness]])
        #expect(recipe.effects == EffectToggles(applyGrain: grain, applySharpness: sharpness, applyExtraCrop: true))
    }
    @Test(arguments: ["applyGrain", "applySharpness"])
    func missingLegacyFlag_defaultsWithoutErasingExplicitFalse(field: String) throws {
        let recipe = try decode(["hncs": [field: false]])
        #expect(recipe.effects.applyGrain == (field != "applyGrain"))
        #expect(recipe.effects.applySharpness == (field != "applySharpness"))
        #expect(recipe.effects.applyExtraCrop)
    }
    @Test(arguments: ["ffcs", "lumix"])
    func inactiveLegacyHNCS_flagsDoNotChangeOtherModes(mode: String) throws {
        let recipe = try decode(["mode": mode, "hncs": ["applyGrain": false, "applySharpness": false]])
        #expect(recipe.effects == .standard)
    }
    @Test func nullEffects_useLegacyHNCSFlags() throws {
        let recipe = try decode(["effects": NSNull(), "hncs": ["applyGrain": false]])
        #expect(recipe.effects == EffectToggles(applyGrain: false, applySharpness: true, applyExtraCrop: true))
    }
    @Test(arguments: effectCombinations)
    func absentFFCSSettings_useNeutralDefaultsWithoutLosingEffects(effects: EffectToggles) throws {
        let recipe = try decode(["mode": "ffcs", "effects": ["applyGrain": effects.applyGrain, "applySharpness": effects.applySharpness, "applyExtraCrop": effects.applyExtraCrop]])
        #expect(recipe.ffcs.renderRevision == 2)
        #expect(recipe.ffcs.cameraFamily == .xh2s)
        #expect(!recipe.ffcs.applyReferenceAdjustments)
        #expect(recipe.ffcs.sharpenRadius == 1)
        #expect(recipe.effects == effects)
    }
    @Test(arguments: [(ColorMode.hncs, false, ImageCrop.none), (.hncs, true, .centeredSquare),
                      (.ffcs, false, .none), (.ffcs, true, .none),
                      (.lumix, false, .none), (.lumix, true, .none)])
    func extraCrop_onlyAffectsActiveHNCSSquarePreset(mode: ColorMode, enabled: Bool, expected: ImageCrop) {
        var settings = HNCSSettings.standard; settings.presetKey = "square-crop"
        let recipe = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500, simulationIndex: 0, seed: 0,
                                      hncs: settings, effects: .init(applyExtraCrop: enabled))
        #expect(recipe.crop == expected)
    }
}
