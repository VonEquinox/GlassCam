import Testing
import Foundation
import Combine
import GlassCamTestSupport
@testable import Capture
@testable import ImagingCore

struct RAWArchiveTests {
    @Test func balancedArchive_retryReusesPublishedFiles() throws {
        let work = try TestDirectory(), id = UUID(), bytes = Data([1,2,3])
        let saved = try CaptureRAWStore.retain(id: id,quality: .balanced,sourceIdentity: "same",root: work.url) {
            try bytes.write(to: $0.appendingPathComponent("balanced-camera.dng"))
        }

        let retried = try CaptureRAWStore.retain(id: id,quality: .balanced,sourceIdentity: "same",root: work.url) { _ in
            throw WorkflowFailure()
        }

        #expect(retried == saved)
        #expect(try Data(contentsOf: retried.appendingPathComponent("balanced-camera.dng")) == bytes)
    }

    @Test func failedArchive_doesNotPublishIncompleteFiles() throws {
        let work = try TestDirectory(), id = UUID()

        #expect(throws: WorkflowFailure.self) {
            try CaptureRAWStore.retain(id: id,quality: .balanced,sourceIdentity: "known",root: work.url) { directory in
                try Data([1,2,3]).write(to: directory.appendingPathComponent("partial.dng"))
                throw WorkflowFailure()
            }
        }

        #expect(!FileManager.default.fileExists(atPath: work.url.appendingPathComponent(id.uuidString + "/balanced").path))
    }

    @Test func changedSource_doesNotOverwriteExistingArchive() throws {
        let work = try TestDirectory(), id = UUID()
        let target = try CaptureRAWStore.retain(id: id,quality: .balanced,sourceIdentity: "first",root: work.url) {
            try Data([1,2,3]).write(to: $0.appendingPathComponent("original.dng"))
        }

        #expect(throws: CaptureJournal.Failure.self) {
            try CaptureRAWStore.retain(id: id,quality: .balanced,sourceIdentity: "second",root: work.url) { _ in }
        }

        #expect(try Data(contentsOf: target.appendingPathComponent("original.dng")) == Data([1,2,3]))
    }

    @Test func storageUsageAndClear_removesArchivedRootsWithoutTouchingUnlistedDirectories() throws {
        let work = try TestDirectory()
        let rawCaptures = work.url.appendingPathComponent("RAWCaptures", isDirectory: true)
        let f5Archives = work.url.appendingPathComponent("F5Archives", isDirectory: true)
        let pending = work.url.appendingPathComponent("PendingCapture", isDirectory: true)
        let id = UUID()
        _ = try CaptureRAWStore.retain(id: id, quality: .balanced, sourceIdentity: "first", root: rawCaptures) {
            try Data(repeating: 7, count: 128).write(to: $0.appendingPathComponent("balanced-camera.dng"))
        }
        let f5Set = f5Archives.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: f5Set, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64).write(to: f5Set.appendingPathComponent("burst.json"))
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let pendingManifest = pending.appendingPathComponent("capture.json")
        try Data([9, 8, 7]).write(to: pendingManifest)

        let before = CaptureRAWStore.storageUsage(roots: [rawCaptures, f5Archives])
        try CaptureRAWStore.clearArchives(roots: [rawCaptures, f5Archives])
        let after = CaptureRAWStore.storageUsage(roots: [rawCaptures, f5Archives])

        #expect(before.setCount == 2)
        #expect(before.bytes > 192)
        #expect(after == .init())
        #expect(try Data(contentsOf: pendingManifest) == Data([9, 8, 7]))
    }
}

@Suite(.serialized,.timeLimit(.minutes(1))) @MainActor
struct RAWTestRecorderTests {
    private func finished(_ recorder: RAWTestRecorder, start: () -> Void) async {
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = recorder.$isRecording.dropFirst().filter { !$0 }.first().sink { _ in
                DispatchQueue.main.async { continuation.resume() }
            }
            start()
        }
        withExtendedLifetime(subscription) {}
    }

    @Test func sceneCapture_usesOneArchiveID() async {
        let recorder = RAWTestRecorder()
        var ids = [UUID]()

        await finished(recorder) {
            recorder.recordScene { id in ids.append(id) }
        }

        #expect(ids.count == 1)
        #expect(recorder.directory == ids.first.map { CaptureRAWStore.directory(id: $0) })
    }

    @Test func sceneCaptureFailure_reportsOriginalError() async {
        let recorder = RAWTestRecorder()

        await finished(recorder) {
            recorder.recordScene { _ in throw WorkflowFailure() }
        }

        #expect(recorder.status == WorkflowFailure().localizedDescription)
    }

    @Test func activeSampleRecording_rejectsSecondTestAction() async {
        let recorder = RAWTestRecorder(), location = FileManager.default.temporaryDirectory
        var accepted: Bool?, captures = 0

        await finished(recorder) {
            recorder.recordSamples { captures += 1; return location }
            accepted = recorder.recordScene { _ in captures += 1 }
        }

        #expect(accepted == false)
        #expect(captures == 1)
        #expect(recorder.directory == location)
    }

}
