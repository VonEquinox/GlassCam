import Testing
import Foundation
import Combine
import GlassCamTestSupport
@testable import Capture
@testable import ImagingCore

struct RAWArchiveTests {
    @Test @MainActor func qualitySource_isArchivedBeforeColorFailure() async throws {
        let work = try TestDirectory(), id = UUID(), bytes = try ImageFixture.pngData()
        let source = try SourceImageFile(data: bytes,fileExtension: "png")
        let recipe = ProcessingRecipe(mode: .ffcs,exposureEV: 0,illuminantKelvin: 6500,simulationIndex: 0,seed: 0,hncs: .standard)
        let snapshot = CaptureSnapshot(recipe: recipe,output: .native,quality: .quality,rawArchiveID: id)
        let services = CaptureWorkflow.Services.live(resources: .init(resourceDirectory: work.url.appendingPathComponent("missing")),
            rawArchiveRoot: work.url,authorize: {},save: { _ in })

        await #expect(throws: (any Error).self) { _ = try await services.process(.file(source),snapshot,{ _ in }) }

        #expect(try Data(contentsOf: work.url.appendingPathComponent(id.uuidString + "/quality/original-proraw.dng")) == bytes)
    }
    @Test func originalProRAW_isRetainedByteExactlyAndRetryReusesDirectory() throws {
        let work = try TestDirectory(), id = UUID(), data = Data((0..<1024).map { UInt8($0 % 251) })
        let source = work.url.appendingPathComponent("source.dng")
        try data.write(to: source)
        let snapshot = CaptureSnapshot(recipe: .standard,output: .native,quality: .quality,rawArchiveID: id)

        try CaptureRAWStore.retainProRAW(source,id: id,snapshot: snapshot,root: work.url)
        try CaptureRAWStore.retainProRAW(source,id: id,snapshot: snapshot,root: work.url)

        let file = work.url.appendingPathComponent(id.uuidString + "/quality/original-proraw.dng")
        #expect(try Data(contentsOf: file) == data)
        let restored = try JSONDecoder().decode(CaptureSnapshot.self,from: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("capture.json")))
        #expect(restored.rawArchiveID == id)
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
        let target = try CaptureRAWStore.retain(id: id,quality: .quality,sourceIdentity: "first",root: work.url) {
            try Data([1,2,3]).write(to: $0.appendingPathComponent("original.dng"))
        }

        #expect(throws: CaptureJournal.Failure.self) {
            try CaptureRAWStore.retain(id: id,quality: .quality,sourceIdentity: "second",root: work.url) { _ in }
        }

        #expect(try Data(contentsOf: target.appendingPathComponent("original.dng")) == Data([1,2,3]))
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

    @Test func pairedScene_usesOneIDAndCapturesBalancedBeforeProRAW() async {
        let recorder = RAWTestRecorder()
        var modes = [CaptureQuality](), ids = [UUID]()

        await finished(recorder) {
            recorder.recordScene { mode,id in modes.append(mode); ids.append(id) }
        }

        #expect(modes == [.balanced,.quality])
        #expect(Set(ids).count == 1)
        #expect(recorder.directory == ids.first.map { CaptureRAWStore.directory(id: $0) })
    }

    @Test func firstCaptureFails_doesNotSubmitProRAW() async {
        let recorder = RAWTestRecorder()
        var modes = [CaptureQuality]()

        await finished(recorder) {
            recorder.recordScene { mode,_ in modes.append(mode); throw WorkflowFailure() }
        }

        #expect(modes == [.balanced])
        #expect(recorder.status == WorkflowFailure().localizedDescription)
    }

    @Test func activeSampleRecording_rejectsSecondTestAction() async {
        let recorder = RAWTestRecorder(), location = FileManager.default.temporaryDirectory
        var accepted: Bool?, captures = 0

        await finished(recorder) {
            recorder.recordSamples { captures += 1; return location }
            accepted = recorder.recordScene { _,_ in captures += 1 }
        }

        #expect(accepted == false)
        #expect(captures == 1)
        #expect(recorder.directory == location)
    }

}
