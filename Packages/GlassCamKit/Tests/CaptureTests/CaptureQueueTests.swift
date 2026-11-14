import Combine
import Foundation
import Testing
import GlassCamTestSupport
@testable import Capture
@testable import ImagingCore

@MainActor private final class QueueHarness {
    let work: TestDirectory
    let raw: Data
    let preview: PreviewRaster
    var starts: [CaptureSlot?] = []
    var shutterSlots: [CaptureSlot?] = []
    var saves = 0
    var active = 0
    var maximumActive = 0
    var firstFails = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init() throws {
        work = try TestDirectory(); raw = try ImageFixture.pngData()
        preview = try PreviewRaster(linearRGBA: [Float](repeating: 1, count: 8 * 8 * 4), width: 8, height: 8)
    }
    func queue(initiallyActive: Bool = true) -> CaptureQueue {
        let services = CaptureWorkflow.Services(authorize: {}, retain: { data in
            try SourceImageFile(data: data, fileExtension: "png")
        }, process: { [self] _, snapshot, _ in
            try await render(snapshot, control: nil)
        }, save: { [self] _ in saves += 1 }, processWithControl: { [self] _, snapshot, _, control in
            try await render(snapshot, control: control)
        })
        return CaptureQueue(services: services, directory: work.url, initiallyActive: initiallyActive)
    }
    func take(_ queue: CaptureQueue) {
        queue.capturePhoto(snapshot: .init(recipe: .standard, output: .camera24())) { [self] snapshot, completion in
            shutterSlots.append(snapshot.recoverySlot)
            completion(.success(.init(data: raw, framing: .init())))
        }
    }
    private func render(_ snapshot: CaptureSnapshot, control: CaptureProcessingControl?) async throws -> SavedCapture {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        starts.append(snapshot.recoverySlot)
        let ready = startWaiters.filter { starts.count >= $0.0 }
        startWaiters.removeAll { starts.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if firstFails, snapshot.recoverySlot == .first { throw WorkflowFailure() }
        await withCheckedContinuation { gates.append($0) }
        if control?.isStopped == true { throw CancellationError() }
        let file = TemporaryHEIFFile()
        try Data("encoded-\(snapshot.recoverySlot!.rawValue)".utf8).write(to: file.url)
        return SavedCapture(file: file, preview: preview, width: 8, height: 8, snapshot: snapshot)
    }
    func untilStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
    func releaseNext() { if !gates.isEmpty { gates.removeFirst().resume() } }
}

@MainActor private func waitForQueue(_ queue: CaptureQueue, phase: CaptureWorkflow.Phase, count: Int? = nil) async {
    for await value in queue.$phase.values {
        if value == phase, count == nil || queue.pendingCount == count { return }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct CaptureQueueTests {
    @Test func retainedFirstPhoto_admitsSecondAndBoundsProcessingAndCapacity() async throws {
        let harness = try QueueHarness(), queue = harness.queue()
        await waitForQueue(queue, phase: .idle)
        harness.take(queue)
        await harness.untilStarts(1)
        #expect(queue.canCapture)

        harness.take(queue)
        harness.take(queue)
        await waitForQueue(queue, phase: .processing, count: 2)

        #expect(harness.shutterSlots == [.first, .second])
        #expect(harness.starts == [.first])
        #expect(!queue.canCapture)
        harness.releaseNext()
        await harness.untilStarts(2)
        harness.releaseNext()
        await waitForQueue(queue, phase: .idle)
        #expect(harness.maximumActive == 1)
        #expect(harness.saves == 2)
    }

    @Test func discardingFailedPhoto_keepsOtherSlotProcessing() async throws {
        let harness = try QueueHarness()
        harness.firstFails = true
        let queue = harness.queue()
        await waitForQueue(queue, phase: .idle)
        harness.take(queue)
        await waitForQueue(queue, phase: .failed)
        harness.take(queue)
        await harness.untilStarts(2)

        queue.discardFailed()
        await waitForQueue(queue, phase: .processing, count: 1)

        #expect(harness.starts == [.first, .second])
        harness.releaseNext()
        await waitForQueue(queue, phase: .idle)
        #expect(harness.saves == 1)
        #expect(queue.latest?.snapshot.recoverySlot == .second)
    }

    @Test func backgroundingBothSlots_pausesQueuedWorkWithoutStartingAnotherRender() async throws {
        let harness = try QueueHarness(), queue = harness.queue()
        await waitForQueue(queue, phase: .idle)
        harness.take(queue)
        await harness.untilStarts(1)
        harness.take(queue)
        await waitForQueue(queue, phase: .processing, count: 2)

        queue.setForeground(false)
        harness.releaseNext()
        await waitForQueue(queue, phase: .paused, count: 2)

        #expect(harness.starts == [.first])
        #expect(harness.saves == 0)
        #expect(!queue.canCapture)
    }

    @Test func restartingQueue_recoversBothFrozenSlotsSerially() async throws {
        let harness = try QueueHarness()
        for slot in CaptureSlot.allCases {
            let journal = CaptureJournal(directory: harness.work.url.appendingPathComponent(slot.directoryName))
            _ = try journal.retain(harness.raw, id: UUID(),
                snapshot: CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .speed).forSlot(slot))
        }
        let queue = harness.queue(initiallyActive: false)

        queue.setForeground(true)
        await harness.untilStarts(1)
        harness.releaseNext()
        await harness.untilStarts(2)
        harness.releaseNext()
        await waitForQueue(queue, phase: .idle)

        #expect(Set(harness.starts.compactMap { $0 }) == Set(CaptureSlot.allCases))
        #expect(harness.maximumActive == 1)
        #expect(harness.saves == 2)
    }
}
