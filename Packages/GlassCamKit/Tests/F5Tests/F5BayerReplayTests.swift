import Testing
import Foundation
import ImageIO
import GlassCamTestSupport
@testable import F5
@testable import Capture
@testable import ImagingCore

/// Explicitly enabled integration with locally retained Bayer capture bundles.
@Suite(.serialized)
struct F5BayerReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSCAM_RAW_SCENE_REPLAY"] != nil))
    func recordedScene_archivesMergedRAWWithoutColorResources() throws {
        guard let input = TestResources.environmentURL("GLASSCAM_RAW_SCENE_REPLAY"),
              let output = TestResources.environmentURL("GLASSCAM_RAW_SCENE_OUTPUT") else { return }
        let source = try F5BurstSource(directory: input)
        let snapshot = CaptureSnapshot(recipe: .standard,output: .native,quality: .balanced,rawArchiveID: source.manifest.id)

        let saved = try F5ImagePipeline.archiveRAW(source,snapshot: snapshot,progress: { _ in },isCancelled: { false },
            shaderURL: F5TestContext.shader,archiveRoot: output)

        let names = try FileManager.default.contentsOfDirectory(atPath: saved.path)
        #expect(names.contains("balanced-camera.dng"))
        #expect(names.contains("balanced-linear.tiff"))
        #expect(!names.contains(where: { $0.hasSuffix("heic") }))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSCAM_BAYER_REPLAY"] != nil),
          arguments: [CaptureQuality.speed,.balanced], ColorMode.allCases)
    func recordedRAW_exportsSourceWhitePointISOAndNativeGrid(quality: CaptureQuality, mode: ColorMode) throws {
        guard let root = TestResources.environmentURL("GLASSCAM_BAYER_REPLAY") else { return }
        let source = try F5BurstSource(directory: root.appendingPathComponent(quality.rawValue))
        let recipe = ProcessingRecipe(mode: mode,exposureEV: 0,illuminantKelvin: 6500,simulationIndex: 0,seed: 0,hncs: .standard)
        let archives = TestResources.environmentURL("GLASSCAM_BAYER_ARCHIVE")
        let archiveID: UUID? = archives != nil && quality == .balanced && mode == .hncs ? UUID() : nil
        let snapshot = CaptureSnapshot(recipe: recipe,output: .native,quality: quality,rawArchiveID: archiveID)

        let result = try F5ImagePipeline.render(resources: TestResources.colors,source,snapshot: snapshot,
            progress: { _ in },isCancelled: { false },shaderURL: F5TestContext.shader,archiveRoot: archives)

        let white = try #require(result.snapshot.recipe.photoWhiteBalance)
        #expect(white.isValid)
        #expect(result.snapshot.quality == quality)
        if mode == .lumix { #expect(result.snapshot.recipe.lumix.sourceISO == Int(source.manifest.frames[0].actualISO)) }
        if let output = TestResources.environmentURL("GLASSCAM_BAYER_OUTPUT") {
            try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
            let file = output.appendingPathComponent("\(quality.rawValue)-\(mode.rawValue).heic")
            try FileManager.default.copyItem(at: result.file.url,to: file)
        }
    }
}
