import ImagingCore
import Foundation
import Combine
import ImageIO

public struct CaptureSnapshot: Codable, Sendable {
    public let recipe: ProcessingRecipe
    public let output: ExportSettings
    public let quality: CaptureQuality
    public let f5: (any CaptureProvenance)?
    public let archiveF5RAW: Bool
    public let rawArchiveID: UUID?

    public init(recipe: ProcessingRecipe, output: ExportSettings, quality: CaptureQuality = .balanced, f5: (any CaptureProvenance)? = nil, archiveF5RAW: Bool = false, rawArchiveID: UUID? = nil) {
        self.recipe = recipe
        self.output = .camera24(framing: output.framing)
        self.quality = quality; self.f5 = f5; self.archiveF5RAW = archiveF5RAW; self.rawArchiveID = rawArchiveID
    }
    private enum CodingKeys: String, CodingKey { case recipe, output, quality, f5, archiveF5RAW, rawArchiveID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try values.decode(ProcessingRecipe.self, forKey: .recipe)
        let savedOutput = try values.decode(ExportSettings.self, forKey: .output)
        output = .camera24(framing: savedOutput.framing)
        quality = try values.decodeIfPresent(CaptureQuality.self, forKey: .quality) ?? .balanced
        if values.contains(.f5), try !values.decodeNil(forKey: .f5) {
            let formats = decoder.userInfo[CaptureFormats.decoderKey] as? CaptureFormats ?? CaptureFormats()
            let format = try formats.requireFormat(identifier: "f5")
            f5 = try format.decodeProvenance(from: values.superDecoder(forKey: .f5))
        } else { f5 = nil }
        archiveF5RAW = try values.decodeIfPresent(Bool.self, forKey: .archiveF5RAW) ?? false
        rawArchiveID = try values.decodeIfPresent(UUID.self, forKey: .rawArchiveID)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recipe, forKey: .recipe)
        try values.encode(output, forKey: .output)
        try values.encode(quality, forKey: .quality)
        if let f5 { try f5.encode(to: values.superEncoder(forKey: .f5)) }
        try values.encode(archiveF5RAW, forKey: .archiveF5RAW)
        try values.encodeIfPresent(rawArchiveID, forKey: .rawArchiveID)
    }
}

public struct SavedCapture: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let file: TemporaryHEIFFile
    public let preview: PreviewRaster
    public let width: Int
    public let height: Int
    public let snapshot: CaptureSnapshot
    public func loadFullPreview() async throws -> PreviewRaster {
        let current = preview
        let url = file.url
        guard max(current.width, current.height) < 512,
              FileManager.default.fileExists(atPath: url.path) else {
            return current
        }
        return try await Task.detached(priority: .userInitiated) {
            try ImagePipeline.decodePreviewRaster(at: url, maximumEdge: 2048).raster
        }.value
    }
    public var resolutionDescription: String? {
        if let f5 = snapshot.f5 {
            return f5.resolutionDescription(width: width, height: height)
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
    case burst(any CapturePayload)
}

/// Root-owned single-photo workflow. A Photos receipt or an explicit user
/// decision releases a recoverable photo after a process restart.
@MainActor
public final class CaptureWorkflow: ObservableObject {
    public enum Phase: Equatable {
        case idle, authorizing, capturing, retaining, processing, saving, failed
        case restoring, paused, saveOutcomeUnknown
    }
    public struct Services {
        var authorize: @MainActor () async throws -> Void
        var retain: @Sendable (Data) async throws -> SourceImageFile
        var process: @Sendable (RetainedCaptureSource, CaptureSnapshot, @escaping @Sendable (Double) -> Void) async throws -> SavedCapture
        var save: @MainActor (TemporaryHEIFFile) async throws -> Void
        var processWithControl: (@Sendable (RetainedCaptureSource, CaptureSnapshot, @escaping @Sendable (Double) -> Void,
                                           CaptureProcessingControl) async throws -> SavedCapture)? = nil
        var reload: (@Sendable (URL, CaptureSnapshot, CaptureProcessingControl) async throws -> SavedCapture)? = nil

        public static func live(resources: ColorResources, formats: CaptureFormats = CaptureFormats(), authorize: @escaping @MainActor () async throws -> Void,
                         save: @escaping @MainActor (TemporaryHEIFFile) async throws -> Void) -> Services {
            Services(authorize: authorize, retain: { data in
                try await Task.detached(priority: .userInitiated) {
                    try SourceImageFile(data: data, fileExtension: "dng")
                }.value
            }, process: { source, snapshot, progress in
                try await processCapture(resources: resources, formats: formats, source, snapshot: snapshot, progress: progress, control: CaptureProcessingControl())
            }, save: save, processWithControl: { source, snapshot, progress, control in
                try await processCapture(resources: resources, formats: formats, source, snapshot: snapshot, progress: progress, control: control)
            }, reload: { url, snapshot, control in
                try await reloadCapture(url, snapshot: snapshot, control: control)
            })
        }

        nonisolated private static func processCapture(resources: ColorResources, formats: CaptureFormats, _ source: RetainedCaptureSource, snapshot: CaptureSnapshot,
            progress: @escaping @Sendable (Double) -> Void, control: CaptureProcessingControl) async throws -> SavedCapture {
            try await Task.detached(priority: .userInitiated) {
                if control.isStopped { throw CancellationError() }
                if case .burst(let burst) = source {
                    let format = try formats.requireFormat(identifier: burst.formatIdentifier)
                    let result = try format.render(resources: resources, burst, snapshot: snapshot, progress: progress, isCancelled: { control.isStopped })
                    return try review(result.file, snapshot: result.snapshot, control: control)
                }
                let input: SourceImageFile
                switch source {
                case .file(let file): input = file
                case .memory(let data): input = try SourceImageFile(data: data, fileExtension: "dng")
                case .burst(let payload): throw CaptureSourceFailure(source: payload, detail: "Unexpected burst dispatch.")
                }
                let file = TemporaryHEIFFile(captureDate: input.metadata.captureDate)
                var framing = snapshot.output.framing
                let recipe = try ImagePipeline.writeHEIF(resources: resources, sourceFile: input, recipe: snapshot.recipe,
                    to: file.url, settings: snapshot.output, isCancelled: { control.isStopped }, progress: progress,
                    onSourceDimensions: { width, height in
                        framing?.decodedWidth = width; framing?.decodedHeight = height
                    })
                let output = framing.map { snapshot.output.withFraming($0) } ?? snapshot.output
                return try review(file, snapshot: CaptureSnapshot(recipe: recipe, output: output, quality: snapshot.quality, archiveF5RAW: snapshot.archiveF5RAW, rawArchiveID: snapshot.rawArchiveID), control: control)
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
            let decoded = try ImagePipeline.decodePreviewRaster(at: file.url, maximumEdge: 160)
            if control.isStopped { throw CancellationError() }
            return SavedCapture(file: file, preview: decoded.raster, width: decoded.pixelWidth,
                                height: decoded.pixelHeight, snapshot: snapshot)
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
        var captureSubmitted = false
    }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progress = 0.0
    @Published public private(set) var latest: SavedCapture?
    @Published public private(set) var failureMessage: String?
    @Published public private(set) var needsPhotosPermission = false
    @Published public private(set) var notice: String?
    private let services: Services
    private let journal: CaptureJournal?
    private var job: Job?
    private var task: Task<Void, Never>?
    private var processingControl: CaptureProcessingControl?
    private var foreground: Bool
    private var restored: Bool
    private var restoreFailed = false
    private var authorizedCapture: (id: UUID, takePhoto: (@escaping (Result<CapturedCameraPhoto, Error>) -> Void) -> Void)?

    public init(services: Services, journal: CaptureJournal? = nil, initiallyActive: Bool = true) {
        self.services = services; self.journal = journal; foreground = initiallyActive
        restored = journal == nil
        if journal != nil { phase = .restoring; if initiallyActive { restore() } }
    }
    public var canCapture: Bool { phase == .idle && restored && foreground }
    public var isWorking: Bool {
        switch phase {
        case .idle, .failed, .paused, .saveOutcomeUnknown: return false
        default: return true
        }
    }
    public var canRetry: Bool { phase == .failed && (restoreFailed || job?.source != nil || job?.encoded != nil) }
    public var requiresDiscardConfirmation: Bool {
        phase == .failed && (restoreFailed || job?.captureSubmitted == true || job?.source != nil || job?.encoded != nil)
    }
    public var pendingCapture: SavedCapture? { job?.encoded }
    public var pendingDate: Date? { job?.record?.createdAt }
    public var status: String {
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
    public func setForeground(_ active: Bool) {
        foreground = active
        if !active { processingControl?.stop(); return }
        guard task == nil else { return }
        if authorizedCapture != nil { submitAuthorizedCapture(); return }
        if !restored { restore() }
        else if phase == .paused, job != nil { retryPaused() }
    }

    /// Compatibility entry for non-camera sources and the service tests.
    public func capture(snapshot: CaptureSnapshot,
                 takePhoto: @escaping (@escaping (Result<Data, Error>) -> Void) -> Void) {
        capturePhoto(snapshot: snapshot) { callback in
            takePhoto { callback($0.map { CapturedCameraPhoto(data: $0, framing: snapshot.output.framing ?? CaptureFraming()) }) }
        }
    }

    public func capturePhoto(snapshot: CaptureSnapshot,
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
        authorizedCapture = nil; job?.captureSubmitted = true; phase = .capturing
        pending.takePhoto { [self] result in receive(result, id: pending.id) }
    }

    private func receive(_ result: Result<CapturedCameraPhoto, Error>, id: UUID) {
        guard job?.id == id, phase == .capturing else { return }
        switch result {
        case .failure(let error): fail(error, id: id)
        case .success(let photo):
            if let snapshot = job?.snapshot, photo.framing != CaptureFraming() {
                guard photo.framing.isValid else { fail(CaptureJournal.Failure.damaged, id: id); return }
                job?.snapshot = CaptureSnapshot(recipe: snapshot.recipe, output: snapshot.output.withFraming(photo.framing), quality: snapshot.quality,archiveF5RAW:snapshot.archiveF5RAW,rawArchiveID:snapshot.rawArchiveID)
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
                let retained = try await Task.detached(priority: .userInitiated) {
                    try journal.retainBurst(burst, id: id, snapshot: snapshot)
                }.value
                guard job?.id == id else { return }
                job?.record = retained.record; job?.source = .burst(retained.payload)
                return
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let data: Data
                switch source {
                case .memory(let bytes): data = bytes
                case .file(let file): data = try Data(contentsOf: file.url)
                case .burst(let payload): throw CaptureSourceFailure(source: payload, detail: "Unexpected single-photo retention.")
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

    public func retry() {
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

    public func discardFailed() {
        guard phase == .failed, task == nil else { return }
        if journal == nil {
            job = nil; authorizedCapture = nil; phase = .idle
            failureMessage = nil; needsPhotosPermission = false; progress = 0
            return
        }
        phase = .retaining
        task = Task {
            do {
                if let journal {
                    try await Task.detached { try journal.discard() }.value
                }
                job = nil; task = nil; authorizedCapture = nil; phase = .idle; restored = true; restoreFailed = false
                failureMessage = nil; needsPhotosPermission = false; progress = 0
            } catch {
                task = nil; phase = .failed; failureMessage = error.localizedDescription
            }
        }
    }

    public func confirmAlreadySaved() {
        guard phase == .saveOutcomeUnknown, let id = job?.id, foreground, task == nil else { return }
        job?.photosConfirmed = true; phase = .saving
        task = Task { await finish(id: id) }
    }

    public func saveAgain() {
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
                            let clamped = min(1, max(0, value))
                            if clamped == 0 || clamped == 1 || Int(clamped * 100) != Int(self.progress * 100) {
                                self.progress = clamped
                            }
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
                try await Task.detached { try journal.finishSaved(id: id) }.value
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
                guard let retained = try await Task.detached(operation: { try journal.load() }).value else {
                    restored = true; phase = .idle; task = nil; processingControl = nil; return
                }
                let record = retained.record
                if record.stage == .savedConfirmed {
                    try await Task.detached { try journal.finishSaved(id: record.id) }.value
                    restored = true; phase = .idle; task = nil; processingControl = nil; return
                }
                if control.isStopped || !foreground { throw CancellationError() }
                var recovered = Job(id: record.id, snapshot: record.snapshot, record: record)
                if record.stage == .rawReady {
                    if let payload = retained.payload {
                        recovered.source = .burst(payload)
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
