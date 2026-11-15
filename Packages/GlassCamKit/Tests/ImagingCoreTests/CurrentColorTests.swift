import Testing
import CHNCS
import CFFCS
import CLUMIX
@testable import ImagingCore
import GlassCamTestSupport

struct CurrentColorTests {
    let input: [Float] = [0, 0, 0, 0.0001, 0.0001, 0.0001, 0.8, 0.05, 0.2, 0.18, 0.18, 0.18]

    @Test func currentFFCS_usesTheVerifiedNativeMapping() throws {
        let directory = try #require(TestResources.colors.ffcsDirectory)
        var error = [CChar](repeating: 0, count: 1024)
        let context = try #require(ffcs_create_native_family_config(
            directory.path, "XH2S", 1, 0, 0, 0, 1, &error, error.count))
        defer { ffcs_destroy(context) }
        var expected = [Float](repeating: 0, count: input.count)
        try #require(ffcs_process_linear_rgb_optimized(context, input, input.count,
            4, 1, 0, 0, &expected, expected.count, nil, 0, 1, &error, error.count) == 1)

        let actual = try FFCSEngine.exportLinearRGBA(resources: TestResources.colors,
            linearSRGB: input, width: 4, height: 1, exposureEV: 0, simulationIndex: 1, seed: 0,
            effects: .init(applyGrain: false, applySharpness: false))

        #expect(actual == (try FloatRasterOperations.rgba(fromRGB: expected)))
    }

    @Test func currentLUMIX_usesNativeLowISOAndIntegerControls() throws {
        let directory = try #require(TestResources.colors.lumixDirectory)
        var settings = LUMIXSettings(photoStyle: "vivid", contrast: 2, saturation: 3)
        settings.sourceISO = 50
        var error = [CChar](repeating: 0, count: 1024)
        let context = try #require(lumix_create_native_pipeline(
            directory.path, 1, 4000, 14, 16, 50, &error, error.count))
        defer { lumix_destroy(context) }
        var expected = [Float](repeating: 0, count: 16)
        try #require(lumix_process_native_rgba(context, input, input.count,
            4, 0, &expected, expected.count, &error, error.count) == 1)

        let actual = try LUMIXEngine.exportLinearRGBA(resources: TestResources.colors,
            linearSRGB: input, width: 4, height: 1, exposureEV: 0,
            settings: settings, illuminantKelvin: 4000)

        #expect(actual == expected)
    }

    @Test func currentHNCS_usesTheVerifiedHDRWorkingProfile() throws {
        var settings = HNCSSettings.standard
        settings.workingSpace = .lstar
        let scale = 5.8829245141
        let base = try #require(hncs_create_preset_native_color(0, 6500, 0, 1, 0, 4, 2, "standard", 1, nil, nil))
        defer { hncs_destroy(base) }
        let context = try #require(hncs_clone_with_apple_hdr_work_scale(base, scale))
        defer { hncs_destroy(context) }
        var expected = [Float](repeating: 0, count: 16)
        try #require(hncs_finish_apple_hdr_work_linear(context, input, &expected, 4, scale) == 0)

        let actual = try HNCSEngine.finishPresetWork(input, width: 4, height: 1,
            exposureEV: 0, captureKelvin: 6500, settings: settings, workScale: scale)

        #expect(actual == expected)
    }
}
