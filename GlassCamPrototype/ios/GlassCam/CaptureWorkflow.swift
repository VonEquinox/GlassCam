import Foundation
import Combine
import ImageIO

struct CaptureSnapshot: Sendable {
    let recipe: ProcessingRecipe
    let output: ExportSettings
}

struct SavedCapture: Identifiable, @unchecked Sendable {
    let id = UUID()
    let file: TemporaryHEIFFile
    let preview: PreviewRaster
    let width: Int
    let height: Int
    let snapshot: CaptureSnapshot
}

enum RetainedCaptureSource: @unchecked Sendable {
    case file(SourceImageFile)
    case memory(Data) // At most one committed DNG if disk retention fails.
}

/// Owns a shot through camera callbacks, processing, Photos, and retry. Neither
/// settings edits nor view/scene lifetimes can retarget or release a committed shot.
@MainActor
final class CaptureWorkflow: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, capturing, retaining, processing, saving, failed
    }
    struct Services {
        var authorize: @MainActor () async throws -> Void
        var retain: @Sendable (Data) async throws -> SourceImageFile
        var process: @Sendable (RetainedCaptureSource, CaptureSnapshot, @escaping @Sendable (Double) -> Void) async throws -> SavedCapture
        var save: @MainActor (TemporaryHEIFFile) async throws -> Void

        static func live(authorize: @escaping @MainActor () async throws -> Void,
                         save: @escaping @MainActor (TemporaryHEIFFile) async throws -> Void) -> Services {
            Services(authorize: authorize, retain: { data in
                try await Task.detached(priority: .userInitiated) {
                    try SourceImageFile(data: data, fileExtension: "dng")
                }.value
            }, process: { source, snapshot, progress in
                try await Task.detached(priority: .userInitiated) {
                    let input: SourceImageFile
                    switch source {
                    case .file(let file): input = file
                    case .memory(let data): input = try SourceImageFile(data: data, fileExtension: "dng")
                    }
                    let file = TemporaryHEIFFile()
                    let recipe = try ImagePipeline.writeHEIF(sourceFile: input, recipe: snapshot.recipe,
                        to: file.url, settings: snapshot.output, progress: progress)
                    // Review the finalized HEIF, including full-source spatial effects.
                    let data = try Data(contentsOf: file.url)
                    let review = try ImagePipeline.load(data: data, fileExtension: "heic")
                    guard let container = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
                          let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw PipelineError.encoding }
                    return SavedCapture(file: file, preview: review.original, width: width.intValue,
                                        height: height.intValue, snapshot: CaptureSnapshot(recipe: recipe, output: snapshot.output))
                }.value
            }, save: save)
        }
    }
    private struct Job {
        let id = UUID()
        let snapshot: CaptureSnapshot
        var source: RetainedCaptureSource?
        var encoded: SavedCapture?
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var latest: SavedCapture?
    @Published private(set) var failureMessage: String?
    @Published private(set) var needsPhotosPermission = false
    @Published private(set) var notice: String?
    private let services: Services
    private var job: Job?
    private var task: Task<Void, Never>?

    init(services: Services) { self.services = services }
    var canCapture: Bool { phase == .idle }
    var isWorking: Bool { phase != .idle && phase != .failed }
    var canRetry: Bool { phase == .failed && (job?.source != nil || job?.encoded != nil) }
    var status: String {
        switch phase {
        case .idle: return notice ?? ""
        case .authorizing: return "Checking Photos access…"
        case .capturing: return "Capturing RAW…"
        case .retaining: return "Retaining photo…"
        case .processing: return "Processing HDR · \(Int(progress * 100))%"
        case .saving: return "Saving to Photos…"
        case .failed: return failureMessage ?? "Couldn’t finish this photo."
        }
    }

    func capture(snapshot: CaptureSnapshot,
                 takePhoto: @escaping (@escaping (Result<Data, Error>) -> Void) -> Void) {
        guard canCapture, snapshot.recipe.isValid else { return }
        let newJob = Job(snapshot: snapshot)
        job = newJob; phase = .authorizing; progress = 0
        failureMessage = nil; notice = nil; needsPhotosPermission = false
        task = Task {
            do {
                try await services.authorize()
                guard job?.id == newJob.id, phase == .authorizing else { return }
                phase = .capturing
                takePhoto { [self] result in receive(result, id: newJob.id) }
            } catch {
                guard job?.id == newJob.id else { return }
                needsPhotosPermission = true
                fail(error, id: newJob.id)
            }
        }
    }

    private func receive(_ result: Result<Data, Error>, id: UUID) {
        // Terminal duplicate/late callbacks may not replace or fail a newer shot.
        guard job?.id == id, phase == .capturing else { return }
        switch result {
        case .failure(let error): fail(error, id: id)
        case .success(let data):
            phase = .retaining
            task = Task {
                let source: RetainedCaptureSource
                do { source = .file(try await services.retain(data)) }
                catch { source = .memory(data) }
                guard job?.id == id else { return }
                job?.source = source
                await finish(id: id)
            }
        }
    }

    func retry() {
        guard canRetry, let id = job?.id else { return }
        phase = .authorizing; failureMessage = nil; needsPhotosPermission = false
        task = Task {
            do { try await services.authorize() }
            catch {
                needsPhotosPermission = true; fail(error, id: id); return
            }
            guard job?.id == id else { return }
            await finish(id: id)
        }
    }

    func discardFailed() {
        guard phase == .failed else { return }
        job = nil; task = nil; phase = .idle
        failureMessage = nil; needsPhotosPermission = false; progress = 0
    }

    private func finish(id: UUID) async {
        guard let current = job, current.id == id else { return }
        do {
            let encoded: SavedCapture
            if let existing = current.encoded { encoded = existing }
            else {
                guard let source = current.source else { return }
                phase = .processing; progress = 0
                encoded = try await services.process(source, current.snapshot) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.job?.id == id, self.phase == .processing else { return }
                        self.progress = min(1, max(0, value))
                    }
                }
                guard job?.id == id else { return }
                job?.encoded = encoded
                job?.source = nil // A verified HEIF now owns the recoverable photo.
            }
            phase = .saving
            // No cancellation/discard while the Photos transaction is in flight.
            try await services.save(encoded.file)
            guard job?.id == id else { return }
            latest = encoded; job = nil; phase = .idle; progress = 1
            notice = "Saved HDR · \(encoded.width) × \(encoded.height)"
            task = nil
        } catch { fail(error, id: id) }
    }

    private func fail(_ error: Error, id: UUID) {
        guard job?.id == id else { return }
        phase = .failed; failureMessage = error.localizedDescription; task = nil
    }
}
