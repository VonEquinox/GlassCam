import Testing
import Combine
@testable import Capture
@testable import ImagingCore
import GlassCamTestSupport
import Foundation

private struct RecoveryCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private final class JournalFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: CaptureJournal.Operation?
    private var remaining = 0
    func arm(_ operation: CaptureJournal.Operation, count: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        self.operation = operation; remaining = count
    }
    func check(_ operation: CaptureJournal.Operation) throws {
        lock.lock(); defer { lock.unlock() }
        if self.operation == operation && remaining > 0 {
            remaining -= 1
            throw RecoveryCheckFailure(message: "Injected journal \(operation.rawValue) failure")
        }
    }
}

private final class JournalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered { lock.unlock(); continuation.resume() }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func check(_ operation: CaptureJournal.Operation) throws {
        guard operation == .beginSave else { return }
        lock.lock()
        if entered { lock.unlock(); return }
        entered = true; let continuation = waiter; waiter = nil; lock.unlock()
        continuation?.resume()
        guard releaseSignal.wait(timeout: .now() + 10) == .success else {
            throw RecoveryCheckFailure(message: "Timed out at journal test gate")
        }
    }
    func release() { releaseSignal.signal() }
}

@MainActor private final class RecoveryHarness {
    let raster: PreviewRaster
    var processes = 0
    var saves = 0
    var reloads = 0
    var authorizations = 0
    var saveFailures = 0
    var holdProcessing = false
    var processingContinuation: CheckedContinuation<Void, Never>?
    func releaseProcessing() {
        holdProcessing = false
        processingContinuation?.resume(); processingContinuation = nil
    }
    var holdSave = false
    var saveContinuation: CheckedContinuation<Void, Never>?
    var observedSnapshots: [CaptureSnapshot] = []

    init() throws { raster = try PreviewRaster(linearRGBA: Array(repeating: 0.5, count: 8 * 8 * 4), width: 8, height: 8) }

    func encoded(_ snapshot: CaptureSnapshot, bytes: Data = Data("verified-test-HEIF".utf8)) throws -> SavedCapture {
        let file = TemporaryHEIFFile(); try bytes.write(to: file.url)
        return SavedCapture(file: file, preview: raster, width: 8, height: 8, snapshot: snapshot)
    }

    func services() -> CaptureWorkflow.Services {
        CaptureWorkflow.Services(authorize: { [self] in authorizations += 1 },
            retain: { data in try SourceImageFile(data: data, fileExtension: "png") },
            process: { [self] _, snapshot, _ in try await render(snapshot, control: nil) },
            save: { [self] _ in
                saves += 1
                if holdSave { await withCheckedContinuation { saveContinuation = $0 } }
                if saveFailures > 0 { saveFailures -= 1; throw RecoveryCheckFailure(message: "Injected Photos failure") }
            }, processWithControl: { [self] _, snapshot, _, control in try await render(snapshot, control: control) },
            reload: { [self] url, snapshot, control in
                if control.isStopped { throw CancellationError() }
                return try await reload(url, snapshot: snapshot)
            })
    }
    private func render(_ snapshot: CaptureSnapshot, control: CaptureProcessingControl?) async throws -> SavedCapture {
        processes += 1; observedSnapshots.append(snapshot)
        if holdProcessing { await withCheckedContinuation { processingContinuation = $0 } }

        if control?.isStopped == true { throw CancellationError() }
        return try encoded(snapshot)
    }
    private func reload(_ url: URL, snapshot: CaptureSnapshot) throws -> SavedCapture {
        reloads += 1; observedSnapshots.append(snapshot)
        return try encoded(snapshot, bytes: Data(contentsOf: url))
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct RecoveryTests {
    let work: TestDirectory
    let raw: Data
    let snapshot = CaptureSnapshot(recipe: .standard, output: .camera(48,
        framing: CaptureFraming(displayZoom: 2, deviceZoom: 4, nativeDeviceZoom: 2, nativePixelCount: 48_000_000)))
    init() throws { work = try TestDirectory(); raw = try ImageFixture.pngData() }
    var directory: URL { work.url }
    private func store(_ name: String, faults: JournalFaults? = nil) -> CaptureJournal {
        CaptureJournal(directory: directory.appendingPathComponent("recovery-\(name)/pending"),
                       beforeOperation: { try faults?.check($0) })
    }
    private func makePending(_ journal: CaptureJournal, harness: RecoveryHarness, saving: Bool) throws -> CaptureJournal.Record {
        let id = UUID()
        _ = try journal.retain(raw, id: id, snapshot: snapshot)
        let record = try journal.storeEncoded(harness.encoded(snapshot), id: id)
        return saving ? try journal.beginSave(id: id) : record
    }
    @Test func legacyNature_recoveryKeepsFrozenWhiteBalance() async throws {
        let journal = store("legacy-white-balance"), harness = try RecoveryHarness()
        var settings = HNCSSettings.legacyStandard
        settings.presetKey = "nature"; settings.whiteBalancePolicy = .preset
        let recipe = ProcessingRecipe(mode: .hncs, exposureEV: -0.05, illuminantKelvin: 6504,
            simulationIndex: 0, seed: 0, hncs: settings, photoWhiteBalance: .renderedD65)
        let frozen = CaptureSnapshot(recipe: recipe, output: snapshot.output)
        _ = try journal.retain(raw, id: UUID(), snapshot: frozen)
        let url = journal.directory.appendingPathComponent("capture.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var storedSnapshot = document["snapshot"] as! [String: Any]
        var storedRecipe = storedSnapshot["recipe"] as! [String: Any]
        var storedSettings = storedRecipe["hncs"] as! [String: Any]
        storedSettings["renderRevision"] = 10
        storedSettings.removeValue(forKey: "whiteBalancePolicy")
        storedRecipe["hncs"] = storedSettings; storedSnapshot["recipe"] = storedRecipe
        document["snapshot"] = storedSnapshot
        try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        #expect(harness.observedSnapshots.count == 1, "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
        #expect(harness.observedSnapshots.first?.recipe == frozen.recipe, "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
        #expect(harness.observedSnapshots.first?.output == frozen.output, "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
        #expect(harness.processes == 1, "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
        #expect(harness.saves == 1, "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
    }
    @Test func borrowedRaw_releasePreservesJournalAndRecovery() async throws {
        let journal = store("raw")
        _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
        var borrowed: SourceImageFile? = try SourceImageFile(retainedURL: journal.rawURL, fileExtension: "png")
        #expect(borrowed?.pixelWidth == 8, "Borrowed RAW dimensions changed")
        borrowed = nil
        #expect(FileManager.default.fileExists(atPath: journal.rawURL.path), "Releasing RAW owner erased recovery source")
        let harness = try RecoveryHarness()
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        #expect(harness.processes == 1, "RAW recovery did not finish exactly once")
        #expect(harness.saves == 1, "RAW recovery did not finish exactly once")
        #expect(workflow.latest?.snapshot.output == snapshot.output, "Recovery read current settings instead of the shutter snapshot")
        #expect(workflow.latest?.snapshot.recipe == snapshot.recipe, "Recovery read current settings instead of the shutter snapshot")
        #expect(try journal.load() == nil, "Successful recovery left an active record")
        #expect(FileManager.default.fileExists(atPath: workflow.latest!.file.url.path), "Journal cleanup erased the review/share file")
    }
    @Test func encodedReady_reloadsWithoutProcessing() async throws {
        let harness = try RecoveryHarness(), journal = store("encoded")
        _ = try makePending(journal, harness: harness, saving: false)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        #expect(harness.processes == 0, "Encoded recovery unnecessarily reprocessed the photo")
        #expect(harness.reloads == 1, "Encoded recovery unnecessarily reprocessed the photo")
        #expect(harness.saves == 1, "Encoded recovery unnecessarily reprocessed the photo")
    }
    @Test(arguments: [false, true]) func unknownSave_requiresExplicitResolution(confirmSaved: Bool) async throws {
        let harness = try RecoveryHarness(), journal = store("unknown-\(confirmSaved)")
        _ = try makePending(journal, harness: harness, saving: true)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .saveOutcomeUnknown)
        workflow.retry(); workflow.discardFailed()
        workflow.capture(snapshot: snapshot) { _ in Issue.record("Unknown save admitted another shutter") }
        #expect(harness.saves == 0, "Unknown outcome automatically saved or admitted another photo")
        #expect(!workflow.canCapture, "Unknown outcome automatically saved or admitted another photo")
        #expect(!workflow.canRetry, "Unknown outcome automatically saved or admitted another photo")
        workflow.setForeground(false); workflow.setForeground(true)
        #expect(workflow.phase == .saveOutcomeUnknown, "Foregrounding retried an unknown save")
        #expect(harness.saves == 0, "Foregrounding retried an unknown save")
        if confirmSaved { workflow.confirmAlreadySaved(); workflow.confirmAlreadySaved() }
        else { workflow.saveAgain(); workflow.saveAgain() }
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == (confirmSaved ? 0 : 1), "User resolution of unknown save produced the wrong number of writes")
        #expect(harness.processes == 0, "User resolution of unknown save produced the wrong number of writes")
    }
    @Test(arguments: [CaptureJournal.Operation.confirmSave, .clear, .encode]) func bookkeepingFailure_retryDoesNotRepeatCompletedWork(failure: CaptureJournal.Operation) async throws {
        let faults = JournalFaults(); faults.arm(failure)
        let harness = try RecoveryHarness(), journal = store("failure-\(failure.rawValue)", faults: faults)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await waitForPhase(workflow, .failed)
        #expect(harness.saves == (failure == .encode ? 0 : 1), "Photos was called before durability or called twice")
        if failure != .encode { #expect(workflow.status.contains("Saved to Photos"), "Receipt failure was misreported as Photos failure") }
        workflow.retry()
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 1, "Bookkeeping retry repeated processing or Photos")
        #expect(harness.processes == 1, "Bookkeeping retry repeated processing or Photos")
    }
    @Test(arguments: [CaptureJournal.Operation.retain, .encode, .beginSave, .failSave, .confirmSave, .clear]) func afterAtomicWriteFailure_retryUsesActualDiskState(failure: CaptureJournal.Operation) async throws {
        let faults = JournalFaults(); faults.arm(failure)
        let harness = try RecoveryHarness()
        if failure == .failSave { harness.saveFailures = 1 }
        let journal = CaptureJournal(directory: directory.appendingPathComponent("recovery-after-\(failure.rawValue)/pending"),
                                     afterOperation: { try faults.check($0) })
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await waitForPhase(workflow, .failed)
        workflow.retry()
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == (failure == .failSave ? 2 : 1), "After-write \(failure.rawValue) failure wedged retry or repeated a completed save")
        #expect(harness.processes == 1, "After-write \(failure.rawValue) failure wedged retry or repeated a completed save")
    }
    @Test func backgroundedSaveIntent_pausesBeforePhotos() async throws {
        let gate = JournalGate(), harness = try RecoveryHarness()
        let journal = CaptureJournal(directory: directory.appendingPathComponent("recovery-submit-gate/pending"),
                                     beforeOperation: { try gate.check($0) })
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await gate.waitUntilEntered()
        workflow.setForeground(false); gate.release()
        await waitForPhase(workflow, .paused)
        #expect(harness.saves == 0, "A save intent completing in background submitted Photos or became unknown")
        #expect((try journal.load())?.stage == .encodedReady, "A save intent completing in background submitted Photos or became unknown")
        workflow.setForeground(true)
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 1, "Unsubmitted attempt did not resume exactly once")
    }
    @Test func durableReceipt_restartDoesNotSaveAgain() async throws {
        let harness = try RecoveryHarness(), journal = store("completed")
        let record = try makePending(journal, harness: harness, saving: true)
        _ = try journal.confirmSaved(id: record.id, attemptID: record.attemptID)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 0, "Durable receipt was ignored on restart")
        #expect(harness.reloads == 0, "Durable receipt was ignored on restart")
    }
    @Test func backgroundedProcessing_retainsRawForForeground() async throws {
        let harness = try RecoveryHarness(), journal = store("pause")
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        harness.holdProcessing = true
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await waitForPhase(workflow, .processing)
        workflow.setForeground(false)
        harness.releaseProcessing()
        await waitForPhase(workflow, .paused)
        #expect(harness.saves == 0, "Background cancellation lost RAW or submitted Photos")
        #expect(!workflow.canCapture, "Background cancellation lost RAW or submitted Photos")
        #expect((try journal.load())?.stage == .rawReady, "Background cancellation lost RAW or submitted Photos")
        harness.holdProcessing = false; workflow.setForeground(true)
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 1, "Foreground did not restart the retained photo")
        #expect(harness.processes == 2, "Foreground did not restart the retained photo")
    }
    @Test func activePhotosTransaction_foregroundChangesDoNotDuplicateSave() async throws {
        let harness = try RecoveryHarness(), journal = store("inflight")
        harness.holdSave = true
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await waitForPhase(workflow, .saving)
        workflow.setForeground(false); workflow.setForeground(true); workflow.retry(); workflow.discardFailed()
        #expect(harness.saves == 1, "Live Photos transaction was duplicated or discarded")
        #expect(workflow.phase == .saving, "Live Photos transaction was duplicated or discarded")
        harness.holdSave = false; harness.saveContinuation?.resume(); harness.saveContinuation = nil
        await waitForPhase(workflow, .idle)
    }
    @Test func definitePhotosFailure_retryUsesEncodedFile() async throws {
        let harness = try RecoveryHarness(), journal = store("photos-failed")
        harness.saveFailures = 1
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
        await waitForPhase(workflow, .failed)
        #expect((try journal.load())?.stage == .encodedReady, "Definite Photos failure became an unknown outcome")
        workflow.retry()
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 2, "Definite save retry reprocessed RAW")
        #expect(harness.processes == 1, "Definite save retry reprocessed RAW")
    }
    @Test func damagedRaw_isPreservedWithoutSaving() async throws {
        let harness = try RecoveryHarness(), journal = store("tamper")
        _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
        try Data("damaged".utf8).write(to: journal.rawURL)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .failed)
        #expect(harness.saves == 0, "Damaged recovery data was saved or silently deleted")
        #expect(FileManager.default.fileExists(atPath: journal.rawURL.path), "Damaged recovery data was saved or silently deleted")
        workflow.discardFailed()
        await waitForPhase(workflow, .idle)
    }
    @Test func protectedStartup_waitsForForegroundAndAllowsRetry() async throws {
        let faults = JournalFaults(); faults.arm(.load)
        let harness = try RecoveryHarness(), journal = store("unreadable", faults: faults)
        _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal, initiallyActive: false)
        #expect(harness.processes == 0, "Protected startup did work before foreground")
        #expect(harness.saves == 0, "Protected startup did work before foreground")
        workflow.setForeground(true)
        await waitForPhase(workflow, .failed)
        workflow.retry()
        await waitForPhase(workflow, .idle)
        #expect(harness.saves == 1, "Recovery did not retry after protected storage became available")
    }
    @Test func retiredCleanup_restartDoesNotRepeatSave() async throws {
        let harness = try RecoveryHarness(), journal = store("retired")
        let record = try makePending(journal, harness: harness, saving: true)
        _ = try journal.confirmSaved(id: record.id, attemptID: record.attemptID)
        let retired = journal.directory.deletingLastPathComponent().appendingPathComponent("FinishedCapture-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: journal.directory, to: retired)
        let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
        await waitForPhase(workflow, .idle)
        #expect(!FileManager.default.fileExists(atPath: retired.path), "Interrupted retired-file cleanup leaked the photo or repeated its save")
        #expect(harness.saves == 0, "Interrupted retired-file cleanup leaked the photo or repeated its save")
    }
}
