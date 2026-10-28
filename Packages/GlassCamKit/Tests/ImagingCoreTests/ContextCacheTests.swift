import Foundation
import Testing
import CHNCS
import CFFCS
@testable import ImagingCore
import GlassCamTestSupport

struct ContextCacheTests {
    @Test(arguments: ["exposure","captureKelvin","whiteBalance","preset","filmCurve","workingSpace","intent","whiteBalancePolicy","factoryKelvin","toneCurve","renderRevision","grain","sharpness","crop","workScale"])
    func hncsChangedRequest_keepsAllRequestedSettings(field: String) throws {
        let cache = HNCSEngine.ContextCache()
        _ = try cache.context(exposure: 0,kelvin: 6500,settings: .standard,effects: .standard,whiteBalance: nil)
        var settings = HNCSSettings.standard
        switch field {
        case "preset": settings.presetKey = "nature"
        case "filmCurve": settings.filmCurve = .highContrast
        case "workingSpace": settings.workingSpace = .lstar
        case "intent": settings.intent = .reproduction
        case "whiteBalancePolicy": settings.whiteBalancePolicy = .preset
        case "factoryKelvin": settings.factoryKelvinOverride = 4500
        case "toneCurve": settings.applyToneCurve = false
        case "renderRevision": settings.renderRevision = 11
        default: break
        }
        let expected = HNCSEngine.ContextKey(exposure: field == "exposure" ? 1 : 0,
            captureKelvin: field == "captureKelvin" ? 4500 : 6500,
            whiteBalance: field == "whiteBalance" ? .renderedD65 : nil, settings: settings,
            effects: .init(applyGrain: field != "grain",applySharpness: field != "sharpness",applyExtraCrop: field != "crop"),
            workScale: field == "workScale" ? 2 : 1)

        let owner = try cache.context(exposure: expected.exposure,kelvin: expected.captureKelvin,settings: settings,
                                     effects: expected.effects,whiteBalance: expected.whiteBalance,workScale: expected.workScale)

        #expect(owner.key == expected)
    }
    @Test(arguments: ["simulation","family","reference","radius","revision","grain","sharpness","crop"])
    func ffcsChangedRequest_keepsAllRequestedSettings(field: String) throws {
        let directory = try #require(TestResources.colors.ffcsDirectory)
        let cache = FFCSEngine.ContextCache()
        _ = try cache.context(directory: directory,simulationIndex: 0,effects: .standard,settings: .standard)
        var settings = FFCSSettings.standard
        if field == "family" { settings.cameraFamily = .xa3 }
        if field == "reference" { settings.applyReferenceAdjustments = true }
        if field == "radius" { settings.sharpenRadius = 2 }
        if field == "revision" { settings.renderRevision = 1 }
        let effects = EffectToggles(applyGrain: field != "grain",applySharpness: field != "sharpness",applyExtraCrop: field != "crop")
        let simulation = field == "simulation" ? 8 : 0

        let owner = try cache.context(directory: directory,simulationIndex: simulation,effects: effects,settings: settings)

        #expect(owner.simulationIndex == simulation)
        #expect(owner.settings == settings)
        #expect(owner.effects == effects)
    }
    @Test func newResourceDirectory_doesNotReuseOldLocation() throws {
        let directory = try #require(TestResources.colors.ffcsDirectory)
        let work = try TestDirectory(); let alias = work.url.appendingPathComponent("FFCS")
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: directory)
        let cache = FFCSEngine.ContextCache()
        _ = try cache.context(directory: directory,simulationIndex: 0,effects: .standard,settings: .standard)
        let owner = try cache.context(directory: alias,simulationIndex: 0,effects: .standard,settings: .standard)
        #expect(owner.directory == alias.path)
    }
    @Test func replacedHNCSEntry_keepsInFlightNativeOwnerUsable() throws {
        let cache = HNCSEngine.ContextCache()
        let owner = try cache.context(exposure: 0,kelvin: 6500,settings: .standard,effects: .standard,whiteBalance: nil)
        let input: [Float] = [0.1,0.3,0.7]
        var before = [Float](repeating: 0,count: 4), after = before
        try #require(hncs_process_linear_rgba(owner.pointer,input,&before,1) == 0)

        _ = try cache.context(exposure: 1,kelvin: 4500,settings: .standard,effects: .standard,whiteBalance: nil)
        let status = hncs_process_linear_rgba(owner.pointer,input,&after,1)

        #expect(status == 0)
        #expect(after == before)
    }
    @Test func replacedFFCSEntry_keepsInFlightNativeOwnerUsable() throws {
        let directory = try #require(TestResources.colors.ffcsDirectory)
        let cache = FFCSEngine.ContextCache()
        let owner = try cache.context(directory: directory,simulationIndex: 0,effects: .standard,settings: .standard)
        let input: [Float] = [0.1,0.3,0.7]
        var before = [Float](repeating: 0,count: 4), after = before, message = [CChar](repeating: 0,count: 1024)
        try #require(ffcs_process_linear_rgb_color_only(owner.pointer,input,3,1,&before,4,&message,message.count) == 1)

        _ = try cache.context(directory: directory,simulationIndex: 8,effects: .standard,settings: .standard)
        let status = ffcs_process_linear_rgb_color_only(owner.pointer,input,3,1,&after,4,&message,message.count)

        #expect(status == 1)
        #expect(after == before)
    }
}
