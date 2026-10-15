import SwiftUI
import UIKit

/// Camera is the permanent home. Photo processing belongs to the root-owned
/// workflow, so opening settings/review never dismisses or retargets a shot.
struct ContentView: View {
    @StateObject private var settings = CameraSettingsStore()
    @StateObject private var workflow = CaptureWorkflow(services: .live(
        authorize: { try await HEIFSaveDelivery.authorizePhotos() },
        save: { try await HEIFSaveDelivery.saveToPhotos($0) }))

    var body: some View {
        CameraView(settings: settings, workflow: workflow)
            .preferredColorScheme(.dark)
    }
}

struct HNCSPresetControls: View {
    @Binding var settings: HNCSSettings

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
        Toggle("Override factory CCT", isOn: Binding(
            get: { settings.factoryKelvinOverride != nil },
            set: { settings.factoryKelvinOverride = $0 ? 6500 : nil }))
        if let kelvin = settings.factoryKelvinOverride {
            Stepper("Factory CCT: \(Int(kelvin)) K", value: Binding(
                get: { settings.factoryKelvinOverride ?? 6500 },
                set: { settings.factoryKelvinOverride = $0 }), in: 2000...10000, step: 50)
        }
        Text("Photo white balance is read automatically. WB presets apply their look relative to that photo. Factory CCT override changes the color profile only; it does not change photo white balance.")
            .font(.caption).foregroundStyle(.secondary)
        Text("As Shot uses Standard because Apple inputs have no Phocus curve metadata. Standard, Low and High share the recovered V1 family; Old Standard is distinct only in legacy space. Reproduction uses the pure curve. Grain and sharpening follow the portable reference, not proprietary Phocus kernels.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Shared gates remain editable even when a look has no matching stage. Their
/// saved state survives preset/mode changes; only source-defined stages run.
struct EffectToggleControls: View {
    @Binding var effects: EffectToggles
    let mode: ColorMode
    let hncs: HNCSSettings
    private var presetFlags: UInt32 {
        HNCSEngine.presets.first { $0.id == hncs.presetKey }?.flags ?? 0
    }

    var body: some View {
        Toggle("Preset USM / sharpening", isOn: $effects.applySharpness)
            .accessibilityIdentifier("effects.sharpening")
        Toggle("Preset grain", isOn: $effects.applyGrain)
            .accessibilityIdentifier("effects.grain")
        Toggle("Preset extra crop", isOn: $effects.applyExtraCrop)
            .accessibilityIdentifier("effects.extraCrop")
        Text("Each switch uses only the current preset's parameters. Your choices stay saved when you change presets or engines.")
            .font(.caption).foregroundStyle(.secondary)
        if mode == .ffcs {
            Text("FFCS 0.2 native LUTs have neutral postprocessing: enabling grain or sharpening alone adds nothing. Reference analytic adjustments are a separate opt-in. FFCS has no extra crop; this crop choice stays saved for HNCS.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            if hncs.presetKey == "standard" {
                Text("Standard bypasses preset grain and sharpening. Enabling either switch adds no effect to this preset.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if presetFlags & 4 == 0 {
                    Text("This HNCS preset has no grain stage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if presetFlags & (8 | 16) == 0 {
                    Text("This HNCS preset has no sharpening stage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if presetFlags & 4 != 0 && effects.applyGrain {
                Text("Grain uses image dimensions and whole-image statistics. Its preview pattern can differ from the full-source export, even with the same recipe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hncs.presetKey == "square-crop" {
                Text(effects.applyExtraCrop
                     ? "Centered 1:1 crop. Output keeps genuine pixels; its megapixel count is lower than the full-sensor selection."
                     : "Extra crop is off. The full source aspect and selected sensor output are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This HNCS preset has no extra crop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        Text("Research LUT asset family, not the iPhone capture camera. Only native available looks are listed; no analytic fallback.")
            .font(.caption).foregroundStyle(.secondary)
        if let actualFamily = FFCSEngine.resolvedAssetFamily(simulationIndex, family: settings.cameraFamily) {
            Text(actualFamily == settings.cameraFamily.rawValue
                 ? "Actual LUT asset family: \(actualFamily)"
                 : "Actual LUT asset family: \(actualFamily). The source-defined native GFX fallback is active for this look.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("ffcs.actualAssetFamily")
        } else {
            Text("This native LUT asset is unavailable. Choose another look or family.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Reference analytic adjustments (approx.)", isOn: $settings.applyReferenceAdjustments)
            .accessibilityIdentifier("ffcs.referenceAdjustments")
        Text("FFCS 0.2 corrects the previous default: native LUT rendering is neutral after the LUT. Existing grain, sharpening and crop switches stay saved. Opt in to approximate reference tone/color, grain and Gaussian sharpening; grain and sharpening still obey their own switches.")
            .font(.caption).foregroundStyle(.secondary)
        if settings.applyReferenceAdjustments {
            Stepper("Reference sharpening radius: \(settings.sharpenRadius, specifier: "%.1f") px",
                    value: $settings.sharpenRadius, in: 0.1...5.0, step: 0.1)
                .accessibilityIdentifier("ffcs.sharpenRadius")
        }
    }
}
