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

struct LiveColorProxyStatus: Equatable {
    let isShowingEffect: Bool
    let text: String
    static let off = LiveColorProxyStatus(isShowingEffect: false, text: "System preview · live color off")
}

/// Color processing for the paired drawable. It transforms only the center
/// image from that exact pair; it owns no separate frame queue or presentation.
final class PairedLiveColorProcessor {
    private let cubes=LiveColorCubeStore()
    private var cube:LiveColorCube?
    private var filter:CIFilter?
    private var recipe:LiveColorRecipe?
    private var enabled=false
    private var ready=false
    private var callback:((LiveColorProxyStatus)->Void)?
    private var lastStatus:LiveColorProxyStatus?
    private(set) var revision:UInt64=0
    private(set) var currentFrameUsesEffect=false

    func configure(recipe:LiveColorRecipe?,enabled:Bool,cameraReady:Bool,onStatus:((LiveColorProxyStatus)->Void)?) {
        callback=onStatus
        guard self.recipe != recipe || self.enabled != enabled || ready != cameraReady else {return}
        self.recipe=recipe;self.enabled=enabled;ready=cameraReady;revision &+= 1
        cubes.cancel();cube=nil;filter=nil;currentFrameUsesEffect=false
        guard enabled,let recipe else {report(.off);return}
        if let reason=recipe.unsupportedReason {report(.init(isShowingEffect:false,text:reason));return}
        guard cameraReady else {report(.init(isShowingEffect:false,text:"Live color waiting for camera · system preview"));return}
        report(.init(isShowingEffect:false,text:"Preparing experimental live color · system preview"))
        let ticket=revision
        cubes.request(recipe) { [weak self] result in
            guard let self,self.revision==ticket,self.enabled,self.ready else {return}
            switch result {
            case .success(let cube):
                guard let filter=CIFilter(name:"CIColorCube") else {return}
                filter.setValue(LiveColorRecipe.dimension,forKey:"inputCubeDimension")
                filter.setValue(cube.rgbaFloat32Data,forKey:"inputCubeData")
                self.cube=cube;self.filter=filter
                self.revision &+= 1
            case .failure(let error):self.report(.init(isShowingEffect:false,text:error.localizedDescription))
            }
        }
    }
    func image(for pair:PeripheralFrameSource.Pair)->CIImage? {
        currentFrameUsesEffect=false
        guard enabled,ready,let filter,let sample=pair.centerSampleBuffer,
              let frame=LiveCameraFrame(sampleBuffer:sample,generation:pair.epoch) else {return nil}
        if let reason=LiveSourceValidation.validate(frame) {
            report(.init(isShowingEffect:false,text:reason));return nil
        }
        let image=CIImage(cvPixelBuffer:frame.pixelBuffer).cropped(to:frame.cleanRect)
        let bounded=image.applyingFilter("CIColorClamp",parameters:[
            "inputMinComponents":CIVector(x:0,y:0,z:0,w:1),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
        filter.setValue(bounded.applyingFilter("CILinearToSRGBToneCurve"),forKey:kCIInputImageKey)
        defer {filter.setValue(nil,forKey:kCIInputImageKey)}
        guard let result=filter.outputImage else {return nil}
        currentFrameUsesEffect=true
        return result.applyingFilter("CIColorClamp",parameters:[
            "inputMinComponents":CIVector(x:0,y:0,z:0,w:1),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
    }
    func completed(revision:UInt64,applied:Bool,success:Bool) {
        guard revision==self.revision,applied else {return}
        report(.init(isShowingEffect:success,text:success ? "EXPERIMENTAL APPROX. COLOR · 8-BIT SOURCE · COLOR ONLY":
            "Live color failed on the GPU. Showing system preview."))
    }
    private func report(_ value:LiveColorProxyStatus) {
        guard lastStatus != value else {return};lastStatus=value
        DispatchQueue.main.async { [weak self] in
            guard let self,self.lastStatus==value else {return};self.callback?(value)
        }
    }
    deinit {cubes.cancel(clearCache:true)}
}
