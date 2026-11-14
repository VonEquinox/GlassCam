import ImagingCore
import Capture
import F5
import Peripheral
#if os(iOS)
import SwiftUI

struct F5SettingsCard: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var rawTests: RAWTestRecorder
    @ObservedObject var workflow: CaptureQueue
    let canRecord: Bool
    @State private var storageUsage = CaptureRAWStore.StorageUsage()
    @State private var clearConfirmation = false
    @State private var clearError: String?

    private var canClearStorage: Bool {
        !storageUsage.isEmpty && !rawTests.isRecording && !camera.isCapturing && !workflow.isWorking
    }

    var body: some View {
        CameraCard(title: "RAW & Diagnostics", symbol: "square.stack.3d.up") {
            Toggle("Archive Balanced pre-color RAW", isOn: $settings.archiveBalancedPreColorRAW)
                .disabled(camera.isCapturing)
                .accessibilityIdentifier("settings.balanced.keepPreColorRAW")
            Text("When enabled, each Balanced photo also writes 32-bit float pre-color files to Files → GlassCam → RAWCaptures (~570 MB per photo).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Also keep Bayer input frames", isOn: $settings.archiveF5RAW)
                .disabled(camera.isCapturing)
                .accessibilityIdentifier("settings.bayer.keepRAW")
            Text("When enabled, saved photos keep their Bayer RAW input set in Files → GlassCam → F5Archives.")
                .font(.caption).foregroundStyle(.secondary)

            Divider().overlay(.white.opacity(0.12))

            HStack {
                Text("Archived RAW storage")
                Spacer()
                Text(storageSummary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }.font(.subheadline)
            Button("Clear archived RAW files", role: .destructive) {
                clearConfirmation = true
            }
            .foregroundStyle(canClearStorage ? Color.red : Color.white.opacity(0.35))
            .disabled(!canClearStorage)
            .accessibilityIdentifier("settings.raw.clearArchives")
            if let clearError {
                Text(clearError).font(.caption).foregroundStyle(.red)
            }

            Divider().overlay(.white.opacity(0.12))

            Button("Record 11 RAW samples") {
                rawTests.recordSamples { try await camera.recordBayerSamples() }
            }.disabled(!canRecord || !camera.canReserveCapture || rawTests.isRecording)
                .accessibilityIdentifier("settings.raw.record11")
            Text("Keeps eleven equal-exposure Bayer originals and metadata in Files → GlassCam → F5Samples for offline fusion.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Record scene · Balanced") {
                let recipe = settings.recipe, archive = settings.archiveF5RAW
                rawTests.recordScene { id in
                    try await camera.recordScene(id: id, recipe: recipe, archiveInputs: archive)
                }
            }.disabled(!canRecord || !camera.canReserveCapture || rawTests.isRecording)
                .accessibilityIdentifier("settings.raw.recordScene")
            Text("Records only the Balanced merged source, without color processing or Photos export. Keep the scene steady.")
                .font(.caption).foregroundStyle(.secondary)
            if !rawTests.status.isEmpty { Text(LocalizedStringKey(rawTests.status)).font(.caption).textSelection(.enabled) }
            if rawTests.isRecording {
                Text(LocalizedStringKey(workflow.isWorking ? workflow.status : camera.status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let directory = rawTests.directory { Text(directory.lastPathComponent).font(.caption2).textSelection(.enabled) }
        }
        .task { await refreshStorageUsage() }
        .onChange(of: rawTests.isRecording) { _, isRecording in
            if !isRecording { Task { await refreshStorageUsage() } }
        }
        .onChange(of: workflow.phase) { _, phase in
            if phase == .idle { Task { await refreshStorageUsage() } }
        }
        .confirmationDialog("Delete all archived RAW and sample files from Files → GlassCam? Saved photos in Photos are not affected.",
                            isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button("Clear archived RAW files", role: .destructive) {
                clearArchivedFiles()
            }
        }
    }

    private var storageSummary: LocalizedStringKey {
        guard !storageUsage.isEmpty else { return "None" }
        let formatted = ByteCountFormatter.string(fromByteCount: storageUsage.bytes, countStyle: .file)
        return "\(storageUsage.setCount) sets · \(formatted)"
    }

    private func refreshStorageUsage() async {
        let usage = await Task.detached(priority: .utility) {
            CaptureRAWStore.storageUsage()
        }.value
        storageUsage = usage
    }

    private func clearArchivedFiles() {
        clearError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CaptureRAWStore.clearArchives()
                }.value
                await refreshStorageUsage()
            } catch {
                clearError = error.localizedDescription
                await refreshStorageUsage()
            }
        }
    }
}
#endif
