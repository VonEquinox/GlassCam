import SwiftUI
import AVFoundation
import UIKit

/// Full-window live camera. Exact photo effects run only after DNG capture.
/// An opt-in approximate GPU color proxy affects the central viewfinder only.
/// No SwiftUI view, glass overlay, peripheral image, or screenshot enters that DNG.
struct CameraView: View {
    @Binding var colorMode: ColorMode
    @Binding var simulationIndex: Int
    @Binding var exposureEV: Double
    @Binding var illuminantKelvin: Double
    @Binding var hncs: HNCSSettings
    @Binding var effects: EffectToggles
    @Binding var ffcs: FFCSSettings
    let thumbnail: PreviewRaster?
    let captureSlotAvailable: Bool
    let reserveCapture: () -> Bool
    let onCaptureFailure: () -> Void
    let onCapture: (Data, ExportSettings, ProcessingRecipe) -> Void
    let onClose: () -> Void
    @StateObject private var camera = CameraController()
    @StateObject private var settings = CameraSettingsStore()
    @State private var selectedLens: CameraController.Mode = .main
    @State private var captureError: String?
    @State private var isClosing = false
    @State private var experimentalLiveColor = false
    @State private var liveProxyStatus = LiveColorProxyStatus.off
    @State private var gridVisible = true
    @State private var activePanel: CameraPanel?
    @State private var compactPanelOffered = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let framing = CameraFraming(size: proxy.size,
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ?? 1,
                                        cropToSquare: colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare,
                                        centerHorizontalFieldOfView: camera.geometry?.centerHorizontalFieldOfView,
                                        peripheralHorizontalFieldOfView: camera.geometry?.peripheralHorizontalFieldOfView,
                                        peripheralAspectRatio: orientedPeripheralAspectRatio)
            let chrome = CameraChromeLayout(framing: framing, safeArea: proxy.safeAreaInsets,
                                            needsAccessiblePanel: dynamicTypeSize.isAccessibilitySize)
            ZStack(alignment: .topLeading) {
                Color.black
                // Only the independently captured wider physical lens appears here.
                // Ultrawide has no wider lens: its approved perimeter remains black.
                if let layer = camera.peripheralPreviewLayer, let extent = framing.peripheral,
                   framing.hasPeripheralCoverage {
                    CameraPreview(layer: layer, gravity: .resizeAspect)
                        .frame(width: extent.width, height: extent.height)
                        .position(x: extent.midX, y: extent.midY)
                }
                // One clear native pane per natural spare region. No glass control
                // backgrounds, merging container, edge copies or simulated frosting.
                ForEach(Array(framing.perimeter.enumerated()), id: \.offset) { _, pane in
                    Color.clear
                        .frame(width: pane.width, height: pane.height)
                        .modifier(CameraPaneGlass())
                        .clipped()
                        .position(x: pane.midX, y: pane.midY)
                        .allowsHitTesting(false)
                }
                // Opaque-backed, maximum aspect-fit photograph above the panes.
                // There is no glass modifier or rounded clipping on the photograph.
                if let layer = camera.centerPreviewLayer, camera.geometry != nil {
                    CameraPreview(layer: layer, gravity: .resizeAspect)
                        .frame(width: framing.sourcePhoto.width, height: framing.sourcePhoto.height)
                        .background(.black)
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .clipped()
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .accessibilityLabel("Unprocessed system camera preview inside the photograph frame")
                }
                if let source = camera.centerLiveSource, camera.geometry != nil {
                    LiveColorProxy(source: source, recipe: liveRecipe,
                                   enabled: experimentalLiveColor && scenePhase == .active && !camera.isPreviewFrozen,
                                   cameraReady: camera.isReady && coverageAvailable(framing)) { status in
                        liveProxyStatus = status
                    }
                    .frame(width: framing.sourcePhoto.width, height: framing.sourcePhoto.height)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .clipped()
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false)
                }
                PhotoFrameGuide(gridVisible: gridVisible)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if !camera.isCapturing && (!camera.isReady || !coverageAvailable(framing)) {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(camera.isReady && !coverageAvailable(framing)
                             ? "The wider camera can’t cover this window. Rotate or resize the window, or choose Ultra wide in settings."
                             : camera.status).font(.callout).multilineTextAlignment(.center)
                        if !camera.isReady && !camera.isConfiguring {
                            Button("Retry camera") { restartCamera() }.padding(10)
                        }
                        if chrome.style == .separate {
                            Button("Open camera controls") { activePanel = .compact }
                                .frame(minHeight: 44)
                        }
                    }
                    .padding(16)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .background(.black)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                }
                if chrome.style == .separate && (camera.isCapturing || (camera.isReady && coverageAvailable(framing))) {
                    // The initial plain control panel explains this genuine gesture.
                    // It never changes the photo rect; no invisible shutter is used.
                    Color.clear.contentShape(Rectangle())
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .onTapGesture { activePanel = .compact }
                        .accessibilityElement()
                        .accessibilityLabel("Viewfinder. Open camera controls")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { activePanel = .compact }
                }
                controls(framing: framing, chrome: chrome)
                if camera.isPreviewFrozen {
                    Text(camera.isCapturing ? "Preview paused · Capturing RAW" : "Preview paused")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(8)
                        .frame(width: framing.photo.width)
                        .position(x: framing.photo.midX, y: framing.photo.minY + 20)
                        .allowsHitTesting(false)
                }
                CameraOrientationObserver { camera.updateOrientation($0) }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: chrome.style, initial: true) { _, style in
                offerCompactPanel(for: style)
            }
            .onChange(of: camera.geometry?.photoAspectRatio) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .onChange(of: camera.isReady) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .onChange(of: camera.isPreviewFrozen) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .sheet(item: $activePanel) { panel in
                cameraPanel(panel, framing: framing)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.black)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(.white)
        .buttonStyle(.plain)
        .onAppear { restartCamera() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera.stop() }
            else if phase == .active { restartCamera() }
        }
        .onChange(of: selectedLens) { _, _ in restartCamera() }
        .onChange(of: settings.centerPreviewLongEdge) { _, _ in restartCamera() }
        .onChange(of: settings.peripheralPreviewLongEdge) { _, _ in restartCamera() }
        .alert("Couldn’t capture ProRAW", isPresented: Binding(get: { captureError != nil }, set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) { captureError = nil }
        } message: { Text(captureError ?? "Unknown capture error") }
    }

    @ViewBuilder
    private func controls(framing: CameraFraming, chrome: CameraChromeLayout) -> some View {
        switch chrome.style {
        case .portrait:
            VStack(spacing: 6) {
                HStack {
                    flashOff
                    Spacer(minLength: 8)
                    wordmark
                    Spacer(minLength: 8)
                    gridButton
                }
                captureMetadata
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 10) {
                photoMode
                HStack {
                    thumbnailButton
                    Spacer(minLength: 12)
                    shutter(coverageAvailable: coverageAvailable(framing), diameter: 82)
                    Spacer(minLength: 12)
                    settingsButton
                }
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .landscape:
            VStack(spacing: 12) {
                wordmark.font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                flashOff
                Text(photoAspectLabel).font(.caption.weight(.semibold))
                lensMenu
                Text("RAW").font(.caption.weight(.semibold)).tracking(2)
                gridButton
                Spacer(minLength: 0)
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 12) {
                photoMode
                thumbnailButton
                Spacer(minLength: 0)
                shutter(coverageAvailable: coverageAvailable(framing), diameter: 82)
                Spacer(minLength: 0)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactHorizontal:
            HStack(spacing: 8) {
                flashOff
                Spacer(minLength: 0)
                captureMetadata
                Spacer(minLength: 0)
                gridButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            HStack {
                thumbnailButton
                Spacer(minLength: 8)
                shutter(coverageAvailable: coverageAvailable(framing), diameter: 56)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactVertical:
            VStack(spacing: 8) {
                flashOff
                lensMenu
                Spacer(minLength: 0)
                gridButton
                thumbnailButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                photoMode
                Spacer(minLength: 0)
                shutter(coverageAvailable: coverageAvailable(framing), diameter: 56)
                Spacer(minLength: 0)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .separate:
            EmptyView()
        }
    }

    private var wordmark: some View {
        Text("GLASSCAM").font(.system(size: 14, weight: .semibold))
            .tracking(3.5).lineLimit(1).minimumScaleFactor(0.65)
            .accessibilityLabel("GlassCam")
    }

    private var flashOff: some View {
        // Photo settings use the backend’s default flash-off path. This is status,
        // not a pretend button; no unsupported flash feature is advertised.
        Image(systemName: "bolt.slash").font(.system(size: 21, weight: .light))
            .frame(width: 44, height: 44).accessibilityLabel("Flash off")
    }

    private var gridButton: some View {
        Button { gridVisible.toggle() } label: {
            Image(systemName: "grid").font(.system(size: 21, weight: .light))
                .foregroundStyle(gridVisible ? .white : .white.opacity(0.55))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(gridVisible ? "Hide composition grid" : "Show composition grid")
        .accessibilityValue(gridVisible ? "On" : "Off")
    }

    private var captureMetadata: some View {
        HStack(spacing: 14) {
            Text(photoAspectLabel)
            Text("·")
            lensMenu
            Text("·")
            Text("RAW")
        }
        .font(.system(size: 12, weight: .semibold)).tracking(1.5)
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    private var photoMode: some View {
        let isApproximate = experimentalLiveColor && liveProxyStatus.isShowingEffect
            && camera.isReady && !camera.isPreviewFrozen
        return Text(isApproximate ? "Photo · Approx. preview" : "Photo")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white).multilineTextAlignment(.center)
            .accessibilityLabel(isApproximate ? "Photo mode. Approximate live color preview" : "Photo mode")
    }

    private var photoAspectLabel: String {
        if colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare { return "1:1 crop" }
        guard let size = camera.geometry?.sensorPhotoDimensions,
              size.width > 0, size.height > 0 else { return "—" }
        let long = Int(max(size.width, size.height))
        let short = Int(min(size.width, size.height))
        var a = long, b = short
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return "\(long / a):\(short / a)"
    }

    private var lensLabel: String {
        // Main is its physical lens at the backend’s verified 1× zoom. Neither
        // ultrawide nor tele is assigned an invented device-dependent multiplier.
        switch selectedLens {
        case .main: return "1×"
        case .ultraWide: return "Ultra"
        case .telephoto: return "Tele"
        }
    }

    private var lensMenu: some View {
        Menu {
            Picker("Physical camera", selection: $selectedLens) {
                ForEach(CameraController.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
        } label: {
            Text(lensLabel).font(.system(size: 12, weight: .semibold))
                .lineLimit(1).frame(minWidth: 44, minHeight: 44)
        }
        .disabled(camera.isCapturing || camera.isConfiguring)
        .accessibilityLabel("Physical camera: \(selectedLens.title)")
    }

    private var thumbnailButton: some View {
        Button(action: closeCamera) {
            Group {
                if let thumbnail {
                    PrecisionPreview(source: thumbnail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 21, weight: .light))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
        }
        .accessibilityLabel(camera.isCapturing ? "Stop capture and open editor"
                            : thumbnail == nil ? "Open editor and import a photo" : "Open photo in editor")
    }

    private var settingsButton: some View {
        Button { activePanel = .settings } label: {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 21, weight: .light))
                .frame(width: 44, height: 44)
        }
        .disabled(camera.isCapturing || camera.isConfiguring)
        .accessibilityLabel("Camera settings and photo effects")
    }

    private var liveRecipe: LiveColorRecipe {
        LiveColorRecipe(mode: colorMode, simulationIndex: colorMode == .ffcs ? simulationIndex : 0,
                        exposureEV: exposureEV, illuminantKelvin: colorMode == .hncs ? illuminantKelvin : 5500,
                        hncs: colorMode == .hncs ? hncs : .standard, effects: effects,
                        ffcs: colorMode == .ffcs ? ffcs : .standard)
    }

    private func cameraPanel(_ panel: CameraPanel, framing: CameraFraming) -> some View {
        NavigationStack {
            Form {
                if panel == .compact {
                    Section {
                        Text("This window has too little space around the full photograph for controls. Return to the viewfinder for an unobstructed view, then tap it to reopen these controls.")
                            .font(.footnote)
                        HStack {
                            thumbnailButton
                            Spacer()
                            shutter(coverageAvailable: coverageAvailable(framing), diameter: 82)
                            Spacer()
                            gridButton
                        }
                        .frame(maxWidth: .infinity)
                        if camera.isPreviewFrozen { Text(camera.isCapturing ? "Preview paused · Capturing RAW" : "Preview paused") }
                        else if !camera.isReady { Text(camera.status).font(.footnote) }
                    } header: { Text("Photo controls") }
                }
                Section("Camera") {
                    Picker("Physical camera", selection: $selectedLens) {
                        ForEach(CameraController.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Toggle("Composition grid", isOn: $gridVisible)
                    LabeledContent("Photo aspect", value: photoAspectLabel)
                    if colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare {
                        Text("Output choices below describe the full sensor. The square export keeps its center at the same pixel scale; no upsampling.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Flash", value: "Off")
                    if !captureSlotAvailable {
                        Text("A previous capture is finishing or waiting in the editor. Open that photo before taking another.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if camera.supportedOutputOptions.isEmpty {
                        Text("Output unavailable for this camera configuration")
                    } else {
                        if selectedOutput == nil { Text("Saved output is unavailable. Choose a supported size.") }
                        Picker("\(selectedLens.title) output", selection: outputSelection) {
                            ForEach(camera.supportedOutputOptions) { option in
                                Text("\(option.megapixels) MP · \(option.width) × \(option.height)")
                                    .tag(option.megapixels)
                            }
                        }
                    }
                }.disabled(camera.isCapturing || camera.isConfiguring)
                Section {
                    Picker("Color engine", selection: $colorMode) {
                        ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    if colorMode == .ffcs {
                        FFCSReferenceControls(settings: $ffcs, simulationIndex: $simulationIndex)
                    }
                    LabeledContent("Exposure", value: String(format: "%+.2f EV", exposureEV))
                    Slider(value: $exposureEV, in: -2...2, step: 0.05)
                        .accessibilityLabel("Photo effect exposure")
                    if colorMode == .hncs {
                        HNCSPresetControls(settings: $hncs)
                        LabeledContent("Virtual capture CCT", value: "\(Int(illuminantKelvin)) K")
                        Slider(value: $illuminantKelvin, in: 2000...10000, step: 50)
                            .accessibilityLabel("Virtual capture correlated color temperature")
                        Text("Synthetic baseline for Apple-decoded RGB, not measured camera WB. Preset target gains are resolved separately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    EffectToggleControls(effects: $effects, mode: colorMode, hncs: hncs)
                    Button("Reset effect adjustments") {
                        exposureEV = 0
                        if colorMode == .hncs { illuminantKelvin = 6500; hncs = .standard }
                    }
                } header: { Text("Photo effects") }
                  footer: { Text("\(colorMode == .ffcs ? FFCSEngine.simulationName(at: simulationIndex) : colorMode.title) is applied after capture. Compare, save and share in the editor.") }
                  .disabled(camera.isCapturing)
                Section {
                    Toggle("Experimental live color (approx.)", isOn: $experimentalLiveColor)
                    Text("Central color only. Periphery stays unprocessed. No grain, blur or spatial effects.")
                    Text("Experimental 65³ proxy; visible color errors possible. 8-bit input, half-float SDR display.")
                    Text("Domain: linear RGB [0,1]; out-of-range colors clamp. Apple GPU validation pending.")
                    if let reason = liveRecipe.unsupportedReason { Text(reason) }
                    if experimentalLiveColor { Text(liveProxyStatus.text) }
                } header: { Text("Live color preview") }
                  .font(.footnote).disabled(camera.isCapturing)
                Section("Live preview resolution") {
                    Picker("Center long-edge limit", selection: $settings.centerPreviewLongEdge) {
                        ForEach(CameraSettingsStore.centerPreviewCaps.filter { $0 > settings.peripheralPreviewLongEdge }, id: \.self) { limit in
                            Text("Up to \(limit) px").tag(limit)
                        }
                    }
                    Picker("Peripheral long-edge limit", selection: $settings.peripheralPreviewLongEdge) {
                        ForEach(CameraSettingsStore.peripheralPreviewCaps.filter { $0 < settings.centerPreviewLongEdge }, id: \.self) { limit in
                            Text("Up to \(limit) px").tag(limit)
                        }
                    }
                }.disabled(camera.isCapturing || camera.isConfiguring)
                Section("Diagnostics") {
                    Text(camera.status)
                    Text(camera.isPreviewFrozen ? "FROZEN PREVIEW"
                         : selectedLens == .ultraWide ? "SYSTEM PREVIEW · 8-BIT VIDEO · ProRAW PHOTO"
                         : "8-BIT VIDEO · RAW PERIPHERY · APPROX. ALIGNMENT / PARALLAX")
                    if let dimensions = camera.centerPreviewDimensions {
                        Text("Center: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
                        Text(camera.centerPreviewEncoding ?? "Pixel format pending")
                    }
                    if let dimensions = camera.peripheralPreviewDimensions {
                        Text("Periphery: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
                        Text(camera.peripheralPreviewEncoding ?? "Pixel format pending")
                    }
                    if let dimensions = camera.sourceCaptureDimensions {
                        Text("Single-camera ProRAW source: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
                    }
                    Text("The wider lens uses approximate FOV alignment. Parallax and lens distortion remain; the central frame matches the selected final crop.")
                    if !camera.isReady && !camera.isConfiguring {
                        Button("Retry camera") { restartCamera() }
                    }
                    #if compiler(>=6.2)
                    if #unavailable(iOS 26.0) { Text("This OS uses a plain transparent camera perimeter. Native clear glass requires iOS 26.") }
                    #else
                    Text("This build uses a plain transparent camera perimeter. Native clear glass requires the iOS 26 SDK.")
                    #endif
                }.font(.footnote)
                Section {
                    Button(camera.isCapturing ? "Stop capture and open editor" : "Open editor / import photo", action: closeCamera)
                    Button("Close camera", action: closeCamera)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(panel == .compact ? "Camera controls" : "Camera settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(panel == .compact ? "Viewfinder" : "Done") { activePanel = nil }
                }
            }
        }
        .tint(.white)
    }

    private var orientedPeripheralAspectRatio: CGFloat? {
        guard let dimensions = camera.peripheralPreviewDimensions,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        // Controller publishes unrotated scaled sensor dimensions; delivered
        // sample buffers themselves are rotated by the output connection.
        let landscapeAspect = dimensions.width / dimensions.height
        return (camera.geometry?.photoAspectRatio ?? 1) < 1 ? 1 / landscapeAspect : landscapeAspect
    }

    private func coverageAvailable(_ framing: CameraFraming) -> Bool {
        selectedLens == .ultraWide || framing.hasPeripheralCoverage
    }

    private var selectedOutput: CameraController.OutputOption? {
        guard let cameraID = camera.physicalCameraID else { return nil }
        let choices = camera.supportedOutputOptions.sorted { $0.megapixels < $1.megapixels }
        if let saved = settings.outputMegapixels(physicalCameraID: cameraID, mode: selectedLens.rawValue) {
            // Preserve the saved physical-lens choice. A capability change must
            // require a new explicit selection, never silently lower resolution.
            return choices.first(where: { $0.megapixels == saved })
        }
        return choices.first
    }

    private var outputSelection: Binding<Int> {
        Binding(get: { selectedOutput?.megapixels ?? 0 }, set: { value in
            guard !camera.isCapturing, let cameraID = camera.physicalCameraID,
                  camera.supportedOutputOptions.contains(where: { $0.megapixels == value }) else { return }
            settings.setOutputMegapixels(value, physicalCameraID: cameraID, mode: selectedLens.rawValue)
        })
    }

    private func offerCompactPanel(for style: CameraChromeLayout.Style) {
        // Startup's provisional square frame must never launch the compact UI.
        guard camera.geometry != nil else { return }
        guard style == .separate else { compactPanelOffered = false; return }
        guard !compactPanelOffered, !isClosing, !camera.isCapturing,
              !camera.isPreviewFrozen else { return }
        compactPanelOffered = true
        activePanel = .compact
    }

    private func closeCamera() {
        isClosing = true
        activePanel = nil
        camera.stop()
        onClose()
    }

    private func restartCamera() {
        guard !isClosing, scenePhase == .active, !camera.isCapturing else { return }
        camera.start(mode: selectedLens,
                     centerPreviewLongEdge: settings.centerPreviewLongEdge,
                     peripheralPreviewLongEdge: settings.peripheralPreviewLongEdge)
    }

    private func shutter(coverageAvailable: Bool, diameter: CGFloat) -> some View {
        Button {
            guard camera.isReady, !camera.isCapturing, coverageAvailable, let output = selectedOutput else { return }
            activePanel = nil
            // Freeze the entire output recipe at shutter time. A successful photo
            // can arrive after Close, when editor controls already show another look.
            // Neither those controls nor onDismiss may retarget this committed shot.
            let portrait = (camera.geometry?.photoAspectRatio ?? 1) < 1
            let export = ExportSettings(targetWidth: portrait ? output.height : output.width,
                                        targetHeight: portrait ? output.width : output.height)
            let capturedRecipe = ProcessingRecipe(mode: colorMode, exposureEV: exposureEV,
                illuminantKelvin: illuminantKelvin, simulationIndex: simulationIndex, seed: 0, hncs: hncs, effects: effects, ffcs: ffcs)
            guard reserveCapture() else {
                captureError = "Couldn’t start this photo. Close the camera and reopen it, then try again."
                return
            }
            camera.captureProRAW { [capturedRecipe, export] result in
                switch result {
                case .success(let data): onCapture(data, export, capturedRecipe)
                case .failure(let error):
                    // Every terminal failure/cancel frees the slot, even after Close.
                    onCaptureFailure()
                    if !isClosing { captureError = error.localizedDescription }
                }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 2.5)
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6).padding(3.5)
                if camera.isCapturing { ProgressView() }
                else { Circle().fill(.white).padding(7) }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .disabled(!camera.isReady || camera.isCapturing || selectedOutput == nil || !coverageAvailable || !captureSlotAvailable)
        .accessibilityLabel("Capture Apple ProRAW DNG")
        .accessibilityHint(captureSlotAvailable
            ? "Full-resolution photo with the selected effect applied after capture"
            : "Open the previous completed capture in the editor before taking another photo")
    }
}

private enum CameraPanel: String, Identifiable {
    case settings, compact
    var id: Self { self }
}

/// Controls use only the intersection of natural spare regions and the safe area.
/// When that space cannot hold real touch targets, a separate plain panel takes
/// over. Crucially, this helper never returns or changes a photograph rectangle.
private struct CameraChromeLayout {
    enum Style: Equatable { case portrait, landscape, compactHorizontal, compactVertical, separate }
    let style: Style
    let first: CGRect
    let second: CGRect

    init(framing: CameraFraming, safeArea: EdgeInsets, needsAccessiblePanel: Bool) {
        let window = framing.window
        let safe = CGRect(x: safeArea.leading, y: safeArea.top,
                          width: max(0, window.width - safeArea.leading - safeArea.trailing),
                          height: max(0, window.height - safeArea.top - safeArea.bottom))
        func usable(_ rect: CGRect) -> CGRect {
            let intersection = rect.intersection(safe)
            guard !intersection.isNull, intersection.width > 16, intersection.height > 16 else { return .zero }
            return intersection.insetBy(dx: 8, dy: 4)
        }
        if framing.usesVerticalControls {
            first = usable(CGRect(x: 0, y: 0, width: framing.photo.minX, height: window.height))
            second = usable(CGRect(x: framing.photo.maxX, y: 0,
                                   width: window.width - framing.photo.maxX, height: window.height))
            if !needsAccessiblePanel, min(first.width, second.width) >= 100,
               min(first.height, second.height) >= 292 {
                style = .landscape
            } else if !needsAccessiblePanel, first.width >= 44, second.width >= 56,
                      min(first.height, second.height) >= 212 {
                style = .compactVertical
            } else { style = .separate }
        } else {
            first = usable(CGRect(x: 0, y: 0, width: window.width, height: framing.photo.minY))
            second = usable(CGRect(x: 0, y: framing.photo.maxY, width: window.width,
                                   height: window.height - framing.photo.maxY))
            if !needsAccessiblePanel, first.height >= 94, second.height >= 112,
               min(first.width, second.width) >= 276 {
                style = .portrait
            } else if !needsAccessiblePanel, first.height >= 44, second.height >= 56,
                      min(first.width, second.width) >= 312 {
                style = .compactHorizontal
            } else { style = .separate }
        }
    }
}

/// Clear glass does not adapt contrast. A small glyph/control shadow keeps the
/// white chrome legible over bright scenes; clipping prevents center-frame spill.
private struct CameraChromeRegion: ViewModifier {
    let rect: CGRect
    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: rect.height)
            .shadow(color: .black.opacity(0.75), radius: 1.5, x: 0, y: 1)
            .clipped()
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct PhotoFrameGuide: View {
    let gridVisible: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if gridVisible {
                    Path { path in
                        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                            path.move(to: CGPoint(x: proxy.size.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: proxy.size.width * fraction, y: proxy.size.height))
                            path.move(to: CGPoint(x: 0, y: proxy.size.height * fraction))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * fraction))
                        }
                    }.stroke(.white.opacity(0.24), lineWidth: 0.5)
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
                    path.move(to: CGPoint(x: 0, y: max(0, proxy.size.height - 0.5)))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: max(0, proxy.size.height - 0.5)))
                }.stroke(.white.opacity(0.9), lineWidth: 1)
            }
        }
    }
}

private struct CameraPaneGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Rectangle())
        } else {
            // Honest compatibility path: a plain transparent perimeter, not glass.
            content
        }
        #else
        content
        #endif
    }
}

private struct CameraPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> CameraPreviewHost { CameraPreviewHost() }
    func updateUIView(_ uiView: CameraPreviewHost, context: Context) {
        uiView.install(layer, gravity: gravity)
    }
    static func dismantleUIView(_ uiView: CameraPreviewHost, coordinator: ()) {
        uiView.preview?.removeFromSuperlayer()
        uiView.preview = nil
    }
}

private final class CameraPreviewHost: UIView {
    var preview: AVSampleBufferDisplayLayer?
    func install(_ preview: AVSampleBufferDisplayLayer, gravity: AVLayerVideoGravity) {
        if self.preview !== preview {
            self.preview?.removeFromSuperlayer()
            self.preview = preview
            layer.addSublayer(preview)
        }
        backgroundColor = .black
        clipsToBounds = true
        preview.videoGravity = gravity
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        CATransaction.commit()
    }
}

private struct CameraOrientationObserver: UIViewRepresentable {
    let changed: (UIInterfaceOrientation) -> Void
    func makeUIView(context: Context) -> CameraOrientationView {
        let view = CameraOrientationView()
        view.changed = changed
        return view
    }
    func updateUIView(_ uiView: CameraOrientationView, context: Context) {
        uiView.changed = changed
        uiView.setNeedsLayout()
    }
}

private final class CameraOrientationView: UIView {
    var changed: ((UIInterfaceOrientation) -> Void)?
    private var previous: UIInterfaceOrientation?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let orientation = window?.windowScene?.interfaceOrientation,
              orientation != .unknown, orientation != previous else { return }
        previous = orientation
        // Do not publish camera changes during SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in self?.changed?(orientation) }
    }
}
