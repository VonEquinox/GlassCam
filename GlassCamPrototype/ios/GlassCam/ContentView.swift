import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var imported: ImportedImage?
    @Published var processed: ProcessedImage?
    @Published var exposure = 0.0
    @Published var kelvin = 6500.0
    @Published var busy = false
    @Published var error: String?
    @Published var export: ExportFile?

    private var importTask: Task<Void, Never>?
    private var operationID = UUID()
    private var sharedURL: URL?

    func selectPhoto(_ selected: PhotosPickerItem) {
        beginImport {
            guard let data = try await selected.loadTransferable(type: Data.self) else {
                throw PipelineError.invalidImage
            }
            let ext = selected.supportedContentTypes.contains(where: { $0.conforms(to: .rawImage) }) ? "dng" : nil
            return (data, ext)
        }
    }

    func selectFile(_ url: URL) {
        beginImport {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            return (data, url.pathExtension)
        }
    }

    /// The token guards every suspension point: an older provider transfer or decode
    /// may finish after cancellation, but can never replace the latest selection.
    private func beginImport(_ fetch: @escaping @MainActor () async throws -> (Data, String?)) {
        importTask?.cancel()
        let id = UUID()
        operationID = id
        busy = true
        error = nil
        let ev = exposure, cct = kelvin
        importTask = Task { @MainActor in
            defer {
                if operationID == id { busy = false; importTask = nil }
            }
            do {
                let (data, ext) = try await fetch()
                guard operationID == id, !Task.isCancelled else { return }
                let input = try await Task.detached(priority: .userInitiated) {
                    try ImagePipeline.load(data: data, fileExtension: ext)
                }.value
                guard operationID == id, !Task.isCancelled else { return }
                let output = try await Task.detached(priority: .userInitiated) {
                    try ImagePipeline.process(input, exposureEV: ev, kelvin: cct)
                }.value
                guard operationID == id, !Task.isCancelled else { return }
                imported = input
                processed = output
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func render() async {
        guard let input = imported, !busy else { return }
        let id = UUID()
        operationID = id
        busy = true
        defer { if operationID == id { busy = false } }
        let ev = exposure, cct = kelvin
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try ImagePipeline.process(input, exposureEV: ev, kelvin: cct)
            }.value
            guard operationID == id else { return }
            processed = output
        } catch { if operationID == id { self.error = error.localizedDescription } }
    }

    func share() {
        guard let processed, !busy else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlassCam-\(UUID().uuidString).png")
            try processed.png.write(to: url, options: .atomic)
            sharedURL = url
            export = ExportFile(url: url)
        } catch { self.error = error.localizedDescription }
    }

    func cleanupExport() {
        // The sheet has finished; recipients have had the opportunity to copy the file.
        if let url = sharedURL { try? FileManager.default.removeItem(at: url) }
        sharedURL = nil
    }

}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var photo: PhotosPickerItem?
    @State private var filesPresented = false
    @State private var comparison = 0.5

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.065, blue: 0.08), .black,
                                    Color(red: 0.09, green: 0.065, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    imageArea
                    importButtons
                    controls
                    Text("EXPERIMENTAL SOURCE ADAPTER")
                        .font(.caption2.weight(.semibold)).tracking(1.8).foregroundStyle(.orange)
                    Text("Imported images are adapted from linear sRGB into the target camera color space. This is an effect preview, not a calibrated camera match. Factory CCT selects the profile’s illuminant interpolation; it does not recover scene white balance.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Preview and export: up to 2048 px • sRGB PNG • transparency flattened to black • source metadata omitted")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
        }
        .tint(.white)
        .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                model.selectFile(url)
            } catch { model.error = error.localizedDescription }
        }
        .onChange(of: photo) { _, selected in
            guard let selected else { return }
            model.selectPhoto(selected)
        }
        .sheet(item: $model.export, onDismiss: model.cleanupExport) { file in ShareSheet(url: file.url) }
        .alert("Couldn’t finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "Unknown error") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("GlassCam").font(.largeTitle.weight(.semibold)).tracking(-1.2)
                Text("HNCS  /  COLOR STUDY 01").font(.caption2.weight(.medium)).tracking(2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.share) {
                Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 48, height: 48)
            }.glassSurface().disabled(model.processed == nil || model.busy)
                .accessibilityLabel("Export processed PNG")
        }
    }

    private var imageArea: some View {
        VStack(spacing: 12) {
            ZStack {
                if let input = model.imported, let output = model.processed {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Image(uiImage: input.original).resizable().scaledToFit()
                            Image(uiImage: output.image).resizable().scaledToFit()
                                .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * comparison) }
                            Rectangle().fill(.white.opacity(0.85)).frame(width: 1)
                                .offset(x: geometry.size.width * comparison)
                        }
                    }.aspectRatio(CGFloat(input.width) / CGFloat(input.height), contentMode: .fit)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.aperture").font(.system(size: 56, weight: .ultraLight))
                        Text("A different kind of color.").font(.title3.weight(.medium))
                        Text("Import a photograph to explore the HNCS transform.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).frame(height: 310).padding(.horizontal)
                }
                if model.busy {
                    ProgressView("Developing color…").padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }.background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
            if let input = model.imported {
                HStack {
                    Text("HNCS").foregroundStyle(.white)
                    Spacer()
                    Text("ORIGINAL").foregroundStyle(.secondary)
                }.font(.caption2.weight(.semibold)).tracking(1.5)
                Slider(value: $comparison, in: 0...1).accessibilityLabel("Before and after comparison")
                Text("\(input.width) × \(input.height)  ·  \(input.sourceDescription)")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var importButtons: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 15)
            }.glassSurface()
            Button { filesPresented = true } label: {
                Label("Files / DNG", systemImage: "folder").frame(maxWidth: .infinity).padding(.vertical, 15)
            }.glassSurface()
        }.font(.subheadline.weight(.medium)).disabled(model.busy)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Develop").font(.headline); Spacer(); Text("FACTORY PROFILE").font(.caption2).tracking(1).foregroundStyle(.secondary) }
            HStack { Text("Exposure"); Spacer(); Text(String(format: "%+.2f EV", model.exposure)).monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
            Slider(value: $model.exposure, in: -2...2, step: 0.05) { editing in
                if !editing { Task { await model.render() } }
            }.accessibilityLabel("Exposure compensation")
            HStack { Text("Factory CCT"); Spacer(); Text("\(Int(model.kelvin)) K").monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
            Slider(value: $model.kelvin, in: 2000...10000, step: 50) { editing in
                if !editing { Task { await model.render() } }
            }.accessibilityLabel("Factory correlated color temperature")
            Button("Reset to 0 EV / 6500 K") {
                model.exposure = 0; model.kelvin = 6500
                Task { await model.render() }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).glassSurface().disabled(model.busy)
    }
}

private struct GlassSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14), lineWidth: 0.7))
    }
}

private extension View {
    func glassSurface() -> some View { modifier(GlassSurface()) }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
