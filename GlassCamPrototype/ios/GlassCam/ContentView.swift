import SwiftUI
import UIKit

/// Camera is the permanent home. Photo processing belongs to the root-owned
/// workflow, so opening settings/review never dismisses or retargets a shot.
struct ContentView: View {
    @StateObject private var settings = CameraSettingsStore()
    @StateObject private var workflow = CaptureWorkflow(services: .live(
        authorize: { try await HEIFSaveDelivery.authorizePhotos() },
        save: { try await HEIFSaveDelivery.saveToPhotos($0) }), journal: CaptureJournal(), initiallyActive: false)
    @Environment(\.scenePhase) private var scenePhase

    private func updateProcessingAvailability() {
        workflow.setForeground(scenePhase == .active && UIApplication.shared.isProtectedDataAvailable)
    }

    var body: some View {
        CameraView(settings: settings, workflow: workflow)
            .preferredColorScheme(.dark)
            .onAppear { updateProcessingAvailability() }
            .onChange(of: scenePhase) { _, _ in updateProcessingAvailability() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                workflow.setForeground(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                updateProcessingAvailability()
            }
    }
}

struct HNCSPresetControls: View {
    @Binding var settings: HNCSSettings
    var showCommon = true

    var body: some View {
        if showCommon {
            Picker("Phocus preset", selection: $settings.presetKey) {
                ForEach(HNCSEngine.cameraPresets) { preset in Text(preset.name).tag(preset.id) }
            }
            Picker("White balance", selection: $settings.whiteBalancePolicy) {
                ForEach(HNCSWhiteBalancePolicy.allCases) { policy in Text(LocalizedStringKey(policy.title)).tag(policy) }
            }
            .accessibilityIdentifier("settings.whiteBalance")
        }
        Picker("Film curve", selection: $settings.filmCurve) {
            ForEach(HNCSFilmCurve.allCases) { curve in Text(LocalizedStringKey(curve.title)).tag(curve) }
        }
        Picker("Working space", selection: $settings.workingSpace) {
            ForEach(HNCSWorkingSpace.allCases) { space in Text(LocalizedStringKey(space.title)).tag(space) }
        }
        Picker("Rendering intent", selection: $settings.intent) {
            ForEach(HNCSIntent.allCases) { intent in Text(LocalizedStringKey(intent.title)).tag(intent) }
        }
        Toggle("Preset tone curve", isOn: $settings.applyToneCurve)
        Toggle("Override factory CCT", isOn: Binding(
            get: { settings.factoryKelvinOverride != nil },
            set: { settings.factoryKelvinOverride = $0 ? 6500 : nil }))
        if let kelvin = settings.factoryKelvinOverride {
            Stepper("Factory CCT: \(Int(kelvin)) K", value: Binding(
                get: { settings.factoryKelvinOverride ?? 6500 },
                set: { settings.factoryKelvinOverride = $0 }), in: 2000...10000, step: 50)
        }
        Text("Factory CCT override changes the color profile only; it does not change photo white balance.")
            .font(.caption).foregroundStyle(.secondary)
        Text("As Shot uses the Standard film curve for iPhone photos. The selected preset also supplies its tone and detail settings.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The camera exposes two effect switches. The legacy crop flag remains in
/// serialized recipes for previously saved photos, outside this UI.
struct EffectToggleControls: View {
    @Binding var effects: EffectToggles
    let mode: ColorMode

    var body: some View {
        Toggle("Sharpening", isOn: $effects.applySharpness)
            .accessibilityIdentifier("effects.sharpening")
        Toggle("Grain", isOn: $effects.applyGrain)
            .accessibilityIdentifier("effects.grain")
        Text("Uses this look’s sharpening and grain settings, when available. Your choices stay saved when you change looks.")
            .font(.caption).foregroundStyle(.secondary)
        if mode == .ffcs {
            Text("To add sharpening or grain to FFCS looks, enable additional reference adjustments in Advanced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
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

/// Native research asset selection, separate from the physical capture camera.
struct FFCSReferenceControls: View {
    @Binding var settings: FFCSSettings
    @Binding var simulationIndex: Int

    var body: some View {
        Picker("Reference LUT camera family", selection: $settings.cameraFamily) {
            ForEach(FFCSCameraFamily.allCases) { family in Text(family.rawValue).tag(family) }
        }.accessibilityIdentifier("ffcs.cameraFamily")
        .onChange(of: settings.cameraFamily) { _, family in
            if !FFCSEngine.isSimulationAvailable(simulationIndex, family: family) {
                simulationIndex = FFCSEngine.simulations(for: family).first?.id ?? 0
            }
        }
        Picker("Film simulation", selection: $simulationIndex) {
            ForEach(FFCSEngine.simulations(for: settings.cameraFamily)) { simulation in
                Text(simulation.name).tag(simulation.id)
            }
        }.pickerStyle(.menu).accessibilityIdentifier("ffcs.simulation")
        Text("Choose the camera color reference for this look.")
            .font(.caption).foregroundStyle(.secondary)
        if let actualFamily = FFCSEngine.resolvedAssetFamily(simulationIndex, family: settings.cameraFamily) {
            Text("Color reference: \(actualFamily)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("ffcs.actualAssetFamily")
        } else {
            Text("This native LUT asset is unavailable. Choose another look or family.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Reference analytic adjustments (approx.)", isOn: $settings.applyReferenceAdjustments)
            .accessibilityIdentifier("ffcs.referenceAdjustments")
        Text("Optional tone, color, grain and sharpening adjustments. Grain and sharpening also follow your saved switches.")
            .font(.caption).foregroundStyle(.secondary)
        if settings.applyReferenceAdjustments {
            Stepper("Reference sharpening radius: \(settings.sharpenRadius, specifier: "%.1f") px",
                    value: $settings.sharpenRadius, in: 0.1...5.0, step: 0.1)
                .accessibilityIdentifier("ffcs.sharpenRadius")
        }
    }
}
