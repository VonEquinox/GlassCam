import SwiftUI
import AVFoundation
import UIKit

/// Full-window live camera. The color recipe is applied only after DNG capture.
/// No SwiftUI view, glass overlay, peripheral image, or screenshot enters that DNG.
struct CameraView: View {
    @Binding var colorMode: ColorMode
    @Binding var simulationIndex: Int
    let onCapture: (Data, ExportSettings) -> Void
    let onClose: () -> Void
    @StateObject private var camera = CameraController()
    @StateObject private var settings = CameraSettingsStore()
    @State private var selectedLens: CameraController.Mode = .main
    @State private var captureError: String?

    var body: some View {
        GeometryReader { proxy in
            let framing = CameraFraming(size: proxy.size,
                                        photoAspectRatio: camera.geometry?.photoAspectRatio ?? 1,
                                        controlBand: max(112, 92 + (proxy.size.width > proxy.size.height
                                            ? max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
                                            : max(proxy.safeAreaInsets.top, proxy.safeAreaInsets.bottom))),
                                        centerHorizontalFieldOfView: camera.geometry?.centerHorizontalFieldOfView,
                                        peripheralHorizontalFieldOfView: camera.geometry?.peripheralHorizontalFieldOfView,
                                        peripheralAspectRatio: orientedPeripheralAspectRatio)
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
                ForEach(Array(framing.perimeter.enumerated()), id: \.offset) { _, pane in
                    Color.clear
                        .frame(width: pane.width, height: pane.height)
                        .modifier(CameraPaneGlass())
                        .clipped()
                        .position(x: pane.midX, y: pane.midY)
                        .allowsHitTesting(false)
                }
                // This opaque-backed layer is above every perimeter glass pane.
                // There is deliberately no glass modifier or rounded clipping here.
                if let layer = camera.centerPreviewLayer, camera.geometry != nil {
                    CameraPreview(layer: layer, gravity: .resizeAspect)
                        .background(.black)
                        .frame(width: framing.photo.width, height: framing.photo.height)
                        .clipped()
                        .position(x: framing.photo.midX, y: framing.photo.midY)
                        .accessibilityLabel("Unprocessed system camera preview inside the photograph frame")
                }
                if !camera.isReady || !coverageAvailable(framing) {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(camera.isReady && !coverageAvailable(framing)
                             ? "Wider physical camera cannot cover this window at the matched field-of-view scale. Rotate or resize the window, or choose Ultra."
                             : camera.status).font(.callout).multilineTextAlignment(.center)
                        if !camera.isReady && !camera.isConfiguring {
                            Button("Retry camera") { restartCamera() }
                                .padding(10).modifier(CameraControlGlass())
                        }
                    }
                    .padding(16)
                    .frame(width: max(0, framing.photo.width), height: max(0, framing.photo.height))
                    .background(.black)
                    .position(x: framing.photo.midX, y: framing.photo.midY)
                }
                controls(framing: framing, safeArea: proxy.safeAreaInsets)
                CameraOrientationObserver { camera.updateOrientation($0) }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { restartCamera() }
        .onDisappear { camera.stop() }
        .onChange(of: selectedLens) { _, _ in restartCamera() }
        .onChange(of: settings.centerPreviewLongEdge) { _, _ in restartCamera() }
        .onChange(of: settings.peripheralPreviewLongEdge) { _, _ in restartCamera() }
        .alert("Couldn’t capture ProRAW", isPresented: Binding(get: { captureError != nil }, set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) { captureError = nil }
        } message: { Text(captureError ?? "Unknown capture error") }
    }

    @ViewBuilder
    private func controls(framing: CameraFraming, safeArea: EdgeInsets) -> some View {
        if framing.usesVerticalControls {
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    closeButton
                    lensMenu
                    colorMenu
                    settingsMenu
                }.frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
            .padding(.top, max(12, safeArea.top))
            .padding(.leading, max(8, safeArea.leading))
            .padding(.trailing, 8)
            .frame(width: framing.photo.minX, height: framing.window.height)
            .clipped()
            VStack(spacing: 12) {
                previewLabel
                Spacer(minLength: 0)
                shutter(coverageAvailable: coverageAvailable(framing))
                Spacer(minLength: 0)
                recipeLabel
            }
            .padding(.vertical, 14)
            .padding(.leading, 8)
            .padding(.trailing, max(8, safeArea.trailing))
            .frame(width: framing.window.width - framing.photo.maxX, height: framing.window.height)
            .clipped()
            .offset(x: framing.photo.maxX)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 6) { closeButton; Spacer(minLength: 0); lensMenu; colorMenu; settingsMenu }
                previewLabel
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, max(12, safeArea.top))
            .frame(width: framing.window.width, height: framing.photo.minY)
            .clipped()
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                recipeLabel
                shutter(coverageAvailable: coverageAvailable(framing))
                Spacer(minLength: 0)
            }
            .padding(.bottom, max(8, safeArea.bottom))
            .frame(width: framing.window.width, height: framing.window.height - framing.photo.maxY)
            .clipped()
            .offset(y: framing.photo.maxY)
        }
    }

    private var previewLabel: some View {
        Text(selectedLens == .ultraWide ? "SYSTEM PREVIEW · ProRAW"
             : "SYSTEM PREVIEW · APPROX. ALIGNMENT / PARALLAX")
            .font(.system(size: 10, weight: .semibold)).tracking(1)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.8))
    }

    private var recipeLabel: some View {
        Text("\(colorMode == .ffcs ? FFCSEngine.simulationName(at: simulationIndex) : colorMode.title) after capture")
            .font(.caption2).multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.8))
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").frame(width: 40, height: 40)
        }.modifier(CameraControlGlass()).accessibilityLabel("Close camera")
            .disabled(camera.isCapturing)
    }

    private var lensMenu: some View {
        Menu {
            Picker("Physical camera", selection: $selectedLens) {
                ForEach(CameraController.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
        } label: {
            Text(selectedLens == .ultraWide ? "Ultra" : selectedLens == .telephoto ? "Tele" : "Main")
                .font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, 10).frame(height: 40)
        }.modifier(CameraControlGlass()).disabled(camera.isCapturing || camera.isConfiguring)
    }

    private var colorMenu: some View {
        Menu {
            Picker("Color after capture", selection: $colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            if colorMode == .ffcs {
                Picker("Film simulation", selection: $simulationIndex) {
                    ForEach(FFCSEngine.simulations) { simulation in Text(simulation.name).tag(simulation.id) }
                }
            }
        } label: {
            Text(colorMode.title).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 40)
        }.modifier(CameraControlGlass()).disabled(camera.isCapturing)
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
            // A changed runtime graph may lower the cap. Never silently exceed it.
            return choices.last(where: { $0.megapixels <= saved })
        }
        return choices.first
    }

    private var outputSelection: Binding<Int> {
        Binding(get: { selectedOutput?.megapixels ?? 0 }, set: { value in
            guard let cameraID = camera.physicalCameraID,
                  camera.supportedOutputOptions.contains(where: { $0.megapixels == value }) else { return }
            settings.setOutputMegapixels(value, physicalCameraID: cameraID, mode: selectedLens.rawValue)
        })
    }

    private var settingsMenu: some View {
        Menu {
            if camera.supportedOutputOptions.isEmpty {
                Text("Output unavailable for this camera configuration")
            } else {
                Picker("\(selectedLens.title) output", selection: outputSelection) {
                    ForEach(camera.supportedOutputOptions) { option in
                        Text("\(option.megapixels) MP · \(option.width) × \(option.height)")
                            .tag(option.megapixels)
                    }
                }
            }
            Menu("Live preview resolution") {
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
                if let dimensions = camera.centerPreviewDimensions {
                    Text("Center: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
                }
                if let dimensions = camera.peripheralPreviewDimensions {
                    Text("Periphery: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
                }
            }
            if let dimensions = camera.sourceCaptureDimensions {
                Text("ProRAW source: \(Int(dimensions.width)) × \(Int(dimensions.height)) px")
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "slider.horizontal.3")
                if let output = selectedOutput { Text("\(output.megapixels) MP").font(.system(size: 9)) }
            }.frame(width: 40, height: 40)
        }
        .modifier(CameraControlGlass())
        .disabled(camera.isCapturing || camera.isConfiguring)
        .accessibilityLabel("Output and preview settings")
    }

    private func restartCamera() {
        camera.start(mode: selectedLens,
                     centerPreviewLongEdge: settings.centerPreviewLongEdge,
                     peripheralPreviewLongEdge: settings.peripheralPreviewLongEdge)
    }

    private func shutter(coverageAvailable: Bool) -> some View {
        Button {
            guard coverageAvailable, let output = selectedOutput else { return }
            // Snapshot dimensions before exposure. Later UI changes cannot retarget
            // this source; ExportSettings is retained with its processing recipe.
            let portrait = (camera.geometry?.photoAspectRatio ?? 1) < 1
            let export = ExportSettings(targetWidth: portrait ? output.height : output.width,
                                        targetHeight: portrait ? output.width : output.height)
            camera.captureProRAW { result in
                switch result {
                case .success(let data): onCapture(data, export)
                case .failure(let error): captureError = error.localizedDescription
                }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 66, height: 66)
                if camera.isCapturing { ProgressView() }
                else { Circle().fill(.white).frame(width: 52, height: 52) }
            }.padding(4)
        }
        .modifier(CameraControlGlass())
        .disabled(!camera.isReady || camera.isCapturing || selectedOutput == nil || !coverageAvailable)
        .accessibilityLabel("Capture Apple ProRAW DNG")
    }
}

private struct CameraPaneGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else { content.background(.ultraThinMaterial) }
        #else
        content.background(.ultraThinMaterial)
        #endif
    }
}

private struct CameraControlGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.plain).background(.ultraThinMaterial, in: Capsule()) }
        #else
        content.buttonStyle(.plain).background(.ultraThinMaterial, in: Capsule())
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
