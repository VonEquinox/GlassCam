import Foundation
import Combine
import ImageIO

struct CaptureSnapshot: Codable, Sendable {
    let recipe: ProcessingRecipe
    let output: ExportSettings
    let quality: CaptureQuality
    let f5: F5CaptureProvenance?
    let archiveF5RAW: Bool

    init(recipe: ProcessingRecipe, output: ExportSettings, quality: CaptureQuality = .quality, f5: F5CaptureProvenance? = nil, archiveF5RAW: Bool = false) {
        self.recipe = recipe
        self.output = quality == .f5 ? ExportSettings(targetWidth:nil,targetHeight:nil,framing:output.framing) : output
        self.quality = quality; self.f5 = f5; self.archiveF5RAW = archiveF5RAW
    }
    private enum CodingKeys: String, CodingKey { case recipe, output, quality, f5, archiveF5RAW }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try values.decode(ProcessingRecipe.self, forKey: .recipe)
        output = try values.decode(ExportSettings.self, forKey: .output)
        quality = try values.decodeIfPresent(CaptureQuality.self, forKey: .quality) ?? .quality
        f5 = try values.decodeIfPresent(F5CaptureProvenance.self, forKey: .f5)
        archiveF5RAW = try values.decodeIfPresent(Bool.self, forKey: .archiveF5RAW) ?? false
    }
}

struct SavedCapture: Identifiable, @unchecked Sendable {
    let id = UUID()
    let file: TemporaryHEIFFile
    let preview: PreviewRaster
    let width: Int
    let height: Int
    let snapshot: CaptureSnapshot
    var resolutionDescription: String? {
        if let f5 = snapshot.f5 {
            return String(format: "F5 · 5 RAW · Output %.1f MP", Double(width * height) / 1_000_000) +
                (f5.hasFallback ? " · Some areas use native detail" : "")
        }
        guard let framing = snapshot.output.framing,
              let sourceWidth = framing.decodedWidth ?? framing.deliveredWidth,
              let sourceHeight = framing.decodedHeight ?? framing.deliveredHeight,
              let effective = try? snapshot.output.effectivePixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: snapshot.recipe.crop) else { return nil }
        let output = Double(width) * Double(height)
        let interpolation = output > effective * 1.025 ? " · Interpolated" : ""
        return String(format: "Estimated source %.1f MP · Output %.1f MP", effective / 1_000_000, output / 1_000_000) + interpolation
    }
}

enum RetainedCaptureSource: @unchecked Sendable {
    case file(SourceImageFile)
    case memory(Data)
    case burst(F5BurstSource)
}

/// Root-owned single-photo workflow. A Photos receipt or an explicit user
/// decision releases a recoverable photo after a process restart.
@MainActor
final class CaptureWorkflow: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, capturing, retaining, processing, saving, failed
        case restoring, paused, saveOutcomeUnknown
    }
    struct Services {
        var authorize: @MainActor () async throws -> Void
        var retain: @Sendable (Data) async throws -> SourceImageFile
        var process: @Sendable (RetainedCaptureSource, CaptureSnapshot, @escaping @Sendable (Double) -> Void) async throws -> SavedCapture
        var save: @MainActor (TemporaryHEIFFile) async throws -> Void
        var processWithControl: (@Sendable (RetainedCaptureSource, CaptureSnapshot, @escaping @Sendable (Double) -> Void,
                                           CaptureProcessingControl) async throws -> SavedCapture)? = nil
        var reload: (@Sendable (URL, CaptureSnapshot, CaptureProcessingControl) async throws -> SavedCapture)? = nil

        static func live(resources: ColorResources, authorize: @escaping @MainActor () async throws -> Void,
                         save: @escaping @MainActor (TemporaryHEIFFile) async throws -> Void) -> Services {
            Services(authorize: authorize, retain: { data in
                try await Task.detached(priority: .userInitiated) {
                    try SourceImageFile(data: data, fileExtension: "dng")
                }.value
            }, process: { source, snapshot, progress in
                try await processCapture(resources: resources, source, snapshot: snapshot, progress: progress, control: CaptureProcessingControl())
            }, save: save, processWithControl: { source, snapshot, progress, control in
                try await processCapture(resources: resources, source, snapshot: snapshot, progress: progress, control: control)
            }, reload: { url, snapshot, control in
                try await reloadCapture(url, snapshot: snapshot, control: control)
            })
        }

        nonisolated private static func processCapture(resources: ColorResources, _ source: RetainedCaptureSource, snapshot: CaptureSnapshot,
            progress: @escaping @Sendable (Double) -> Void, control: CaptureProcessingControl) async throws -> SavedCapture {
            try await Task.detached(priority: .userInitiated) {
                if control.isStopped { throw CancellationError() }
                if case .burst(let burst) = source {
                    let result = try F5ImagePipeline.render(resources: resources, burst, snapshot: snapshot, progress: progress, isCancelled: { control.isStopped })
                    return try review(result.file, snapshot: result.snapshot, control: control)
                }
                let input: SourceImageFile
                switch source {
                case .file(let file): input = file
                case .memory(let data): input = try SourceImageFile(data: data, fileExtension: "dng")
                case .burst: throw F5Failure(.damagedBundle, "Unexpected burst dispatch.")
                }
                let file = TemporaryHEIFFile(captureDate: input.metadata.captureDate)
                var framing = snapshot.output.framing
                let recipe = try ImagePipeline.writeHEIF(resources: resources, sourceFile: input, recipe: snapshot.recipe,
                    to: file.url, settings: snapshot.output, isCancelled: { control.isStopped }, progress: progress,
                    onSourceDimensions: { width, height in
                        framing?.decodedWidth = width; framing?.decodedHeight = height
                    })
                let output = framing.map { snapshot.output.withFraming($0) } ?? snapshot.output
                return try review(file, snapshot: CaptureSnapshot(recipe: recipe, output: output, quality: snapshot.quality), control: control)
            }.value
        }

        nonisolated static func reloadCapture(_ url: URL, snapshot: CaptureSnapshot,
                                              control: CaptureProcessingControl) async throws -> SavedCapture {
            try await Task.detached(priority: .userInitiated) {
                if control.isStopped { throw CancellationError() }
                let file = TemporaryHEIFFile(captureDate: try PhotoMetadata.read(from: url).captureDate)
                try CaptureJournal.writeProtected(Data(contentsOf: url), to: file.url)
                return try review(file, snapshot: snapshot, control: control)
            }.value
        }

        nonisolated private static func review(_ file: TemporaryHEIFFile, snapshot: CaptureSnapshot,
                                               control: CaptureProcessingControl) throws -> SavedCapture {
            if control.isStopped { throw CancellationError() }
            let data = try Data(contentsOf: file.url)
            let decoded = try ImagePipeline.load(data: data, fileExtension: "heic")
            if control.isStopped { throw CancellationError() }
            guard let container = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw PipelineError.encoding }
            return SavedCapture(file: file, preview: decoded.original, width: width.intValue,
                                height: height.intValue, snapshot: snapshot)
        }
    }

    private struct Job {
        var id: UUID
        var snapshot: CaptureSnapshot
        var source: RetainedCaptureSource?
        var encoded: SavedCapture?
        var record: CaptureJournal.Record?
        var photosConfirmed = false
        var confirmedSaveFailure: String?
        var unsubmittedAttempt: UUID?
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var latest: SavedCapture?
    @Published private(set) var failureMessage: String?
    @Published private(set) var needsPhotosPermission = false
    @Published private(set) var notice: String?
    private let services: Services
    private let journal: CaptureJournal?
    private var job: Job?
    private var task: Task<Void, Never>?
    private var processingControl: CaptureProcessingControl?
    private var foreground: Bool
    private var restored: Bool
    private var restoreFailed = false
    private var authorizedCapture: (id: UUID, takePhoto: (@escaping (Result<CapturedCameraPhoto, Error>) -> Void) -> Void)?

    init(services: Services, journal: CaptureJournal? = nil, initiallyActive: Bool = true) {
        self.services = services; self.journal = journal; foreground = initiallyActive
        restored = journal == nil
        if journal != nil { phase = .restoring; if initiallyActive { restore() } }
    }
    var canCapture: Bool { phase == .idle && restored && foreground }
    var isWorking: Bool {
        switch phase {
        case .idle, .failed, .paused, .saveOutcomeUnknown: return false
        default: return true
        }
    }
    var canRetry: Bool { phase == .failed && (restoreFailed || job?.source != nil || job?.encoded != nil) }
    var pendingCapture: SavedCapture? { job?.encoded }
    var pendingDate: Date? { job?.record?.createdAt }
    var status: String {
        switch phase {
        case .idle: return notice ?? ""
        case .authorizing: return "Checking Photos access…"
        case .capturing: return "Capturing RAW…"
        case .retaining: return "Retaining photo…"
        case .processing: return "Processing HDR · \(Int(progress * 100))%"
        case .saving: return "Saving to Photos…"
        case .restoring: return "Checking retained photo…"
        case .paused: return "Photo paused. Return to GlassCam to finish it."
        case .saveOutcomeUnknown: return "This photo may already be in Photos. A copy is retained here. Check Photos before saving it again."
        case .failed: return failureMessage ?? "Couldn’t finish this photo."
        }
    }

    /// In-flight Photos requests are not cancelled or considered failed merely
    /// because the app leaves the foreground.
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { processingControl?.stop(); return }
        guard task == nil else { return }
        if authorizedCapture != nil { submitAuthorizedCapture(); return }
        if !restored { restore() }
        else if phase == .paused, job != nil { retryPaused() }
    }

    /// Compatibility entry for non-camera sources and the service tests.
    func capture(snapshot: CaptureSnapshot,
                 takePhoto: @escaping (@escaping (Result<Data, Error>) -> Void) -> Void) {
        capturePhoto(snapshot: snapshot) { callback in
            takePhoto { callback($0.map { CapturedCameraPhoto(data: $0, framing: snapshot.output.framing ?? CaptureFraming()) }) }
        }
    }

    func capturePhoto(snapshot: CaptureSnapshot,
                      takePhoto: @escaping (@escaping (Result<CapturedCameraPhoto, Error>) -> Void) -> Void) {
        guard canCapture, snapshot.recipe.isValid else { return }
        let newJob = Job(id: UUID(), snapshot: snapshot)
        job = newJob; phase = .authorizing; progress = 0
        failureMessage = nil; notice = nil; needsPhotosPermission = false
        task = Task {
            do {
                try await services.authorize()
                guard job?.id == newJob.id, phase == .authorizing else { return }
                task = nil; authorizedCapture = (newJob.id, takePhoto)
                if foreground { submitAuthorizedCapture() }
            } catch {
                guard job?.id == newJob.id else { return }
                needsPhotosPermission = !(error is CaptureWorkflowFailure)
                fail(error, id: newJob.id)
            }
        }
    }

    private func submitAuthorizedCapture() {
        guard foreground, let pending = authorizedCapture, job?.id == pending.id, phase == .authorizing else { return }
        authorizedCapture = nil; phase = .capturing
        pending.takePhoto { [self] result in receive(result, id: pending.id) }
    }

    private func receive(_ result: Result<CapturedCameraPhoto, Error>, id: UUID) {
        guard job?.id == id, phase == .capturing else { return }
        switch result {
        case .failure(let error): fail(error, id: id)
        case .success(let photo):
            if let snapshot = job?.snapshot, snapshot.output.cameraMegapixels != nil {
                guard photo.framing.isValid else { fail(CaptureJournal.Failure.damaged, id: id); return }
                job?.snapshot = CaptureSnapshot(recipe: snapshot.recipe, output: snapshot.output.withFraming(photo.framing), quality: snapshot.quality,archiveF5RAW:snapshot.archiveF5RAW)
            }
            job?.source = photo.burst.map { .burst($0) } ?? .memory(photo.data); phase = .retaining
            task = Task {
                do {
                    try await retainSource(id: id)
                    guard job?.id == id else { return }
                    if foreground { await finish(id: id) }
                    else { pause(id: id) }
                } catch {
                    if foreground { fail(error, id: id) }
                    else { pause(id: id) }
                }
            }
        }
    }

    private func retainSource(id: UUID) async throws {
        guard let current = job, current.id == id, let source = current.source else { return }
        if let journal {
            if current.record != nil { return }
            let snapshot = current.snapshot
            if case .burst(let burst) = source {
                let record = try await Task.detached(priority: .userInitiated) {
                    try journal.retainBurst(burst, id: id, snapshot: snapshot)
                }.value
                guard job?.id == id else { return }
                job?.record = record; job?.source = .burst(try F5BurstSource(directory: journal.burstURL))
                return
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let data: Data
                switch source {
                case .memory(let bytes): data = bytes
                case .file(let file): data = try Data(contentsOf: file.url)
                case .burst: throw F5Failure(.damagedBundle, "Unexpected single-photo retention.")
                }
                let record = try journal.retain(data, id: id, snapshot: snapshot)
                let file = try SourceImageFile(retainedURL: journal.rawURL, fileExtension: "dng")
                return (record, file)
            }.value
            guard job?.id == id else { return }
            job?.record = result.0; job?.source = .file(result.1)
        } else if case .memory(let data) = source {
            do { job?.source = .file(try await services.retain(data)) }
            catch { job?.source = .memory(data) }
        }
    }

    func retry() {
        guard canRetry else { return }
        if restoreFailed { restoreFailed = false; restored = false; restore(); return }
        startRetry()
    }
    private func retryPaused() { guard phase == .paused else { return }; startRetry() }
    private func startRetry() {
        guard foreground, task == nil, let id = job?.id else { return }
        phase = .authorizing; failureMessage = nil; needsPhotosPermission = false
        task = Task {
            do {
                if job?.photosConfirmed != true {
                    do { try await services.authorize() }
                    catch { needsPhotosPermission = true; throw error }
                }
                guard job?.id == id else { return }
                if !foreground { pause(id: id); return }
                try await retainSource(id: id)
                await finish(id: id)
            } catch { fail(error, id: id) }
        }
    }

    func discardFailed() {
        guard phase == .failed, task == nil else { return }
        if journal == nil {
            job = nil; authorizedCapture = nil; phase = .idle
            failureMessage = nil; needsPhotosPermission = false; progress = 0
            return
        }
        let id = job?.id
        phase = .retaining
        task = Task {
            do {
                if let journal {
                    if let id, job?.record != nil { try await Task.detached { try journal.clear(id: id) }.value }
                    else { try await Task.detached { try journal.discardUnreadable() }.value }
                }
                job = nil; task = nil; authorizedCapture = nil; phase = .idle; restored = true; restoreFailed = false
                failureMessage = nil; needsPhotosPermission = false; progress = 0
            } catch {
                task = nil; phase = .failed; failureMessage = error.localizedDescription
            }
        }
    }

    func confirmAlreadySaved() {
        guard phase == .saveOutcomeUnknown, let id = job?.id, foreground, task == nil else { return }
        job?.photosConfirmed = true; phase = .saving
        task = Task { await finish(id: id) }
    }

    func saveAgain() {
        guard phase == .saveOutcomeUnknown, let id = job?.id, let journal, foreground, task == nil else { return }
        phase = .retaining
        task = Task {
            do {
                let record = try await Task.detached { try journal.allowAnotherSave(id: id) }.value
                guard job?.id == id else { return }
                job?.record = record; task = nil; phase = .paused
                if foreground { retryPaused() }
            } catch {
                task = nil; phase = .saveOutcomeUnknown; failureMessage = error.localizedDescription
            }
        }
    }

    private func finish(id: UUID) async {
        guard let current = job, current.id == id else { return }
        if !foreground && !current.photosConfirmed { pause(id: id); return }
        do {
            if !current.photosConfirmed {
                if let journal, let attempt = job?.unsubmittedAttempt {
                    let record = try await Task.detached { try journal.cancelUnsubmittedSave(id: id, attemptID: attempt) }.value
                    job?.record = record; job?.unsubmittedAttempt = nil
                }
                let encoded: SavedCapture
                if let existing = current.encoded { encoded = existing }
                else {
                    guard let source = current.source else { throw CaptureJournal.Failure.damaged }
                    phase = .processing; progress = 0
                    let control = CaptureProcessingControl(); processingControl = control
                    let report: @Sendable (Double) -> Void = { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.job?.id == id, self.phase == .processing else { return }
                            self.progress = min(1, max(0, value))
                        }
                    }
                    if let process = services.processWithControl { encoded = try await process(source, current.snapshot, report, control) }
                    else { encoded = try await services.process(source, current.snapshot, report) }
                    processingControl = nil
                    guard job?.id == id else { return }
                    job?.encoded = encoded
                }
                if let journal, job?.record?.stage == .rawReady {
                    let record = try await Task.detached { try journal.storeEncoded(encoded, id: id) }.value
                    guard job?.id == id else { return }
                    job?.record = record
                }
                job?.source = nil // Durable RAW remains until the terminal receipt.
                if !foreground { pause(id: id); return }
                if let journal {
                    if let failure = job?.confirmedSaveFailure, let attempt = job?.record?.attemptID {
                        let record = try await Task.detached { try journal.saveFailed(id: id, attemptID: attempt, message: failure) }.value
                        job?.record = record; job?.confirmedSaveFailure = nil
                    }
                    let attempt = UUID(); job?.unsubmittedAttempt = attempt
                    let record = try await Task.detached { try journal.beginSave(id: id, attemptID: attempt) }.value
                    guard job?.id == id else { return }
                    job?.record = record
                    if !foreground {
                        let reset = try await Task.detached { try journal.cancelUnsubmittedSave(id: id, attemptID: attempt) }.value
                        job?.record = reset; job?.unsubmittedAttempt = nil
                        pause(id: id); return
                    }
                }
                if !foreground { pause(id: id); return }
                job?.unsubmittedAttempt = nil
                phase = .saving
                do { try await services.save(encoded.file) }
                catch {
                    guard job?.id == id else { return }
                    let message = error.localizedDescription
                    job?.confirmedSaveFailure = message
                    if let journal, let attempt = job?.record?.attemptID,
                       let record = try? await Task.detached(operation: { try journal.saveFailed(id: id, attemptID: attempt, message: message) }).value {
                        job?.record = record; job?.confirmedSaveFailure = nil
                    }
                    throw error
                }
                guard job?.id == id else { return }
                job?.photosConfirmed = true
            }
            if let journal {
                let attempt = job?.record?.attemptID
                let record = try await Task.detached { try journal.confirmSaved(id: id, attemptID: attempt) }.value
                job?.record = record
                try await Task.detached { try journal.clear(id: id) }.value
            }
            guard let encoded = job?.encoded else { throw CaptureJournal.Failure.damaged }
            latest = encoded; job = nil; phase = .idle; progress = 1; task = nil
            notice = "Saved HDR · \(encoded.width) × \(encoded.height)"
        } catch is CancellationError {
            processingControl = nil; pause(id: id)
            if foreground { retryPaused() }
        } catch {
            processingControl = nil
            if !foreground { pause(id: id) }
            else { fail(error, id: id) }
        }
    }

    private func restore() {
        guard let journal, foreground, task == nil else { return }
        phase = .restoring; restoreFailed = false
        let control = CaptureProcessingControl(); processingControl = control
        task = Task {
            do {
                guard let record = try await Task.detached(operation: { try journal.load() }).value else {
                    restored = true; phase = .idle; task = nil; processingControl = nil; return
                }
                if record.stage == .savedConfirmed {
                    try await Task.detached { try journal.clear(id: record.id) }.value
                    restored = true; phase = .idle; task = nil; processingControl = nil; return
                }
                if control.isStopped || !foreground { throw CancellationError() }
                var recovered = Job(id: record.id, snapshot: record.snapshot, record: record)
                if record.stage == .rawReady {
                    if record.sourceKind == "f5" {
                        recovered.source = .burst(try await Task.detached { try F5BurstSource(directory: journal.burstURL) }.value)
                    } else {
                        recovered.source = .file(try await Task.detached { try SourceImageFile(retainedURL: journal.rawURL, fileExtension: "dng") }.value)
                    }
                } else {
                    let reload = services.reload ?? Services.reloadCapture
                    recovered.encoded = try await reload(journal.encodedURL, record.snapshot, control)
                }
                if control.isStopped || !foreground { throw CancellationError() }
                job = recovered; restored = true; task = nil; processingControl = nil
                phase = record.stage == .savePending ? .saveOutcomeUnknown : .paused
                if phase == .paused { retryPaused() }
            } catch is CancellationError {
                task = nil; processingControl = nil; phase = .paused
                if foreground { restore() }
            } catch {
                task = nil; processingControl = nil
                if !foreground { phase = .paused }
                else { restoreFailed = true; phase = .failed; failureMessage = error.localizedDescription }
            }
        }
    }

    private func pause(id: UUID) {
        guard job?.id == id else { return }
        task = nil; phase = .paused
        if foreground { retryPaused() }
    }
    private func fail(_ error: Error, id: UUID) {
        guard job?.id == id else { return }
        phase = .failed; task = nil
        failureMessage = job?.photosConfirmed == true
            ? "Saved to Photos. Retry to finish the recovery record: \(error.localizedDescription)"
            : error.localizedDescription
    }
}

private enum CaptureWorkflowFailure: LocalizedError {
    case inactiveCamera
    var errorDescription: String? { "Return to the camera and take the photo again." }
}
