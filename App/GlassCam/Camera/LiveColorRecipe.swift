import ImagingCore
import Capture
import F5
import Peripheral
import CHNCS
import CFFCS
import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MetalKit
import QuartzCore
import SwiftUI
import UIKit

/// Experimental pointwise viewfinder only. Never used by ImagePipeline/export.
/// CPU studies cover [0,1] linear sRGB, EV=0 and HNCS CCT=5500 or 6500.
struct LiveColorRecipe: Equatable {
    let resources: ColorResources
    let mode: ColorMode
    let simulationIndex: Int
    let exposureEV: Double
    let illuminantKelvin: Double
    let hncs: HNCSSettings
    // Snapshot/cache identity includes the photo stage choices. The cube still
    // renders color only and never bakes grain, sharpening or a geometric crop.
    let effects: EffectToggles
    let ffcs: FFCSSettings
    let lumix: LUMIXSettings
    init(resources: ColorResources, mode: ColorMode, simulationIndex: Int, exposureEV: Double, illuminantKelvin: Double,
         hncs: HNCSSettings, effects: EffectToggles, ffcs: FFCSSettings, lumix: LUMIXSettings = .standard) {
        self.resources = resources; self.mode = mode; self.simulationIndex = simulationIndex; self.exposureEV = exposureEV
        self.illuminantKelvin = illuminantKelvin; self.hncs = hncs; self.effects = effects
        self.ffcs = ffcs; self.lumix = lumix
    }
    @MainActor init(resources: ColorResources, settings: CameraSettingsStore, simulationIndex: Int? = nil) {
        self.init(resources: resources, mode: settings.colorMode,
            simulationIndex: simulationIndex ?? settings.simulationIndex, exposureEV: settings.exposure,
            illuminantKelvin: 5500, hncs: settings.colorMode == .hncs ? settings.hncs : .standard,
            effects: settings.effects, ffcs: settings.colorMode == .ffcs ? settings.ffcs : .standard,
            lumix: settings.colorMode == .lumix ? settings.lumix : .standard)
    }
    static let dimension = 65
    // A recipe/cache identity must change if an asset, engine or domain changes.
    let contract = "v8:ffcs-native-mapping-xh2s-provia-acros:pointwise-only:linear-srgb01:srgb-shaped65:float32-rgba-rfast:display-linear:trilinear"

    var unsupportedReason: String? {
        if mode == .hncs {
            return "HNCS uses each captured RAW photo's white balance. Showing system preview."
        }
        if mode == .lumix {
            return "LUMIX Photo Style applies to saved photos. Showing system preview."
        }
        guard exposureEV == 0 else { return "Experimental live color needs photo exposure 0 EV. Showing system preview." }
        if mode == .ffcs {
            guard ffcs.isValid,
                  (0..<Int(ffcs_simulation_count())).contains(simulationIndex),
                  FFCSEngine.isSimulationAvailable(resources: resources, simulationIndex, family: ffcs.cameraFamily) else {
                return "This FFCS recipe or native LUT asset is unavailable. Showing system preview."
            }
            guard ffcs.cameraFamily == .xh2s, !ffcs.applyReferenceAdjustments,
                  ffcs.sharpenRadius == 1.0, [0, 8].contains(simulationIndex) else {
            return "Use XH2S PROVIA or ACROS with default reference adjustments for live color. Showing system preview."
            }
            // This proxy uses the same current mapping as photo export.
            // It remains a trilinear approximation in the viewfinder.
        }
        return nil
    }
}
