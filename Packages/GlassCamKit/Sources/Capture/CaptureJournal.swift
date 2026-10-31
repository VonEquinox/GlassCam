import ImagingCore
import Foundation
import CryptoKit

/// One crash-recoverable photo. File IO is serialized and called off the UI
/// thread. The journal never treats a Photos placeholder as a saved receipt.
public final class CaptureJournal: @unchecked Sendable {
    public enum Stage: String, Codable, Sendable { case rawReady, encodedReady, savePending, savedConfirmed }
    public enum Operation: String, Sendable { case retain, encode, beginSave, failSave, confirmSave, clear, load }
    public struct Blob: Codable, Equatable, Sendable {
        public let bytes: Int
        package let sha256: String
        package init(sha256: String, bytes: Int) { self.sha256 = sha256; self.bytes = bytes }
        public init(_ data: Data) {
            bytes = data.count
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    public struct Record: Codable, Sendable {
        public init(schemaVersion: Int = 1, id: UUID, createdAt: Date, snapshot: CaptureSnapshot,
                     stage: Stage, raw: Blob, sourceKind: String? = nil, encoded: Blob? = nil,
                     width: Int? = nil, height: Int? = nil, attemptID: UUID? = nil, lastError: String? = nil) {
            self.schemaVersion = schemaVersion; self.id = id; self.createdAt = createdAt
            self.snapshot = snapshot; self.stage = stage; self.raw = raw; self.sourceKind = sourceKind
            self.encoded = encoded; self.width = width; self.height = height
            self.attemptID = attemptID; self.lastError = lastError
        }
        package var schemaVersion = 1
        public var id: UUID
        package var createdAt: Date
        public var snapshot: CaptureSnapshot
        public var stage: Stage
        public var raw: Blob
        package var sourceKind: String?
        public var encoded: Blob?
        public var width: Int?
        public var height: Int?
        var attemptID: UUID?
        var lastError: String?
    }
    package enum Failure: LocalizedError {
        case anotherPhoto, damaged, unsupportedVersion, staleAttempt
        package var errorDescription: String? {
            switch self {
            case .anotherPhoto: return "Finish the retained photo before taking another one."
            case .damaged: return "The retained photo could not be verified. Its files have been kept."
            case .unsupportedVersion: return "This retained photo uses an unsupported recovery format. Its files have been kept."
            case .staleAttempt: return "The photo's saved state changed. Reopen it before retrying."
            }
        }
    }

    public let directory: URL
    var rawURL: URL { directory.appendingPathComponent("source.dng") }
    var encodedURL: URL { directory.appendingPathComponent("result.heic") }
    private var manifestURL: URL { directory.appendingPathComponent("capture.json") }
    private let lock = NSLock()
    private let beforeOperation: (@Sendable (Operation) throws -> Void)?
    private let afterOperation: (@Sendable (Operation) throws -> Void)?
    private let recoversStaging: Bool
    private let formats: CaptureFormats

    public init(directory: URL? = nil, formats: CaptureFormats = CaptureFormats(), recoverStagedCaptures: Bool? = nil, beforeOperation: (@Sendable (Operation) throws -> Void)? = nil,
         afterOperation: (@Sendable (Operation) throws -> Void)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCam/PendingCapture", isDirectory: true)
        self.beforeOperation = beforeOperation
        self.afterOperation = afterOperation
        recoversStaging = recoverStagedCaptures ?? (directory == nil)
        self.formats = formats
    }

    func retainBurst(_ source: any CapturePayload, id: UUID, snapshot: CaptureSnapshot) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.retain)
        let format = try formats.requireFormat(identifier: source.formatIdentifier)
        let record = try format.retain(source, id: id, snapshot: snapshot,
            directory: directory, recoversStaging: recoversStaging)
        try afterOperation?(.retain)
        return record
    }
    func hasPayload(for record: Record) -> Bool { formats.format(identifier: record.sourceKind) != nil }
    func retainedPayload(for record: Record) throws -> any CapturePayload {
        guard let kind = record.sourceKind else { throw Failure.damaged }
        return try formats.requireFormat(identifier: kind).source(in: directory)
    }

    public func retain(_ data: Data, id: UUID, snapshot: CaptureSnapshot) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.retain)
        guard !data.isEmpty, snapshot.recipe.isValid, snapshot.output.framing?.isValid != false else { throw Failure.damaged }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let old = try readRecord()
            guard old.id == id, old.stage == .rawReady else { throw Failure.anotherPhoto }
            try validate(old.raw, at: rawURL)
            return old
        }
        try makeDirectory()
        let record = Record(id: id, createdAt: Date(), snapshot: snapshot, stage: .rawReady, raw: Blob(data))
        try Self.writeProtected(data, to: rawURL)
        try writeRecord(record)
        try afterOperation?(.retain)
        return record
    }

    func storeEncoded(_ capture: SavedCapture, id: UUID) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.encode)
        var record = try matching(id)
        guard record.stage == .rawReady || record.stage == .encodedReady else { throw Failure.staleAttempt }
        let data = try Data(contentsOf: capture.file.url)
        guard !data.isEmpty, capture.width > 0, capture.height > 0 else { throw Failure.damaged }
        try Self.writeProtected(data, to: encodedURL)
        record.encoded = Blob(data); record.width = capture.width; record.height = capture.height
        record.snapshot = capture.snapshot; record.stage = .encodedReady
        try writeRecord(record)
        try afterOperation?(.encode)
        return record
    }

    func beginSave(id: UUID, attemptID: UUID = UUID()) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.beginSave)
        var record = try matching(id)
        guard record.stage == .encodedReady, record.encoded != nil else { throw Failure.staleAttempt }
        record.stage = .savePending; record.attemptID = attemptID; record.lastError = nil
        try writeRecord(record)
        try afterOperation?(.beginSave)
        return record
    }

    public func saveFailed(id: UUID, attemptID: UUID?, message: String) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.failSave)
        var record = try matching(id)
        guard record.attemptID == attemptID else { throw Failure.staleAttempt }
        if record.stage == .encodedReady { return record }
        guard record.stage == .savePending else { throw Failure.staleAttempt }
        record.stage = .encodedReady; record.lastError = message
        try writeRecord(record)
        try afterOperation?(.failSave)
        return record
    }

    /// The caller proves it never invoked Photos for this attempt. This cannot
    /// be used to resolve an unknown attempt recovered from another process.
    func cancelUnsubmittedSave(id: UUID, attemptID: UUID) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        var record = try matching(id)
        if record.stage == .encodedReady { return record }
        guard record.stage == .savePending, record.attemptID == attemptID else { throw Failure.staleAttempt }
        record.stage = .encodedReady
        try writeRecord(record)
        return record
    }

    func confirmSaved(id: UUID, attemptID: UUID?) throws -> Record? {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.confirmSave)
        guard try directoryExists() else { return nil }
        var record = try matching(id)
        guard (record.stage == .savePending || record.stage == .savedConfirmed),
              record.attemptID == attemptID else { throw Failure.staleAttempt }
        record.stage = .savedConfirmed; record.lastError = nil
        try writeRecord(record)
        try afterOperation?(.confirmSave)
        return record
    }

    /// Only an explicit user decision may turn an unknown attempt into a retry.
    func allowAnotherSave(id: UUID) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        var record = try matching(id)
        guard record.stage == .savePending else { throw Failure.staleAttempt }
        record.stage = .encodedReady
        try writeRecord(record)
        return record
    }

    public func load() throws -> Record? {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.load)
        cleanRetiredDirectories()
        if try !directoryExists() {
            if recoversStaging {
                for format in formats.formats {
                    if let record = try format.recoverPending(directory: directory) { return record }
                }
            }
            return nil
        }
        let record = try readRecord()
        if record.stage == .savedConfirmed { return record }
        if let format = formats.format(identifier: record.sourceKind) {
            try format.validate(record, directory: directory, recoversStaging: recoversStaging)
        } else { try validate(record.raw, at: rawURL) }
        if record.stage != .rawReady {
            guard let encoded = record.encoded, let width = record.width, let height = record.height,
                  width > 0, height > 0 else { throw Failure.damaged }
            try validate(encoded, at: encodedURL)
        }
        return record
    }

    public func clear(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.clear)
        guard try directoryExists() else { return }
        let record = try matching(id)
        try formats.format(identifier: record.sourceKind)?.finish(record, directory: directory)
        try retireDirectory()
        try afterOperation?(.clear)
    }

    /// Called only after the user confirms discarding unreadable retained data.
    func discardUnreadable() throws {
        lock.lock(); defer { lock.unlock() }
        try beforeOperation?(.clear)
        guard try directoryExists() else {
            if recoversStaging {
                for format in formats.formats { try format.discardPending() }
            }
            return
        }
        try retireDirectory()
    }

    private func retireDirectory() throws {
        // Rename before recursive cleanup so an interrupted deletion cannot
        // leave a half-deleted active recovery record.
        let retired = directory.deletingLastPathComponent().appendingPathComponent("FinishedCapture-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: directory, to: retired)
        try? FileManager.default.removeItem(at: retired)
    }

    private func directoryExists() throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.damaged }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func cleanRetiredDirectories() {
        let parent = directory.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("FinishedCapture-") {
            let suffix = String(url.lastPathComponent.dropFirst("FinishedCapture-".count))
            guard UUID(uuidString: suffix) != nil,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func matching(_ id: UUID) throws -> Record {
        let record = try readRecord()
        guard record.id == id else { throw Failure.anotherPhoto }
        return record
    }
    private func readRecord() throws -> Record {
        let record = try formats.decoder().decode(Record.self, from: Data(contentsOf: manifestURL))
        guard record.schemaVersion == 1 || formats.format(identifier: record.sourceKind)?.schemaVersion == record.schemaVersion else { throw Failure.unsupportedVersion }
        guard record.snapshot.recipe.isValid, record.snapshot.output.framing?.isValid != false,
              record.raw.bytes > 0, record.raw.sha256.count == 64 else { throw Failure.damaged }
        return record
    }
    private func writeRecord(_ record: Record) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try Self.writeProtected(encoder.encode(record), to: manifestURL)
    }
    private func validate(_ blob: Blob, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == blob.bytes else { throw Failure.damaged }
        guard Blob(try Data(contentsOf: url, options: .mappedIfSafe)) == blob else { throw Failure.damaged }
    }
    private func makeDirectory() throws {
#if os(macOS)
        let attributes: [FileAttributeKey: Any]? = nil
#else
        let attributes: [FileAttributeKey: Any]? = [.protectionKey: FileProtectionType.complete]
#endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var location = directory; try location.setResourceValues(values)
    }
    package static func writeProtected(_ data: Data, to url: URL) throws {
#if os(macOS)
        try data.write(to: url, options: [.atomic])
#else
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
