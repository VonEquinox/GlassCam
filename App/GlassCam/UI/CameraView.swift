import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

/// Full-window live camera. Exact photo effects run only after DNG capture.
/// An opt-in approximate GPU color proxy affects the central viewfinder only.
/// Paired Metal preview presents both lenses together; glass stays outside.
struct CameraView: View {
    @Environment(\.colorResources) var resources
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var workflow: CaptureWorkflow
    @StateObject var camera = CameraController()
    @StateObject var rawTests = RAWTestRecorder()
    let selectedLens: CameraController.Mode = .main
    @State var liveProxyStatus = LiveColorProxyStatus.off
    @State var activePanel: CameraPanel?
    @State private var compactPanel = CompactCameraPanel()
    @State var destination: CameraDestination?
    private var settingsPresented: Bool { if case .settings = destination { return true }; return false }
    private var reviewedCapture: SavedCapture? { if case .photo(let photo) = destination { return photo }; return nil }
    @State private var configuredPreviewLimit: Int?
    @State private var discardConfirmation = false
    @State private var pinchStartZoom: Double?
    @State private var shutterReservation: UUID?
    @State private var repeatSaveConfirmation = false
    var colorMode: ColorMode { settings.colorMode }
    var hncs: HNCSSettings { settings.hncs }
    private var effects: EffectToggles { settings.effects }
    var experimentalLiveColor: Bool { settings.experimentalLiveColor }
    var gridVisible: Bool { settings.gridVisible }
    var thumbnail: PreviewRaster? { workflow.latest?.preview }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let framing = CameraFraming(size: proxy.size,
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ??
                                            (proxy.size.width > proxy.size.height ? 4.0 / 3.0 : 3.0 / 4.0))
            let chrome = CameraChromeLayout(framing: framing, safeArea: proxy.safeAreaInsets,
                                            needsAccessiblePanel: dynamicTypeSize.isAccessibilitySize)
            let showsUnavailableCamera = !camera.isCapturing && !camera.isReady && !workflow.isWorking
            ZStack(alignment: .topLeading) {
                Color.black
                // Retained raw fallback for single-camera mode / graph handoff.
                // While paired frames are available the single drawable above
                // it owns BOTH camera images, with no independent center clock.
                if let layer = camera.centerPreviewLayer, camera.geometry != nil {
                    CameraPreview(layer: layer, gravity: .resizeAspect)
                        .frame(width: framing.sourcePhoto.width, height: framing.sourcePhoto.height)
                        .background(.black)
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .clipped()
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Unprocessed system camera preview inside the photograph frame")
                        .accessibilityIdentifier("camera.photo.frame")
                }
                PeripheralGlassView(source: camera.peripheralSource, framing: framing,
                                    enabled: scenePhase == .active && !settingsPresented && reviewedCapture == nil && !camera.isPreviewFrozen,
                                    colorRecipe: liveRecipe,
                                    colorEnabled: experimentalLiveColor && scenePhase == .active && !camera.isPreviewFrozen && camera.peripheralSource != nil,
                                    cameraReady: camera.isReady) { status in
                        if camera.peripheralSource != nil {liveProxyStatus=status}
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
                PeripheralLiquidGlass(framing: framing)
                    .frame(width: proxy.size.width,height: proxy.size.height)
                if let source = camera.centerLiveSource, camera.geometry != nil, camera.peripheralSource == nil {
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
                PhotoFrameBoundary(rect: framing.photo)
                    .allowsHitTesting(false).accessibilityHidden(true)
                PhotoFrameGuide(gridVisible: gridVisible)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if showsUnavailableCamera {
                    ScrollView {
                        VStack(spacing: 20) {
                            VStack(spacing: 12) {
                                Image(systemName: "camera.fill").font(.largeTitle)
                                Text(LocalizedStringKey(camera.status)).font(.callout).multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !camera.isConfiguring {
                                    Button("Retry camera") { restartCamera() }.padding(10)
                                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                                        Button("Open Settings") {
                                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                        }
                                    }
                                }
                                if chrome.style == .separate {
                                    Button("Open camera controls") { activePanel = .compact }
                                        .frame(minHeight: 44)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .background(.black)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                }
                if !showsUnavailableCamera, camera.centerPreviewLayer != nil {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .gesture(MagnificationGesture().onChanged { value in
                            guard workflow.canCapture, !camera.isCapturing, !settings.captureQuality.usesBayer else { return }
                            if pinchStartZoom == nil { pinchStartZoom = camera.requestedZoom }
                            camera.setZoom((pinchStartZoom ?? camera.requestedZoom) * Double(value))
                        }.onEnded { _ in pinchStartZoom = nil })
                        .onTapGesture { if chrome.style == .separate { activePanel = .compact } }
                        .accessibilityElement()
                        .accessibilityLabel("Viewfinder. Open camera controls")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { if chrome.style == .separate { activePanel = .compact } }
                        .accessibilityHidden(chrome.style != .separate)
                }
                controls(framing: framing, chrome: chrome)
                    // Clear glass transmits bright scenes; a soft glyph shadow
                    // keeps controls legible without dimming the periphery.
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 0.5)
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
                    .presentationDetents(panel == .zoom ? [.height(300), .large] : [.large])
                    .presentationDragIndicator(.visible)
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
        .onChange(of: settings.captureQuality, initial: true) { _, quality in
            if quality.usesBayer { camera.selectF5MainCamera() }
        }
        .onChange(of: workflow.phase) { _, phase in
            if phase == .idle || phase == .failed || phase == .paused {
                if let reservation = shutterReservation { camera.releaseCaptureReservation(reservation) }
                shutterReservation = nil
            }
        }
        .fullScreenCover(item: $destination, onDismiss: { restartCamera() }) { page in
            switch page {
            case .settings:
                CameraSettingsView(settings: settings, camera: camera, rawTests: rawTests, workflow: workflow, canRecordF5: workflow.canCapture,
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
        .confirmationDialog("Save this photo again? Check Photos first to avoid a duplicate.", isPresented: $repeatSaveConfirmation,
                            titleVisibility: .visible) {
            Button("Save to Photos again") { workflow.saveAgain() }
        }
    }

    private var workflowStatus: some View {
        VStack(spacing: 8) {
            Text(LocalizedStringKey(workflow.status)).font(.footnote).multilineTextAlignment(.center)
            if workflow.phase == .processing { ProgressView(value: workflow.progress) }
            if workflow.phase == .saveOutcomeUnknown {
                if let date = workflow.pendingDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                HStack {
                    if let capture = workflow.pendingCapture {
                        Button("Review") { destination = .photo(capture) }
                    }
                    Button("Already in Photos") { workflow.confirmAlreadySaved() }
                    Button("Save again…") { repeatSaveConfirmation = true }
                }.buttonStyle(.bordered)
            }
            if workflow.phase == .failed {
                HStack {
                    if workflow.canRetry { Button("Retry save", action: workflow.retry) }
                    if workflow.needsPhotosPermission {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Button(LocalizedStringKey(workflow.canRetry ? "Discard…" : "OK")) {
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

    private var liveRecipe: LiveColorRecipe {
        LiveColorRecipe(resources: resources, mode: colorMode, simulationIndex: colorMode == .ffcs ? settings.simulationIndex : 0,
                        exposureEV: settings.exposure, illuminantKelvin: 5500,
                        hncs: colorMode == .hncs ? hncs : .standard, effects: effects,
                        ffcs: colorMode == .ffcs ? settings.ffcs : .standard,
                        lumix: colorMode == .lumix ? settings.lumix : .standard)
    }

    private func cameraPanel(_ panel: CameraPanel, framing: CameraFraming) -> some View {
        VStack(spacing: 0) {
            CameraPageHeader(title: panel == .zoom ? "Focal length" : panel == .looks ? "Photo styles" : "Camera controls",
                             backIdentifier: "camera.panel.back") {
                activePanel = nil
            }
            ScrollView {
                if panel == .zoom { zoomRuler }
                else if panel == .looks {
                    CameraLookPicker(settings: settings) { activePanel = nil }.padding(20)
                } else if panel == .status {
                    VStack(spacing: 20) {
                        Text(LocalizedStringKey(camera.isPreviewFrozen ? "Capturing RAW" : camera.status))
                        if !workflow.status.isEmpty { workflowStatus }
                        Text(estimatedOutputLabel).font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                } else {
                    VStack(spacing: 20) {
                        zoomButtons
                        styleButton
                        HStack { resolutionButton; qualityButton }
                        HStack { thumbnailButton; Spacer(); shutter(diameter: 76); Spacer(); settingsButton }
                        if !workflow.status.isEmpty { workflowStatus }
                    }.padding(22)
                }
            }
        }.tint(.white) // The system Liquid Glass sheet is the panel background.
    }

    private func offerCompactPanel(for style: CameraChromeLayout.Style) {
        if compactPanel.offer(hasGeometry: camera.geometry != nil, style: style,
                              settingsPresented: settingsPresented, reviewing: reviewedCapture != nil,
                              capturing: camera.isCapturing, frozen: camera.isPreviewFrozen) {
            activePanel = .compact
        }
    }

    private func restartCamera() {
        guard !settingsPresented, reviewedCapture == nil, scenePhase == .active, !camera.isCapturing else { return }
        if camera.isReady && configuredPreviewLimit == settings.centerPreviewLongEdge { return }
        configuredPreviewLimit = settings.centerPreviewLongEdge
        camera.start(mode: selectedLens, centerPreviewLongEdge: settings.centerPreviewLongEdge)
    }

    func shutter(diameter: CGFloat) -> some View {
        Button {
            guard !rawTests.isRecording, workflow.canCapture, let reservation = camera.reserveCapture() else { return }
            activePanel = nil
            shutterReservation = reservation
            let export = ExportSettings.native.withFraming(camera.currentFraming)
            let snapshot = CaptureSnapshot(recipe: settings.recipe, output: export, quality: settings.captureQuality,archiveF5RAW:settings.archiveF5RAW,
                rawArchiveID: settings.captureQuality == .balanced ? UUID() : nil)
            workflow.capturePhoto(snapshot: snapshot) { completion in
                guard scenePhase == .active, !settingsPresented, reviewedCapture == nil else {
                    completion(.failure(CaptureUIError.cameraInactive)); return
                }
                camera.capturePhoto(reservation: reservation, quality: snapshot.quality, snapshot: snapshot, completion: completion)
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
        .disabled(rawTests.isRecording || !camera.canReserveCapture || !workflow.canCapture)
        .accessibilityLabel("Take photo and save to Photos")
        .accessibilityIdentifier("camera.shutter")
        .accessibilityHint("Apply your saved settings and automatically save an HDR photo")
    }

}

enum CameraDestination: Identifiable {
    case settings
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

enum CameraPanel: String, Identifiable {
    case compact, zoom, looks, status
    var id: Self { self }
}
