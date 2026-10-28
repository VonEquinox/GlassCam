import ImagingCore
import Capture
import F5
import Peripheral
#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct F5SettingsCard: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var settings: CameraSettingsStore
    let canRecord: Bool
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        CameraCard(title: "F5 main camera", symbol: "square.stack.3d.up") {
            Text(camera.f5ProfileAvailable ? "Main-camera profile available" : "Main-camera calibration required")
                .font(.subheadline.weight(.semibold))
            Text("F5 starts with the iPhone 18 Pro Max main camera. Telephoto and Ultra Wide will follow after main-camera validation.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Keep five RAW originals",isOn:$settings.archiveF5RAW)
                .disabled(camera.isCapturing).accessibilityIdentifier("settings.f5.keepRAW")
            Text("When enabled, saved F5 photos keep their RAW set in Files under F5Archives. Each set can use several hundred megabytes.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import accepted main-camera profile") { importing = true }
                .disabled(busy || camera.isCapturing).accessibilityIdentifier("settings.f5.importProfile")
            Button("Record five RAW samples") { camera.recordF5Sample() }
                .disabled(!canRecord || !camera.isReady || camera.isCapturing || busy)
                .accessibilityIdentifier("settings.f5.recordSamples")
            Text("Sample recording keeps five original RAW files and metadata in Files. It does not certify image quality or save a finished photo.")
                .font(.caption).foregroundStyle(.secondary)
            if camera.isCapturing { ProgressView(); Text(LocalizedStringKey(camera.status)).font(.caption) }
            if let url = camera.f5SampleDirectory {
                ShareLink(item: url) { Label("Share recorded RAW set", systemImage: "square.and.arrow.up") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                busy = true
                Task { @MainActor in
                    do {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        _ = try await Task.detached { try F5ProfileStore.importPackage(at: url) }.value
                        camera.refreshF5ProfileStatus()
                        message = String(localized: "Main-camera profile imported.")
                    } catch { message = error.localizedDescription }
                    busy = false
                }
            }
        }
        .alert("F5", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}
#endif
