import SwiftUI
import AVFoundation
import UIKit

/// Full-window live camera. Exact photo effects run only after DNG capture.
/// An opt-in approximate GPU color proxy affects the central viewfinder only.
/// The photo frame is surrounded by opaque black control bands.
struct CameraView: View {
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var workflow: CaptureWorkflow
    @StateObject private var camera = CameraController()
    private let selectedLens: CameraController.Mode = .main
    @State private var liveProxyStatus = LiveColorProxyStatus.off
    @State private var activePanel: CameraPanel?
    @State private var compactPanelOffered = false
    @State private var destination: CameraDestination?
    private var settingsPresented: Bool { if case .settings = destination { return true }; return false }
    private var reviewedCapture: SavedCapture? { if case .photo(let photo) = destination { return photo }; return nil }
    @State private var configuredPreviewLimit: Int?
    @State private var discardConfirmation = false
    private var colorMode: ColorMode { settings.colorMode }
    private var hncs: HNCSSettings { settings.hncs }
    private var effects: EffectToggles { settings.effects }
    private var experimentalLiveColor: Bool { settings.experimentalLiveColor }
    private var gridVisible: Bool { settings.gridVisible }
    private var thumbnail: PreviewRaster? { workflow.latest?.preview }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let framing = CameraFraming(size: proxy.size,
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ?? 1,
                                        cropToSquare: colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare)
            let chrome = CameraChromeLayout(framing: framing, safeArea: proxy.safeAreaInsets,
                                            needsAccessiblePanel: dynamicTypeSize.isAccessibilitySize)
            ZStack(alignment: .topLeading) {
                Color.black
                // Opaque black spare regions have hard edges at the photo frame.
                ForEach(Array(framing.perimeter.enumerated()), id: \.offset) { _, pane in
                    Color.black
                        .frame(width: pane.width, height: pane.height)
                        .position(x: pane.midX, y: pane.midY)
                        .allowsHitTesting(false)
                }
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
                                   cameraReady: camera.isReady) { status in
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
                if !camera.isCapturing && !camera.isReady && !workflow.isWorking {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(camera.status).font(.callout).multilineTextAlignment(.center)
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
                if chrome.style == .separate && (camera.isCapturing || camera.isReady) {
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
                if !workflow.status.isEmpty {
                    workflowStatus
                        .frame(maxWidth: min(360, proxy.size.width - 32))
                        .position(x: proxy.size.width / 2, y: framing.photo.maxY - 64)
                }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera.stop() }
            else if phase == .active { restartCamera() }
        }
        .onChange(of: settings.centerPreviewLongEdge) { _, _ in restartCamera() }
        .fullScreenCover(item: $destination, onDismiss: { restartCamera() }) { page in
            switch page {
            case .settings(let options, let cameraID):
                CameraSettingsView(settings: settings, options: options,
                                   physicalCameraID: cameraID, mode: selectedLens.rawValue,
                                   onBack: { destination = nil })
            case .photo(let capture):
                CaptureReview(capture: capture, onBack: { destination = nil })
                    .onAppear { camera.stop() }
            }
        }
        .confirmationDialog("Discard this unsaved photo?", isPresented: $discardConfirmation,
                            titleVisibility: .visible) {
            Button("Discard photo", role: .destructive) { workflow.discardFailed() }
        }
    }

    private var workflowStatus: some View {
        VStack(spacing: 8) {
            Text(workflow.status).font(.footnote).multilineTextAlignment(.center)
            if workflow.phase == .processing { ProgressView(value: workflow.progress) }
            if workflow.phase == .failed {
                HStack {
                    if workflow.canRetry { Button("Retry save", action: workflow.retry) }
                    if workflow.needsPhotosPermission {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Button(workflow.canRetry ? "Discard…" : "OK") {
                        if workflow.canRetry { discardConfirmation = true }
                        else { workflow.discardFailed() }
                    }
                }.buttonStyle(.bordered)
            }
        }
        .padding(12).foregroundStyle(.white).background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("capture.status")
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
                    shutter(diameter: 82)
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
                lensIndicator
                Text("RAW").font(.caption.weight(.semibold)).tracking(2)
                gridButton
                Spacer(minLength: 0)
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 12) {
                photoMode
                thumbnailButton
                Spacer(minLength: 0)
                shutter(diameter: 82)
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
                shutter(diameter: 56)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactVertical:
            VStack(spacing: 8) {
                flashOff
                lensIndicator
                Spacer(minLength: 0)
                gridButton
                thumbnailButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                photoMode
                Spacer(minLength: 0)
                shutter(diameter: 56)
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
        Button { settings.gridVisible.toggle() } label: {
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
            lensIndicator
            Text("·")
            Text("\(selectedOutput?.megapixels ?? 24) MP · HDR")
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

    private var lensIndicator: some View {
        Text("1×").font(.system(size: 12, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Main camera")
    }

    private var thumbnailButton: some View {
        Button {
            activePanel = nil
            if let capture = workflow.latest {
                destination = .photo(capture)
            }
        } label: {
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
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
        }
        .disabled(workflow.latest == nil || workflow.isWorking)
        .accessibilityLabel("View latest saved photo")
        .accessibilityIdentifier("camera.thumbnail")
    }

    private var settingsButton: some View {
        Button { activePanel = nil; destination = .settings(options: camera.supportedOutputOptions, cameraID: camera.physicalCameraID) } label: {
            Image(systemName: "gearshape").font(.system(size: 21, weight: .light))
                .frame(width: 44, height: 44)
        }
        .disabled(camera.isCapturing || camera.isConfiguring || workflow.phase == .authorizing)
        .accessibilityLabel("Camera settings and photo effects")
        .accessibilityIdentifier("camera.settings")
    }

    private var liveRecipe: LiveColorRecipe {
        LiveColorRecipe(mode: colorMode, simulationIndex: colorMode == .ffcs ? settings.simulationIndex : 0,
                        exposureEV: settings.exposure, illuminantKelvin: colorMode == .hncs ? settings.kelvin : 5500,
                        hncs: colorMode == .hncs ? hncs : .standard, effects: effects,
                        ffcs: colorMode == .ffcs ? settings.ffcs : .standard)
    }

    private func cameraPanel(_ panel: CameraPanel, framing: CameraFraming) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Return to the viewfinder for an unobstructed view. Tap it to reopen these controls.")
                    .font(.footnote).multilineTextAlignment(.center)
                HStack {
                    thumbnailButton
                    Spacer()
                    shutter(diameter: 82)
                    Spacer()
                    settingsButton
                }
                Text(workflow.isWorking ? workflow.status : camera.status).font(.footnote)
            }.padding().background(Color.black)
                .navigationTitle("Camera controls")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Viewfinder") { activePanel = nil }
                    }
                }
        }.tint(.white)
    }

    private var selectedOutput: CameraController.OutputOption? {
        guard let cameraID = camera.physicalCameraID else { return nil }
        let saved = settings.outputMegapixels(physicalCameraID: cameraID, mode: selectedLens.rawValue)
        // Unsupported choices never fall back to lower resolution or upsampling.
        return camera.supportedOutputOptions.first { $0.megapixels == saved }
    }

    private func offerCompactPanel(for style: CameraChromeLayout.Style) {
        // Startup's provisional square frame must never launch the compact UI.
        guard camera.geometry != nil else { return }
        guard style == .separate else { compactPanelOffered = false; return }
        guard !compactPanelOffered, !settingsPresented, reviewedCapture == nil, !camera.isCapturing,
              !camera.isPreviewFrozen else { return }
        compactPanelOffered = true
        activePanel = .compact
    }

    private func restartCamera() {
        guard !settingsPresented, reviewedCapture == nil, scenePhase == .active, !camera.isCapturing else { return }
        if camera.isReady && configuredPreviewLimit == settings.centerPreviewLongEdge { return }
        configuredPreviewLimit = settings.centerPreviewLongEdge
        camera.start(mode: selectedLens, centerPreviewLongEdge: settings.centerPreviewLongEdge)
    }

    private func shutter(diameter: CGFloat) -> some View {
        Button {
            guard camera.isReady, !camera.isCapturing, let output = selectedOutput else { return }
            activePanel = nil
            let portrait = (camera.geometry?.photoAspectRatio ?? 1) < 1
            let export = ExportSettings(targetWidth: portrait ? output.height : output.width,
                                        targetHeight: portrait ? output.width : output.height)
            let snapshot = CaptureSnapshot(recipe: settings.recipe, output: export)
            workflow.capture(snapshot: snapshot) { completion in
                guard scenePhase == .active, !settingsPresented, reviewedCapture == nil else {
                    completion(.failure(CaptureUIError.cameraInactive)); return
                }
                camera.captureProRAW(completion: completion)
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 2.5)
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6).padding(3.5)
                if workflow.isWorking { ProgressView() }
                else { Circle().fill(.white).padding(7) }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .disabled(!camera.isReady || camera.isCapturing || selectedOutput == nil || !workflow.canCapture)
        .accessibilityLabel("Take photo and save to Photos")
        .accessibilityIdentifier("camera.shutter")
        .accessibilityHint("Apply your saved settings and automatically save an HDR photo")
    }

}

private enum CameraDestination: Identifiable {
    case settings(options: [CameraController.OutputOption], cameraID: String?)
    case photo(SavedCapture)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .photo(let capture): return capture.id.uuidString
        }
    }
}

private enum CaptureUIError: LocalizedError {
    case cameraInactive
    var errorDescription: String? { "Return to the camera and try again." }
}

private enum CameraPanel: String, Identifiable {
    case compact
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

/// Opaque black bands keep controls legible outside the photograph.
private struct CameraChromeRegion: ViewModifier {
    let rect: CGRect
    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: rect.height)
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
            }
        }
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

/// An independent page; all controls update the same persisted shutter settings.
private struct CameraSettingsView: View {
    @ObservedObject var settings: CameraSettingsStore
    let options: [CameraController.OutputOption]
    let physicalCameraID: String?
    let mode: String
    let onBack: () -> Void

    private var outputSelection: Binding<Int> {
        Binding(get: { physicalCameraID.map { settings.outputMegapixels(physicalCameraID: $0, mode: mode) } ?? 24 },
                set: { value in
                    guard let id = physicalCameraID, options.contains(where: { $0.megapixels == value }) else { return }
                    settings.setOutputMegapixels(value, physicalCameraID: id, mode: mode)
                })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Photo output") {
                    Picker("Resolution", selection: outputSelection) {
                        ForEach([24, 48], id: \.self) { value in
                            Text("\(value) MP\(options.contains(where: { $0.megapixels == value }) ? "" : " · Unavailable")")
                                .tag(value)
                        }
                    }.pickerStyle(.segmented)
                        .disabled(physicalCameraID == nil || options.isEmpty)
                        .accessibilityIdentifier("settings.resolution")
                    if let choice = options.first(where: { $0.megapixels == outputSelection.wrappedValue }) {
                        let crop = settings.recipe.crop
                        let size = try? crop.resolve(width: choice.width, height: choice.height)
                        if let size {
                            LabeledContent("Saved dimensions", value: "\(size.width) × \(size.height)")
                            if crop == .centeredSquare {
                                Text("Square crop · \(Double(size.width * size.height) / 1_000_000, specifier: "%.1f") MP after crop")
                            }
                        }
                    } else { Text("Selected output is unavailable. Select a supported size before taking a photo.").foregroundStyle(.orange) }
                    LabeledContent("Format", value: "10-bit HDR HEIF")
                    Text("Photos are automatically saved to your system photo library using these settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Photo effects") {
                    Picker("Color engine", selection: $settings.colorMode) {
                        ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    if settings.colorMode == .ffcs {
                        FFCSReferenceControls(settings: $settings.ffcs, simulationIndex: $settings.simulationIndex)
                    }
                    LabeledContent("Exposure", value: String(format: "%+.2f EV", settings.exposure))
                    Slider(value: $settings.exposure, in: -2...2, step: 0.05)
                        .accessibilityLabel("Photo effect exposure")
                    if settings.colorMode == .hncs {
                        HNCSPresetControls(settings: $settings.hncs)
                        LabeledContent("Virtual capture CCT", value: "\(Int(settings.kelvin)) K")
                        Slider(value: $settings.kelvin, in: 2000...10000, step: 50)
                            .accessibilityLabel("Virtual capture correlated color temperature")
                    }
                    EffectToggleControls(effects: $settings.effects, mode: settings.colorMode, hncs: settings.hncs)
                    Button("Reset effect adjustments") {
                        settings.exposure = 0
                        if settings.colorMode == .hncs { settings.kelvin = 6500; settings.hncs = .standard }
                    }
                }
                Section("Viewfinder") {
                    LabeledContent("Camera", value: "Main · 1×")
                    Toggle("Composition grid", isOn: $settings.gridVisible)
                    Picker("Preview long-edge limit", selection: $settings.centerPreviewLongEdge) {
                        ForEach(CameraSettingsStore.centerPreviewCaps, id: \.self) { limit in
                            Text("Up to \(limit) px").tag(limit)
                        }
                    }
                    Toggle("Experimental live color (approx.)", isOn: $settings.experimentalLiveColor)
                    Text("Approximate color only; the saved photo uses the complete selected effect.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Camera settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { Label("Camera", systemImage: "chevron.left") }
                        .accessibilityIdentifier("settings.back")
                }
            }
        }.preferredColorScheme(.dark).tint(.white)
    }
}

private struct CaptureReview: View {
    let capture: SavedCapture
    let onBack: () -> Void
    @State private var sharing = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let scale = min(5, max(1, zoom * pinch))
                let maxX = proxy.size.width * (scale - 1) / 2
                let maxY = proxy.size.height * (scale - 1) / 2
                PrecisionPreview(source: capture.preview)
                    .scaleEffect(scale)
                    .offset(x: min(maxX, max(-maxX, pan.width + drag.width)),
                            y: min(maxY, max(-maxY, pan.height + drag.height)))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in zoom = min(5, max(1, zoom * value)); if zoom == 1 { pan = .zero } })
                    .simultaneousGesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            pan = CGSize(width: min(maxX, max(-maxX, pan.width + value.translation.width)),
                                         height: min(maxY, max(-maxY, pan.height + value.translation.height)))
                        })
                    .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1; pan = .zero }
                    .accessibilityLabel("Saved HDR photo")
                    .accessibilityAction(named: "Zoom in") { zoom = min(5, zoom + 1) }
                    .accessibilityAction(named: "Reset zoom") { zoom = 1; pan = .zero }
            }.clipped().background(Color.black)
            .navigationTitle("\(capture.width) × \(capture.height) · HDR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Camera", action: onBack) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share saved HDR photo")
                }
            }
        }.preferredColorScheme(.dark).tint(.white)
            .sheet(isPresented: $sharing) { ShareSheet(file: capture.file) }
    }
}
