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
    static let dimension = 65
    // A recipe/cache identity must change if an asset, engine or domain changes.
    let contract = "v7:hncs-revision11-photo-white-balance/ffcs-0.2-neutral-verified-xh2s-provia-acros-radius1:pointwise-only:linear-srgb01:srgb-shaped65:float32-rgba-rfast:display-linear:trilinear"

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
                return "Experimental FFCS live color is measured only for XH2S PROVIA and ACROS, with neutral native LUT rendering and radius 1. Showing system preview."
            }
            // FFCS 0.2 CPU study: 452,780 held-out colors per look, Float32
            // trilinear cube + RGBA16F display. Still approximate; Apple GPU
            // and device-camera validation remain pending. No spatial stages.
        }
        return nil
    }
}
