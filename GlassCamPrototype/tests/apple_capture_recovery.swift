import Foundation

private struct RecoveryCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func recoveryRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw RecoveryCheckFailure(message: message) }
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
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func check(_ operation: CaptureJournal.Operation) throws {
        guard operation == .beginSave else { return }
        lock.lock()
        if entered { lock.unlock(); return }
        entered = true; lock.unlock()
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
        while holdProcessing {
            if control?.isStopped == true { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
        if control?.isStopped == true { throw CancellationError() }
        return try encoded(snapshot)
    }
    private func reload(_ url: URL, snapshot: CaptureSnapshot) throws -> SavedCapture {
        reloads += 1; observedSnapshots.append(snapshot)
        return try encoded(snapshot, bytes: Data(contentsOf: url))
    }
    func wait(_ workflow: CaptureWorkflow, for phase: CaptureWorkflow.Phase) async throws {
        for _ in 0..<5000 {
            if workflow.phase == phase { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RecoveryCheckFailure(message: "Expected \(phase), got \(workflow.phase): \(workflow.status)")
    }
}

enum CaptureRecoveryChecks {
    @MainActor static func run(fixture: ImportedImage, directory: URL) async throws {
        let raw = try Data(contentsOf: fixture.sourceFile.url)
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera(48,
            framing: CaptureFraming(displayZoom: 2, deviceZoom: 4, nativeDeviceZoom: 2, nativePixelCount: 48_000_000)))
        func store(_ name: String, faults: JournalFaults? = nil) -> CaptureJournal {
            CaptureJournal(directory: directory.appendingPathComponent("recovery-\(name)/pending"),
                           beforeOperation: { try faults?.check($0) })
        }
        func makePending(_ journal: CaptureJournal, harness: RecoveryHarness, saving: Bool) throws -> CaptureJournal.Record {
            let id = UUID()
            _ = try journal.retain(raw, id: id, snapshot: snapshot)
            let record = try journal.storeEncoded(harness.encoded(snapshot), id: id)
            return saving ? try journal.beginSave(id: id) : record
        }

        // A pre-fix capture survives an app update without adopting the new
        // camera default. The on-disk recipe has no WB policy field.
        do {
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
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.observedSnapshots.count == 1 && harness.observedSnapshots.first?.recipe == frozen.recipe &&
                                harness.observedSnapshots.first?.output == frozen.output && harness.processes == 1 && harness.saves == 1,
                                "Recovered old Nature capture adopted automatic WB or lost its frozen recipe")
        }

        // An in-memory owner's release must not erase a journal-owned RAW.
        do {
            let journal = store("raw")
            _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
            var borrowed: SourceImageFile? = try SourceImageFile(retainedURL: journal.rawURL, fileExtension: "png")
            try recoveryRequire(borrowed?.pixelWidth == fixture.sourceFile.pixelWidth, "Borrowed RAW dimensions changed")
            borrowed = nil
            try recoveryRequire(FileManager.default.fileExists(atPath: journal.rawURL.path), "Releasing RAW owner erased recovery source")
            let harness = try RecoveryHarness()
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.processes == 1 && harness.saves == 1, "RAW recovery did not finish exactly once")
            try recoveryRequire(workflow.latest?.snapshot.output == snapshot.output && workflow.latest?.snapshot.recipe == snapshot.recipe,
                                "Recovery read current settings instead of the shutter snapshot")
            try recoveryRequire(try journal.load() == nil, "Successful recovery left an active record")
            try recoveryRequire(FileManager.default.fileExists(atPath: workflow.latest!.file.url.path), "Journal cleanup erased the review/share file")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("encoded")
            _ = try makePending(journal, harness: harness, saving: false)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.processes == 0 && harness.reloads == 1 && harness.saves == 1,
                                "Encoded recovery unnecessarily reprocessed the photo")
        }
        for confirmSaved in [false, true] {
            let harness = try RecoveryHarness(), journal = store("unknown-\(confirmSaved)")
            _ = try makePending(journal, harness: harness, saving: true)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .saveOutcomeUnknown)
            workflow.retry(); workflow.discardFailed()
            workflow.capture(snapshot: snapshot) { _ in fatalError("Unknown save admitted another shutter") }
            try recoveryRequire(harness.saves == 0 && !workflow.canCapture && !workflow.canRetry,
                                "Unknown outcome automatically saved or admitted another photo")
            workflow.setForeground(false); workflow.setForeground(true)
            try recoveryRequire(workflow.phase == .saveOutcomeUnknown && harness.saves == 0, "Foregrounding retried an unknown save")
            if confirmSaved { workflow.confirmAlreadySaved(); workflow.confirmAlreadySaved() }
            else { workflow.saveAgain(); workflow.saveAgain() }
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == (confirmSaved ? 0 : 1) && harness.processes == 0,
                                "User resolution of unknown save produced the wrong number of writes")
        }
        // A live completion and its durable receipt are separate operations.
        for failure in [CaptureJournal.Operation.confirmSave, .clear, .encode] {
            let faults = JournalFaults(); faults.arm(failure)
            let harness = try RecoveryHarness(), journal = store("failure-\(failure.rawValue)", faults: faults)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            try await harness.wait(workflow, for: .failed)
            try recoveryRequire(harness.saves == (failure == .encode ? 0 : 1), "Photos was called before durability or called twice")
            if failure != .encode { try recoveryRequire(workflow.status.contains("Saved to Photos"), "Receipt failure was misreported as Photos failure") }
            workflow.retry()
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 1 && harness.processes == 1, "Bookkeeping retry repeated processing or Photos")
        }
        // Throw AFTER the atomic replacement: method failure must not be taken
        // as proof that the previous disk state is still present.
        for failure in [CaptureJournal.Operation.retain, .encode, .beginSave, .failSave, .confirmSave, .clear] {
            let faults = JournalFaults(); faults.arm(failure)
            let harness = try RecoveryHarness()
            if failure == .failSave { harness.saveFailures = 1 }
            let journal = CaptureJournal(directory: directory.appendingPathComponent("recovery-after-\(failure.rawValue)/pending"),
                                         afterOperation: { try faults.check($0) })
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            try await harness.wait(workflow, for: .failed)
            workflow.retry()
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == (failure == .failSave ? 2 : 1) && harness.processes == 1,
                                "After-write \(failure.rawValue) failure wedged retry or repeated a completed save")
        }
        do {
            let gate = JournalGate(), harness = try RecoveryHarness()
            let journal = CaptureJournal(directory: directory.appendingPathComponent("recovery-submit-gate/pending"),
                                         beforeOperation: { try gate.check($0) })
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            for _ in 0..<5000 {
                if gate.didEnter { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try recoveryRequire(gate.didEnter, "Save intent did not reach the gated write")
            workflow.setForeground(false); gate.release()
            try await harness.wait(workflow, for: .paused)
            try recoveryRequire(harness.saves == 0 && (try journal.load())?.stage == .encodedReady,
                                "A save intent completing in background submitted Photos or became unknown")
            workflow.setForeground(true)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 1, "Unsubmitted attempt did not resume exactly once")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("completed")
            let record = try makePending(journal, harness: harness, saving: true)
            _ = try journal.confirmSaved(id: record.id, attemptID: record.attemptID)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 0 && harness.reloads == 0, "Durable receipt was ignored on restart")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("pause")
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            harness.holdProcessing = true
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            try await harness.wait(workflow, for: .processing)
            workflow.setForeground(false)
            try await harness.wait(workflow, for: .paused)
            try recoveryRequire(harness.saves == 0 && !workflow.canCapture && (try journal.load())?.stage == .rawReady,
                                "Background cancellation lost RAW or submitted Photos")
            harness.holdProcessing = false; workflow.setForeground(true)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 1 && harness.processes == 2, "Foreground did not restart the retained photo")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("inflight")
            harness.holdSave = true
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            try await harness.wait(workflow, for: .saving)
            workflow.setForeground(false); workflow.setForeground(true); workflow.retry(); workflow.discardFailed()
            try recoveryRequire(harness.saves == 1 && workflow.phase == .saving, "Live Photos transaction was duplicated or discarded")
            harness.holdSave = false; harness.saveContinuation?.resume(); harness.saveContinuation = nil
            try await harness.wait(workflow, for: .idle)
        }
        do {
            let harness = try RecoveryHarness(), journal = store("photos-failed")
            harness.saveFailures = 1
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            workflow.capture(snapshot: snapshot) { $0(.success(raw)) }
            try await harness.wait(workflow, for: .failed)
            try recoveryRequire((try journal.load())?.stage == .encodedReady, "Definite Photos failure became an unknown outcome")
            workflow.retry()
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 2 && harness.processes == 1, "Definite save retry reprocessed RAW")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("tamper")
            _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
            try Data("damaged".utf8).write(to: journal.rawURL)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .failed)
            try recoveryRequire(harness.saves == 0 && FileManager.default.fileExists(atPath: journal.rawURL.path),
                                "Damaged recovery data was saved or silently deleted")
            workflow.discardFailed()
            try await harness.wait(workflow, for: .idle)
        }
        do {
            let faults = JournalFaults(); faults.arm(.load)
            let harness = try RecoveryHarness(), journal = store("unreadable", faults: faults)
            _ = try journal.retain(raw, id: UUID(), snapshot: snapshot)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal, initiallyActive: false)
            try recoveryRequire(harness.processes == 0 && harness.saves == 0, "Protected startup did work before foreground")
            workflow.setForeground(true)
            try await harness.wait(workflow, for: .failed)
            workflow.retry()
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(harness.saves == 1, "Recovery did not retry after protected storage became available")
        }
        do {
            let harness = try RecoveryHarness(), journal = store("retired")
            let record = try makePending(journal, harness: harness, saving: true)
            _ = try journal.confirmSaved(id: record.id, attemptID: record.attemptID)
            let retired = journal.directory.deletingLastPathComponent().appendingPathComponent("FinishedCapture-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: journal.directory, to: retired)
            let workflow = CaptureWorkflow(services: harness.services(), journal: journal)
            try await harness.wait(workflow, for: .idle)
            try recoveryRequire(!FileManager.default.fileExists(atPath: retired.path) && harness.saves == 0,
                                "Interrupted retired-file cleanup leaked the photo or repeated its save")
        }
        print("PASS: durable RAW/HEIF recovery, unknown Photos outcomes, receipts/cleanup failures, foreground suspension, corruption preservation and one-photo admission")
    }
}

enum CaptureOutputChecks {
    static func run() throws {
        for count in [23_999_999, 24_000_000, 24_000_001] {
            let framing = CaptureFraming(nativePixelCount: count)
            let low = ExportSettings.camera(24, framing: framing)
            let high = ExportSettings.camera(48, framing: framing)
            try recoveryRequire(try low.selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == 24, "24MP mode changed tiers")
            try recoveryRequire(try high.selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == (count < 24_000_000 ? 24 : 48),
                                "48MP threshold boundary is incorrect")
        }
        for size in [(8000, 6000), (6000, 8000), (257, 389), (389, 257), (1000, 1000)] {
            let dimensions = try ExportSettings.camera(24).dimensions(sourceWidth: size.0, sourceHeight: size.1)
            let pixels = Double(dimensions.width) * Double(dimensions.height)
            try recoveryRequire(abs(pixels / 24_000_000 - 1) < 0.002, "Adaptive output missed the 24MP target")
            try recoveryRequire(abs((Double(dimensions.width) / Double(dimensions.height)) / (Double(size.0) / Double(size.1)) - 1) < 0.001,
                                "Adaptive output stretched its composition")
        }
        let cropped = ExportSettings.camera(48)
        try recoveryRequire(try cropped.selectedOutputMegapixels(sourceWidth: 6000, sourceHeight: 4000, crop: .centeredSquare) == 24,
                            "MP threshold was evaluated before the recipe crop")
        let zoomed = ExportSettings.camera(48, framing: CaptureFraming(displayZoom: 2, deviceZoom: 4, nativeDeviceZoom: 2, nativePixelCount: 48_000_000))
        try recoveryRequire(try zoomed.selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == 24,
                            "Digital zoom ignored the estimated native-pixel ceiling")
        let native = try ExportSettings.native.dimensions(sourceWidth: 257, sourceHeight: 389)
        try recoveryRequire(native.width == 257 && native.height == 389, "Native export changed source size")
        do {
            _ = try ExportSettings(targetWidth: 514, targetHeight: 778).dimensions(sourceWidth: 257, sourceHeight: 389)
            throw RecoveryCheckFailure(message: "Legacy explicit output silently started upscaling")
        } catch is PipelineError {}
        for settings in [ExportSettings.camera(0), .camera(48, framing: CaptureFraming(deviceZoom: .nan))] {
            do {
                _ = try settings.dimensions(sourceWidth: 8000, sourceHeight: 6000)
                throw RecoveryCheckFailure(message: "Invalid capture settings were accepted")
            } catch is PipelineError {}
        }
        let range = CameraZoomRange(lowerBound: 0.5, upperBound: 10, stops: [])
        try recoveryRequire(range.clamped(0.1) == 0.5 && range.clamped(20) == 10 && range.clamped(.nan) == 0.5,
                            "Zoom limits accepted invalid values")
        let nativeFraming = CaptureFraming(cameraID: "main", nativePixelCount: 8064 * 6048)
        try recoveryRequire(!nativeFraming.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3024, bufferWidth: 4032, bufferHeight: 3024),
            "Native 1x source loss was hidden by interpolation")
        try recoveryRequire(nativeFraming.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 6048, deliveredHeight: 8064, bufferWidth: 8064, bufferHeight: 6048),
            "A correctly oriented native RAW was rejected")
        let croppedFraming = CaptureFraming(deviceZoom: 2, cameraID: "main", nativePixelCount: 8064 * 6048)
        try recoveryRequire(croppedFraming.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3024, bufferWidth: 4032, bufferHeight: 3024),
            "Explicitly zoomed RAW could not use a smaller source")
        try recoveryRequire(!croppedFraming.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3000, bufferWidth: 4032, bufferHeight: 3000),
            "A RAW with inconsistent framing aspect was accepted")
        let exifFraming = CaptureFraming(cameraID: "main", nativePixelCount: 48_000_000, exifDigitalZoom: 2)
        try recoveryRequire(exifFraming.acceptsRAWDimensions(requestedWidth: 8000, requestedHeight: 6000,
            deliveredWidth: 4000, deliveredHeight: 3000, bufferWidth: 4000, bufferHeight: 3000),
            "Photo metadata describing digital cropping did not allow the cropped RAW")
        try recoveryRequire(try ExportSettings.camera(48, framing: exifFraming)
            .selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == 24,
            "Captured digital zoom metadata did not constrain the effective-pixel estimate")
        for exif in [Double.nan, .infinity, -1, 0, 1, 1.5] {
            let framing = CaptureFraming(deviceZoom: 2, exifDigitalZoom: exif)
            try recoveryRequire(framing.relativeDigitalZoom == 2, "Invalid/default EXIF erased known digital zoom")
        }
        let decodedFraming = CaptureFraming(nativePixelCount: 48_000_000, deliveredWidth: 8000, deliveredHeight: 6000,
                                             decodedWidth: 4000, decodedHeight: 3000)
        let replayFraming = try JSONDecoder().decode(CaptureFraming.self, from: JSONEncoder().encode(decodedFraming))
        let review = SavedCapture(file: TemporaryHEIFFile(),
            preview: try PreviewRaster(linearRGBA: [Float](repeating: 1, count: 4 * 4 * 4), width: 4, height: 4),
            width: 5656, height: 4242,
            snapshot: CaptureSnapshot(recipe: .standard, output: .camera(48, framing: replayFraming)))
        try recoveryRequire(review.resolutionDescription?.contains("source 12.0 MP") == true &&
                            review.resolutionDescription?.contains("Interpolated") == true,
                            "Recovered review used the uncropped RAW callback size instead of the decoded extent")
        let frozen = CaptureSnapshot(recipe: .standard, output: zoomed)
        let replay = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(frozen))
        try recoveryRequire(replay.recipe == frozen.recipe && replay.output == frozen.output, "Capture geometry did not survive persistence")
        print("PASS: 24/48MP thresholds, post-crop policy, interpolation dimensions/aspect, zoom limits, native compatibility and Codable replay")
    }
}
