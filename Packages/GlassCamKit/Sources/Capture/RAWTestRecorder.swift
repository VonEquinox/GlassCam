import Foundation
import Combine
import ImagingCore

/// One test action owns admission until its samples or a Balanced scene capture
/// finish. Scene operations archive sources without a styled photo export.
@MainActor
public final class RAWTestRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var status = ""
    @Published public private(set) var directory: URL?
    private var task: Task<Void,Never>?
    public init() {}

    @discardableResult
    public func recordSamples(_ capture: @escaping @MainActor () async throws -> URL) -> Bool {
        guard !isRecording else { return false }
        isRecording = true; directory = nil; status = "Recording 11 RAW samples…"
        task = Task {
            do { directory = try await capture(); status = "11 RAW samples saved." }
            catch { status = error.localizedDescription }
            isRecording = false; task = nil
        }
        return true
    }

    @discardableResult
    public func recordScene(_ capture: @escaping @MainActor (UUID) async throws -> Void) -> Bool {
        guard !isRecording else { return false }
        let id = UUID()
        isRecording = true; directory = nil; status = "Recording scene · Balanced…"
        task = Task {
            do {
                try await capture(id)
                directory = CaptureRAWStore.directory(id: id)
                status = "Balanced scene files saved."
            } catch {
                let saved = CaptureRAWStore.directory(id: id)
                if FileManager.default.fileExists(atPath: saved.path) { directory = saved }
                status = error.localizedDescription
            }
            isRecording = false; task = nil
        }
        return true
    }
}
