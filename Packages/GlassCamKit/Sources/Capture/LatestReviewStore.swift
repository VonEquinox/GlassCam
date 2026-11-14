import Foundation
import ImagingCore

/// A single confirmed photo. Publishing a pointer after immutable bytes makes
/// replacement recoverable without replacing a file still owned by a share.
public final class LatestReviewStore: @unchecked Sendable {
    private struct Record: Codable {
        var schemaVersion = 1
        let generation: UUID
        let captureID: UUID
        let confirmedAt: Date
        let width: Int
        let height: Int
        let snapshot: CaptureSnapshot
        let photo: CaptureJournal.Blob
    }
    public let directory: URL
    private let formats: CaptureFormats
    private let lock = NSLock()
    private var manifest: URL { directory.appendingPathComponent("latest.json") }

    public init(directory: URL? = nil, formats: CaptureFormats = CaptureFormats()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCam/LatestReview", isDirectory: true)
        self.formats = formats
    }

    public func save(_ capture: SavedCapture) throws {
        lock.lock(); defer { lock.unlock() }
        let confirmedAt = capture.confirmedAt ?? Date()
        if let data = try? Data(contentsOf: manifest),
           let previous = try? formats.decoder().decode(Record.self, from: data),
           previous.confirmedAt > confirmedAt { return }
        let data = try Data(contentsOf: capture.file.url, options: .mappedIfSafe)
        guard !data.isEmpty, capture.width > 0, capture.height > 0, capture.snapshot.recipe.isValid else {
            throw CaptureJournal.Failure.damaged
        }
        try CaptureJournal.createDirectory(directory)
        let record = Record(generation: UUID(), captureID: capture.id, confirmedAt: confirmedAt,
                            width: capture.width, height: capture.height,
                            snapshot: capture.snapshot, photo: CaptureJournal.Blob(data))
        let entry = directory.appendingPathComponent(record.generation.uuidString, isDirectory: true)
        do {
            try CaptureJournal.createDirectory(entry)
            try CaptureJournal.writeProtected(data, to: entry.appendingPathComponent("photo.heic"))
            try CaptureJournal.writeProtected(JSONEncoder().encode(record), to: manifest)
        } catch {
            try? FileManager.default.removeItem(at: entry)
            throw error
        }
        cleanOtherGenerations(keeping: record.generation)
    }

    public func load() throws -> SavedCapture? {
        lock.lock(); defer { lock.unlock() }
        let bytes: Data
        do { bytes = try Data(contentsOf: manifest) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try formats.decoder().decode(Record.self, from: bytes)
        guard record.schemaVersion == 1, record.width > 0, record.height > 0,
              record.snapshot.recipe.isValid, record.photo.bytes > 0 else { throw CaptureJournal.Failure.damaged }
        let url = directory.appendingPathComponent(record.generation.uuidString, isDirectory: true)
            .appendingPathComponent("photo.heic")
        guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == record.photo.bytes else {
            throw CaptureJournal.Failure.damaged
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard CaptureJournal.Blob(data) == record.photo else { throw CaptureJournal.Failure.damaged }
        let file = TemporaryHEIFFile(captureDate: try PhotoMetadata.read(from: url).captureDate)
        try CaptureJournal.writeProtected(data, to: file.url)
        let capture = try CaptureWorkflow.Services.review(file, snapshot: record.snapshot,
            control: CaptureProcessingControl(), id: record.captureID).confirming(at: record.confirmedAt)
        guard capture.width == record.width, capture.height == record.height else { throw CaptureJournal.Failure.damaged }
        cleanOtherGenerations(keeping: record.generation)
        return capture
    }

    private func cleanOtherGenerations(keeping generation: UUID) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in contents {
            guard let id = UUID(uuidString: entry.lastPathComponent), id != generation,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
