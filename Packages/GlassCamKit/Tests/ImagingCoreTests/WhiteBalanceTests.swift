import Testing
import Foundation
@testable import ImagingCore
import GlassCamTestSupport

struct WhiteBalanceTests {
    let warm = PhotoWhiteBalance(origin: .appleRAW, temperature: 2850, tint: 4, x: 0.44757, y: 0.40745)
    let tinted = PhotoWhiteBalance(origin: .appleRAW, temperature: 5200, tint: 25, x: 0.34, y: 0.38)
    // Frozen telephoto white point from the original Nature regression fixture.
    let tele = PhotoWhiteBalance(origin: .appleRAW, temperature: 5393, tint: 44.5, x: 0.33567193150520325, y: 0.37427031993865967)
    func renderNature(_ policy: HNCSWhiteBalancePolicy) throws -> [Float] {
        var settings = HNCSSettings.standard; settings.presetKey = "nature"; settings.workingSpace = .lstar; settings.whiteBalancePolicy = policy
        return try HNCSEngine.exportLinearRGBA(linearSRGB: [Float](repeating: 0.18, count: 4 * 4 * 3), width: 4, height: 4,
            exposureEV: 0, illuminantKelvin: 6500, settings: settings,
            effects: .init(applyGrain: false, applySharpness: false, applyExtraCrop: false), whiteBalance: tele)
    }
    @Test func automaticWhiteBalance_bindsPhotoOnceAndSurvivesCodable() throws {
        let frozen = ProcessingRecipe.standard.resolvingWhiteBalance(warm)
        #expect(frozen.photoWhiteBalance == warm)
        #expect(frozen.illuminantKelvin != 6500)
        #expect(frozen.resolvingWhiteBalance(tinted) == frozen)
        #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(frozen)) == frozen)
    }
    @Test func invalidWhitePoint_isRejected() {
        #expect(!PhotoWhiteBalance(origin: .appleRAW, temperature: 5000, tint: 0, x: .nan, y: 0.3).isValid)
    }
    @Test func changedWhitePoint_invalidatesContextWithoutChangingPriorRender() throws {
        let work = try TestDirectory()
        let input = try ImagePipelineTests.fixture(work.url, width: 257, height: 389)
        func render(_ white: PhotoWhiteBalance) throws -> [Float] {
            try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width, height: input.height,
                exposureEV: 0, illuminantKelvin: 6500, whiteBalance: white)
        }
        let first = try render(warm)
        let changed = try render(tinted)
        let restored = try render(warm)
        // The original regression requires a visible difference above Float32 rounding.
        let minimumWhitePointDifference: Float = 0.001
        #expect(try ImagePipelineTests.error(first, changed) > minimumWhitePointDifference)
        #expect(restored == first)
    }
    @Test func processing_bindsInputWhitePoint() throws {
        let work = try TestDirectory()
        let input = try ImagePipelineTests.fixture(work.url, width: 257, height: 389)
        let result = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        #expect(result.recipe.photoWhiteBalance == input.whiteBalance)
    }
    @Test func presetNature_replaysOriginalTelephotoWhiteBalance() throws {
        let fixed = try renderNature(.preset)
        let legacyGolden: [Float] = [0.26048735, 0.33648133, 0.23170701]
        // Original pre-fix Float32 golden tolerance.
        let legacyTolerance: Float = 1e-7
        let maximumError = zip(fixed.prefix(3), legacyGolden).map { abs($0 - $1) }.max() ?? .infinity
        #expect(maximumError < legacyTolerance)
        #expect(fixed[1] / ((fixed[0] + fixed[2]) / 2) > 1.25)
    }
    @Test func photoNature_keepsTelephotoGrayNeutralAcrossPolicyChanges() throws {
        let automatic = try renderNature(.photo)
        _ = try renderNature(.preset)
        let restored = try renderNature(.photo)
        // Original neutral-gray fixture permits 2.5% green-channel deviation.
        let grayTolerance: Float = 0.025
        #expect(abs(automatic[1] / ((automatic[0] + automatic[2]) / 2) - 1) < grayTolerance)
        #expect(restored == automatic)
    }
    @Test func reviewDescription_distinguishesPresetAndPhotoWhiteBalance() {
        var nature = HNCSSettings.standard; nature.presetKey = "nature"; nature.whiteBalancePolicy = .preset
        let fixed = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: nature, photoWhiteBalance: tele)
        #expect(fixed.whiteBalanceDescription == "Preset WB · Nature · 5500 K")
        #expect(ProcessingRecipe.standard.resolvingWhiteBalance(tele).whiteBalanceDescription == tele.description)
    }
}
