import Foundation
import CoreImage

private struct WorkflowCheckError: Error, LocalizedError {
    var errorDescription: String? { "Injected workflow failure" }
}

@MainActor
private final class WorkflowHarness {
    var denied = false
    var retentionFails = false
    var processingFailures = 0
    var saveFailures = 0
    var holdSave = false
    var saveContinuation: CheckedContinuation<Void, Never>?
    var shutterCalls = 0
    var processCalls = 0
    var saves: [TemporaryHEIFFile] = []
    var snapshots: [CaptureSnapshot] = []
    var sawMemoryFallback = false
    let data: Data
    let raster: PreviewRaster

    init(data: Data) throws {
        self.data = data
        raster = try PreviewRaster(linearRGBA: [Float](repeating: 1, count: 8 * 8 * 4), width: 8, height: 8)
    }
    func makeWorkflow() -> CaptureWorkflow {
        CaptureWorkflow(services: .init(authorize: { [self] in
            if denied { throw WorkflowCheckError() }
        }, retain: { [self] data in
            if await retentionFails { throw WorkflowCheckError() }
            return try SourceImageFile(data: data, fileExtension: "png")
        }, process: { [self] source, snapshot, progress in
            try await render(source, snapshot: snapshot, progress: progress)
        }, save: { [self] file in
            saves.append(file)
            if holdSave { await withCheckedContinuation { saveContinuation = $0 } }
            if saveFailures > 0 { saveFailures -= 1; throw WorkflowCheckError() }
        }))
    }
    func render(_ source: RetainedCaptureSource, snapshot: CaptureSnapshot,
                progress: @escaping @Sendable (Double) -> Void) async throws -> SavedCapture {
        processCalls += 1; snapshots.append(snapshot)
        switch source {
        case .file(let file): try check(try Data(contentsOf: file.url) == data, "Retained source changed")
        case .memory(let bytes): sawMemoryFallback = true; try check(bytes == data, "Memory fallback changed")
        }
        progress(0.5)
        await Task.yield()
        if processingFailures > 0 { processingFailures -= 1; throw WorkflowCheckError() }
        let file = TemporaryHEIFFile()
        try Data("encoded-\(processCalls)".utf8).write(to: file.url)
        return SavedCapture(file: file, preview: raster, width: snapshot.output.targetWidth ?? 8,
                            height: snapshot.output.targetHeight ?? 8, snapshot: snapshot)
    }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CaptureWorkflowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func wait(_ workflow: CaptureWorkflow, phase: CaptureWorkflow.Phase) async throws {
        for _ in 0..<2000 {
            if workflow.phase == phase { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(false, "Timed out waiting for \(phase), got \(workflow.phase): \(workflow.status)")
    }
}

enum CaptureWorkflowChecks {
    @MainActor static func run(fixture: ImportedImage) async throws {
        let data = try Data(contentsOf: fixture.sourceFile.url)
        let snapshot = CaptureSnapshot(recipe: .standard, output: .init(targetWidth: 5656, targetHeight: 4242))
        do {
            let harness = try WorkflowHarness(data: data); harness.denied = true
            let workflow = harness.makeWorkflow()
            workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 1 }
            try await harness.wait(workflow, phase: .failed)
            try harness.check(harness.shutterCalls == 0 && workflow.needsPhotosPermission && !workflow.canRetry,
                              "Denied Photos permission admitted the shutter")
            workflow.discardFailed()
            try harness.check(workflow.canCapture, "Permission failure did not release admission")
        }
        do {
            let harness = try WorkflowHarness(data: data); harness.saveFailures = 1
            let workflow = harness.makeWorkflow()
            var callback: ((Result<Data, Error>) -> Void)?
            workflow.capture(snapshot: snapshot) { callback = $0; harness.shutterCalls += 1 }
            workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 100 }
            try await harness.wait(workflow, phase: .capturing)
            callback?(.success(data)); callback?(.success(Data()))
            try await harness.wait(workflow, phase: .failed)
            try harness.check(harness.shutterCalls == 1 && harness.processCalls == 1 && workflow.canRetry,
                              "Duplicate shutter/callback created extra processing")
            workflow.retry(); workflow.retry()
            try await harness.wait(workflow, phase: .idle)
            try harness.check(harness.processCalls == 1 && harness.saves.count == 2 && harness.saves[0] === harness.saves[1],
                              "Save retry re-encoded or replaced the original HEIF")
            try harness.check(workflow.latest?.snapshot.recipe == snapshot.recipe && workflow.latest?.width == 5656,
                              "Output did not use shutter snapshot")
            var newer: ((Result<Data, Error>) -> Void)?
            workflow.capture(snapshot: snapshot) { newer = $0 }
            try await harness.wait(workflow, phase: .capturing)
            callback?(.failure(WorkflowCheckError())); callback?(.success(data))
            try harness.check(workflow.phase == .capturing, "Old callback changed a newer capture")
            newer?(.failure(WorkflowCheckError()))
            try await harness.wait(workflow, phase: .failed)
            workflow.discardFailed()
            try harness.check(workflow.canCapture && workflow.latest != nil, "Capture failure lost last saved photo")
        }
        do {
            let suite = "GlassCam.workflow-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let legacyKey = "main:\(Data("physical-main".utf8).base64EncodedString())"
            defaults.set([legacyKey: 12], forKey: "camera.output.megapixels.byPhysicalLens.v1")
            let legacyRecipe = ProcessingRecipe(mode: .hncs, exposureEV: 0.25, illuminantKelvin: 2850,
                simulationIndex: 0, seed: 0, hncs: .standard)
            defaults.set(try JSONEncoder().encode(legacyRecipe), forKey: "editor.processingRecipe.revision8.v1")
            let settings = CameraSettingsStore(defaults: defaults)
            try WorkflowHarness(data: data).check(settings.recipe.photoWhiteBalance == nil &&
                settings.recipe.illuminantKelvin == 6500 && settings.exposure == 0.25,
                "Legacy manual WB survived automatic migration or reset unrelated effects")
            try WorkflowHarness(data: data).check(settings.outputMegapixels(physicalCameraID: "physical-main", mode: "main") == 24,
                                                  "12MP migration did not select 24MP")
            settings.hncs.presetKey = "square-crop"; settings.effects.applyGrain = false
            settings.exposure = 0.5; settings.gridVisible = false
            settings.experimentalLiveColor = true; settings.centerPreviewLongEdge = 2560
            settings.setOutputMegapixels(48, physicalCameraID: "physical-main", mode: "main")
            let frozen = CaptureSnapshot(recipe: settings.recipe, output: .init(targetWidth: 8064, targetHeight: 6048))
            let harness = try WorkflowHarness(data: data)
            harness.processingFailures = 1; harness.retentionFails = true; harness.holdSave = true
            let workflow = harness.makeWorkflow()
            workflow.capture(snapshot: frozen) { $0(.success(data)) }
            settings.exposure = -1; settings.hncs.presetKey = "standard"
            try await harness.wait(workflow, phase: .failed)
            try harness.check(workflow.canRetry && harness.sawMemoryFallback, "Failed processing lost sole source")
            workflow.retry()
            try await harness.wait(workflow, phase: .saving)
            workflow.discardFailed(); workflow.retry()
            workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 100 }
            try harness.check(workflow.phase == .saving && harness.shutterCalls == 0 && !workflow.canCapture,
                              "In-flight Photos transaction admitted discard/retry/capture")
            harness.holdSave = false; harness.saveContinuation?.resume(); harness.saveContinuation = nil
            try await harness.wait(workflow, phase: .idle)
            try harness.check(harness.snapshots.allSatisfy { $0.recipe == frozen.recipe },
                              "Settings changes retargeted committed shot or retry")
            let restored = CameraSettingsStore(defaults: defaults)
            try harness.check(restored.recipe == settings.recipe && !restored.gridVisible && restored.experimentalLiveColor &&
                              restored.centerPreviewLongEdge == 2560 &&
                              restored.outputMegapixels(physicalCameraID: "physical-main", mode: "main") == 48,
                              "Settings did not survive reconstruction")
            settings.setOutputMegapixels(12, physicalCameraID: "physical-main", mode: "main")
            try harness.check(settings.outputMegapixels(physicalCameraID: "physical-main", mode: "main") == 48,
                              "Unsupported 12MP output was accepted")
        }
        print("PASS: production capture workflow permission/admission, duplicate/late callbacks, immutable settings, processing/save retry, in-flight Photos ownership, and persisted 24/48MP migration")
    }
}
