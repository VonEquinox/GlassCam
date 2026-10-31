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
    @ObservedObject var workflow: CaptureWorkflow
    let canRecord: Bool

    var body: some View {
        CameraCard(title: "RAW recording", symbol: "square.stack.3d.up") {
            Text("Balanced merged RAW and original ProRAW are saved before color processing. Finished photos still save to Photos.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Pre-color files are in Files → GlassCam → RAWCaptures.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Record 11 RAW samples") {
                rawTests.recordSamples { try await camera.recordBayerSamples() }
            }.disabled(!canRecord || !camera.canReserveCapture || rawTests.isRecording)
                .accessibilityIdentifier("settings.raw.record11")
            Text("Keeps eleven equal-exposure Bayer originals and metadata for offline fusion.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sample sets are in Files → GlassCam → F5Samples.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Record scene · Balanced + ProRAW") {
                let recipe = settings.recipe, archive = settings.archiveF5RAW
                rawTests.recordScene { quality,id in
                    try await camera.recordScene(quality: quality,id: id,recipe: recipe,archiveInputs: archive)
                }
            }.disabled(!canRecord || !camera.canReserveCapture || rawTests.isRecording)
                .accessibilityIdentifier("settings.raw.recordScene")
            Text("Records only the Balanced merged source and original ProRAW, without color processing or Photos export. Keep the scene steady.")
                .font(.caption).foregroundStyle(.secondary)
            if !rawTests.status.isEmpty { Text(LocalizedStringKey(rawTests.status)).font(.caption).textSelection(.enabled) }
            if rawTests.isRecording {
                Text(LocalizedStringKey(workflow.isWorking ? workflow.status : camera.status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let directory = rawTests.directory { Text(directory.lastPathComponent).font(.caption2).textSelection(.enabled) }
            Toggle("Also keep Bayer input frames", isOn: $settings.archiveF5RAW)
                .disabled(camera.isCapturing).accessibilityIdentifier("settings.bayer.keepRAW")
        }
    }
}
#endif
