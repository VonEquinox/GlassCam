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
    init(mode: ColorMode, simulationIndex: Int, exposureEV: Double, illuminantKelvin: Double,
         hncs: HNCSSettings, effects: EffectToggles, ffcs: FFCSSettings, lumix: LUMIXSettings = .standard) {
        self.mode = mode; self.simulationIndex = simulationIndex; self.exposureEV = exposureEV
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
                  FFCSEngine.isSimulationAvailable(simulationIndex, family: ffcs.cameraFamily) else {
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

/// Retains the original tagged buffer and timing. AVCapture has already applied
/// rotation/mirroring to the delivered raster; never rotate or flip it again.
final class LiveCameraFrame {
    let pixelBuffer: CVPixelBuffer
    let formatDescription: CMVideoFormatDescription
    let presentationTime: CMTime
    // Local monotonic receipt time is only a freshness watchdog. Keep the real
    // capture presentationTime separately; never substitute this for capture PTS.
    let receivedHostTime: CFTimeInterval
    let generation: UInt64
    let cleanRect: CGRect
    init?(sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        self.pixelBuffer = pixelBuffer
        self.formatDescription = format
        self.presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        self.receivedHostTime = CACurrentMediaTime()
        self.generation = generation
        self.cleanRect = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: false)
    }
}

/// One REPLACEABLE pending frame, distinct from the raw fallback display layer.
/// Only the renderer takes frames. Capture never waits for a drawable/the GPU.
final class LiveCameraFrameSource {
    private let lock = NSLock()
    private var latestFrame: LiveCameraFrame?
    private var generation: UInt64 = 0
    private var active = true
    private var enabled = false

    func reset(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; active = true; latestFrame = nil
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; generation &+= 1; latestFrame = nil
    }
    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
        if !enabled { latestFrame = nil }
    }
    func offer(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard active, enabled, self.generation == generation else { return }
        latestFrame = LiveCameraFrame(sampleBuffer: sampleBuffer, generation: generation)
    }
    func takeLatest() -> LiveCameraFrame? {
        lock.lock(); defer { lock.unlock() }
        guard active, enabled else { latestFrame = nil; return nil }
        let frame = latestFrame; latestFrame = nil
        return frame
    }
    func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return generation
    }
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active && enabled && self.generation == generation
    }
}

private enum LiveProxyFailure: LocalizedError {
    case unavailable(String), cancelled
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message; case .cancelled: return "Live color build superseded." }
    }
}

private final class LiveColorCube {
    let recipe: LiveColorRecipe
    let rgbaFloat32Data: Data
    init(recipe: LiveColorRecipe, rgbaFloat32Data: Data) {
        self.recipe = recipe; self.rgbaFloat32Data = rgbaFloat32Data
    }
}

/// One utility worker + one replaceable requested recipe, with a two-cube LRU.
/// Cancellation is checked between 65²-node slabs, never a CPU camera-frame job.
private final class LiveColorCubeStore {
    private struct Request {
        let recipe: LiveColorRecipe
        let revision: UInt64
        let completion: (Result<LiveColorCube, Error>) -> Void
    }
    private let queue = DispatchQueue(label: "dev.glasscam.live-color-bake", qos: .utility)
    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    private var revision: UInt64 = 0
    private var cache: [LiveColorCube] = []
    private let cacheLimit = 2

    func request(_ recipe: LiveColorRecipe, completion: @escaping (Result<LiveColorCube, Error>) -> Void) {
        lock.lock()
        revision &+= 1
        pending = Request(recipe: recipe, revision: revision, completion: completion)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }
    func cancel(clearCache: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1; pending = nil
        if clearCache { cache.removeAll() }
    }
    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return revision == ticket
    }
    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else { running = false; lock.unlock(); return }
            pending = nil
            let cachedIndex = cache.firstIndex { $0.recipe == request.recipe }
            let cached = cachedIndex.map { cache.remove(at: $0) }
            if let cached { cache.append(cached) }
            lock.unlock()
            let result: Result<LiveColorCube, Error> = Result {
                if let cached { return cached }
                return try bake(request.recipe, ticket: request.revision)
            }
            lock.lock()
            let current = revision == request.revision
            if current, cached == nil, case .success(let cube) = result {
                cache.append(cube)
                if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
            }
            lock.unlock()
            guard current else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(request.revision) else { return }
                request.completion(result)
            }
        }
    }
    private func bake(_ recipe: LiveColorRecipe, ticket: UInt64) throws -> LiveColorCube {
        if let reason = recipe.unsupportedReason { throw LiveProxyFailure.unavailable(reason) }
        let n = LiveColorRecipe.dimension, slabPixels = n * n
        var rgba = [Float](repeating: 0, count: n * n * n * 4)
        var input = [Float](repeating: 0, count: slabPixels * 3)
        var message = [CChar](repeating: 0, count: 1024)
        var hncs: OpaquePointer?
        var ffcs: OpaquePointer?
        if recipe.mode == .hncs {
            hncs = hncs_create(recipe.exposureEV, recipe.illuminantKelvin)
            guard hncs != nil else { throw LiveProxyFailure.unavailable("HNCS live-color core could not initialize.") }
        } else if recipe.mode == .ffcs {
            guard let resources = Bundle.main.resourceURL else {
                throw LiveProxyFailure.unavailable("Original FFCS resources are unavailable.")
            }
            let directory = resources.appendingPathComponent("FFCS", isDirectory: true)
            ffcs = directory.path.withCString { path in
                recipe.ffcs.cameraFamily.rawValue.withCString { family in
                    message.withUnsafeMutableBufferPointer { error in
                        ffcs_create_family_config(path, family, recipe.simulationIndex,
                            recipe.effects.applyGrain ? 1 : 0, recipe.effects.applySharpness ? 1 : 0,
                            recipe.ffcs.applyReferenceAdjustments ? 1 : 0, recipe.ffcs.sharpenRadius,
                            error.baseAddress, error.count)
                    }
                }
            }
            guard ffcs != nil else { throw LiveProxyFailure.unavailable(String(cString: message)) }
        } else {
            throw LiveProxyFailure.unavailable("This color engine uses the system viewfinder preview.")
        }
        defer {
            if let hncs { hncs_destroy(hncs) }
            if let ffcs { ffcs_destroy(ffcs) }
        }
        func inverseSRGB(_ index: Int) -> Float {
            let q = Double(index) / Double(n - 1)
            return Float(q <= 0.04045 ? q / 12.92 : pow((q + 0.055) / 1.055, 2.4))
        }
        let nodes = (0..<n).map(inverseSRGB)
        for blue in 0..<n {
            guard isCurrent(ticket) else { throw LiveProxyFailure.cancelled }
            // CIColorCube layout: R varies fastest, then G, then B.
            for green in 0..<n {
                for red in 0..<n {
                    let p = (green * n + red) * 3
                    input[p] = nodes[red]; input[p + 1] = nodes[green]; input[p + 2] = nodes[blue]
                }
            }
            let success = input.withUnsafeBufferPointer { source in
                rgba.withUnsafeMutableBufferPointer { output in
                    let destination = output.baseAddress!.advanced(by: blue * slabPixels * 4)
                    if let hncs {
                        return hncs_process_linear_rgba(hncs, source.baseAddress, destination, slabPixels) == 0
                    }
                    return message.withUnsafeMutableBufferPointer { error in
                        ffcs_process_linear_rgb_color_only(ffcs, source.baseAddress, source.count,
                            slabPixels, destination, slabPixels * 4, error.baseAddress, error.count) == 1
                    }
                }
            }
            guard success else { throw LiveProxyFailure.unavailable("Live-color core failed: \(String(cString: message))") }
        }
        guard isCurrent(ticket) else { throw LiveProxyFailure.cancelled }
        guard rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              stride(from: 3, to: rgba.count, by: 4).allSatisfy({ rgba[$0] == 1 }) else {
            throw LiveProxyFailure.unavailable("Live-color cube violates its display-linear RGBA contract.")
        }
        return LiveColorCube(recipe: recipe, rgbaFloat32Data: rgba.withUnsafeBytes { Data($0) })
    }
}

private enum LiveSourceValidation {
    /// Require authoritative buffer tags. Format-description tags detect conflicts;
    /// they are never a reason to silently relabel an untagged buffer as Rec.709.
    static func validate(_ frame: LiveCameraFrame) -> String? {
        let buffer = frame.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format),
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return "Live color requires tagged 8-bit NV12 video." }
        // This also rejects aperture, aspect and chroma-attachment discrepancies,
        // rather than cropping one interpretation while CI decodes another.
        guard CMVideoFormatDescriptionMatchesImageBuffer(frame.formatDescription, imageBuffer: buffer) else {
            return "Live color paused: camera format and buffer metadata disagree."
        }
        func attachment(_ key: CFString) -> CFTypeRef? {
            // Copy imports as ARC-managed CFTypeRef; no Unmanaged conversion.
            CVBufferCopyAttachment(buffer, key, nil)
        }
        func colorTag(_ key: CFString, formatKey: CFString) -> String? {
            guard let value = attachment(key) as? String else { return nil }
            if let other = CMFormatDescriptionGetExtension(frame.formatDescription, extensionKey: formatKey) as? String,
               other != value { return nil }
            return value
        }
        guard let primaries = colorTag(kCVImageBufferColorPrimariesKey, formatKey: kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = colorTag(kCVImageBufferTransferFunctionKey, formatKey: kCMFormatDescriptionExtension_TransferFunction),
              let matrix = colorTag(kCVImageBufferYCbCrMatrixKey, formatKey: kCMFormatDescriptionExtension_YCbCrMatrix) else {
            return "Live color paused: missing or conflicting camera color tags."
        }
        guard [kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
               kCVImageBufferColorPrimaries_P3_D65 as String].contains(primaries),
              [kCVImageBufferTransferFunction_ITU_R_709_2 as String,
               kCVImageBufferTransferFunction_sRGB as String].contains(transfer),
              [kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
               kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String].contains(matrix) else {
            return "Live color paused: this HDR/log or color encoding has not been validated."
        }
        // CI owns actual YCbCr/chroma conversion; retain its original attachments.
        let top = attachment(kCVImageBufferChromaLocationTopFieldKey) as? String
        let bottom = attachment(kCVImageBufferChromaLocationBottomFieldKey) as? String
        if let top, let bottom, top != bottom { return "Live color does not support interlaced chroma locations." }
        for location in [top, bottom].compactMap({ $0 }) {
            let supported = [kCVImageBufferChromaLocation_Left as String,
                             kCVImageBufferChromaLocation_Center as String,
                             kCVImageBufferChromaLocation_TopLeft as String]
            guard supported.contains(location) else { return "Live color does not support this chroma location." }
        }
        if let aspect = attachment(kCVImageBufferPixelAspectRatioKey) as? [String: Any] {
            guard let horizontal = aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber,
                  let vertical = aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber,
                  horizontal.doubleValue.isFinite, vertical.doubleValue.isFinite,
                  horizontal.doubleValue > 0, horizontal.doubleValue == vertical.doubleValue else {
                return "Live color requires square camera pixels."
            }
        }
        let raster = CGRect(x: 0, y: 0, width: CGFloat(CVPixelBufferGetWidth(buffer)),
                            height: CGFloat(CVPixelBufferGetHeight(buffer)))
        guard !frame.cleanRect.isEmpty, !frame.cleanRect.isInfinite, !frame.cleanRect.isNull,
              raster.contains(frame.cleanRect) else { return "Live color received an invalid clean aperture." }
        return nil
    }
}

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

/// The system AVSampleBufferDisplayLayer stays underneath this view at all times.
/// Opacity changes only after valid GPU completion, never a SwiftUI image update.
struct LiveColorProxy: UIViewRepresentable {
    let source: LiveCameraFrameSource
    let recipe: LiveColorRecipe
    let enabled: Bool
    let cameraReady: Bool
    let onStatus: (LiveColorProxyStatus) -> Void

    func makeCoordinator() -> Renderer { Renderer() }
    func makeUIView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = LiveColorProxyView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.sampleCount = 1
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityLabel = "Experimental approximate color-only live preview"
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = renderer.colorSpace
            layer.wantsExtendedDynamicRangeContent = false
        }
        view.delegate = renderer
        view.windowChanged = { [weak renderer] in renderer?.updateWindowAvailability() }
        renderer.attach(view)
        renderer.update(source: source, recipe: recipe, enabled: enabled, cameraReady: cameraReady, onStatus: onStatus)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(source: source, recipe: recipe, enabled: enabled, cameraReady: cameraReady, onStatus: onStatus)
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        (view as? LiveColorProxyView)?.windowChanged = nil
        coordinator.stop()
        view.delegate = nil
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        let colorSpace: CGColorSpace
        private let queue: MTLCommandQueue?
        private let context: CIContext?
        private let cubes = LiveColorCubeStore()
        private var cube: LiveColorCube?
        // Main-thread-only mutable filter, rebuilt only when the cube changes.
        private var cubeFilter: CIFilter?
        private var recipe: LiveColorRecipe?
        private var source: LiveCameraFrameSource?
        private weak var view: MTKView?
        private var displayLink: CADisplayLink?
        private var displayTarget: LiveDisplayLinkTarget?
        private var active = false
        private var requestedEnabled = false
        private var cameraReady = false
        private var inFlight = false
        private var revision: UInt64 = 0
        private var sessionGeneration: UInt64 = 0
        private var presentationRevision: UInt64 = 0
        private var hasWindow = false
        private var lastPresentedReceiptTime: CFTimeInterval?
        private static let maximumFrameAge: CFTimeInterval = 0.5
        private var onStatus: ((LiveColorProxyStatus) -> Void)?
        private var lastStatus: LiveColorProxyStatus?
        // Retained timing for instrumentation, never used to manufacture timestamps.
        private(set) var lastPresentedTimestamp: CMTime = .invalid

        override init() {
            // Use locals during phase-one initialization; do not read self until
            // every stored property is initialized.
            let device = MTLCreateSystemDefaultDevice()
            let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            self.device = device; self.colorSpace = colorSpace
            if let device {
                queue = device.makeCommandQueue()
                context = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: colorSpace,
                    .workingFormat: CIFormat.RGBAf.rawValue,
                    .cacheIntermediates: false
                ])
            } else { queue = nil; context = nil }
            super.init()
        }
        func attach(_ view: MTKView) {
            self.view = view
            let target = LiveDisplayLinkTarget()
            target.renderer = self
            let link = CADisplayLink(target: target, selector: #selector(LiveDisplayLinkTarget.tick))
            link.preferredFramesPerSecond = 60
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayTarget = target; displayLink = link
            updateWindowAvailability()
        }
        fileprivate func updateWindowAvailability() {
            let available = view?.window != nil
            guard available != hasWindow else { return }
            hasWindow = available
            source?.setEnabled(active && available)
            displayLink?.isPaused = !(active && available)
            hidePresentation()
            if active {
                report(.init(isShowingEffect: false, text: available
                    ? "Live color waiting for a fresh camera frame · system preview"
                    : "Live color paused while the view is offscreen"))
            }
        }
        private func hidePresentation() {
            presentationRevision &+= 1
            lastPresentedTimestamp = .invalid
            lastPresentedReceiptTime = nil
            view?.alpha = 0
        }
        private func waitForFrame(_ message: String) {
            hidePresentation()
            report(.init(isShowingEffect: false, text: message))
        }
        func update(source: LiveCameraFrameSource, recipe: LiveColorRecipe, enabled: Bool,
                    cameraReady: Bool, onStatus: @escaping (LiveColorProxyStatus) -> Void) {
            self.onStatus = onStatus
            guard self.source !== source || self.recipe != recipe || requestedEnabled != enabled || self.cameraReady != cameraReady else { return }
            self.source?.setEnabled(false)
            revision &+= 1
            hidePresentation()
            cubes.cancel()
            cube = nil; cubeFilter = nil
            self.source = source; self.recipe = recipe
            requestedEnabled = enabled; self.cameraReady = cameraReady
            active = enabled && cameraReady
            displayLink?.isPaused = !(active && hasWindow)
            sessionGeneration = source.currentGeneration()
            guard enabled else { active = false; report(.off); return }
            if let reason = recipe.unsupportedReason { fail(reason); return }
            guard cameraReady else { report(.init(isShowingEffect: false, text: "Live color waiting for camera · system preview")); return }
            guard device != nil, context != nil, queue != nil else {
                fail("Metal live color is unavailable. Showing system preview."); return
            }
            source.setEnabled(hasWindow)
            report(.init(isShowingEffect: false, text: "Preparing experimental live color · system preview"))
            let ticket = revision
            cubes.request(recipe) { [weak self] result in
                guard let self, self.active, self.revision == ticket else { return }
                switch result {
                case .success(let cube):
                    guard let filter = CIFilter(name: "CIColorCube") else {
                        self.fail("Live color cube is unavailable. Showing system preview."); return
                    }
                    filter.setValue(LiveColorRecipe.dimension, forKey: "inputCubeDimension")
                    filter.setValue(cube.rgbaFloat32Data, forKey: "inputCubeData")
                    self.cube = cube; self.cubeFilter = filter
                    self.report(.init(isShowingEffect: false, text: "Live color waiting for a fresh camera frame · system preview"))
                case .failure(let error): self.fail("Live color unavailable: \(error.localizedDescription) System preview remains available.")
                }
            }
        }
        fileprivate func tick() {
            guard active, hasWindow, let source, let view else { return }
            let generation = source.currentGeneration()
            if generation != sessionGeneration || !source.isCurrent(generation) {
                sessionGeneration = generation
                waitForFrame("Live color waiting for a current camera frame · system preview")
                guard source.isCurrent(generation) else { return }
            }
            if let receipt = lastPresentedReceiptTime, CACurrentMediaTime() - receipt > Self.maximumFrameAge {
                waitForFrame("Live color paused: camera frame expired · system preview")
            }
            // With no new frame draw() returns before asking for a drawable.
            view.draw()
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Reject an older drawable completion if layout changes mid-flight.
            hidePresentation()
        }
        func draw(in view: MTKView) {
            guard active, hasWindow, view.window != nil, !inFlight,
                  let source, let cube, let filter = cubeFilter, let context, let queue,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  let frame = source.takeLatest(), source.isCurrent(frame.generation) else { return }
            guard CACurrentMediaTime() - frame.receivedHostTime <= Self.maximumFrameAge else {
                waitForFrame("Live color paused: camera frame expired · system preview"); return
            }
            if let reason = LiveSourceValidation.validate(frame) {
                waitForFrame(reason + " Showing system preview.")
                return
            }
            guard let drawable = view.currentDrawable else {
                waitForFrame("Live color waiting for a GPU drawable · system preview"); return
            }
            // Drawable acquisition may wait; reject a frame that aged during it.
            guard CACurrentMediaTime() - frame.receivedHostTime <= Self.maximumFrameAge else {
                waitForFrame("Live color paused: camera frame expired · system preview"); return
            }
            guard let commandBuffer = queue.makeCommandBuffer() else {
                fail("Live color could not create a GPU command. Showing system preview."); return
            }
            // Keep buffer color management ON; do not label camera YCbCr as linear.
            let input = CIImage(cvPixelBuffer: frame.pixelBuffer).cropped(to: frame.cleanRect)
            // Deliberate experimental input-domain clamp. P3 negative/extended
            // components lose information; no highlight preservation claim.
            let bounded = input.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            let coordinates = bounded.applyingFilter("CILinearToSRGBToneCurve")
            filter.setValue(coordinates, forKey: kCIInputImageKey)
            // The reusable filter must not retain an extra camera buffer between
            // draws. The immutable output graph owns its input for this command.
            defer { filter.setValue(nil, forKey: kCIInputImageKey) }
            guard var output = filter.outputImage else {
                fail("Live color cube failed. Showing system preview."); return
            }
            // Cube outputs ALREADY display-linear. No inverse curve after cube,
            // no encoded-sRGB tag and no CIColorCubeWithColorSpace reinterpretation.
            output = output.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            let aperture = frame.cleanRect
            let size = CGSize(width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
            let bounds = CGRect(origin: .zero, size: size)
            let scale = min(size.width / aperture.width, size.height / aperture.height)
            output = output.cropped(to: aperture)
                .transformed(by: CGAffineTransform(translationX: -aperture.minX, y: -aperture.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (size.width - aperture.width * scale) / 2,
                                                   y: (size.height - aperture.height * scale) / 2))
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
                .cropped(to: bounds)
            let ticket = revision, presentationTicket = presentationRevision
            let renderTask: CIRenderTask
            do {
                renderTask = try PreviewRendering.render(output, with: context, to: drawable.texture,
                                                         commandBuffer: commandBuffer, colorSpace: colorSpace)
            } catch {
                fail("Live color could not prepare a GPU render. Showing system preview."); return
            }
            inFlight = true
            commandBuffer.addCompletedHandler { [weak self, frame, cube, renderTask] buffer in
                // CI's deferred evaluation may still read this CVPixelBuffer and
                // cube when the view/recipe/session is replaced. Own both to here.
                withExtendedLifetime(frame) {}
                withExtendedLifetime(cube) {}
                withExtendedLifetime(renderTask) {}
                let failed = buffer.status == .error
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    guard self.active, self.hasWindow, self.view?.window != nil, self.revision == ticket,
                          self.presentationRevision == presentationTicket,
                          source.isCurrent(frame.generation) else { return }
                    if failed { self.fail("Live color failed on the GPU. Showing system preview."); return }
                    guard CACurrentMediaTime() - frame.receivedHostTime <= Self.maximumFrameAge else {
                        self.waitForFrame("Live color paused: GPU frame expired · system preview"); return
                    }
                    self.lastPresentedTimestamp = frame.presentationTime
                    self.lastPresentedReceiptTime = frame.receivedHostTime
                    self.view?.alpha = 1
                    self.report(.init(isShowingEffect: true, text: "EXPERIMENTAL APPROX. COLOR · 8-BIT SOURCE · COLOR ONLY"))
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        private func report(_ status: LiveColorProxyStatus) {
            guard status != lastStatus else { return }
            lastStatus = status
            // Never mutate SwiftUI state from updateUIView or a per-frame publish.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastStatus == status else { return }
                self.onStatus?(status)
            }
        }
        private func fail(_ reason: String) {
            active = false; displayLink?.isPaused = true
            revision &+= 1; hidePresentation()
            cubes.cancel(); cube = nil; cubeFilter = nil
            source?.setEnabled(false)
            report(.init(isShowingEffect: false, text: reason))
        }
        func stop() {
            active = false; revision &+= 1; hidePresentation()
            displayLink?.invalidate(); displayLink = nil; displayTarget = nil
            source?.setEnabled(false); source = nil
            cubes.cancel(clearCache: true); cube = nil; cubeFilter = nil
            view?.alpha = 0; onStatus = nil
            // Never clear inFlight here: only GPU completion releases that slot.
        }
        deinit { displayLink?.invalidate(); cubes.cancel(clearCache: true) }
    }
}

private final class LiveColorProxyView: MTKView {
    // Lifecycle hook only. Drawing methods remain unoverridden and use delegate.
    var windowChanged: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowChanged?()
    }
}

private final class LiveDisplayLinkTarget: NSObject {
    weak var renderer: LiveColorProxy.Renderer?
    @objc func tick() { renderer?.tick() }
}
