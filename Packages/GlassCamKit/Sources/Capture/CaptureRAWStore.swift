import Foundation
import ImagingCore
import CryptoKit

/// Durable Balanced files before a photo enters any selected color style.
public enum CaptureRAWStore {
    public static var root: URL {
        FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("RAWCaptures",isDirectory: true)
    }
    public static var archivedRoots: [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ["RAWCaptures", "F5Archives", "F5Samples"].map {
            documents.appendingPathComponent($0, isDirectory: true)
        }
    }
    public static func directory(id: UUID) -> URL { root.appendingPathComponent(id.uuidString,isDirectory: true) }

    public struct StorageUsage: Equatable, Sendable {
        public let setCount: Int
        public let bytes: Int64
        public init(setCount: Int = 0, bytes: Int64 = 0) {
            self.setCount = setCount
            self.bytes = bytes
        }
        public var isEmpty: Bool { setCount == 0 && bytes == 0 }
    }

    public static func storageUsage(roots: [URL] = archivedRoots) -> StorageUsage {
        let fm = FileManager.default
        var setCount = 0
        var totalBytes: Int64 = 0
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true,
                   !item.lastPathComponent.hasPrefix("Incoming-"),
                   !item.lastPathComponent.hasPrefix("Writing-"),
                   !item.lastPathComponent.hasPrefix("Removing-") {
                    setCount += 1
                }
                totalBytes += regularFileBytes(at: item)
            }
        }
        return StorageUsage(setCount: setCount, bytes: totalBytes)
    }

    public static func clearArchives(roots: [URL] = archivedRoots) throws {
        let fm = FileManager.default
        for root in roots where fm.fileExists(atPath: root.path) {
            let parent = root.deletingLastPathComponent()
            let retired = parent.appendingPathComponent("Removing-\(root.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: root, to: retired)
            try fm.removeItem(at: retired)
        }
    }

    private static func regularFileBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isSymbolicLink != true else { return 0 }
        if values?.isRegularFile == true { return Int64(values?.fileSize ?? 0) }
        guard values?.isDirectory == true,
              let enumerator = fm.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let props = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if props?.isSymbolicLink != true, props?.isRegularFile == true {
                total += Int64(props?.fileSize ?? 0)
            }
        }
        return total
    }

    package struct Entry: Codable {
        let revision: Int, id: UUID, quality: CaptureQuality, sourceIdentity: String
        let files: [String: CaptureJournal.Blob]
    }

    package static func retain(id: UUID, quality: CaptureQuality, sourceIdentity: String, root: URL? = nil,
                               write: (URL) throws -> Void) throws -> URL {
        guard quality == .balanced, !sourceIdentity.isEmpty else { throw CaptureJournal.Failure.damaged }
        let scene = (root ?? Self.root).appendingPathComponent(id.uuidString,isDirectory: true)
        let target = scene.appendingPathComponent(quality.rawValue,isDirectory: true)
        let manifest = target.appendingPathComponent("archive.json")
        if FileManager.default.fileExists(atPath: target.path) {
            let entry = try JSONDecoder().decode(Entry.self,from: Data(contentsOf: manifest))
            guard entry.revision == 1, entry.id == id, entry.quality == quality, entry.sourceIdentity == sourceIdentity else {
                throw CaptureJournal.Failure.anotherPhoto
            }
            for (name,blob) in entry.files {
                guard name == URL(fileURLWithPath: name).lastPathComponent else { throw CaptureJournal.Failure.damaged }
                let file = target.appendingPathComponent(name)
                guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == blob.bytes,
                      try digest(file) == blob.sha256 else { throw CaptureJournal.Failure.damaged }
            }
            return target
        }
        try FileManager.default.createDirectory(at: scene,withIntermediateDirectories: true,attributes: ImageFileProtection.attributes)
        let temporary = scene.appendingPathComponent("Incoming-\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: temporary,withIntermediateDirectories: true,attributes: ImageFileProtection.attributes)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(temporary)
        var files = [String:CaptureJournal.Blob]()
        for file in try FileManager.default.contentsOfDirectory(at: temporary,includingPropertiesForKeys: [.isRegularFileKey,.fileSizeKey]) {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey])
            guard properties.isRegularFile == true, file.lastPathComponent != "archive.json" else { throw CaptureJournal.Failure.damaged }
            files[file.lastPathComponent] = .init(sha256: try digest(file),bytes: properties.fileSize ?? 0)
        }
        guard !files.isEmpty else { throw CaptureJournal.Failure.damaged }
        let entry = Entry(revision: 1,id: id,quality: quality,sourceIdentity: sourceIdentity,files: files)
        try CaptureJournal.writeProtected(JSONEncoder().encode(entry),to: temporary.appendingPathComponent("archive.json"))
        try FileManager.default.moveItem(at: temporary,to: target)
        return target
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x",$0) }.joined()
    }
}
