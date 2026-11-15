import Testing
@testable import ImagingCore
import GlassCamTestSupport
import CoreImage
import Foundation

@Suite(.serialized) struct FFCSMetalCoverageTests {
    struct Combination: Sendable {
        let family: FFCSCameraFamily
        let look: Int
    }
    enum Pattern: CaseIterable, Sendable {
        case constant, impulse, step, fineLines, checker, bandLimited, noise, hdrTexture
    }
    struct SpatialCase: Sendable {
        let combination: Combination
        let pattern: Pattern
        let radius: Double
        let width: Int
        let height: Int
        let effects: EffectToggles
    }
    static func expectedLooks(_ family: FFCSCameraFamily) -> [Int] {
        switch family {
        case .xh2s, .gfx100s: return Array(0...18)
        case .xa3: return [0, 1, 2, 3, 9, 10, 11, 12, 16, 17, 18]
        case .gfx100: return Array(0...18).filter { $0 != 5 }
        case .gfx100ii: return Array(0...19).filter { $0 != 5 }
        }
    }
    static var combinations: [Combination] {
        FFCSCameraFamily.allCases.flatMap { family in
            expectedLooks(family).map { Combination(family: family, look: $0) }
        }
    }
    static let representatives: [Combination] = [
        .init(family: .xh2s, look: 0), .init(family: .xh2s, look: 1),
        .init(family: .xh2s, look: 8), .init(family: .xh2s, look: 12),
        .init(family: .xa3, look: 17), .init(family: .gfx100, look: 4),
        .init(family: .gfx100s, look: 5), .init(family: .gfx100ii, look: 19),
    ]
    static var spatialCases: [SpatialCase] {
        // All spatial formulas and table families see each signal and radius.
        let signals = representatives.flatMap { combination in
            Pattern.allCases.flatMap { pattern in
                [0.1, 1.0, 5.0].map { radius in
                    SpatialCase(combination: combination, pattern: pattern, radius: radius,
                                width: 83, height: 79, effects: .standard)
                }
            }
        }
        let switches = representatives.flatMap { combination in
            [false, true].flatMap { grain in
                [false, true].map { sharpness in
                    SpatialCase(combination: combination, pattern: .noise, radius: 1,
                                width: 83, height: 79,
                                effects: .init(applyGrain: grain, applySharpness: sharpness))
                }
            }
        }
        let tiny = representatives.flatMap { combination in
            [(1, 1), (1, 7), (9, 1), (5, 3)].map { size in
                SpatialCase(combination: combination, pattern: .impulse, radius: 5,
                            width: size.0, height: size.1, effects: .standard)
            }
        }
        return signals + switches + tiny
    }

    @Test(arguments: FFCSCameraFamily.allCases)
    func familyCatalog_exposesEveryFrozenCombination(family: FFCSCameraFamily) {
        let actual = FFCSEngine.simulations(resources: TestResources.colors, for: family).map(\.id)

        #expect(actual == Self.expectedLooks(family))
    }

    @Test(arguments: FFCSMetalCoverageTests.combinations, [false, true])
    func eachFamilyAndAdjustmentMode_staysWithinHDRBudget(combination: Combination, adjustments: Bool) throws {
        let recipe = ProcessingRecipe(mode: .ffcs, exposureEV: -0.5, illuminantKelvin: 6500,
            simulationIndex: combination.look, seed: 19, hncs: .standard,
            effects: .init(applyGrain: false, applySharpness: false),
            ffcs: .init(cameraFamily: combination.family, applyReferenceAdjustments: adjustments))

        try MetalColorTests.checkColor(recipe)
    }

    static func signal(_ pattern: Pattern, width: Int, height: Int) -> [Float] {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        let period = 17.0
        for y in 0..<height { for x in 0..<width {
            let value: Float
            switch pattern {
            case .constant: value = 0.4
            case .impulse: value = x == width / 2 && y == height / 2 ? 4 : 0.1
            case .step: value = x < width / 2 ? 0.05 : 1.2
            case .fineLines: value = x % 7 == 0 || y % 11 == 0 ? 1.5 : 0.05
            case .checker: value = (x + y) % 2 == 0 ? 0.1 : 1.5
            case .bandLimited: value = Float(0.5 + 0.3 * sin(Double(x + y) * 2 * .pi / period))
            case .noise:
                let code = UInt32(truncatingIfNeeded: y * width + x) &* 1664525 &+ 1013904223
                value = Float(code & 65535) / 65535
            case .hdrTexture: value = Float(4 + 2 * sin(Double(x + y) * 2 * .pi / period))
            }
            let offset = (y * width + x) * 4
            rgba[offset] = value * 0.3
            rgba[offset + 1] = value * 0.7
            rgba[offset + 2] = value * 1.1
        } }
        return rgba
    }

    @Test(arguments: FFCSMetalCoverageTests.spatialCases)
    func croppedGPURequests_preserveWholeFrameHaloAndCoordinates(sample: SpatialCase) throws {
        let width = sample.width, height = sample.height
        let recipe = ProcessingRecipe(mode: .ffcs, exposureEV: -0.5, illuminantKelvin: 6500,
            simulationIndex: sample.combination.look, seed: 0xffffffff, hncs: .standard,
            effects: sample.effects,
            ffcs: .init(cameraFamily: sample.combination.family, applyReferenceAdjustments: true,
                        sharpenRadius: sample.radius))
        let source = MetalColorTests.image(Self.signal(sample.pattern, width: width, height: height),
                                          width: width, height: height)
        let sourcePixels = ImagePipelineTests.pixels(source)
        var rgb = (0..<(width * height)).flatMap { Array(sourcePixels[($0 * 4)..<($0 * 4 + 3)]) }
        let gains = try ImagePipeline.normalizeHighlights(&rgb, exposureEV: recipe.exposureEV)
        var expected = try FFCSEngine.exportLinearRGBA(resources: TestResources.colors, linearSRGB: rgb,
            width: width, height: height, exposureEV: 0, simulationIndex: recipe.simulationIndex,
            seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
        try ImagePipeline.restoreHighlights(&expected, gains: gains)
        let rendered = try #require(try MetalColorEngine.image(resources: TestResources.colors,
                                                               source: source, recipe: recipe))

        var actual: [Float] = []
        let requestedRows = 7
        for firstRow in stride(from: 0, to: height, by: requestedRows) {
            let rows = min(requestedRows, height - firstRow)
            let crop = CGRect(x: 0, y: height - firstRow - rows, width: width, height: rows)
            actual += ImagePipelineTests.pixels(rendered.cropped(to: crop))
        }

        MetalColorTests.checkBudget(try MetalColorTests.metrics(expected, actual, width: width, height: height))
    }
}
