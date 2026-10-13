import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// One retained, committed camera result. The delivery reservation prevents
/// another shutter while this owner is being written or awaits an explicit Open.
struct PendingCapturedPhoto: Identifiable {
    enum Storage {
        case file(SourceImageFile)
        case memory(Data) // Bounded to one DNG, only if disk retention failed.
    }
    let id = UUID()
    let ticket: UUID
    let storage: Storage
    let exportSettings: ExportSettings
    let recipe: ProcessingRecipe
    let warning: String?
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var pendingCapture: PendingCapturedPhoto?
    @Published private(set) var isRetainingCapture = false
    @Published private(set) var captureSlotAvailable = true
    private var captureReservation: UUID?
    // Unlike operationID, ordinary recipe rerenders do not change admission.
    private var captureAdmissionGeneration = UUID()

    func beginCameraSession() -> UUID {
        captureAdmissionGeneration = UUID()
        return captureAdmissionGeneration
    }

    func reserveCaptureDelivery(ticket: UUID) -> Bool {
        guard captureSlotAvailable, ticket == captureAdmissionGeneration else { return false }
        captureReservation = ticket
        captureSlotAvailable = false
        return true
    }

    func releaseCaptureDelivery(ticket: UUID) {
        guard captureReservation == ticket else { return }
        captureReservation = nil
        captureSlotAvailable = true
    }

    @Published var imported: ImportedImage?
    @Published var processed: ProcessedImage?
    @Published var colorMode: ColorMode = .hncs { didSet { persistRecipe() } }
    @Published var simulationIndex = 0 { didSet { persistRecipe() } }
    @Published var exposure = 0.0 { didSet { persistRecipe() } }
    @Published var kelvin = 6500.0 { didSet { persistRecipe() } }
    @Published var hncs = HNCSSettings.standard { didSet { persistRecipe() } }
    private let defaults: UserDefaults
    private static let recipeKey = "editor.processingRecipe.revision8.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recipeKey),
           let saved = try? JSONDecoder().decode(ProcessingRecipe.self, from: data), saved.isValid {
            colorMode = saved.mode; simulationIndex = saved.simulationIndex
            exposure = saved.exposureEV; kelvin = saved.illuminantKelvin; hncs = saved.hncs
        }
    }

    private func persistRecipe() {
        guard recipe.isValid, let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: Self.recipeKey)
    }
    @Published var busy = false
    @Published var error: String?
    @Published var export: ExportFile?
    @Published var fileSave: ExportFile?
    @Published var notice: String?
    @Published var exportProgress = 0.0
    @Published var canCancelExport = false
    private var exportTask: Task<Void, Never>?
    private var exportWork: Task<TemporaryHEIFFile, Swift.Error>?
    private var exportCancellation: ImageOperationCancellation?
    enum Destination: Equatable { case share, files, photos }

    private var recipe: ProcessingRecipe {
        ProcessingRecipe(mode: colorMode, exposureEV: exposure, illuminantKelvin: kelvin,
                         simulationIndex: simulationIndex, seed: 0, hncs: hncs)
    }

    @Published var canCancelImageWork = false
    private var cancelImageWorker: (() -> Void)?
    var hasPendingChanges: Bool { imported != nil && processed?.recipe != recipe }
    var canDeliver: Bool { processed != nil && !busy && !hasPendingChanges }
    private var importTask: Task<Void, Never>?
    private var operationID = UUID()

    func selectPhoto(_ selected: PhotosPickerItem) {
        captureAdmissionGeneration = UUID()
        beginImport {
            guard let data = try await selected.loadTransferable(type: Data.self) else {
                throw PipelineError.invalidImage
            }
            let ext = selected.supportedContentTypes.contains(where: { $0.conforms(to: .rawImage) }) ? "dng" : nil
            return (data, ext)
        }
    }

    func selectFile(_ url: URL) {
        captureAdmissionGeneration = UUID()
        beginImport {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            return (data, url.pathExtension)
        }
    }

    func selectCapture(_ data: Data, settings: ExportSettings,
                       capturedRecipe: ProcessingRecipe, ticket: UUID) {
        // Success is never canceled just because Close/new work changed admission.
        // The reservation remains held until a decoded copy has a new source owner.
        isRetainingCapture = true
        Task { @MainActor in
            let storage: PendingCapturedPhoto.Storage
            let warning: String?
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try SourceImageFile(data: data, fileExtension: "dng")
                }.value
                storage = .file(file); warning = nil
            } catch {
                // Disk failure must not discard the only committed photo. The
                // occupied slot bounds this fallback to one in-memory DNG.
                storage = .memory(data)
                warning = "Couldn’t retain the completed photo on disk: \(error.localizedDescription) It’s temporarily kept in memory. Open it before closing the app."
            }
            let retained = PendingCapturedPhoto(ticket: ticket, storage: storage,
                exportSettings: settings, recipe: capturedRecipe, warning: warning)
            pendingCapture = retained
            isRetainingCapture = false
            if ticket == captureAdmissionGeneration {
                // Matching admission permits replacing an older recipe render,
                // but never a newer source selection, camera session or export.
                importRetainedCapture(retained)
            }
        }
    }

    func openPendingCapture() {
        guard !busy, let pendingCapture else { return }
        importRetainedCapture(pendingCapture)
    }

    private func importRetainedCapture(_ retained: PendingCapturedPhoto) {
        captureAdmissionGeneration = UUID()
        beginImport(exportSettings: retained.exportSettings, explicitRecipe: retained.recipe,
                    onSourceRetained: { [weak self] in
                        guard let self, self.pendingCapture?.id == retained.id else { return }
                        self.pendingCapture = nil
                        self.releaseCaptureDelivery(ticket: retained.ticket)
                    }) {
            switch retained.storage {
            case .file(let file):
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: file.url)
                }.value
                return (data, "dng")
            case .memory(let data): return (data, "dng")
            }
        }
    }

    private func adoptRecipeSnapshot(_ snapshot: ProcessingRecipe) {
        colorMode = snapshot.mode; simulationIndex = snapshot.simulationIndex
        exposure = snapshot.exposureEV; kelvin = snapshot.illuminantKelvin; hncs = snapshot.hncs
    }

    /// The token guards every suspension point: an older provider transfer or decode
    /// may finish after cancellation, but can never replace the latest selection.
    private func beginImport(exportSettings: ExportSettings = .native,
                             explicitRecipe: ProcessingRecipe? = nil,
                             onSourceRetained: (() -> Void)? = nil,
                             _ fetch: @escaping @MainActor () async throws -> (Data, String?)) {
        importTask?.cancel()
        cancelImageWorker?()
        let id = UUID()
        operationID = id
        busy = true; canCancelImageWork = true
        error = nil; notice = nil
        let settings = explicitRecipe ?? recipe
        // Install operation/busy guards before publishing the captured controls.
        // Their onChange callbacks and a queued camera onDismiss render then see
        // the same snapshot, and cannot start a competing render during import.
        if explicitRecipe != nil { adoptRecipeSnapshot(settings) }
        importTask = Task { @MainActor in
            defer {
                if operationID == id {
                    if Task.isCancelled { notice = "Image operation cancelled." }
                    busy = false; importTask = nil; canCancelImageWork = false; cancelImageWorker = nil
                }
            }
            do {
                let (data, ext) = try await fetch()
                guard operationID == id, !Task.isCancelled else { return }
                let decode = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let input = try ImagePipeline.load(data: data, fileExtension: ext, exportSettings: exportSettings)
                    try Task.checkCancellation()
                    return input
                }
                cancelImageWorker = { decode.cancel() }
                let input = try await decode.value
                guard operationID == id, !Task.isCancelled else { return }
                // Retain a successfully decoded capture even if its effect fails.
                imported = input
                processed = nil
                onSourceRetained?()
                let rendering = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let output = try ImagePipeline.process(input, recipe: settings)
                    try Task.checkCancellation()
                    return output
                }
                cancelImageWorker = { rendering.cancel() }
                let output = try await rendering.value
                guard operationID == id, !Task.isCancelled else { return }
                processed = output
            } catch is CancellationError {
                if operationID == id { notice = "Image operation cancelled." }
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func cancelImageOperation() {
        guard canCancelImageWork else { return }
        canCancelImageWork = false
        cancelImageWorker?()
        importTask?.cancel()
        notice = "Cancelling after the current image operation…"
        // Busy stays set until work returns; no competing RAW decode is started.
    }

    func renderIfNeeded() async { if hasPendingChanges { await render() } }

    func render() async {
        guard let input = imported, !busy else { return }
        let id = UUID()
        operationID = id
        busy = true; canCancelImageWork = true; error = nil; notice = nil
        defer {
            if operationID == id { busy = false; canCancelImageWork = false; cancelImageWorker = nil }
        }
        let settings = recipe
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try ImagePipeline.process(input, recipe: settings)
            try Task.checkCancellation()
            return output
        }
        cancelImageWorker = { work.cancel() }
        do {
            let output = try await work.value
            guard operationID == id, !work.isCancelled else {
                if operationID == id { notice = "Image operation cancelled." }
                return
            }
            processed = output
        } catch is CancellationError {
            if operationID == id { notice = "Image operation cancelled." }
        } catch { if operationID == id { self.error = error.localizedDescription } }
    }

    func share() { deliver(.share) }
    func saveToFiles() { deliver(.files) }
    func saveToPhotos() { deliver(.photos) }

    func cancelExport() {
        guard canCancelExport else { return }
        canCancelExport = false
        exportCancellation?.cancel()
        exportWork?.cancel()
        exportTask?.cancel()
        // Keep busy until the current decoder/encoder call returns. It has no
        // synchronous cancellation API, and another export must not overlap it.
        notice = "Cancelling after the current image operation…"
    }

    private func deliver(_ destination: Destination) {
        guard let processed, canDeliver else { return }
        captureAdmissionGeneration = UUID()
        let id = UUID()
        operationID = id
        busy = true; error = nil; notice = nil; exportProgress = 0
        exportTask = Task { @MainActor in
            defer {
                if operationID == id {
                    busy = false; canCancelExport = false
                    exportWork = nil; exportTask = nil; exportCancellation = nil
                }
            }
            do {
                if destination == .photos { try await HEIFSaveDelivery.authorizePhotos() }
                try Task.checkCancellation()
                canCancelExport = true
                let cancellation = ImageOperationCancellation()
                exportCancellation = cancellation
                let work = Task.detached(priority: .userInitiated) {
                    let file = TemporaryHEIFFile()
                    try ImagePipeline.writeHEIF(processed, to: file.url, isCancelled: { cancellation.isCancelled }) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == id else { return }
                            self.exportProgress = progress
                        }
                    }
                    try Task.checkCancellation()
                    return file
                }
                exportWork = work
                let file = try await work.value
                try Task.checkCancellation()
                guard operationID == id else { return }
                canCancelExport = false
                switch destination {
                case .share: export = ExportFile(file: file)
                case .files: fileSave = ExportFile(file: file)
                case .photos:
                    // Photos transactions cannot be cancelled after submission.
                    try await HEIFSaveDelivery.saveToPhotos(file)
                    notice = "Saved original 10-bit HEIF to Photos."
                }
            } catch is CancellationError {
                if operationID == id { notice = "Export cancelled. No save was submitted." }
            } catch {
                if operationID == id { self.error = error.localizedDescription }
            }
        }
    }

}

/// Providers retain this owner through any outstanding file request, so dismissing
/// the sheet cannot eagerly delete a file that is still being handed to a recipient.
final class TemporaryHEIFFile: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassCam-\(UUID().uuidString).heic")
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let file: TemporaryHEIFFile
}

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var photo: PhotosPickerItem?
    @State private var filesPresented = false
    @State private var cameraPresented = false
    @State private var cameraTicket = UUID()
    @State private var comparison = 0.5

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.065, blue: 0.08), .black,
                                    Color(red: 0.09, green: 0.065, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if model.busy && model.canCancelExport {
                        HStack {
                            ProgressView(value: model.exportProgress)
                            Button("Cancel export", action: model.cancelExport)
                        }
                    }
                    if model.busy && model.canCancelImageWork {
                        Button("Cancel image operation", action: model.cancelImageOperation)
                    }
                    if model.hasPendingChanges && !model.busy {
                        Text("These settings have not been rendered. Save and share are paused until the preview succeeds.")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Retry effect") { Task { await model.render() } }.glassSurface()
                    }
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.isRetainingCapture {
                        Text("Retaining completed capture…").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let pending = model.pendingCapture {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("A completed capture is ready with its shutter-time recipe.")
                            if let warning = pending.warning { Text(warning).foregroundStyle(.orange) }
                            Button("Open captured photo", action: model.openPendingCapture).disabled(model.busy)
                        }.font(.footnote)
                    }
                    imageArea
                    Button {
                        cameraTicket = model.beginCameraSession()
                        cameraPresented = true
                    } label: {
                        Label("Open ProRAW camera", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity).padding(14)
                    }.glassSurface().disabled(model.busy)
                    importButtons
                    controls
                    Text("EXPERIMENTAL SOURCE ADAPTER")
                        .font(.caption2.weight(.semibold)).tracking(1.8).foregroundStyle(.orange)
                    Text(model.colorMode == .hncs
                         ? "Imported images are adapted from linear sRGB into the target camera color space. This is an effect preview, not a calibrated camera match. Virtual capture CCT defines a synthetic baseline for Apple-decoded linear RGB. A white-balance preset separately replaces virtual-camera target gains and selects factory interpolation; it does not recover scene white balance."
                         : "FFCS uses the supplied XH2S reference LUTs and research rendering pipeline with fixed grain seed 0. Imported images enter as linear sRGB. This is an experimental effect, not a calibrated Fujifilm camera match.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Preview: up to 2048 px / high-precision SDR Float → RGBA16F • export: full source or selected lens output / 10-bit SDR HEIF")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Save keeps the original 10-bit HEIF. Sharing offers HEIF first and an on-demand compatibility image; receiver behavior still needs device testing.")
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
        .onChange(of: model.colorMode) { _, _ in
            if !cameraPresented { Task { await model.render() } }
        }
        .onChange(of: model.simulationIndex) { _, _ in
            if !cameraPresented { Task { await model.render() } }
        }
        .onChange(of: model.hncs) { _, _ in
            if !cameraPresented { Task { await model.render() } }
        }
        .fullScreenCover(isPresented: $cameraPresented, onDismiss: {
            // Camera controls may change the selected recipe even without a shot.
            // Restore editor control/preview coherence after returning.
            if model.captureSlotAvailable { Task { await model.renderIfNeeded() } }
        }) {
            let sessionTicket = cameraTicket
            CameraView(colorMode: $model.colorMode, simulationIndex: $model.simulationIndex,
                       exposureEV: $model.exposure, illuminantKelvin: $model.kelvin, hncs: $model.hncs,
                       thumbnail: model.processed?.image ?? model.imported?.original,
                       captureSlotAvailable: model.captureSlotAvailable,
                       reserveCapture: { model.reserveCaptureDelivery(ticket: sessionTicket) },
                       onCaptureFailure: { model.releaseCaptureDelivery(ticket: sessionTicket) },
                       onCapture: { data, settings, capturedRecipe in
                           model.selectCapture(data, settings: settings, capturedRecipe: capturedRecipe, ticket: sessionTicket)
                           // An old session's late success must not dismiss a new camera.
                           if cameraTicket == sessionTicket { cameraPresented = false }
                       }, onClose: {
                           if cameraTicket == sessionTicket { cameraPresented = false }
                       })
        }
        .sheet(item: $model.fileSave) { exported in
            HEIFFileSaveSheet(file: exported.file) { saved in
                model.fileSave = nil
                if saved { model.notice = "Saved original 10-bit HEIF to Files." }
            }
        }
        .sheet(item: $model.export) { export in ShareSheet(file: export.file) }
        .alert("Couldn’t finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "Unknown error") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("GlassCam").font(.largeTitle.weight(.semibold)).tracking(-1.2)
                Text("\(model.colorMode.title)  /  COLOR STUDY 01").font(.caption2.weight(.medium)).tracking(2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Save HEIF to Photos", action: model.saveToPhotos)
                Button("Save HEIF to Files", action: model.saveToFiles)
            } label: {
                Image(systemName: "square.and.arrow.down").font(.title3).frame(width: 48, height: 48)
            }.glassSurface().disabled(!model.canDeliver)
                .accessibilityLabel("Save original 10-bit HEIF")
            Button(action: model.share) {
                Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 48, height: 48)
            }.glassSurface().disabled(!model.canDeliver)
                .accessibilityLabel("Export 10-bit SDR HEIF")
        }
    }

    private var imageArea: some View {
        VStack(spacing: 12) {
            ZStack {
                if model.imported != nil, let output = model.processed {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            PrecisionPreview(source: output.comparisonSource, processed: output.image,
                                             comparisonFraction: CGFloat(comparison))
                            Rectangle().fill(.white.opacity(0.85)).frame(width: 1)
                                .offset(x: geometry.size.width * comparison)
                        }
                    }.aspectRatio(CGFloat(output.image.width) / CGFloat(output.image.height), contentMode: .fit)
                } else if let input = model.imported {
                    PrecisionPreview(source: input.original)
                        .aspectRatio(CGFloat(input.width) / CGFloat(input.height), contentMode: .fit)
                        .accessibilityLabel("Retained high-precision source preview; effect is pending")
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.aperture").font(.system(size: 56, weight: .ultraLight))
                        Text("A different kind of color.").font(.title3.weight(.medium))
                        Text("Import a photograph to explore the \(model.colorMode.title) transform.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).frame(height: 310).padding(.horizontal)
                }
                if model.busy {
                    ProgressView("Processing image…").padding(22).glassSurface()
                }
            }.background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
            if let input = model.imported {
                HStack {
                    Text(model.processed?.recipe.displayName ?? model.colorMode.title).foregroundStyle(.white)
                    Spacer()
                    Text("ORIGINAL").foregroundStyle(.secondary)
                }.font(.caption2.weight(.semibold)).tracking(1.5)
                Slider(value: $comparison, in: 0...1).accessibilityLabel("Before and after comparison").disabled(model.processed == nil)
                Text("\(model.processed?.image.width ?? input.width) × \(model.processed?.image.height ?? input.height) preview  ·  \(input.sourceDescription)")
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
            HStack { Text("Develop").font(.headline); Spacer(); Text(model.colorMode == .hncs ? "FACTORY PROFILE" : "XH2S REFERENCE LUT").font(.caption2).tracking(1).foregroundStyle(.secondary) }
            if ColorMode.allCases.count > 1 {
                Picker("Color engine", selection: $model.colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented)
            }
            if model.colorMode == .ffcs {
                Picker("Simulation", selection: $model.simulationIndex) {
                    ForEach(FFCSEngine.simulations) { simulation in
                        Text(simulation.name).tag(simulation.id)
                    }
                }.pickerStyle(.menu)
            }
            HStack { Text("Exposure"); Spacer(); Text(String(format: "%+.2f EV", model.exposure)).monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
            Slider(value: $model.exposure, in: -2...2, step: 0.05) { editing in
                if !editing { Task { await model.render() } }
            }.accessibilityLabel("Exposure compensation")
            if model.colorMode == .hncs {
                HNCSPresetControls(settings: $model.hncs)
                HStack { Text("Virtual capture CCT"); Spacer(); Text("\(Int(model.kelvin)) K").monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
                Slider(value: $model.kelvin, in: 2000...10000, step: 50) { editing in
                    if !editing { Task { await model.render() } }
                }.accessibilityLabel("Virtual capture correlated color temperature")
            }
            Button(model.colorMode == .hncs ? "Reset HNCS effect" : "Reset exposure to 0 EV") {
                model.exposure = 0
                if model.colorMode == .hncs { model.kelvin = 6500; model.hncs = .standard }
                Task { await model.render() }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).glassSurface().disabled(model.busy)
    }
}

/// Both editor and camera edit the same persisted, immutable-on-render recipe.
struct HNCSPresetControls: View {
    @Binding var settings: HNCSSettings
    private var selectedPreset: HNCSEngine.Preset? { HNCSEngine.presets.first { $0.id == settings.presetKey } }

    var body: some View {
        Picker("Phocus preset", selection: $settings.presetKey) {
            ForEach(HNCSEngine.presets) { preset in Text(preset.name).tag(preset.id) }
        }
        Picker("Film curve", selection: $settings.filmCurve) {
            ForEach(HNCSFilmCurve.allCases) { curve in Text(curve.title).tag(curve) }
        }
        Picker("Working space", selection: $settings.workingSpace) {
            ForEach(HNCSWorkingSpace.allCases) { space in Text(space.title).tag(space) }
        }
        Picker("Rendering intent", selection: $settings.intent) {
            ForEach(HNCSIntent.allCases) { intent in Text(intent.title).tag(intent) }
        }
        Toggle("Preset tone curve", isOn: $settings.applyToneCurve)
        Toggle("Preset grain (portable)", isOn: $settings.applyGrain)
            .disabled((selectedPreset?.flags ?? 0) & 4 == 0)
        Toggle("Preset sharpening (portable)", isOn: $settings.applySharpness)
            .disabled(settings.presetKey == "standard" || (selectedPreset?.flags ?? 0) & (8 | 16) == 0)
        if settings.presetKey == "standard" {
            Text("Standard preserves the unadjusted core render and bypasses preset grain and sharpening.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Override factory CCT", isOn: Binding(
            get: { settings.factoryKelvinOverride != nil },
            set: { settings.factoryKelvinOverride = $0 ? 6500 : nil }))
        if let kelvin = settings.factoryKelvinOverride {
            Stepper("Factory CCT: \(Int(kelvin)) K", value: Binding(
                get: { settings.factoryKelvinOverride ?? 6500 },
                set: { settings.factoryKelvinOverride = $0 }), in: 2000...10000, step: 50)
        }
        Text("Apple-decoded RGB uses a synthetic virtual-camera bridge, not measured capture WB. WB presets replace target gains; the virtual capture CCT/baseline stays separate. Factory CCT override changes matrix/LUT interpolation only.")
            .font(.caption).foregroundStyle(.secondary)
        Text("As Shot uses Standard because Apple inputs have no Phocus curve metadata. Standard, Low and High share the recovered V1 family; Old Standard is distinct only in legacy space. Reproduction uses the pure curve. Grain and sharpening follow the portable reference, not proprietary Phocus kernels.")
            .font(.caption).foregroundStyle(.secondary)
        if (selectedPreset?.flags ?? 0) & 4 != 0 && settings.applyGrain {
            Text("Grain uses image dimensions and whole-image statistics. Its preview pattern can differ from the full-source export, even with the same recipe.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if settings.crop == .centeredSquare {
            Text("Centered 1:1 crop. Output keeps genuine pixels; its megapixel count is lower than the full-sensor selection.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
    let file: TemporaryHEIFFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let configuration = ShareDelivery.makeConfiguration(for: file)
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        // Direct save is a separate HEIF-only route, never a share fallback.
        controller.excludedActivityTypes = [.saveToCameraRoll]
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
