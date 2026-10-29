@testable import F5
@testable import Capture
@testable import ImagingCore
import Foundation

extension JournalFixtures {
    static func generate(at destination: URL, work: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera(48))
        let raw = Data("GlassCam single RAW fixture\n".utf8)
        let single = CaptureJournal(directory: work.appendingPathComponent("single-photo"))
        var record = try single.retain(raw, id: captureID, snapshot: snapshot)
        record.createdAt = createdAt
        try encode(record).write(to: single.directory.appendingPathComponent("capture.json"))
        try manager.copyItem(at: single.directory, to: destination.appendingPathComponent("single-photo"))

        let speed = CaptureJournal(directory: work.appendingPathComponent("speed-legacy"))
        var old = try speed.retain(raw, id: captureID,
            snapshot: CaptureSnapshot(recipe: .standard, output: .camera(12), quality: .speed))
        old.createdAt = createdAt
        var document = try JSONSerialization.jsonObject(with: encode(old)) as! [String: Any]
        var oldSnapshot = document["snapshot"] as! [String: Any]
        oldSnapshot.removeValue(forKey: "archiveF5RAW")
        document["snapshot"] = oldSnapshot
        let legacy = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try legacy.write(to: speed.directory.appendingPathComponent("capture.json"))
        try manager.copyItem(at: speed.directory, to: destination.appendingPathComponent("speed-legacy"))
        let normalized = try JSONDecoder().decode(CaptureJournal.Record.self, from: legacy)
        try encode(normalized).write(to: destination.appendingPathComponent("speed-normalized.json"))

        let fixture = try F5Fixtures.make(directory: work.appendingPathComponent("source-burst"))
        let original = fixture.source.manifest
        let manifest = F5BurstManifest(id: burstID, createdAt: createdAt,
            hardwareModel: original.hardwareModel, osBuild: original.osBuild, synthetic: original.synthetic,
            frames: original.frames, requestOrder: original.requestOrder, timestampOrder: original.timestampOrder,
            flags: original.flags, profile: original.profile, framing: original.framing)
        let sourceDirectory = fixture.source.directory
        try F5Hash.json(manifest).write(to: sourceDirectory.appendingPathComponent("burst.json"))
        let burstSnapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5, archiveF5RAW: true)
        let intent = F5BurstTransaction.Intent(id: burstID, createdAt: createdAt, snapshot: burstSnapshot,
            purpose: "synthetic-test", state: .committed, frames: manifest.frames, error: nil)
        try F5Hash.json(intent).write(to: sourceDirectory.appendingPathComponent("intent.json"))
        let burst = CaptureJournal(directory: work.appendingPathComponent("f5-five-frames"), formats: CaptureFormats([F5CaptureFormat()]))
        _ = try burst.retainBurst(F5BurstSource(directory: sourceDirectory), id: captureID, snapshot: burstSnapshot)
        try manager.copyItem(at: burst.directory, to: destination.appendingPathComponent("f5-five-frames"))

        let provenance = F5CaptureProvenance(decodeRevision: F5Version.decoder, colorBridgeRevision: F5Version.colorBridge,
            profileSHA256: fixture.profile.hash, referenceFrameID: manifest.frames[1].id,
            inputWidth: 8, inputHeight: 6, frameSHA256: manifest.frames.map(\.dng.sha256),
            actualExposures: manifest.frames.map(\.actualExposure), whiteBalanceOwner: "matrix",
            transformSHA256: String(repeating: "1", count: 64), qualityClassCounts: ["FULL_SR": 3, "REFERENCE_ONLY": 1],
            flags: [.budgetStop], solveStatus: "NATIVE_ONLY")
        let savedSnapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5, f5: provenance, archiveF5RAW: true)
        let file = TemporaryHEIFFile(captureDate: createdAt)
        try Data("GlassCam encoded HEIF fixture\n".utf8).write(to: file.url)
        let preview = try PreviewRaster(linearRGBA: Array(repeating: 0.5, count: 8 * 6 * 4), width: 8, height: 6)
        let saved = SavedCapture(file: file, preview: preview, width: 8, height: 6, snapshot: savedSnapshot)
        let encoded = try burst.storeEncoded(saved, id: captureID)
        try encode(encoded).write(to: destination.appendingPathComponent("f5-encoded.json"))
    }
}
