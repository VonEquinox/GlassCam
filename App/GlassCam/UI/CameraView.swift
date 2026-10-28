import SwiftUI
import AVFoundation
import UIKit

/// Full-window live camera. Exact photo effects run only after DNG capture.
/// An opt-in approximate GPU color proxy affects the central viewfinder only.
/// Paired Metal preview presents both lenses together; glass stays outside.
struct CameraView: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var workflow: CaptureWorkflow
    @StateObject private var camera = CameraController()
    @StateObject private var stateRecords = PeripheralRecordingModel()
    private let selectedLens: CameraController.Mode = .main
    @State private var liveProxyStatus = LiveColorProxyStatus.off
    @State private var activePanel: CameraPanel?
    @State private var compactPanelOffered = false
    @State private var destination: CameraDestination?
    private var settingsPresented: Bool { if case .settings = destination { return true }; return false }
    private var reviewedCapture: SavedCapture? { if case .photo(let photo) = destination { return photo }; return nil }
    @State private var configuredPreviewLimit: Int?
    @State private var discardConfirmation = false
    @State private var pinchStartZoom: Double?
    @State private var shutterReservation: UUID?
    @State private var repeatSaveConfirmation = false
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
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ??
                                            (proxy.size.width > proxy.size.height ? 4.0 / 3.0 : 3.0 / 4.0))
            let chrome = CameraChromeLayout(framing: framing, safeArea: proxy.safeAreaInsets,
                                            needsAccessiblePanel: dynamicTypeSize.isAccessibilitySize)
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
                if !camera.isCapturing && !camera.isReady && !workflow.isWorking {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(LocalizedStringKey(camera.status)).font(.callout).multilineTextAlignment(.center)
                        if !camera.isReady && !camera.isConfiguring {
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
                    .padding(16)
                    .frame(width: framing.photo.width, height: framing.photo.height)
                    .background(.black)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                }
                if camera.centerPreviewLayer != nil {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .gesture(MagnificationGesture().onChanged { value in
                            guard workflow.canCapture, !camera.isCapturing, settings.captureQuality != .f5 else { return }
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
                PeripheralRecordingControls(model: stateRecords) {
                    stateRecords.record(source: camera.peripheralSource, camera: [
                        "status": camera.status, "isReady": camera.isReady,
                        "isCapturing": camera.isCapturing, "isPreviewFrozen": camera.isPreviewFrozen,
                        "isConfiguring": camera.isConfiguring, "capturePhase": camera.capturePhase.rawValue,
                        "requestedZoom": camera.requestedZoom, "appliedZoom": camera.appliedZoom,
                        "physicalCameraID": camera.physicalCameraID ?? "none",
                        "previewEncoding": camera.centerPreviewEncoding ?? "none",
                        "sceneActive": scenePhase == .active, "settingsPresented": settingsPresented,
                        "experimentalLiveColor": experimentalLiveColor,
                        "tolerance": PeripheralTolerance.shared.value,
                        "liveColorShowing": liveProxyStatus.isShowingEffect,
                        "workflowPhase": String(describing: workflow.phase),
                        "sourceState": camera.peripheralSource?.diagnosticState() ?? "no-source"])
                }
                .position(x: framing.photo.midX, y: max(62, framing.photo.maxY - 62))
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
            if quality == .f5 { camera.selectF5MainCamera() }
        }
        .onChange(of: workflow.phase) { _, phase in
            if phase == .idle || phase == .failed || phase == .paused {
                if let reservation = shutterReservation { camera.releaseCaptureReservation(reservation) }
                shutterReservation = nil
            }
        }
        .fullScreenCover(item: $destination, onDismiss: { restartCamera() }) { page in
            switch page {
            case .settings(let options, let cameraID):
                CameraSettingsView(settings: settings, camera: camera, canRecordF5: workflow.canCapture, options: options,
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

    @ViewBuilder
    private func controls(framing: CameraFraming, chrome: CameraChromeLayout) -> some View {
        switch chrome.style {
        case .portrait:
            VStack(spacing: 6) {
                HStack {
                    resolutionButton
                    Spacer(minLength: 8)
                    wordmark
                    Spacer(minLength: 8)
                    gridButton
                }
                captureMetadata
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    zoomButtons
                    lensIndicator
                    Spacer(minLength: 0)
                }
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
            VStack(spacing: 8) {
                wordmark.font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                resolutionButton
                qualityButton
                compactStyleButton
                Text(photoAspectLabel).font(.caption.weight(.semibold))
                lensIndicator
                Text("RAW").font(.caption.weight(.semibold)).tracking(2)
                gridButton
                Spacer(minLength: 0)
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                statusButton
                verticalZoomButtons
                thumbnailButton
                Spacer(minLength: 0)
                shutter(diameter: 82)
                Spacer(minLength: 0)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactHorizontal:
            HStack(spacing: 8) {
                resolutionButton
                qualityButton
                compactStyleButton
                Spacer(minLength: 0)
                statusButton
                Spacer(minLength: 0)
                gridButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            HStack {
                thumbnailButton
                lensIndicator
                Spacer(minLength: 8)
                shutter(diameter: 56)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactVertical:
            VStack(spacing: 8) {
                resolutionButton
                qualityButton
                compactStyleButton
                lensIndicator
                Spacer(minLength: 0)
                gridButton
                thumbnailButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                statusButton
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

    private var gridButton: some View {
        Button { settings.gridVisible.toggle() } label: {
            Image(systemName: "grid").font(.system(size: 21, weight: .light))
                .foregroundStyle(gridVisible ? .white : .white.opacity(0.55))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text(LocalizedStringKey(gridVisible ? "Hide composition grid" : "Show composition grid")))
        .accessibilityValue(Text(LocalizedStringKey(gridVisible ? "On" : "Off")))
        .accessibilityIdentifier("camera.grid")
    }

    private var captureMetadata: some View {
        HStack(spacing: 12) {
            styleButton
            qualityButton
            Spacer(minLength: 4)
            statusButton
        }.font(.system(size: 12, weight: .medium)).lineLimit(1)
    }

    private var styleButton: some View {
        Button { activePanel = .looks } label: {
            HStack(spacing: 7) {
                Image(systemName: "camera.filters")
                Text(selectedStyleTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }.modifier(CameraPill())
        }.disabled(workflow.isWorking || camera.isCapturing)
            .accessibilityLabel("Choose photo style").accessibilityIdentifier("camera.style")
            .accessibilityValue(selectedStyleTitle)
    }

    private var selectedStyleTitle: String {
        switch colorMode {
        case .hncs: return hncs.presetTitle
        case .ffcs: return FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)
            .first { $0.id == settings.simulationIndex }?.name ?? "FFCS"
        case .lumix: return settings.lumix.title
        }
    }

    private var compactStyleButton: some View {
        Button { activePanel = .looks } label: {
            Image(systemName: "camera.filters").font(.system(size: 20))
                .frame(width: 44, height: 44)
        }.disabled(workflow.isWorking || camera.isCapturing)
            .accessibilityLabel("Choose photo style").accessibilityValue(selectedStyleTitle)
            .accessibilityIdentifier("camera.style")
    }

    private var resolutionButton: some View {
        Button {
            guard let id = camera.physicalCameraID else { return }
            let next = (selectedOutput?.megapixels ?? 24) == 24 ? 48 : 24
            if camera.supportedOutputOptions.contains(where: { $0.megapixels == next }) {
                settings.setOutputMegapixels(next, physicalCameraID: id, mode: selectedLens.rawValue)
            }
        } label: {
            Text(settings.captureQuality == .f5 ? "2× sampling" : "\(settings.captureQuality.outputMegapixels(preferred: selectedOutput?.megapixels ?? settings.preferredOutputMegapixels)) MP")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .modifier(CameraPill())
        }.disabled(!workflow.canCapture || camera.physicalCameraID == nil || settings.captureQuality == .f5)
            .accessibilityLabel("Photo resolution").accessibilityIdentifier("camera.resolution")
            .accessibilityValue(Text(settings.captureQuality == .f5 ? "2× sampling" : "\(settings.captureQuality.outputMegapixels(preferred: selectedOutput?.megapixels ?? settings.preferredOutputMegapixels)) MP"))
    }

    private var qualityButton: some View {
        Menu {
            ForEach(CaptureQuality.allCases, id: \.self) { quality in
                Button { settings.captureQuality = quality } label: {
                    if settings.captureQuality == quality {
                        Label(quality == .f5 ? "F5 · 5 RAW" : quality.title, systemImage: "checkmark")
                    } else {
                        Text(quality == .f5 ? "F5 · 5 RAW" : quality.title)
                    }
                }.accessibilityIdentifier("camera.quality.\(quality.rawValue)")
            }
        } label: {
            Text(settings.captureQuality.title)
                .font(.system(size: 11, weight: .semibold))
                .modifier(CameraPill())
        }
        .disabled(!workflow.canCapture || camera.isCapturing)
        .accessibilityLabel("Capture priority")
        .accessibilityValue(settings.captureQuality.title)
        .accessibilityIdentifier("camera.quality")
        .accessibilityHint("Choose F5 five-frame RAW, Balanced, or Quality")
    }

    private var statusButton: some View {
        Button { activePanel = .status } label: {
            HStack(spacing: 6) {
                if workflow.isWorking || camera.isPreviewFrozen { ProgressView().controlSize(.mini) }
                else { Circle().fill(.white.opacity(0.65)).frame(width: 4, height: 4) }
                Text(LocalizedStringKey(summaryStatus))
                    .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(minWidth: 44, minHeight: 44).foregroundStyle(.white.opacity(0.78))
        }.accessibilityLabel(Text(LocalizedStringKey(summaryStatus)))
            .accessibilityValue(Text(LocalizedStringKey(workflow.status)))
            .accessibilityIdentifier("capture.status.summary")
    }

    private var summaryStatus: String {
        if settings.captureQuality == .f5, !camera.f5ProfileAvailable, !camera.isCapturing, workflow.canCapture { return "F5 · Main-camera calibration required" }
        if camera.isCapturing || camera.isPreviewFrozen { return "Capturing RAW" }
        switch workflow.phase {
        case .authorizing: return "Preparing photo"
        case .capturing: return "Capturing RAW"
        case .retaining: return "Retaining photo"
        case .processing: return "Processing photo"
        case .saving: return "Saving photo"
        case .restoring: return "Restoring photo"
        case .paused: return "Photo paused"
        case .failed, .saveOutcomeUnknown: return "Photo needs attention"
        case .idle: break
        }
        if workflow.status.hasPrefix("Saved HDR") { return "Saved to Photos" }
        if experimentalLiveColor && liveProxyStatus.isShowingEffect && camera.isReady { return "Approx. preview · HDR" }
        return estimatedOutputLabel
    }

    private var photoAspectLabel: String {
        guard let size = camera.geometry?.sensorPhotoDimensions,
              size.width > 0, size.height > 0 else { return "—" }
        let long = Int(max(size.width, size.height))
        let short = Int(min(size.width, size.height))
        var a = long, b = short
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return "\(long / a):\(short / a)"
    }

    private var lensIndicator: some View {
        Button { activePanel = .zoom } label: {
            Text(CameraZoomRange.label(camera.requestedZoom)).font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!workflow.canCapture || camera.isCapturing || settings.captureQuality == .f5)
        .accessibilityLabel("Focal length controls")
        .accessibilityValue(CameraZoomRange.label(camera.appliedZoom))
        .accessibilityIdentifier("camera.zoom")
    }

    private var estimatedOutputLabel: String {
        if settings.captureQuality == .f5 { return "F5 · 5 RAW · 2× output grid" }
        guard let source = camera.sourceCaptureDimensions else { return "HDR" }
        let mode = selectedOutput?.megapixels ?? settings.captureQuality.outputMegapixels(preferred: settings.preferredOutputMegapixels)
        let output = ExportSettings.camera(mode, framing: camera.currentFraming)
        let tier = try? output.selectedOutputMegapixels(sourceWidth: Int(source.width), sourceHeight: Int(source.height), crop: settings.recipe.crop)
        return "≈\(tier ?? 24) MP · HDR"
    }

    private var zoomButtons: some View {
        HStack(spacing: 8) { zoomStops }
    }

    private var verticalZoomButtons: some View {
        VStack(spacing: 4) { zoomStops }
    }

    private var zoomStops: some View {
        ForEach(camera.zoomRange.stops) { stop in
            Button { camera.setZoom(stop.factor) } label: {
                Text(CameraZoomRange.label(stop.factor))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(abs(camera.appliedZoom - stop.factor) < 0.04 ? Color.white.opacity(0.24) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .onLongPressGesture(minimumDuration: 0.4) { activePanel = .zoom }
            .accessibilityLabel(Text(LocalizedStringKey(stop.title)))
            .accessibilityValue(CameraZoomRange.label(stop.factor))
            .accessibilityIdentifier("camera.zoom.\(stop.title)")
        }
        .disabled(!workflow.canCapture || camera.isCapturing || camera.isConfiguring || settings.captureQuality == .f5)
    }

    private var zoomRuler: some View {
        VStack(spacing: 20) {
            Text(CameraZoomRange.label(camera.requestedZoom)).font(.title2.monospacedDigit())
                .accessibilityIdentifier("camera.zoom.readout")
            zoomButtons
            if camera.zoomRange.upperBound > camera.zoomRange.lowerBound {
                Slider(value: Binding(get: { log2(camera.requestedZoom) },
                                      set: { camera.setZoom(pow(2, $0)) }),
                       in: log2(camera.zoomRange.lowerBound)...log2(camera.zoomRange.upperBound))
                    .disabled(!workflow.canCapture || settings.captureQuality == .f5)
                    .accessibilityLabel("Continuous focal length")
                    .accessibilityValue(CameraZoomRange.label(camera.appliedZoom))
                    .accessibilityIdentifier("camera.zoom.ruler")
            }
            Text(LocalizedStringKey(camera.currentFraming.lensName ?? "Automatic lens selection"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
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

    private var selectedOutput: CameraController.OutputOption? {
        guard let cameraID = camera.physicalCameraID else { return nil }
        if settings.captureQuality == .f5 { return nil }
        let saved = settings.outputMegapixels(physicalCameraID: cameraID, mode: selectedLens.rawValue)
        // Unsupported choices never fall back to lower resolution or upsampling.
        return camera.supportedOutputOptions.first { $0.megapixels == saved }
    }

    private func offerCompactPanel(for style: CameraChromeLayout.Style) {
        // Wait for the negotiated camera geometry before offering compact UI.
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
            guard workflow.canCapture, settings.captureQuality == .f5 || selectedOutput != nil, let reservation = camera.reserveCapture() else { return }
            activePanel = nil
            shutterReservation = reservation
            let export = settings.captureQuality == .f5 ? ExportSettings.native.withFraming(camera.currentFraming) :
                ExportSettings.camera(selectedOutput!.megapixels, framing: camera.currentFraming)
            let snapshot = CaptureSnapshot(recipe: settings.recipe, output: export, quality: settings.captureQuality,archiveF5RAW:settings.archiveF5RAW)
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
        .disabled(!camera.canReserveCapture || (settings.captureQuality != .f5 && selectedOutput == nil) || !workflow.canCapture || (settings.captureQuality == .f5 && !camera.f5ProfileAvailable))
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
    case compact, zoom, looks, status
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
               min(first.height, second.height) >= 408 {
                style = .landscape
            } else if !needsAccessiblePanel, first.width >= 68, second.width >= 64,
                      min(first.height, second.height) >= 264 {
                style = .compactVertical
            } else { style = .separate }
        } else {
            first = usable(CGRect(x: 0, y: 0, width: window.width, height: framing.photo.minY))
            second = usable(CGRect(x: 0, y: framing.photo.maxY, width: window.width,
                                   height: window.height - framing.photo.maxY))
            if !needsAccessiblePanel, first.height >= 94, second.height >= 140,
               min(first.width, second.width) >= 276 {
                style = .portrait
            } else if !needsAccessiblePanel, first.height >= 44, second.height >= 56,
                      min(first.width, second.width) >= 312 {
                style = .compactHorizontal
            } else { style = .separate }
        }
    }
}

/// Hard clipping keeps every control outside the photograph.
private struct CameraChromeRegion: ViewModifier {
    let rect: CGRect
    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct PhotoFrameBoundary: View {
    let rect: CGRect
    var body: some View {
        Path { path in
            let r = rect.insetBy(dx: -1, dy: -1)
            let length: CGFloat = 18
            for (x, dx) in [(r.minX, CGFloat(1)), (r.maxX, CGFloat(-1))] {
                for (y, dy) in [(r.minY, CGFloat(1)), (r.maxY, CGFloat(-1))] {
                    path.move(to: CGPoint(x: x, y: y + dy * length))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * length, y: y))
                }
            }
        }.stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round))
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
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var camera: CameraController
    let canRecordF5: Bool
    let options: [CameraController.OutputOption]
    let physicalCameraID: String?
    let mode: String
    let onBack: () -> Void
    @State private var advanced = false

    private var outputSelection: Binding<Int> {
        Binding(get: { settings.captureQuality.outputMegapixels(preferred:
                    physicalCameraID.map { settings.outputMegapixels(physicalCameraID: $0, mode: mode) } ?? settings.preferredOutputMegapixels) },
                set: { value in
                    guard settings.captureQuality != .f5, let id = physicalCameraID,
                          options.contains(where: { $0.megapixels == value }) else { return }
                    settings.setOutputMegapixels(value, physicalCameraID: id, mode: mode)
                })
    }
    var body: some View {
        VStack(spacing: 0) {
            CameraPageHeader(title: advanced ? "Advanced" : "Settings",
                             backLabel: advanced ? "Back to settings" : "Back to camera") {
                if advanced { advanced = false } else { onBack() }
            }
            ScrollView {
                VStack(spacing: 18) {
                    if advanced { advancedCards } else { commonCards }
                    Text("GLASSCAM").font(.system(size: 10, weight: .medium)).tracking(4)
                        .foregroundStyle(.white.opacity(0.25)).padding(.vertical, 18)
                }.padding(.horizontal, 20).padding(.top, 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
        }
        .background(CameraSettingsBackground()).foregroundStyle(.white)
        .preferredColorScheme(.dark).tint(.white).buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.22), value: advanced)
    }

    @ViewBuilder private var commonCards: some View {
        CameraCard(title: "Photo output", symbol: "photo.stack") {
            Picker("Capture priority", selection: $settings.captureQuality) {
                ForEach(CaptureQuality.allCases, id: \.self) { quality in Text(quality.title).tag(quality) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.captureQuality")
            if settings.captureQuality == .f5 {
                HStack { Text("Sampling"); Spacer(); Text("2× in each dimension").foregroundStyle(.secondary) }
                Text("F5 combines four main exposures and one short exposure. It uses the main camera’s native view and a 2× output grid. Detail can fall back locally when motion or highlights cannot be recovered.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                Picker("Resolution", selection: outputSelection) {
                    ForEach([24,48],id:\.self) { value in Text("\(value) MP").tag(value) }
                }.pickerStyle(.segmented).disabled(physicalCameraID == nil || options.isEmpty)
                    .accessibilityIdentifier("settings.resolution")
            }
            HStack { Text("Format"); Spacer(); Text("10-bit HDR HEIF").foregroundStyle(.secondary) }.font(.subheadline)
            if settings.captureQuality != .f5 {
                Text("Photos save automatically. In 48 MP mode, smaller framed sources save at 24 MP.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
        }
        if settings.captureQuality == .f5 { F5SettingsCard(camera: camera, settings: settings, canRecord: canRecordF5) }
        CameraCard(title: "Photo style", symbol: "camera.filters") {
            Picker("Color engine", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.engine")
            if settings.colorMode == .hncs {
                Picker("Phocus preset", selection: $settings.hncs.presetKey) {
                    ForEach(HNCSEngine.cameraPresets) { preset in Text(preset.name).tag(preset.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.preset")
                Picker("White balance", selection: $settings.hncs.whiteBalancePolicy) {
                    ForEach(HNCSWhiteBalancePolicy.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.whiteBalance")
                Text(LocalizedStringKey(settings.hncs.whiteBalancePolicy == .photo
                     ? "Keeps each photo’s own white balance."
                     : "Uses the original preset white balance, when specified."))
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            } else if settings.colorMode == .ffcs {
                Picker("Film simulation", selection: $settings.simulationIndex) {
                    ForEach(FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)) { look in Text(look.name).tag(look.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("ffcs.simulation")
            } else {
                LUMIXPhotoStyleControls(settings: $settings.lumix)
            }
            HStack {
                Text("Effect exposure")
                Spacer()
                Text(String(format: "%+.2f EV", settings.exposure)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
            Slider(value: $settings.exposure, in: -2...2, step: 0.05)
                .accessibilityLabel("Photo effect exposure")
            EffectToggleControls(effects: $settings.effects, mode: settings.colorMode)
        }
        CameraCard(title: "Viewfinder", symbol: "viewfinder") {
            Toggle("Composition grid", isOn: $settings.gridVisible).accessibilityIdentifier("settings.grid")
            Text("The clear central frame is your photo. The outer glass darkens when camera views cannot align reliably.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
        Button { advanced = true } label: {
            CameraCard(title: "Advanced", symbol: "slider.horizontal.3") {
                HStack {
                    Text("Color processing & preview").font(.subheadline)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }
            }
        }.accessibilityIdentifier("settings.advanced")
    }

    @ViewBuilder private var advancedCards: some View {
        CameraCard(title: "Color processing", symbol: "slider.horizontal.3") {
            if settings.colorMode == .hncs {
                HNCSPresetControls(settings: $settings.hncs, showCommon: false)
            } else if settings.colorMode == .ffcs {
                FFCSReferenceControls(settings: $settings.ffcs, simulationIndex: $settings.simulationIndex)
            } else {
                LUMIXPhotoStyleControls(settings: $settings.lumix)
                Text("Keeps each photo’s own white balance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        CameraCard(title: "Preview", symbol: "viewfinder") {
            Picker("Preview long-edge limit", selection: $settings.centerPreviewLongEdge) {
                ForEach(CameraSettingsStore.centerPreviewCaps, id: \.self) { value in Text("\(value) px").tag(value) }
            }.pickerStyle(.menu)
            Toggle("Experimental live color (approx.)", isOn: $settings.experimentalLiveColor)
            Text("Approximate color only; the saved photo uses the complete selected effect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        CameraCard(title: "Adjustments", symbol: "arrow.counterclockwise") {
            Button("Reset effect adjustments") {
                settings.exposure = 0
                if settings.colorMode == .hncs { settings.hncs = .standard }
            }
            Text("Resets effect exposure and the HNCS look. Output, grain and sharpening choices stay saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CameraLookPicker: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    let selected: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Picker("Color engine", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            if settings.colorMode == .hncs {
                ForEach(HNCSEngine.cameraPresets) { look in
                    lookButton(look.name, active: settings.hncs.presetKey == look.id) {
                        settings.hncs.presetKey = look.id; selected()
                    }
                }
            } else if settings.colorMode == .ffcs {
                ForEach(FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)) { look in
                    lookButton(look.name, active: settings.simulationIndex == look.id) {
                        settings.simulationIndex = look.id; selected()
                    }
                }
            } else {
                ForEach(LUMIXEngine.looks) { look in
                    lookButton(look.name, active: settings.lumix.photoStyle == look.id) {
                        settings.lumix.photoStyle = look.id; selected()
                    }
                }
            }
        }
    }
    private func lookButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 23, weight: .regular, design: .serif))
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "circle").foregroundStyle(.white.opacity(active ? 1 : 0.2))
            }.padding(18).background(.white.opacity(active ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
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
                    .accessibilityLabel("HDR photo")
                    .accessibilityAction(named: "Zoom in") { zoom = min(5, zoom + 1) }
                    .accessibilityAction(named: "Reset zoom") { zoom = 1; pan = .zero }
            }.clipped().background(Color.black)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                if let description = capture.resolutionDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("review.resolution")
                }
                if let white = capture.snapshot.recipe.whiteBalanceDescription {
                    Text(white).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("review.whiteBalance")
                }
                }.padding(8).frame(maxWidth: .infinity).background(Color.black)
            }
            .navigationTitle("\(capture.width) × \(capture.height) · HDR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Camera", action: onBack) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share HDR photo")
                }
            }
        }.preferredColorScheme(.dark).tint(.white)
            .sheet(isPresented: $sharing) { ShareSheet(file: capture.file) }
    }
}
