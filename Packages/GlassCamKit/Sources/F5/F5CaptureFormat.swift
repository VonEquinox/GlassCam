import ImagingCore
import Capture
import Foundation

/// F5 owns its on-disk bundle, provenance codec, recovery and rendering.
public struct F5CaptureFormat: CaptureFormat {
    public let identifier = "f5"
    public let schemaVersion = 2
    var stagingRoot: URL? = nil
    var archiveRoot: URL? = nil

    public init(stagingRoot: URL? = nil, archiveRoot: URL? = nil) {
        self.stagingRoot = stagingRoot; self.archiveRoot = archiveRoot
    }

    /// Recording stops at characterized RAW archival. No brand resources,
    /// HEIF encoder, review image or Photos transaction participate.
    public static func archiveRAW(_ source: F5BurstSource, snapshot: CaptureSnapshot,
                                 progress: @escaping @Sendable (Double) -> Void = { _ in },
                                 isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        try F5ImagePipeline.archiveRAW(source,snapshot: snapshot,progress: progress,isCancelled: isCancelled)
    }

    public func decodeProvenance(from decoder: Decoder) throws -> any CaptureProvenance {
        try F5CaptureProvenance(from: decoder)
    }
    public func source(in directory: URL) throws -> any CapturePayload {
        try F5BurstSource(directory: directory.appendingPathComponent("burst", isDirectory: true))
    }
    public func render(resources: ColorResources, _ payload: any CapturePayload, snapshot: CaptureSnapshot,
                progress: @escaping @Sendable (Double) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws -> CaptureRenderResult {
        guard let source = payload as? F5BurstSource else { throw CaptureJournal.Failure.damaged }
        return try F5ImagePipeline.render(resources: resources, source, snapshot: snapshot,
            progress: progress, isCancelled: isCancelled)
    }
    public func retain(_ payload: any CapturePayload, id: UUID, snapshot: CaptureSnapshot,
                directory: URL, recoversStaging: Bool) throws -> CaptureJournal.Record {
        guard let source = payload as? F5BurstSource else { throw CaptureJournal.Failure.damaged }
        let burstURL = directory.appendingPathComponent("burst", isDirectory: true)
        guard snapshot.quality.usesBayer, snapshot.recipe.isValid,
              snapshot.quality.bayerFrameCount == source.manifest.frames.count else { throw CaptureJournal.Failure.damaged }
        _ = try source.manifest.validate(directory: source.directory)
        if try directoryExists(directory) {
            let old = try readRecord(directory)
            guard old.id == id, old.stage == .rawReady, old.sourceKind == "f5" else { throw CaptureJournal.Failure.anotherPhoto }
            try validate(old.raw, at: burstURL.appendingPathComponent("burst.json"))
            _ = try F5BurstSource(directory: burstURL)
            return old
        }
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
        let staging = parent.appendingPathComponent("IncomingF5-\(id.uuidString)", isDirectory: true)
        // This temporary copy belongs to this same transaction and is safe to
        // rebuild. The original F5Staging directory remains durable throughout.
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("burst", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
        do {
            var files = ["burst.json", "intent.json"]
            files += source.manifest.frames.flatMap { [$0.dng.path, $0.mosaic.path] }
            if source.manifest.profile != nil { files.append("profile.json") }
            if let table = source.manifest.profile?.likelihood.table { files.append(table.path) }
            for path in files {
                let input = source.directory.appendingPathComponent(path).resolvingSymlinksInPath()
                guard input.path.hasPrefix(source.directory.resolvingSymlinksInPath().path + "/") else { throw CaptureJournal.Failure.damaged }
                let output = destination.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
                try CaptureJournal.writeProtected(Data(contentsOf: input, options: .mappedIfSafe), to: output)
            }
            _ = try F5BurstSource(directory: destination)
            let bytes = try Data(contentsOf: destination.appendingPathComponent("burst.json"))
            var record = CaptureJournal.Record(id: id, createdAt: source.manifest.createdAt, snapshot: snapshot, stage: .rawReady,
                raw: CaptureJournal.Blob(bytes), sourceKind: "f5")
            record.schemaVersion = 2
            try CaptureJournal.writeProtected(F5Hash.json(record), to: staging.appendingPathComponent("capture.json"))
            try FileManager.default.moveItem(at: staging, to: directory)
            removeDuplicateStaging(source.manifest, enabled: recoversStaging)
            return record
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    private func removeDuplicateStaging(_ manifest: F5BurstManifest, enabled: Bool) {
        guard enabled else { return }
        let original = (stagingRoot ?? F5BurstTransaction.stagingRoot).appendingPathComponent(manifest.id.uuidString)
        guard let source = try? F5BurstSource(directory: original), source.manifest.id == manifest.id,
              (try? F5Hash.json(source.manifest)) == (try? F5Hash.json(manifest)) else { return }
        try? FileManager.default.removeItem(at: original)
    }

    public func validate(_ record: CaptureJournal.Record, directory: URL, recoversStaging: Bool) throws {
        let burstURL = directory.appendingPathComponent("burst", isDirectory: true)
        try validate(record.raw, at: burstURL.appendingPathComponent("burst.json"))
        let source = try F5BurstSource(directory: burstURL)
        guard record.snapshot.quality.bayerFrameCount == source.manifest.frames.count else { throw CaptureJournal.Failure.damaged }
        removeDuplicateStaging(source.manifest, enabled: recoversStaging)
    }
    public func finish(_ record: CaptureJournal.Record, directory: URL) throws {
        if record.stage == .savedConfirmed, record.snapshot.archiveF5RAW {
            try F5ArchiveStore.retain(F5BurstSource(directory: directory.appendingPathComponent("burst", isDirectory: true)),
                captureID: record.id, root: archiveRoot)
        }
    }
    public func recoverPending(directory: URL) throws -> CaptureJournal.Record? {
        guard let (path, intent) = try F5BurstTransaction.pendingProduct(root: stagingRoot), let snapshot = intent.snapshot else { return nil }
        guard intent.state == .committed else {
            throw F5Failure(.frameMissing, "Bayer capture was interrupted after \(intent.frames.count) of \(snapshot.quality.bayerFrameCount ?? 5) frames. Its files were retained; discard this interrupted capture before taking another.")
        }
        return try retain(F5BurstSource(directory: path), id: intent.id, snapshot: snapshot,
            directory: directory, recoversStaging: true)
    }
    public func discardPending() throws {
        if let (path, _) = try F5BurstTransaction.pendingProduct(root: stagingRoot) {
            let retired = path.deletingLastPathComponent().appendingPathComponent("Discarded-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: path, to: retired)
            try? FileManager.default.removeItem(at: retired)
        }
    }
    private func directoryExists(_ directory: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CaptureJournal.Failure.damaged }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    private func readRecord(_ directory: URL) throws -> CaptureJournal.Record {
        let record = try CaptureFormats([self]).decoder().decode(CaptureJournal.Record.self,
            from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
        guard record.schemaVersion == 1 || (record.schemaVersion == schemaVersion && record.sourceKind == identifier) else {
            throw CaptureJournal.Failure.unsupportedVersion
        }
        guard record.snapshot.recipe.isValid, record.snapshot.output.framing?.isValid != false,
              record.raw.bytes > 0, record.raw.sha256.count == 64 else { throw CaptureJournal.Failure.damaged }
        return record
    }
    private func validate(_ blob: CaptureJournal.Blob, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == blob.bytes else { throw CaptureJournal.Failure.damaged }
        guard CaptureJournal.Blob(try Data(contentsOf: url, options: .mappedIfSafe)) == blob else {
            throw CaptureJournal.Failure.damaged
        }
    }
}
