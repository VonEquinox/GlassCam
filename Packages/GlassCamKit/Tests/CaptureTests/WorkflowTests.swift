import Testing
import Foundation
import Combine
@testable import Capture
@testable import ImagingCore
import GlassCamTestSupport

struct WorkflowFailure: Error, LocalizedError {
    var errorDescription: String? { "Injected workflow failure" }
}

@MainActor final class WorkflowHarness {
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
    var retainedBytes: [Data] = []
    var memoryFallbacks = 0
    let data: Data
    let raster: PreviewRaster
    init() throws {
        data = try ImageFixture.pngData()
        raster = try PreviewRaster(linearRGBA: [Float](repeating: 1, count: 8 * 8 * 4), width: 8, height: 8)
    }
    func makeWorkflow() -> CaptureWorkflow {
        CaptureWorkflow(services: .init(authorize: { [self] in
            if denied { throw WorkflowFailure() }
        }, retain: { [self] data in
            if await retentionFails { throw WorkflowFailure() }
            return try SourceImageFile(data: data, fileExtension: "png")
        }, process: { [self] source, snapshot, progress in
            try await render(source, snapshot: snapshot, progress: progress)
        }, save: { [self] file in
            saves.append(file)
            if holdSave { await withCheckedContinuation { saveContinuation = $0 } }
            if saveFailures > 0 { saveFailures -= 1; throw WorkflowFailure() }
        }))
    }
    func render(_ source: RetainedCaptureSource, snapshot: CaptureSnapshot,
                progress: @escaping @Sendable (Double) -> Void) async throws -> SavedCapture {
        processCalls += 1
        snapshots.append(snapshot)
        switch source {
        case .file(let file): retainedBytes.append(try Data(contentsOf: file.url))
        case .memory(let bytes): memoryFallbacks += 1; retainedBytes.append(bytes)
        case .burst: Issue.record("Single-photo workflow received a burst payload")
        }
        progress(0.5)
        await Task.yield()
        if processingFailures > 0 { processingFailures -= 1; throw WorkflowFailure() }
        let file = TemporaryHEIFFile()
        try Data("encoded-\(processCalls)".utf8).write(to: file.url)
        return SavedCapture(file: file, preview: raster, width: snapshot.output.targetWidth ?? 8,
                            height: snapshot.output.targetHeight ?? 8, snapshot: snapshot)
    }
    func releaseSave() {
        holdSave = false
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

@MainActor func waitForPhase(_ workflow: CaptureWorkflow, _ phase: CaptureWorkflow.Phase) async {
    for await published in workflow.$phase.values {
        if published == phase { return }
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct WorkflowTests {
    let snapshot = CaptureSnapshot(recipe: .standard, output: .init(targetWidth: 5656, targetHeight: 4242))

    @Test func permissionDenied_neverSubmitsShutterOrProcessing() async throws {
        let harness = try WorkflowHarness(); harness.denied = true
        let workflow = harness.makeWorkflow()

        workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 1 }
        await waitForPhase(workflow, .failed)

        #expect(harness.shutterCalls == 0)
        #expect(harness.processCalls == 0)
        #expect(workflow.needsPhotosPermission)
        #expect(!workflow.canRetry)
    }
    @Test func permissionFailure_discardReleasesAdmission() async throws {
        let harness = try WorkflowHarness(); harness.denied = true
        let workflow = harness.makeWorkflow()
        workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 1 }
        await waitForPhase(workflow, .failed)

        workflow.discardFailed()

        #expect(workflow.canCapture)
    }
    @Test func pendingCapture_rejectsSecondShutterAndDuplicateCallback() async throws {
        let harness = try WorkflowHarness(); harness.saveFailures = 1
        let workflow = harness.makeWorkflow()
        var callback: ((Result<Data, Error>) -> Void)?

        workflow.capture(snapshot: snapshot) { callback = $0; harness.shutterCalls += 1 }
        workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 100 }
        await waitForPhase(workflow, .capturing)
        let deliver = try #require(callback)
        deliver(.success(harness.data))
        callback?(.success(Data()))
        await waitForPhase(workflow, .failed)

        #expect(harness.shutterCalls == 1)
        #expect(harness.processCalls == 1)
        #expect(harness.retainedBytes == [harness.data])
    }
    @Test func saveFailure_duplicateRetryReusesEncodedFile() async throws {
        let harness = try WorkflowHarness(); harness.saveFailures = 1
        let workflow = harness.makeWorkflow()
        workflow.capture(snapshot: snapshot) { $0(.success(harness.data)) }
        await waitForPhase(workflow, .failed)
        try #require(workflow.canRetry)

        workflow.retry(); workflow.retry()
        await waitForPhase(workflow, .idle)

        #expect(harness.processCalls == 1)
        #expect(harness.saves.count == 2)
        #expect(harness.saves.first === harness.saves.last)
    }
    @Test func processingFailure_retryKeepsOriginalBytesAndSnapshot() async throws {
        let harness = try WorkflowHarness(); harness.processingFailures = 1
        let workflow = harness.makeWorkflow()
        workflow.capture(snapshot: snapshot) { $0(.success(harness.data)) }
        await waitForPhase(workflow, .failed)

        workflow.retry()
        await waitForPhase(workflow, .idle)

        #expect(harness.processCalls == 2)
        #expect(harness.retainedBytes == [harness.data, harness.data])
        #expect(harness.snapshots.map(\.recipe) == [snapshot.recipe, snapshot.recipe])
        #expect(harness.snapshots.map(\.output) == [snapshot.output, snapshot.output])
    }
    @Test func retentionFailure_processingRetryRetainsMemoryInput() async throws {
        let harness = try WorkflowHarness(); harness.retentionFails = true; harness.processingFailures = 1
        let workflow = harness.makeWorkflow()
        workflow.capture(snapshot: snapshot) { $0(.success(harness.data)) }
        await waitForPhase(workflow, .failed)

        workflow.retry()
        await waitForPhase(workflow, .idle)

        #expect(harness.memoryFallbacks == 2)
        #expect(harness.retainedBytes == [harness.data, harness.data])
    }
    @Test func oldCallback_cannotChangeNewCapture() async throws {
        let harness = try WorkflowHarness()
        let workflow = harness.makeWorkflow()
        var old: ((Result<Data, Error>) -> Void)?
        workflow.capture(snapshot: snapshot) { old = $0 }
        await waitForPhase(workflow, .capturing)
        let deliver = try #require(old)
        deliver(.success(harness.data))
        await waitForPhase(workflow, .idle)
        var newer: ((Result<Data, Error>) -> Void)?
        workflow.capture(snapshot: snapshot) { newer = $0 }
        await waitForPhase(workflow, .capturing)

        old?(.failure(WorkflowFailure())); old?(.success(harness.data))

        #expect(workflow.phase == .capturing)
        newer?(.failure(WorkflowFailure()))
        await waitForPhase(workflow, .failed)
        workflow.discardFailed()
        #expect(workflow.canCapture)
        #expect(workflow.latest != nil)
    }
    @Test func inFlightSave_rejectsDiscardRetryAndNewCapture() async throws {
        let harness = try WorkflowHarness(); harness.holdSave = true
        let workflow = harness.makeWorkflow()
        workflow.capture(snapshot: snapshot) { $0(.success(harness.data)) }
        await waitForPhase(workflow, .saving)

        workflow.discardFailed(); workflow.retry()
        workflow.capture(snapshot: snapshot) { _ in harness.shutterCalls += 1 }

        #expect(workflow.phase == .saving)
        #expect(harness.shutterCalls == 0)
        #expect(!workflow.canCapture)
        harness.releaseSave()
        await waitForPhase(workflow, .idle)
    }
    @Test func invalidRecipe_neverSubmitsShutter() async throws {
        let harness = try WorkflowHarness()
        let workflow = harness.makeWorkflow()
        let invalid = ProcessingRecipe(mode: .hncs, exposureEV: .nan, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: .standard)

        workflow.capture(snapshot: .init(recipe: invalid, output: .native)) { _ in harness.shutterCalls += 1 }

        #expect(harness.shutterCalls == 0)
        #expect(workflow.phase == .idle)
    }
    @Test func settingsMutation_doesNotRetargetFrozenCaptureOrRetry() async throws {
        let suite = "glasscam-frozen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CameraSettingsStore(defaults: defaults)
        settings.hncs.presetKey = "nature"; settings.effects.applyGrain = false
        settings.exposure = 0.5; settings.captureQuality = .balanced
        let frozen = CaptureSnapshot(recipe: settings.recipe, output: .init(targetWidth: 8064, targetHeight: 6048), quality: settings.captureQuality)
        let harness = try WorkflowHarness(); harness.processingFailures = 1
        let workflow = harness.makeWorkflow()

        workflow.capture(snapshot: frozen) { $0(.success(harness.data)) }
        settings.exposure = -1; settings.hncs.presetKey = "standard"; settings.captureQuality = .speed
        await waitForPhase(workflow, .failed)
        workflow.retry()
        await waitForPhase(workflow, .idle)

        #expect(harness.snapshots.map(\.recipe) == [frozen.recipe, frozen.recipe])
        #expect(harness.snapshots.map(\.quality) == [frozen.quality, frozen.quality])
        #expect(workflow.latest?.snapshot.output == frozen.output)
    }
}
