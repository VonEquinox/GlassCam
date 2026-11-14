@testable import F5
@testable import Capture
@testable import ImagingCore
import GlassCamTestSupport
import Foundation
import Testing
import Combine

private enum JournalTestFiles {
    static let fixtures = TestResources.fixtures.appendingPathComponent("journal")
    static let formats = CaptureFormats([F5CaptureFormat()])

    static func data(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }
    static func record(_ path: String) throws -> CaptureJournal.Record {
        try formats.decoder().decode(CaptureJournal.Record.self, from: data(path))
    }
    static func copy(_ name: String, to directory: URL) throws {
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: directory)
    }
}

@Test(arguments: ["f5-five-frames/capture.json", "f5-encoded.json", "speed-normalized.json"])
func currentJournal_decodeEncodePreservesBytes(path: String) throws {
    let bytes = try JournalTestFiles.data(path)

    let record = try JournalTestFiles.formats.decoder().decode(CaptureJournal.Record.self, from: bytes)

    #expect(try JournalFixtures.encode(record) == bytes)
}

@Test func legacySpeed_decodeRetainsModeAndUses24MP() throws {
    let bytes = try JournalTestFiles.data("speed-legacy/capture.json")

    let record = try JournalTestFiles.formats.decoder().decode(CaptureJournal.Record.self, from: bytes)

    #expect(record.snapshot.quality == .speed)
    #expect(record.snapshot.output.cameraMegapixels == 24)
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

@Test(arguments: ["speed-legacy", "f5-five-frames"])
func retainedJournal_loadVerifiesFrozenFiles(name: String) throws {
    let work = try TestDirectory()
    let pending = work.url.appendingPathComponent("pending")
    try JournalTestFiles.copy(name, to: pending)
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)

    let record = try #require(try journal.load()).record

    #expect(record.id == JournalFixtures.captureID)
    #expect(record.stage == .rawReady)
}

@Test func retainedBurst_retryKeepsOriginalRecordAndFiveFrames() throws {
    let work = try TestDirectory()
    let pending = work.url.appendingPathComponent("pending")
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)
    let expected = try JournalTestFiles.record("f5-five-frames/capture.json")
    let source = try F5BurstSource(directory: JournalTestFiles.fixtures.appendingPathComponent("f5-five-frames/burst"))
    _ = try journal.retainBurst(source, id: expected.id, snapshot: expected.snapshot)

    let retried = try journal.retainBurst(source, id: expected.id, snapshot: expected.snapshot)

    #expect(try JournalFixtures.encode(retried.record) == JournalTestFiles.data("f5-five-frames/capture.json"))
    #expect(try Data(contentsOf: pending.appendingPathComponent("capture.json")) == JournalTestFiles.data("f5-five-frames/capture.json"))
    #expect((retried.payload as? F5BurstSource)?.manifest.frames.count == 5)
}

@Test(arguments: [CaptureQuality.speed,.balanced])
func retainedBayer_reloadKeepsModeAndOriginalFrames(quality: CaptureQuality) throws {
    let work = try TestDirectory()
    let fixture = try F5Fixtures.make(directory: work.url,quality: quality)
    let pending = work.url.appendingPathComponent("pending")
    let journal = CaptureJournal(directory: pending,formats: JournalTestFiles.formats)
    let snapshot = CaptureSnapshot(recipe: .standard,output: .native,quality: quality)
    _ = try journal.retainBurst(fixture.source,id: UUID(),snapshot: snapshot)

    let restored = try CaptureJournal(directory: pending,formats: JournalTestFiles.formats).load()

    let retained = try #require(restored)
    let record = retained.record
    let payload = try #require(retained.payload as? F5BurstSource)
    #expect(record.snapshot.quality == quality)
    #expect(payload.manifest.frames.count == quality.bayerFrameCount)
    #expect(payload.manifest.frames.map(\.mosaic.sha256) == fixture.source.manifest.frames.map(\.mosaic.sha256))
}

@Test func corruptBurst_loadRetainsFilesAndOriginalFailure() throws {
    let work = try TestDirectory()
    let pending = work.url.appendingPathComponent("pending")
    try JournalTestFiles.copy("f5-five-frames", to: pending)
    let victim = pending.appendingPathComponent("burst/frame-4.raw")
    var bytes = try Data(contentsOf: victim); bytes[0] ^= 1
    try bytes.write(to: victim)
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)

    let error = #expect(throws: F5Failure.self) { try journal.load() }
    #expect(error?.code == .damagedBundle)

    #expect(try Data(contentsOf: victim) == bytes)
}

@Test func encodedProvenance_decodePreservesRecordedFrameCount() throws {
    let record = try JournalTestFiles.record("f5-encoded.json")

    let description = record.snapshot.f5?.resolutionDescription(width: 8, height: 6)

    #expect(description == "Balanced · 5 RAW · Output 0.0 MP")
}

@Test func committedStaging_loadRecoversAndRemovesDuplicate() throws {
    let work = try TestDirectory()
    let root = work.url
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

    let retained = try #require(try journal.load())

    #expect(retained.record.id == JournalFixtures.burstID)
    #expect((retained.payload as? F5BurstSource)?.manifest.frames.count == 5)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

private enum InterruptedStaging: CaseIterable { case incomplete, malformed, missingIntent, multiple }

@Test func discardingOneSlot_keepsOtherSlotsInterruptedBayerBytes() throws {
    let work = try TestDirectory(), staging = work.url.appendingPathComponent("staging")
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24())
    let first = try F5BurstTransaction(snapshot: snapshot.forSlot(.first), purpose: "product",
        root: staging.appendingPathComponent(CaptureSlot.first.directoryName))
    let second = try F5BurstTransaction(snapshot: snapshot.forSlot(.second), purpose: "product",
        root: staging.appendingPathComponent(CaptureSlot.second.directoryName))
    let kept = second.directory.appendingPathComponent("intent.json")
    let bytes = try Data(contentsOf: kept)
    let firstJournal = CaptureJournal(directory: work.url.appendingPathComponent("first"),
        formats: formats.forSlot(.first), recoverStagedCaptures: true)

    try firstJournal.discard()

    #expect(!FileManager.default.fileExists(atPath: first.directory.path))
    #expect(try Data(contentsOf: kept) == bytes)
}

@Test(arguments: InterruptedStaging.allCases)
private func unrecoverableStaging_explicitDiscardRemovesIt(kind: InterruptedStaging) throws {
    let work = try TestDirectory()
    let root = work.url
    let staging = root.appendingPathComponent("staging")
    let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .balanced)
    let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: staging)
    let intent = transaction.directory.appendingPathComponent("intent.json")
    switch kind {
    case .incomplete: break
    case .malformed: try Data("{".utf8).write(to: intent)
    case .missingIntent: try FileManager.default.removeItem(at: intent)
    case .multiple: _ = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: staging)
    }
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let journal = CaptureJournal(directory: root.appendingPathComponent("pending"), formats: formats, recoverStagedCaptures: true)
    #expect(throws: (any Error).self) { try journal.load() }
    #expect(FileManager.default.fileExists(atPath: transaction.directory.path))

    try journal.discard()

    #expect(try journal.load() == nil)
}

@Test func confirmedBurst_clearArchivesOriginals() throws {
    let work = try TestDirectory()
    let root = work.url
    let pending = root.appendingPathComponent("pending")
    try JournalTestFiles.copy("f5-five-frames", to: pending)
    try JournalTestFiles.data("f5-encoded.json").write(to: pending.appendingPathComponent("capture.json"))
    try Data("GlassCam encoded HEIF fixture\n".utf8).write(to: pending.appendingPathComponent("result.heic"))
    let archives = root.appendingPathComponent("archives")
    let journal = CaptureJournal(directory: pending, formats: CaptureFormats([F5CaptureFormat(archiveRoot: archives)]))
    let attempt = UUID()
    _ = try journal.beginSave(id: JournalFixtures.captureID, attemptID: attempt)
    _ = try journal.confirmSaved(id: JournalFixtures.captureID, attemptID: attempt)

    try journal.finishSaved(id: JournalFixtures.captureID)

    let archived = try F5BurstSource(directory: archives.appendingPathComponent(JournalFixtures.captureID.uuidString))
    #expect(archived.manifest.frames.count == 5)
    #expect(!FileManager.default.fileExists(atPath: pending.path))
}

@Test func savedBurst_archiveFailureDoesNotBlockExplicitDiscard() throws {
    let work = try TestDirectory()
    let pending = work.url.appendingPathComponent("pending")
    try JournalTestFiles.copy("f5-five-frames", to: pending)
    try JournalTestFiles.data("f5-encoded.json").write(to: pending.appendingPathComponent("capture.json"))
    let archives = work.url.appendingPathComponent("archives")
    try Data("not a directory".utf8).write(to: archives)
    let journal = CaptureJournal(directory: pending, formats: CaptureFormats([F5CaptureFormat(archiveRoot: archives)]))
    let attempt = UUID()
    _ = try journal.beginSave(id: JournalFixtures.captureID, attemptID: attempt)
    _ = try journal.confirmSaved(id: JournalFixtures.captureID, attemptID: attempt)
    #expect(throws: (any Error).self) { try journal.finishSaved(id: JournalFixtures.captureID) }

    try journal.discard()

    #expect(try journal.load() == nil)
}

@Test @MainActor func partialBayerFailure_requiresExplicitDiscardOfDeliveredRAW() async throws {
    let work = try TestDirectory()
    let staging = work.url.appendingPathComponent("staging")
    let formats = CaptureFormats([F5CaptureFormat(stagingRoot: staging)])
    let journal = CaptureJournal(directory: work.url.appendingPathComponent("pending"), formats: formats, recoverStagedCaptures: true)
    let services = CaptureWorkflow.Services.live(resources: ColorResources(resourceDirectory: nil), formats: formats,
        authorize: {}, save: { _ in })
    let workflow = CaptureWorkflow(services: services, journal: journal)
    for await phase in workflow.$phase.values { if phase == .idle { break } }
    let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .balanced)
    var deliveredURL: URL?
    workflow.capturePhoto(snapshot: snapshot) { callback in
        do {
            let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "product", root: staging)
            try transaction.register(requestID: 1, indices: [0, 1, 2])
            let original = try JournalTestFiles.data("f5-five-frames/burst/frame-0.dng")
            let delivery = try transaction.retainDelivery(requestID: 1, sequenceCount: 1, dng: original)
            deliveredURL = try delivery.dng.url(in: transaction.directory)
            transaction.cancel(.frameMissing)
            callback(.failure(F5Failure(.frameMissing, "Interrupted bracket")))
        } catch { callback(.failure(error)) }
    }

    for await phase in workflow.$phase.values { if phase == .failed { break } }

    #expect(!workflow.canRetry)
    #expect(workflow.requiresDiscardConfirmation)
    let file = try #require(deliveredURL)
    #expect(try Data(contentsOf: file) == JournalTestFiles.data("f5-five-frames/burst/frame-0.dng"))
}

@Test func retainedBayer_pendingDirectoryIsExcludedFromBackup() throws {
    let work = try TestDirectory()
    let fixture = try F5Fixtures.make(directory: work.url, quality: .balanced)
    let pending = work.url.appendingPathComponent("pending")
    let journal = CaptureJournal(directory: pending, formats: JournalTestFiles.formats)

    _ = try journal.retainBurst(fixture.source, id: UUID(), snapshot: .init(recipe: .standard, output: .camera24()))

    #expect(try pending.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test @MainActor func registeredBurstProcessor_preservesISOFailure() async throws {
    let work = try TestDirectory()
    let fixture = try F5Fixtures.make(directory: work.url, deliveredISOs: [100, 100, 64, 100, 100])
    let services = CaptureWorkflow.Services.live(resources: ColorResources(resourceDirectory: nil),
        formats: JournalTestFiles.formats, authorize: {}, save: { _ in })
    let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .f5)

    let error = await #expect(throws: F5Failure.self) {
        _ = try await services.process(.burst(fixture.source), snapshot, { _ in })
    }
    #expect(error?.code == .isoChanged)
}

@Test func archiveRetain_isDurableAndIdempotent() throws {
    let work = try TestDirectory(), id = UUID(), root = work.url.appendingPathComponent("archives")
    let fixture = try F5Fixtures.make(directory: work.url, quality: .balanced)
    let first = try F5ArchiveStore.retain(fixture.source, captureID: id, root: root)
    let second = try F5ArchiveStore.retain(fixture.source, captureID: id, root: root)
    #expect(first == second)
    #expect(try F5BurstSource(directory: second).manifest.frames.count == 4)
}
@Test func lateConflictingDelivery_doesNotOverwriteOriginal() throws {
    let work = try TestDirectory()
    let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .balanced)
    let transaction = try F5BurstTransaction(snapshot: snapshot, purpose: "synthetic-test", root: work.url)
    try transaction.register(requestID: 900, indices: [0])
    let original = try transaction.retainDelivery(requestID: 900, sequenceCount: 1, dng: JournalTestFiles.data("f5-five-frames/burst/frame-0.dng"))
    transaction.cancel(.unsupportedRAW)
    let late = try transaction.retainDelivery(requestID: 900, sequenceCount: 1, dng: JournalTestFiles.data("f5-five-frames/burst/frame-2.dng"))
    try original.dng.verify(in: transaction.directory)
    try late.dng.verify(in: transaction.directory)
    #expect(original.dng.path != late.dng.path)
}
