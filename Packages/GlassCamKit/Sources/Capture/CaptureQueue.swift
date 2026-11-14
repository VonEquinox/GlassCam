import Combine
import Foundation
import ImagingCore

/// Independent durable photos with one shared permit for large-image work.
/// Each slot owns its staging scope, so discarding cannot erase another shot.
@MainActor
public final class CaptureQueue: ObservableObject {
    @Published public private(set) var phase: CaptureWorkflow.Phase = .restoring
    @Published public private(set) var progress = 0.0
    @Published public private(set) var latest: SavedCapture?
    private let workflows: [CaptureWorkflow]
    private let latestReviewStore: LatestReviewStore?
    private var subscriptions: [AnyCancellable] = []
    private var observedLatest: [UUID?] = [nil, nil]
    private var foreground: Bool
    private var refreshScheduled = false
    private var latestRestore: Task<Void, Never>?
    private var loadedLatest = false

    public init(services: CaptureWorkflow.Services, formats: CaptureFormats = CaptureFormats(),
                directory: URL? = nil, latestReviewStore: LatestReviewStore? = nil, initiallyActive: Bool = true) {
        foreground = initiallyActive; self.latestReviewStore = latestReviewStore
        let parent = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCam/PendingCaptures", isDirectory: true)
        let serial = CaptureProcessingSerialiser()
        let process = services.process, controlled = services.processWithControl
        var bounded = services
        bounded.processWithControl = { source, snapshot, progress, control in
            try await serial.run(control: control) {
                if let controlled { return try await controlled(source, snapshot, progress, control) }
                return try await process(source, snapshot, progress)
            }
        }
        workflows = CaptureSlot.allCases.map { slot in
            CaptureWorkflow(services: bounded,
                journal: CaptureJournal(directory: parent.appendingPathComponent(slot.directoryName, isDirectory: true),
                    formats: formats.forSlot(slot), recoverStagedCaptures: true),
                initiallyActive: initiallyActive, latestReviewStore: latestReviewStore)
        }
        for workflow in workflows {
            subscriptions.append(workflow.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        }
        refresh()
        if initiallyActive { restoreLatest() }
    }

    private var selected: CaptureWorkflow {
        let order: [CaptureWorkflow.Phase] = [.capturing, .authorizing, .retaining, .failed, .saveOutcomeUnknown,
                                              .processing, .saving, .restoring, .paused, .idle]
        return workflows.min {
            order.firstIndex(of: $0.phase)! < order.firstIndex(of: $1.phase)!
        }!
    }
    public var pendingCount: Int { workflows.filter { $0.phase != .idle }.count }
    public var canCapture: Bool {
        let acquiring: [CaptureWorkflow.Phase] = [.authorizing, .capturing, .retaining, .restoring]
        return foreground && !workflows.contains { acquiring.contains($0.phase) } &&
            workflows.contains { $0.canCapture }
    }
    public var isWorking: Bool { workflows.contains { $0.isWorking } }
    public var canRetry: Bool { selected.canRetry }
    public var requiresDiscardConfirmation: Bool { selected.requiresDiscardConfirmation }
    public var needsPhotosPermission: Bool { selected.needsPhotosPermission }
    public var pendingCapture: SavedCapture? { selected.pendingCapture }
    public var pendingDate: Date? { selected.pendingDate }
    public var failureMessage: String? { selected.failureMessage }
    public var status: String {
        if pendingCount > 1 {
            return selected.status + String(localized: " · \(pendingCount) photos pending")
        }
        return selected.status
    }

    public func capturePhoto(snapshot: CaptureSnapshot,
                             takePhoto: @escaping (CaptureSnapshot, @escaping (Result<CapturedCameraPhoto, Error>) -> Void) -> Void) {
        guard canCapture, let index = workflows.firstIndex(where: { $0.canCapture }) else { return }
        let frozen = snapshot.forSlot(CaptureSlot.allCases[index])
        workflows[index].capturePhoto(snapshot: frozen) { takePhoto(frozen, $0) }
        refresh()
    }
    public func setForeground(_ active: Bool) {
        foreground = active
        workflows.forEach { $0.setForeground(active) }
        if active { restoreLatest() }
        refresh()
    }
    public func retry() { selected.retry(); refresh() }
    public func discardFailed() { selected.discardFailed(); refresh() }
    public func confirmAlreadySaved() { selected.confirmAlreadySaved(); refresh() }
    public func saveAgain() { selected.saveAgain(); refresh() }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false; self.refresh()
        }
    }
    private func refresh() {
        for (index, workflow) in workflows.enumerated() {
            if let capture = workflow.latest, observedLatest[index] != capture.id {
                observedLatest[index] = capture.id
                considerLatest(capture)
            }
        }
        phase = selected.phase; progress = selected.progress
    }
    private func restoreLatest() {
        guard !loadedLatest, latestRestore == nil, let latestReviewStore else { return }
        latestRestore = Task { [weak self] in
            let capture = try? await Task.detached(priority: .utility) { try latestReviewStore.load() }.value
            guard let self else { return }
            self.latestRestore = nil
            self.loadedLatest = self.foreground
            if let capture { self.considerLatest(capture) }
        }
    }
    private func considerLatest(_ capture: SavedCapture) {
        guard latest == nil || (capture.confirmedAt ?? .distantPast) >= (latest?.confirmedAt ?? .distantPast) else { return }
        latest = capture
    }
}

private actor CaptureProcessingSerialiser {
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(control: CaptureProcessingControl, operation: @Sendable () async throws -> SavedCapture) async throws -> SavedCapture {
        if control.isStopped { throw CancellationError() }
        if occupied {
            await withCheckedContinuation { waiting.append($0) }
        } else { occupied = true }
        defer {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().resume() }
        }
        if control.isStopped { throw CancellationError() }
        return try await operation()
    }
}
