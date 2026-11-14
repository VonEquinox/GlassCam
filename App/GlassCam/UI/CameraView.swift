import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Full-window live camera. Exact photo effects run only after DNG capture.
/// An opt-in approximate GPU color proxy affects the central viewfinder only.
/// Paired Metal preview presents both lenses together; glass stays outside.
struct CameraView: View {
    @Environment(\.colorResources) var resources
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var workflow: CaptureQueue
    @StateObject var camera = CameraController()
    @StateObject var rawTests = RAWTestRecorder()
    @StateObject private var motion = CameraMotion()
    @State private var haptics = CameraHaptics()
    @State private var shutterFlash = 0.0
    @Namespace var reviewTransition
    let selectedLens: CameraController.Mode = .main
    @State var liveProxyStatus = LiveColorProxyStatus.off
    @State var activePanel: CameraPanel?
    @State var filterDialVisible = false
    @State var settingsPresented = false
    @State private var compactPanel = CompactCameraPanel()
    @State var reviewedCapture: SavedCapture?
    @State private var configuredPreviewLimit: Int?
    @State private var discardConfirmation = false
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

    private func viewfinder(safeArea: EdgeInsets) -> some View {
        GeometryReader { proxy in
            let framing = CameraFraming(size: proxy.size,
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ??
                                            (proxy.size.width > proxy.size.height ? 4.0 / 3.0 : 3.0 / 4.0))
            let chrome = CameraChromeLayout(framing: framing, safeArea: safeArea,
                                            needsAccessiblePanel: dynamicTypeSize.isAccessibilitySize)
            let showsUnavailableCamera = !camera.isCapturing && !camera.isReady && !workflow.isWorking
            let livePreviewEnabled = scenePhase == .active && reviewedCapture == nil && !camera.isCapturing && !rawTests.isRecording
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
                                    enabled: livePreviewEnabled,
                                    colorRecipe: liveRecipe,
                                    colorEnabled: experimentalLiveColor && livePreviewEnabled && camera.peripheralSource != nil,
                                    cameraReady: camera.isReady) { status in
                        if camera.peripheralSource != nil { liveProxyStatus = status }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
                PeripheralLiquidGlass(framing: framing)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if let source = camera.centerLiveSource, camera.geometry != nil, camera.peripheralSource == nil {
                    LiveColorProxy(source: source, recipe: liveRecipe,
                                   enabled: experimentalLiveColor && livePreviewEnabled,
                                   cameraReady: camera.isReady) { status in
                        liveProxyStatus = status
                    }
                    .frame(width: framing.sourcePhoto.width, height: framing.sourcePhoto.height)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .clipped()
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false)
                }
                PhotoFrameBoundary(rect: framing.photo, isCapturing: camera.isExposing)
                    .allowsHitTesting(false).accessibilityHidden(true)
                PhotoFrameGuide(gridVisible: gridVisible)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if showsUnavailableCamera {
                    CameraUnavailableView(camera: camera, offersControls: chrome.style == .separate,
                        onRetry: restartCamera, onControls: { activePanel = .compact })
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .background(.black)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                }
                if !showsUnavailableCamera, camera.centerPreviewLayer != nil {
                    focusGesture(framing: framing, opensControls: chrome.style == .separate)
                    CameraFocusIndicator(camera: camera, source: framing.sourcePhoto)
                }
                Color.black.opacity(shutterFlash)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
                controls(framing: framing, chrome: chrome)
                    // Clear glass transmits bright scenes; a soft glyph shadow
                    // keeps etched engravings legible without dimming periphery.
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 0.5)
                CameraOrientationObserver { camera.updateOrientation($0) }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: chrome.style, initial: true) { _, style in
                if style != .portrait { filterDialVisible = false }
                offerCompactPanel(for: style)
            }
            .onChange(of: camera.geometry?.photoAspectRatio) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .onChange(of: camera.isReady) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .onChange(of: camera.isCapturing) { _, _ in
                offerCompactPanel(for: chrome.style)
            }
            .sheet(item: $activePanel) { panel in
                cameraPanel(panel, framing: framing)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $settingsPresented, onDismiss: { restartCamera() }) {
                CameraSettingsView(settings: settings, camera: camera, rawTests: rawTests, workflow: workflow, canRecordF5: workflow.canCapture && workflow.pendingCount == 0,
                                   onBack: { settingsPresented = false })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            // Read the system insets before the full-window preview opts out.
            viewfinder(safeArea: proxy.safeAreaInsets)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .buttonStyle(.plain)
        .onAppear { motion.setActive(scenePhase == .active); restartCamera() }
        .onDisappear { motion.setActive(false) }
        .onChange(of: scenePhase) { _, phase in
            motion.setActive(phase == .active)
            if phase == .background { camera.stop() }
            else if phase == .active { restartCamera() }
        }
        .onChange(of: settings.centerPreviewLongEdge) { _, _ in restartCamera() }
        .onChange(of: motion.orientation) { _, value in camera.updatePhysicalOrientation(value) }
        .onCameraCaptureEvent(isEnabled: canTakePhoto && activePanel == nil) { event in
            if event.phase == .ended { takePhoto() }
        }
        .onChange(of: camera.exposureCompletionID) { _, value in
            guard value != nil, scenePhase == .active else { return }
            haptics.exposureCompleted()
            if camera.captureQuality == .speed {
                shutterFlash = 0.18
                withAnimation(.easeOut(duration: 0.08)) { shutterFlash = 0 }
            }
        }
        .onChange(of: settings.captureQuality, initial: true) { _, quality in
            if quality.usesBayer { camera.selectF5MainCamera() }
        }
        .onChange(of: workflow.phase) { _, phase in
            if phase == .failed, scenePhase == .active { haptics.failed() }
            if phase == .idle || phase == .failed || phase == .paused {
                if let reservation = shutterReservation { camera.releaseCaptureReservation(reservation) }
                shutterReservation = nil
            }
        }
        .fullScreenCover(item: $reviewedCapture, onDismiss: { restartCamera() }) { capture in
            CaptureReview(capture: capture, onBack: { reviewedCapture = nil })
                .navigationTransition(.zoom(sourceID: Optional(capture.id), in: reviewTransition))
                .presentationBackground(.clear)
                .onAppear { camera.stop() }
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
        CaptureWorkflowStatusCard(
            workflow: workflow,
            onReview: { reviewedCapture = $0 },
            onDiscardConfirmation: { discardConfirmation = true },
            onRepeatSaveConfirmation: { repeatSaveConfirmation = true }
        )
    }

    private var liveRecipe: LiveColorRecipe {
        LiveColorRecipe(resources: resources, settings: settings)
    }

    private func cameraPanel(_ panel: CameraPanel, framing: CameraFraming) -> some View {
        VStack(spacing: 0) {
            CameraPageHeader(title: panel == .looks ? "Photo styles" : panel == .status ? "Capture status" : "Camera controls",
                             backIdentifier: "camera.panel.back") {
                activePanel = nil
            }
            ScrollView {
                if panel == .looks {
                    CameraLookPicker(settings: settings) { activePanel = nil }.padding(20)
                } else if panel == .status {
                    VStack(spacing: 20) {
                        Text(LocalizedStringKey(camera.isCapturing ? "Capturing RAW" : camera.status))
                        workflowStatus
                        Text(LocalizedStringKey(estimatedOutputLabel)).font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                } else {
                    VStack(spacing: 20) {
                        HStack {
                            opticalSpecReadout
                            Spacer()
                            qualityButton
                            gridButton
                        }
                        CameraLookPicker(settings: settings) {}
                        HStack { thumbnailButton; Spacer(); shutter(diameter: 76); Spacer(); settingsButton }
                        workflowStatus
                    }.padding(22)
                }
            }
        }.tint(.white)
    }

    private func offerCompactPanel(for style: CameraChromeLayout.Style) {
        if compactPanel.offer(hasGeometry: camera.geometry != nil, style: style,
                              settingsPresented: settingsPresented, reviewing: reviewedCapture != nil,
                              capturing: camera.isCapturing) {
            activePanel = .compact
        }
    }

    private func restartCamera() {
        guard reviewedCapture == nil, scenePhase == .active, !camera.isCapturing else { return }
        if camera.isReady && configuredPreviewLimit == settings.centerPreviewLongEdge { return }
        configuredPreviewLimit = settings.centerPreviewLongEdge
        camera.start(mode: selectedLens, centerPreviewLongEdge: settings.centerPreviewLongEdge)
    }

    func shutter(diameter: CGFloat) -> some View {
        Button(action: takePhoto) {
            OpticalLensShutterLabel(
                diameter: diameter,
                isCapturing: camera.isExposing,
                isWorking: workflow.isWorking,
                progress: workflow.progress
            )
        }
        .disabled(!canTakePhoto)
        .accessibilityLabel("Take photo and save to Photos")
        .accessibilityIdentifier("camera.shutter")
        .accessibilityHint("Apply your saved settings and automatically save an HDR photo")
    }

    private var canTakePhoto: Bool {
        scenePhase == .active && !settingsPresented && reviewedCapture == nil &&
        !rawTests.isRecording && camera.canReserveCapture && workflow.canCapture && settings.recipe.isValid
    }
    private var canAdjustMetering: Bool {
        scenePhase == .active && !settingsPresented && reviewedCapture == nil &&
        activePanel == nil && !rawTests.isRecording && camera.canReserveCapture
    }
    private func focusGesture(framing: CameraFraming, opensControls: Bool) -> some View {
        CameraFocusGesture(enabled: canAdjustMetering, focus: { point, locked in
            if filterDialVisible {
                withAnimation { filterDialVisible = false }
            } else if opensControls && !locked {
                activePanel = .compact
            } else {
                focus(at: CGPoint(x: framing.photo.minX + point.x, y: framing.photo.minY + point.y),
                      framing: framing, locked: locked)
            }
        }, reset: { camera.setMetering(camera.metering.resumingContinuous()) })
        .frame(width: framing.photo.width, height: framing.photo.height)
        .position(x: framing.photo.midX, y: framing.photo.midY)
        .accessibilityElement()
        .accessibilityLabel(Text(LocalizedStringKey(opensControls
            ? "Viewfinder. Open camera controls"
            : "Viewfinder. Tap to focus; hold to lock focus and exposure")))
        .accessibilityAction {
            if opensControls { activePanel = .compact }
            else { focus(at: CGPoint(x: framing.photo.midX, y: framing.photo.midY), framing: framing, locked: false) }
        }
        .accessibilityAction(named: "Lock focus and exposure") {
            focus(at: CGPoint(x: framing.photo.midX, y: framing.photo.midY), framing: framing, locked: true)
        }
        .accessibilityAction(named: "Open camera controls") { activePanel = .compact }
    }
    private func focus(at point: CGPoint, framing: CameraFraming, locked: Bool) {
        guard canAdjustMetering,
              let target = CameraMeteringGeometry.devicePoint(point, source: framing.sourcePhoto,
                                                               orientation: camera.previewOrientation) else { return }
        camera.setMetering(CameraMetering(point: target, locked: locked, exposureBias: camera.metering.exposureBias))
    }
    private func takePhoto() {
        guard canTakePhoto, let reservation = camera.reserveCapture() else { return }
        activePanel = nil; filterDialVisible = false; shutterReservation = reservation
        haptics.shutterPressed()
        let snapshot = CaptureSnapshot(recipe: settings.recipe, output: .camera24(framing: camera.currentFraming),
            quality: settings.captureQuality, archiveF5RAW: settings.archiveF5RAW,
            rawArchiveID: settings.captureQuality == .balanced && settings.archiveBalancedPreColorRAW ? UUID() : nil)
        workflow.capturePhoto(snapshot: snapshot) { frozen, completion in
            guard scenePhase == .active, !settingsPresented, reviewedCapture == nil else {
                completion(.failure(CaptureUIError.cameraInactive)); return
            }
            camera.capturePhoto(reservation: reservation, quality: frozen.quality, snapshot: frozen, completion: completion)
        }
    }
}

private enum CaptureUIError: LocalizedError {
    case cameraInactive
    var errorDescription: String? { String(localized: "Return to the camera and try again.") }
}

enum CameraPanel: String, Identifiable {
    case compact, looks, status
    var id: Self { self }
}

private struct CaptureWorkflowStatusCard: View {
    @ObservedObject var workflow: CaptureQueue
    let onReview: (SavedCapture) -> Void
    let onDiscardConfirmation: () -> Void
    let onRepeatSaveConfirmation: () -> Void

    var body: some View {
        if !workflow.status.isEmpty {
            VStack(spacing: 10) {
                Text(LocalizedStringKey(workflow.status)).font(.footnote).multilineTextAlignment(.center)
                if workflow.phase == .processing {
                    ProgressView(value: workflow.progress)
                        .tint(.white.opacity(0.9))
                }
                if workflow.phase == .saveOutcomeUnknown {
                    if let date = workflow.pendingDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                    HStack {
                        if let capture = workflow.pendingCapture {
                            Button("Review") { onReview(capture) }
                        }
                        Button("Already in Photos") { workflow.confirmAlreadySaved() }
                        Button("Save again…") { onRepeatSaveConfirmation() }
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
                        Button(LocalizedStringKey(workflow.requiresDiscardConfirmation ? "Discard…" : "OK")) {
                            if workflow.requiresDiscardConfirmation { onDiscardConfirmation() }
                            else { workflow.discardFailed() }
                        }
                    }.buttonStyle(.bordered)
                }
            }
            .padding(14)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.65)
                    }
            }
            .accessibilityIdentifier("capture.status")
        }
    }
}
