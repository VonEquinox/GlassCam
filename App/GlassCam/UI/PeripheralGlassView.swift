import SwiftUI
import MetalKit
import CoreImage
import QuartzCore
import OSLog

struct PeripheralGlassView: UIViewRepresentable {
    let source: PeripheralFrameSource?
    let framing: CameraFraming
    let enabled: Bool
    var colorRecipe: LiveColorRecipe?
    var colorEnabled = false
    var cameraReady = false
    var onColorStatus: ((LiveColorProxyStatus) -> Void)?

    func makeCoordinator() -> Renderer { Renderer() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isOpaque = false; view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.wantsExtendedDynamicRangeContent = true
            layer.maximumDrawableCount = 2
        }
        view.delegate = context.coordinator
        context.coordinator.view=view
        context.coordinator.configure(source: source, framing: framing, enabled: enabled)
        context.coordinator.configureColor(recipe:colorRecipe,enabled:colorEnabled,cameraReady:cameraReady,onStatus:onColorStatus)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.configure(source: source, framing: framing, enabled: enabled)
        context.coordinator.configureColor(recipe:colorRecipe,enabled:colorEnabled,cameraReady:cameraReady,onStatus:onColorStatus)
        view.isPaused = (!enabled || source == nil) && context.coordinator.isBlack
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true; view.delegate = nil; coordinator.stop()
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var source: PeripheralFrameSource?
        weak var view:MTKView?
        private let wakeLock=NSLock()
        private var wakePending=false
        private var lastDrawPair:UInt64=0
        private var lastDrawAt = -Double.infinity
        private var framing = CameraFraming(size: .zero, photoAspectRatio: 0.75)
        private var enabled = false
        private var worker = PeripheralAlignmentWorker()
        private var live = PeripheralLivePipeline()
        private var queue: MTLCommandQueue?
        private var context: CIContext?
        private var pipeline: MTLRenderPipelineState?
        private let color = PairedLiveColorProcessor()
        private var blackTexture: MTLTexture?
        private let textures = PeripheralLiveTextureStore()
        private var sourceRevision: UInt64 = 0
        private var sourceEpoch: UInt64 = .max
        private var commandID: UInt64 = 0
        private var inFlight = false
        private var tolerance = PeripheralTolerance.shared.value
        private var lastOpacity = 1.0
        private let recordingRendererID = UUID().uuidString
        private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var isBlack: Bool { lastOpacity >= 0.9999 }

        override init() {
            super.init()
            guard let device else { return }
            queue = device.makeCommandQueue()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:1,height:1,mipmapped:false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            blackTexture = device.makeTexture(descriptor:descriptor)
            [UInt16](repeating:0,count:4).withUnsafeBytes {
                blackTexture?.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:8)
            }
            if let queue {
                context = CIContext(mtlCommandQueue:queue,options:[.cacheIntermediates:false,
                    .workingColorSpace:colorSpace,.workingFormat:CIFormat.RGBAh.rawValue])
            }
            do {
                let library = try device.makeLibrary(source:PeripheralGlassShader.source,options:nil)
                let state = MTLRenderPipelineDescriptor()
                state.vertexFunction = library.makeFunction(name:"glassVertex")
                state.fragmentFunction = library.makeFunction(name:"pairedPreviewFragment")
                state.colorAttachments[0].pixelFormat = .rgba16Float
                pipeline = try device.makeRenderPipelineState(descriptor:state)
            } catch { PeripheralDiagnostics.trace("shader: \(error.localizedDescription)") }
        }
        func configureColor(recipe:LiveColorRecipe?,enabled:Bool,cameraReady:Bool,onStatus:((LiveColorProxyStatus)->Void)?) {
            color.configure(recipe:recipe,enabled:enabled,cameraReady:cameraReady,onStatus:onStatus)
        }
        func configure(source: PeripheralFrameSource?, framing: CameraFraming, enabled: Bool) {
            let oldAspect = self.framing.photo.width/max(1,self.framing.photo.height)
            let newAspect = framing.photo.width/max(1,framing.photo.height)
            let changedFraming = abs(oldAspect-newAspect) > 0.001 ||
                PeripheralSeams(photo:self.framing.photo,window:self.framing.window.size) != PeripheralSeams(photo:framing.photo,window:framing.window.size)
            if self.source !== source || changedFraming {
                self.source?.observeFrames(nil)
                self.source = source; worker = PeripheralAlignmentWorker(); sourceRevision &+= 1
                reset(epoch:source?.selection().epoch ?? 0)
                source?.observeFrames { [weak self,weak source] in self?.wake(for:source) }
            }
            self.framing = framing; self.enabled = enabled
        }
        private func wake(for sender:PeripheralFrameSource?) {
            wakeLock.lock()
            guard !wakePending else {wakeLock.unlock();return}
            wakePending=true;wakeLock.unlock()
            DispatchQueue.main.async { [weak self,weak sender] in
                guard let self else {return}
                self.wakeLock.lock();self.wakePending=false;self.wakeLock.unlock()
                guard self.source === sender,self.enabled,let view=self.view,view.window != nil else {return}
                view.draw()
            }
        }
        func stop() {source?.observeFrames(nil);source=nil;view=nil}
        private func reset(epoch: UInt64) {
            sourceEpoch = epoch; live = PeripheralLivePipeline()
            textures.reset(); lastOpacity = 1
            lastDrawPair=0;lastDrawAt = -.infinity
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        static func coversWindow(_ matrix: simd_float3x3, framing: CameraFraming,
                                 outerWidth: Int, outerHeight: Int, minimumMargin: Float = 2) -> Bool {
            let r = framing.photo, w = framing.window
            guard r.width > 0, r.height > 0 else { return false }
            let window = CGRect(x:-r.minX/r.width,y:-r.minY/r.height,width:w.width/r.width,height:w.height/r.height)
            return (PeripheralProjection.margin(matrix,window: window,width: outerWidth,height: outerHeight) ?? -.infinity) >= minimumMargin
        }
        func draw(in view: MTKView) {
            guard !inFlight, view.window != nil, let device, let queue, let context, let pipeline,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  framing.photo.width > 0, framing.photo.height > 0 else { return }
            if let pair=source?.latest(),pair.serial==lastDrawPair,CACurrentMediaTime()-lastDrawAt<1/60 {return}
            // Acquire first, then select the newest immutable pair. Waiting for
            // a drawable must not age a preselected camera frame.
            guard let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,
                  let command=queue.makeCommandBuffer() else {return}
            let now = CACurrentMediaTime(), pair = source?.latest(), epoch = source?.selection().epoch ?? 0
            if epoch != sourceEpoch { reset(epoch:epoch) }
            tolerance = PeripheralTolerance.shared.value
            let seams = PeripheralSeams(photo:framing.photo,window:framing.window.size)
            let activeEdges = (0..<4).filter { $0 < 2 ? seams.contains(.horizontal) : seams.contains(.vertical) }
            let window = CGRect(x:-framing.photo.minX/framing.photo.width,y:-framing.photo.minY/framing.photo.height,
                width:framing.window.width/framing.photo.width,height:framing.window.height/framing.photo.height)
            let sourceAvailable = enabled && pair.map { now >= $0.observedAt && now-$0.observedAt <= PeripheralLivePipeline.pixelLifetime } == true
            if sourceAvailable, let pair { worker.request(pair,seams:seams,window:window) }
            let alignment = worker.latest()
            let currentFrame = live.update(pair:pair,analysis:alignment,enabled:enabled,epoch:epoch,
                seams:seams,window:window,tolerance:tolerance,at:now)
            commandID &+= 1
            lastDrawPair=pair?.serial ?? 0;lastDrawAt=now
            let identity = commandID, revision = sourceRevision
            var uploading: PeripheralLiveTextureStore.Bundle?, task: CIRenderTask?, failedUpload = false
            var reasons: [String] = []
            if let currentFrame {
                do {
                    let prepared = try textures.prepare(currentFrame,revision:revision,at:now,
                        device:device,context:context,command:command,colorSpace:colorSpace,includeCenter:true,
                        centerImage:color.image(for:currentFrame.pair))
                    uploading = prepared?.0; task = prepared?.1
                } catch { failedUpload = true; reasons.append("live-texture-encode-failed") }
            }
            let colorRevision=color.revision,colorApplied=uploading != nil && color.currentFrameUsesEffect
            // CI encodes uploads before this render encoder in the SAME command.
            // Use them immediately instead of waiting for next draw's completion.
            let bundle = uploading ?? textures.completed
            if let failure = textures.failureReason { reasons.append(failure) }
            let resourceValid = live.resourceValid(bundle,revision:revision,at:now)
            if !resourceValid { reasons.append(bundle == nil ? "live-texture-not-ready" : "live-source-or-texture-unavailable") }
            let edgeOpacity = live.opacities(bundle:bundle,revision:revision,at:now,tolerance:tolerance)
            let minimumOpacity = activeEdges.map { edgeOpacity[$0] }.min() ?? 1
            let maximumOpacity = activeEdges.map { edgeOpacity[$0] }.max() ?? 1
            lastOpacity = minimumOpacity
            let alpha = Float(minimumOpacity)
            guard let sampled = bundle?.texture ?? blackTexture,
                  let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return }
            let r = framing.photo, w = framing.window
            var uniforms = PeripheralGlassUniforms(
                photo:SIMD4(Float(r.minX/w.width),Float(r.minY/w.height),Float(r.width/w.width),Float(r.height/w.height)),
                viewport:SIMD2(Float(drawable.texture.width),Float(drawable.texture.height)),blackOpacity:alpha,
                photoToOuter:bundle?.frame.matrix ?? matrix_identity_float3x3,gain:SIMD4(repeating:1))
            uniforms.centerEnabled = resourceValid && bundle?.centerTexture != nil ? 1:0
            uniforms.edgeOpacity = SIMD4(Float(edgeOpacity[0]),Float(edgeOpacity[1]),Float(edgeOpacity[2]),Float(edgeOpacity[3]))
            if let gains = bundle?.frame.gains {
                uniforms.gainTop = SIMD4(gains.top,1); uniforms.gainBottom = SIMD4(gains.bottom,1)
                uniforms.gainLeft = SIMD4(gains.left,1); uniforms.gainRight = SIMD4(gains.right,1)
                if gains.affine(0) { uniforms.gainTop = SIMD4(gains.encodedSlope[0],2); uniforms.biasTop = SIMD4(gains.encodedBias[0],0) }
                if gains.affine(1) { uniforms.gainBottom = SIMD4(gains.encodedSlope[1],2); uniforms.biasBottom = SIMD4(gains.encodedBias[1],0) }
                if gains.affine(2) { uniforms.gainLeft = SIMD4(gains.encodedSlope[2],2); uniforms.biasLeft = SIMD4(gains.encodedBias[2],0) }
                if gains.affine(3) { uniforms.gainRight = SIMD4(gains.encodedSlope[3],2); uniforms.biasRight = SIMD4(gains.encodedBias[3],0) }
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
            encoder.setFragmentTexture(sampled,index:0)
            encoder.setFragmentTexture(bundle?.centerTexture ?? blackTexture,index:1)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            PeripheralStateRecorder.shared.updateRenderer([
                "phase":"submitted","hostTime":now,"rendererID":recordingRendererID,
                "commandID":identity,"sourceRevision":revision,"epoch":epoch,
                "tolerance":tolerance,"textureTolerance":bundle?.frame.tolerance ?? .nan,
                "enabled":enabled,"sourceAvailable":sourceAvailable,"alignmentValid":alignment?.isFresh(for:epoch,at:now) == true,
                "policyMode":"fixed-direct-stitch-with-raw-seam-shading",
                "evidenceBasis":"display-preference-separate-from-physical-certification",
                "rejectionReasons":reasons,"analysisGateReasons":alignment?.gateReasons ?? [],
                "effectiveBlackOpacity":alpha,"opacityMode":"per-edge","opacityCoupling":"top-bottom-maximum",
                "effectiveBlackOpacityRange":[minimumOpacity,maximumOpacity],
                "edgeBlackOpacities":edgeOpacity,"activeEdges":activeEdges,"edgePolicyReasons":live.reasons,
                "directStitch":true,"edgeAssessments":live.assessments,
                "presentationMode":"single-command-paired-preview",
                "centerTexturePairID":uniforms.centerEnabled > 0 ? bundle?.frame.pair.serial ?? 0:0,
                "renderedCenterPTS":uniforms.centerEnabled > 0 ? bundle?.frame.pair.centerMetadata?.pts ?? .nan:Double.nan,
                "renderedOuterPTS":bundle?.frame.pair.outerMetadata?.pts ?? .nan,
                "cameraExposureSkew":bundle?.frame.pair.ptsDelta ?? .nan,
                "captureMode":bundle?.frame.pair.captureMode ?? "unavailable",
                "applicationAddedFrameSkew":uniforms.centerEnabled > 0 ? 0:Double.nan,
                "usesCurrentCommandUpload":uploading != nil,
                "targetOpacity":activeEdges.map {live.targets[$0]}.min() ?? 0,
                "policyReason":live.lastReason,"forcedBlack":!resourceValid,"latched":false,
                "textureValid":resourceValid,"textureReadiness":uploading != nil ? "encoding" : (bundle == nil ? "notPreparedYet" : "completed"),
                "texturePairID":bundle?.frame.pair.serial ?? 0,"textureEpoch":bundle?.frame.pair.epoch ?? 0,
                "textureAnalysisPairID":bundle?.frame.analysisPairID ?? 0,
                "textureAnalysisObservedAt":bundle?.frame.analysisObservedAt ?? .nan,
                "textureRefinementID":bundle?.frame.refinement?.id ?? 0,
                "textureRefinementStrength":bundle?.frame.refinementStrength ?? 0,
                "textureMappingBasis":bundle?.frame.mappingBasis ?? "no-resource",
                "texturePhotoToOuter_columns":bundle.map { PeripheralRecordJSON.matrix($0.frame.matrix) } ?? [],
                "textureEdgeGains":bundle.map { PeripheralRecordJSON.edgeGains($0.frame.gains) } ?? [:],
                "analysisAge":live.lastAnalysisAge,"worker":worker.runtimeState(),
                "textureAge":now-(bundle?.frame.pair.observedAt ?? -.infinity),"failedUpload":failedUpload,
                "submittedDisplaySkew":source?.displaySkew(outerPTS:bundle?.frame.pair.outerMetadata?.pts) ?? .nan,
                "alignment":PeripheralRecordJSON.alignment(alignment),
                "sourceState":source?.diagnosticState() ?? "no-source",
                "photoRect":[r.minX,r.minY,r.width,r.height],"windowSize":[w.width,w.height]],
                pair:pair,texturePair:bundle?.frame.pair,analysis:worker.latestDiagnostic(),renderedFrame:bundle?.frame)
            inFlight = true
            let recordingID = recordingRendererID
            command.addCompletedHandler { [weak self, uploading, task, bundle, sampled, currentFrame] completed in
                withExtendedLifetime((task,bundle,sampled,currentFrame)) {}
                PeripheralStateRecorder.shared.gpuEvent(["rendererID":recordingID,"commandID":identity,
                    "epoch":epoch,"sourceRevision":revision,"event":"gpu-completed",
                    "hostTime":CACurrentMediaTime(),"status":completed.status.rawValue,
                    "error":completed.error?.localizedDescription ?? ""])
                DispatchQueue.main.async {
                    guard let self else { return }; self.inFlight = false
                    guard self.sourceRevision == revision, self.source?.selection().epoch == epoch else { return }
                    self.color.completed(revision:colorRevision,applied:colorApplied,success:completed.status == .completed)
                    if let uploading {
                        self.textures.complete(uploading,success:completed.status == .completed,
                            revision:revision,epoch:epoch,at:CACurrentMediaTime())
                    }
                    if completed.status == .error { PeripheralDiagnosticRecorder.shared.trigger("gpu-command-error") }
                }
            }
#if !targetEnvironment(simulator)
            drawable.addPresentedHandler { value in
                PeripheralStateRecorder.shared.gpuEvent(["rendererID":recordingID,"commandID":identity,
                    "epoch":epoch,"sourceRevision":revision,"event":"peripheral-drawable-presented",
                    "hostTime":CACurrentMediaTime(),"presentedTime":value.presentedTime])
            }
#endif
            command.present(drawable); command.commit()
            if (!enabled || source == nil) && isBlack { view.isPaused = true }
        }

    }
}

/// System Liquid Glass over exactly the window-minus-photo panes. The clear
/// variant keeps the wider-lens scene transmitted; darkening comes from the
/// Metal layer beneath, so opaque black reads as black glass. No pane, rim or
/// lensing footprint is placed inside the central photograph.
struct PeripheralLiquidGlass: View {
    let framing: CameraFraming
    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .topLeading) {
                ForEach(Array(framing.perimeter.enumerated()), id: \.offset) { _, pane in
                    Rectangle().fill(.clear)
                        .glassEffect(.clear, in: Rectangle())
                        .frame(width: pane.width, height: pane.height)
                        .position(x: pane.midX, y: pane.midY)
                }
            }
            .frame(width: framing.window.width, height: framing.window.height, alignment: .topLeading)
        }
        .mask {
            Path { path in
                for pane in framing.perimeter { path.addRect(pane) }
            }.fill(.white)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
