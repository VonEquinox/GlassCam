import SwiftUI
import MetalKit
import CoreImage
import QuartzCore
import OSLog

struct PeripheralGlassView: UIViewRepresentable {
    let source: PeripheralFrameSource?
    let framing: CameraFraming
    let enabled: Bool

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
        }
        view.delegate = context.coordinator
        context.coordinator.configure(source: source, framing: framing, enabled: enabled)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.configure(source: source, framing: framing, enabled: enabled)
        view.isPaused = (!enabled || source == nil) && context.coordinator.isBlack
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true; view.delegate = nil; coordinator.source = nil
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var source: PeripheralFrameSource?
        private var framing = CameraFraming(size: .zero, photoAspectRatio: 0.75)
        private var enabled = false
        private var worker = PeripheralAlignmentWorker()
        private var policy = PeripheralGlassPolicy()
        private var texture: MTLTexture?
        private var spareTexture: MTLTexture?
        private var blackTexture: MTLTexture?
        private var lastSerial: UInt64 = 0
        private var lastEpoch: UInt64 = 0
        private var sourceRevision: UInt64 = 0
        private var uploadedSourceRevision: UInt64 = .max
        private var queue: MTLCommandQueue?
        private var context: CIContext?
        private var pipeline: MTLRenderPipelineState?
        private var inFlight = false
        private var lastMatrix = matrix_identity_float3x3
        private var lastGain = SIMD3<Float>(repeating: 1)
        private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var isBlack: Bool { policy.opacity(at: CACurrentMediaTime()) >= 0.9999 }

        override init() {
            super.init()
            guard let device else { return }
            queue = device.makeCommandQueue()
            let blackDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: 1, height: 1, mipmapped: false)
            blackDescriptor.storageMode = .shared
            blackDescriptor.usage = .shaderRead
            blackTexture = device.makeTexture(descriptor: blackDescriptor)
            [UInt16](repeating: 0, count: 4).withUnsafeBytes { bytes in
                blackTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: 8)
            }
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
                .workingColorSpace: colorSpace, .workingFormat: CIFormat.RGBAh.rawValue])
            do {
                let library = try device.makeLibrary(source: PeripheralGlassShader.source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
                descriptor.colorAttachments[0].pixelFormat = .rgba16Float
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                Logger(subsystem: "dev.glasscam.prototype", category: "PeripheralGlass")
                    .error("Glass shader unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        func configure(source: PeripheralFrameSource?, framing: CameraFraming, enabled: Bool) {
            if self.source !== source {
                self.source = source; worker = PeripheralAlignmentWorker()
                sourceRevision &+= 1
                // Keep the last coherent texture/transform while darkening.
                // A new source must upload its own frame even if serials match.
                policy.update(error: nil, available: false, at: CACurrentMediaTime())
            }
            self.framing = framing; self.enabled = enabled
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        static func coversWindow(_ matrix: simd_float3x3, framing: CameraFraming,
                                 outerWidth: Int, outerHeight: Int) -> Bool {
            let r = framing.photo, w = framing.window
            guard r.width > 0, r.height > 0, outerWidth > 0, outerHeight > 0 else { return false }
            // The largest blur/refraction footprint is 9.6 source texels.
            // Include the linear-sampling footprint, even at the smallest cap.
            let margin = SIMD2<Float>(11 / Float(outerWidth), 11 / Float(outerHeight))
            for p in [CGPoint(x: 0,y: 0),CGPoint(x: w.width,y: 0),
                      CGPoint(x: 0,y: w.height),CGPoint(x: w.width,y: w.height)] {
                let normalized = SIMD2(Float((p.x-r.minX)/r.width), Float((p.y-r.minY)/r.height))
                guard let uv = PeripheralAlignmentWorker.project(normalized, using: matrix),
                      uv.x >= margin.x, uv.x <= 1-margin.x,
                      uv.y >= margin.y, uv.y <= 1-margin.y else { return false }
            }
            return true
        }

        func draw(in view: MTKView) {
            guard view.window != nil, !inFlight, let device, let queue, let context, let pipeline,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  framing.window.width > 0, framing.window.height > 0 else { return }
            let now = CACurrentMediaTime()
            let pair = source?.latest()
            if enabled, let pair, now-pair.receipt < 0.25 { worker.request(pair) }
            let alignment = worker.latest()
            let valid: Bool
            if enabled, let pair, let alignment {
                let frameAspect = Double(CVPixelBufferGetWidth(pair.center)) / Double(CVPixelBufferGetHeight(pair.center))
                let photoAspect = Double(framing.photo.width / framing.photo.height)
                valid = pair.epoch == alignment.epoch && now-pair.receipt < 0.25 &&
                    abs(frameAspect-alignment.photoAspectRatio) < 0.001 && abs(frameAspect-photoAspect) < 0.001 &&
                    now-alignment.receipt < 0.6 && Self.coversWindow(alignment.photoToOuter, framing: framing,
                        outerWidth: CVPixelBufferGetWidth(pair.outer), outerHeight: CVPixelBufferGetHeight(pair.outer))
            } else { valid = false }
            let scale = min(framing.photo.width,framing.photo.height) / min(framing.window.width,framing.window.height)
            let error = valid ? alignment.map { $0.residual * Double(scale) } : nil
            policy.update(error: error, available: valid, at: now, measuredAt: alignment?.receipt)
            guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer() else { return }
            var renderTask: CIRenderTask?
            if let pair, let alignment, valid, let error, error <= PeripheralGlassPolicy.darkeningThreshold,
               policy.targetOpacity == 0 || policy.opacity(at: now) < 1,
               pair.serial != lastSerial || pair.epoch != lastEpoch || uploadedSourceRevision != sourceRevision {
                let width = CVPixelBufferGetWidth(pair.outer), height = CVPixelBufferGetHeight(pair.outer)
                if spareTexture?.width != width || spareTexture?.height != height {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                        width: width, height: height, mipmapped: false)
                    descriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]
                    spareTexture = device.makeTexture(descriptor: descriptor)
                }
                if let candidate = spareTexture {
                    do {
                        renderTask = try PreviewRendering.render(CIImage(cvPixelBuffer: pair.outer), with: context,
                            to: candidate, commandBuffer: command, colorSpace: colorSpace)
                        // Publish texture, transform and gain together. A failed
                        // upload can never expose a newly allocated texture.
                        spareTexture = texture; texture = candidate
                        lastSerial = pair.serial; lastEpoch = pair.epoch
                        uploadedSourceRevision = sourceRevision
                        lastMatrix = alignment.photoToOuter; lastGain = alignment.gain
                    } catch {
                        spareTexture = nil
                        policy.update(error: nil, available: false, at: now)
                    }
                } else { policy.update(error: nil, available: false, at: now) }
            }
            guard let sampledTexture = texture ?? blackTexture,
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                // The upload was only encoded, never submitted. Do not retain
                // it as a successfully rendered frame for the next draw.
                texture = nil; spareTexture = nil; lastSerial = 0
                policy.update(error: nil, available: false, at: now)
                return
            }
            let r = framing.photo, w = framing.window
            var uniforms = PeripheralGlassUniforms(
                photo: SIMD4(Float(r.minX/w.width),Float(r.minY/w.height),Float(r.width/w.width),Float(r.height/w.height)),
                viewport: SIMD2(Float(drawable.texture.width),Float(drawable.texture.height)),
                blackOpacity: lastSerial == 0 ? 1 : Float(policy.opacity(at: now)),
                photoToOuter: lastMatrix, gain: SIMD4(lastGain,1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PeripheralGlassUniforms>.stride, index: 0)
            encoder.setFragmentTexture(sampledTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            inFlight = true
            command.addCompletedHandler { [weak self, pair, renderTask, sampledTexture] result in
                withExtendedLifetime((pair,renderTask,sampledTexture)) {}
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    if result.status == .error {
                        self.lastSerial = 0
                        self.texture = nil; self.spareTexture = nil
                        self.policy.update(error: nil, available: false, at: CACurrentMediaTime())
                    }
                }
            }
            command.present(drawable); command.commit()
            if (!enabled || source == nil) && isBlack { view.isPaused = true }
        }
    }
}
