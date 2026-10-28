import Foundation
import Testing

private enum JournalTestFiles {
    static let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLASSCAM_JOURNAL_FIXTURES"]!)
    static let work = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLASSCAM_JOURNAL_WORK"]!)
    static let formats = CaptureFormats([F5CaptureFormat()])

    static func data(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }
    static func record(_ path: String) throws -> CaptureJournal.Record {
        try formats.decoder().decode(CaptureJournal.Record.self, from: data(path))
    }
    static func directory() throws -> URL {
        let directory = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func copy(_ name: String, to directory: URL) throws {
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: directory)
    }
}

@Test(arguments: ["single-photo/capture.json", "f5-five-frames/capture.json", "f5-encoded.json", "speed-normalized.json"])
func currentJournal_decodeEncodePreservesBytes(path: String) throws {
    let bytes = try JournalTestFiles.data(path)

    let record = try JournalTestFiles.formats.decoder().decode(CaptureJournal.Record.self, from: bytes)

    #expect(try JournalFixtures.encode(record) == bytes)
}

@Test func legacySpeed_decodeRetainsQualityAndExistingNormalization() throws {
    let bytes = try JournalTestFiles.data("speed-legacy/capture.json")

    let record = try JournalTestFiles.formats.decoder().decode(CaptureJournal.Record.self, from: bytes)

    #expect(record.snapshot.quality == .speed)
    #expect(record.snapshot.output.cameraMegapixels == 12)
    #expect(try JournalFixtures.encode(record) == JournalTestFiles.data("speed-normalized.json"))
}

@Test func burstManifest_decodeEncodePreservesFiveFrameBytes() throws {
    let bytes = try JournalTestFiles.data("f5-five-frames/burst/burst.json")

    let manifest = try JSONDecoder().decode(F5BurstManifest.self, from: bytes)

    #expect(manifest.frames.count == 5)
    #expect(try F5Hash.json(manifest) == bytes)
}

@Test func burstIntent_decodeEncodePreservesBytes() throws {
    let bytes = try JournalTestFiles.data("f5-five-frames/burst/intent.json")

    let intent = try JournalTestFiles.formats.decoder().decode(F5BurstTransaction.Intent.self, from: bytes)

    #expect(try F5Hash.json(intent) == bytes)
}

@Test func burstProfile_decodeEncodePreservesBytes() throws {
    let bytes = try JournalTestFiles.data("f5-five-frames/burst/profile.json")

    let profile = try JSONDecoder().decode(F5DeviceProfile.self, from: bytes)

    #expect(try F5Hash.json(profile) == bytes)
}

@Test(arguments: ["single-photo", "speed-legacy", "f5-five-frames"])
func retainedJournal_loadVerifiesFrozenFiles(name: String) throws {
    let pending = try JournalTestFiles.directory().appendingPathComponent("pending")
    try JournalTestFiles.copy(name, to: pending)
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)

    let record = try #require(try journal.load())

    #expect(record.id == JournalFixtures.captureID)
    #expect(record.stage == .rawReady)
}

@Test func retainedBurst_retryKeepsOriginalRecordAndFiveFrames() throws {
    let pending = try JournalTestFiles.directory().appendingPathComponent("pending")
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)
    let expected = try JournalTestFiles.record("f5-five-frames/capture.json")
    let source = try F5BurstSource(directory: JournalTestFiles.fixtures.appendingPathComponent("f5-five-frames/burst"))
    _ = try journal.retainBurst(source, id: expected.id, snapshot: expected.snapshot)

    let retried = try journal.retainBurst(source, id: expected.id, snapshot: expected.snapshot)

    #expect(try JournalFixtures.encode(retried) == JournalTestFiles.data("f5-five-frames/capture.json"))
    #expect(try Data(contentsOf: pending.appendingPathComponent("capture.json")) == JournalTestFiles.data("f5-five-frames/capture.json"))
    #expect(try (journal.retainedPayload(for: retried) as? F5BurstSource)?.manifest.frames.count == 5)
}

@Test func corruptBurst_loadRetainsFilesAndOriginalFailure() throws {
    let pending = try JournalTestFiles.directory().appendingPathComponent("pending")
    try JournalTestFiles.copy("f5-five-frames", to: pending)
    let victim = pending.appendingPathComponent("burst/frame-4.raw")
    var bytes = try Data(contentsOf: victim); bytes[0] ^= 1
    try bytes.write(to: victim)
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)

    let error = #expect(throws: F5Failure.self) { try journal.load() }
    #expect(error?.code == .damagedBundle)

    #expect(try Data(contentsOf: victim) == bytes)
}

@Test func encodedProvenance_decodePreservesFallbackDescription() throws {
    let record = try JournalTestFiles.record("f5-encoded.json")

    let description = record.snapshot.f5?.resolutionDescription(width: 8, height: 6)

    #expect(description == "F5 · 5 RAW · Output 0.0 MP · Some areas use native detail")
}

@Test func committedStaging_loadRecoversAndRemovesDuplicate() throws {
    let root = try JournalTestFiles.directory()
    let staging = root.appendingPathComponent("staging")
    let staged = staging.appendingPathComponent(JournalFixtures.burstID.uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try JournalTestFiles.copy("f5-five-frames/burst", to: staged)
    let bytes = try Data(contentsOf: staged.appendingPathComponent("intent.json"))
    let intent = try JournalTestFiles.formats.decoder().decode(F5BurstTransaction.Intent.self, from: bytes)
    let product = F5BurstTransaction.Intent(id: intent.id, createdAt: intent.createdAt, snapshot: intent.snapshot,
        purpose: "product", state: .committed, frames: intent.frames, error: nil)
    try F5Hash.json(product).write(to: staged.appendingPathComponent("intent.json"))
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let journal = CaptureJournal(directory: root.appendingPathComponent("pending"), formats: formats, recoverStagedCaptures: true)

    let record = try #require(try journal.load())

    #expect(record.id == JournalFixtures.burstID)
    #expect(try (journal.retainedPayload(for: record) as? F5BurstSource)?.manifest.frames.count == 5)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func interruptedStaging_loadRetainsFilesWithOriginalFailure() throws {
    let root = try JournalTestFiles.directory()
    let staging = root.appendingPathComponent("staging")
    let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5)
    let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: staging)
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let journal = CaptureJournal(directory: root.appendingPathComponent("pending"), formats: formats, recoverStagedCaptures: true)

    let error = #expect(throws: F5Failure.self) { try journal.load() }
    #expect(error?.code == .frameMissing)
    #expect(error?.detail == "F5 capture was interrupted after 0 of 5 frames. Its diagnostic files were retained; discard this interrupted capture before taking another.")

    #expect(FileManager.default.fileExists(atPath: transaction.directory.path))
}

@Test func interruptedStaging_explicitDiscardRemovesIt() throws {
    let root = try JournalTestFiles.directory()
    let staging = root.appendingPathComponent("staging")
    let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5)
    let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: staging)
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let journal = CaptureJournal(directory: root.appendingPathComponent("pending"), formats: formats, recoverStagedCaptures: true)

    try journal.discardUnreadable()

    #expect(!FileManager.default.fileExists(atPath: transaction.directory.path))
}

@Test func confirmedBurst_clearArchivesOriginals() throws {
    let root = try JournalTestFiles.directory()
    let pending = root.appendingPathComponent("pending")
    try JournalTestFiles.copy("f5-five-frames", to: pending)
    try JournalTestFiles.data("f5-encoded.json").write(to: pending.appendingPathComponent("capture.json"))
    try Data("GlassCam encoded HEIF fixture\n".utf8).write(to: pending.appendingPathComponent("result.heic"))
    let archives = root.appendingPathComponent("archives")
    let journal = CaptureJournal(directory: pending, formats: CaptureFormats([F5CaptureFormat(archiveRoot: archives)]))
    let attempt = UUID()
    _ = try journal.beginSave(id: JournalFixtures.captureID, attemptID: attempt)
    _ = try journal.confirmSaved(id: JournalFixtures.captureID, attemptID: attempt)

    try journal.clear(id: JournalFixtures.captureID)

    let archived = try F5BurstSource(directory: archives.appendingPathComponent(JournalFixtures.captureID.uuidString))
    #expect(archived.manifest.frames.count == 5)
    #expect(!FileManager.default.fileExists(atPath: pending.path))
}

@Test @MainActor func registeredBurstProcessor_preservesISOFailure() async throws {
    let fixture = try F5Fixtures.make(directory: JournalTestFiles.directory(), deliveredISOs: [100, 100, 64, 100, 100])
    let services = CaptureWorkflow.Services.live(resources: ColorResources(resourceDirectory: nil),
        formats: JournalTestFiles.formats, authorize: {}, save: { _ in })
    let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5)

    let error = await #expect(throws: F5Failure.self) {
        _ = try await services.process(.burst(fixture.source), snapshot, { _ in })
    }
    #expect(error?.code == .isoChanged)
}

@main struct JournalCompatibilityMain {
    static func main() async {
        let _: Never = await Testing.__swiftPMEntryPoint()
    }
}
