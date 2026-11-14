import AVFoundation
import CoreImage
import CFFCS
import MetalKit
import Testing
import UIKit
import ImagingCore
import Capture
import Peripheral
@testable import GlassCam

func liveRecipe(mode: ColorMode = .ffcs, simulation: Int = 0, exposure: Double = 0,
                effects: EffectToggles = .init(), ffcs: FFCSSettings = .standard) -> LiveColorRecipe {
    LiveColorRecipe(resources: .init(resourceDirectory: Bundle.main.resourceURL), mode: mode,
                    simulationIndex: simulation, exposureEV: exposure, illuminantKelvin: 5500,
                    hncs: .standard, effects: effects, ffcs: ffcs)
}

@Suite(.serialized) @MainActor
struct LiveColorTests {
    @Test(arguments: [0,8])
    func measuredFFCSRecipe_isAvailable(simulation: Int) {
        #expect(liveRecipe(simulation: simulation).unsupportedReason == nil)
    }
    @Test(arguments: ["hncs","lumix","exposure","simulation","family","reference","radius"])
    func unmeasuredRecipe_usesSystemPreview(change: String) {
        var ffcs = FFCSSettings.standard
        if change == "family" { ffcs.cameraFamily = .xa3 }
        if change == "reference" { ffcs.applyReferenceAdjustments = true }
        if change == "radius" { ffcs.sharpenRadius = 2 }
        let recipe = liveRecipe(mode: change == "hncs" ? .hncs : change == "lumix" ? .lumix : .ffcs,
                                simulation: change == "simulation" ? 1 : 0, exposure: change == "exposure" ? 1 : 0, ffcs: ffcs)
        #expect(recipe.unsupportedReason != nil)
    }
    @Test func defaultSettings_disableExperimentalPreview() {
        let name = "LiveColorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!CameraSettingsStore(defaults: defaults).experimentalLiveColor)
    }
    @Test(arguments: ["grain","sharpness","crop"])
    func effectChange_invalidatesCubeIdentity(change: String) {
        let effects = EffectToggles(applyGrain: change != "grain", applySharpness: change != "sharpness", applyExtraCrop: change != "crop")
        #expect(liveRecipe(effects: effects) != liveRecipe())
    }
    @Test func cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha() async throws {
        let store = LiveColorCubeStore()
        let recipe = liveRecipe()
        let cube = try await withCheckedThrowingContinuation { continuation in store.request(recipe) { continuation.resume(with: $0) } }
        let floats = cube.rgbaFloat32Data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = LiveColorRecipe.dimension
        let coordinates = [(0,0,0),(n-1,0,0),(0,n-1,0),(0,0,n-1),(n-1,n-1,n-1)]
        let input: [Float] = coordinates.flatMap { [Float($0.0 / (n-1)),Float($0.1 / (n-1)),Float($0.2 / (n-1))] }
        var expected = [Float](repeating: 0, count: coordinates.count * 4)
        var message = [CChar](repeating: 0, count: 1024)
        let directory = try #require(recipe.resources.ffcsDirectory)
        let native = try #require(ffcs_create_family_config(directory.path,"XH2S",0,1,1,0,1,&message,message.count))
        defer { ffcs_destroy(native) }
        let status = ffcs_process_linear_rgb_color_only(native,input,input.count,coordinates.count,&expected,expected.count,&message,message.count)
        let selected = coordinates.flatMap { point -> [Float] in
            let offset = ((point.2*n+point.1)*n+point.0)*4
            return Array(floats[offset..<offset+4])
        }
        #expect(status == 1)
        #expect(selected == expected)
        #expect(stride(from: 3,to: floats.count,by: 4).map { floats[$0] }.allSatisfy { $0 == 1 })
    }
    @Test func replacedBake_onlyCompletesNewestRequest() async throws {
        let worker = DispatchQueue(label: "LiveColorTests.worker")
        worker.suspend()
        let store = LiveColorCubeStore(queue: worker)
        var oldCalls = 0
        store.request(liveRecipe()) { _ in oldCalls += 1 }
        let cube = try await withCheckedThrowingContinuation { continuation in
            store.request(liveRecipe(simulation: 8)) { continuation.resume(with: $0) }
            worker.resume()
        }
        #expect(oldCalls == 0)
        #expect(cube.recipe.simulationIndex == 8)
    }
    @Test func repeatedRecipe_reusesCubeOwner() async throws {
        let store = LiveColorCubeStore()
        let first = try await withCheckedThrowingContinuation { continuation in store.request(liveRecipe()) { continuation.resume(with: $0) } }
        let second = try await withCheckedThrowingContinuation { continuation in store.request(liveRecipe()) { continuation.resume(with: $0) } }
        #expect(first === second)
    }
    @Test func validTaggedNV12_preservesOriginalCaptureTimestamp() throws {
        let sample = try SampleFixture.sample(pts: 120)
        let frame = try #require(LiveCameraFrame(sampleBuffer: sample,generation: 7))
        #expect(LiveSourceValidation.validate(frame) == nil)
        #expect(frame.presentationTime == CMTime(value: 120,timescale: 60))
    }
    @Test(arguments: ["missing-tags","format","aspect","conflict"])
    func invalidFrameMetadata_rejectsProcessing(kind: String) throws {
        let sample = try SampleFixture.sample(format: kind == "format" ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                               tagged: kind != "missing-tags") { buffer in
            if kind == "aspect" {
                CVBufferSetAttachment(buffer,kCVImageBufferPixelAspectRatioKey,
                    [kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 2,
                     kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 1] as CFDictionary,.shouldPropagate)
            }

        }
        let frame = try #require(LiveCameraFrame(sampleBuffer: sample,generation: 7))
        if kind == "conflict" {
            CVBufferSetAttachment(frame.pixelBuffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_P3_D65,.shouldPropagate)
        }
        #expect(LiveSourceValidation.validate(frame) != nil)
    }
    @Test(arguments: [CGRect.zero, .null, .infinite, CGRect(x: -1,y: 0,width: 10,height: 10), CGRect(x: 0,y: 0,width: 100,height: 100)])
    func invalidCleanAperture_isRejected(aperture: CGRect) {
        #expect(!LiveSourceValidation.validAperture(aperture,in: CGRect(x: 0,y: 0,width: 16,height: 12)))
    }
    @Test func apertureFit_keepsOrientationAndCentersWithoutStretching() throws {
        let red = CIImage(color: CIColor(red: 1,green: 0,blue: 0)).cropped(to: CGRect(x: 10,y: 20,width: 4,height: 2))
        let blue = CIImage(color: CIColor(red: 0,green: 0,blue: 1)).cropped(to: CGRect(x: 10,y: 20,width: 2,height: 2))
        let input = blue.composited(over: red)
        let output = LiveColorProxy.Renderer.fit(input,aperture: CGRect(x: 10,y: 20,width: 4,height: 2),size: CGSize(width: 8,height: 8))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var rgba = [Float](repeating: 0,count: 8*8*4)
        context.render(output,toBitmap: &rgba,rowBytes: 8*16,bounds: output.extent,format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        #expect(Array(rgba[(3*8+1)*4..<(3*8+1)*4+3]) == [0,0,1])
        #expect(Array(rgba[(3*8+6)*4..<(3*8+6)*4+3]) == [1,0,0])
        #expect(Array(rgba[0..<3]) == [0,0,0])
    }
}

@Suite(.serialized) @MainActor
struct LivePresentationTests {
    @MainActor final class Harness {
        let window: UIWindow
        let source = LiveCameraFrameSource()
        let renderer: LiveColorProxy.Renderer
        let view: MTKView
        var now: CFTimeInterval = 0
        var statuses: [LiveColorProxyStatus] = []
        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            self.window = window
            var clock: (() -> CFTimeInterval) = { 0 }
            renderer = LiveColorProxy.Renderer(now: { clock() })
            view = MTKView(frame: window.bounds,device: renderer.device)
            let controller = UIViewController(); window.rootViewController = controller
            controller.view.addSubview(view)
            window.makeKeyAndVisible()
            clock = { [weak self] in self?.now ?? 0 }
            source.reset(generation: 7)
            renderer.attach(view)
            renderer.update(source: source,recipe: liveRecipe(),enabled: true,cameraReady: true) { [weak self] in self?.statuses.append($0) }
        }
        func frame() throws -> LiveCameraFrame {
            try #require(view.window != nil)
            try #require(source.isCurrent(source.currentGeneration()))
            let value = try #require(LiveCameraFrame(sampleBuffer: try SampleFixture.sample(),generation: source.currentGeneration()))
            now = value.receivedHostTime
            return value
        }
        func complete(_ frame: LiveCameraFrame, failed: Bool = false, revision: UInt64? = nil, presentation: UInt64? = nil) {
            renderer.completeFrame(frame,source: source,revision: revision ?? renderer.revision,presentation: presentation ?? renderer.presentationRevision,failed: failed)
        }
        deinit { renderer.stop() }
    }
    @Test func successfulGPUCompletion_revealsFrameWithCapturePTS() throws {
        let harness = try Harness(); let frame = try harness.frame()
        harness.complete(frame)
        #expect(harness.view.alpha == 1)
        #expect(harness.renderer.lastPresentedTimestamp == frame.presentationTime)
    }
    @Test(arguments: ["age","gpu","generation","revision","presentation"])
    func staleOrFailedGPUCompletion_staysHidden(cause: String) throws {
        let harness = try Harness(); let frame = try harness.frame()
        if cause == "age" { harness.now += 0.501 }
        if cause == "generation" { harness.source.reset(generation: 8) }
        harness.complete(frame,failed: cause == "gpu",revision: cause == "revision" ? harness.renderer.revision &+ 1 : nil,
                         presentation: cause == "presentation" ? harness.renderer.presentationRevision &+ 1 : nil)
        #expect(harness.view.alpha == 0)
        #expect(!harness.renderer.lastPresentedTimestamp.isValid)
    }
    @Test(arguments: ["stop","offscreen","size","paused","camera-failed","unsupported"])
    func lifecycleChange_revokesPresentedFrame(cause: String) throws {
        let harness = try Harness(); let frame = try harness.frame(); harness.complete(frame)
        switch cause {
        case "stop": harness.renderer.stop()
        case "offscreen": harness.view.removeFromSuperview(); harness.renderer.updateWindowAvailability()
        case "size": harness.renderer.mtkView(harness.view,drawableSizeWillChange: CGSize(width: 200,height: 200))
        default: harness.renderer.update(source: harness.source,recipe: liveRecipe(mode: cause == "unsupported" ? .hncs : .ffcs),
                                         enabled: cause != "paused",cameraReady: cause != "camera-failed") { _ in }
        }
        #expect(harness.view.alpha == 0)
        #expect(!harness.renderer.lastPresentedTimestamp.isValid)
    }
    @Test func statusPublication_isDeferredAndDropsSupersededStatus() async throws {
        let harness = try Harness()
        harness.renderer.update(source: harness.source,recipe: liveRecipe(),enabled: false,cameraReady: true) { [weak harness] in harness?.statuses.append($0) }
        #expect(harness.statuses.isEmpty)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(harness.statuses == [.off])
    }
}

@Suite(.serialized) @MainActor
struct PairedRendererTests {
    @MainActor final class Harness {
        let window: UIWindow
        let source = PeripheralFrameSource()
        let renderer: PeripheralGlassView.Renderer
        let view: MTKView
        var time: CFTimeInterval = 1
        var rejectNextEncoder = false
        var command: MTLCommandBuffer?

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 100, height: 90)
            self.window = window
            var clock: () -> CFTimeInterval = { 1 }
            var encode: (MTLCommandBuffer, MTLRenderPassDescriptor) -> MTLRenderCommandEncoder? = {
                $0.makeRenderCommandEncoder(descriptor: $1)
            }
            renderer = PeripheralGlassView.Renderer(now: { clock() }, makeRenderEncoder: { encode($0, $1) })
            view = MTKView(frame: window.bounds, device: renderer.device)
            view.colorPixelFormat = .rgba16Float; view.framebufferOnly = false; view.isPaused = true
            let controller = UIViewController(); window.rootViewController = controller
            controller.view.addSubview(view); window.makeKeyAndVisible()
            source.configure(outputIndex: 1, ratio: 2)
            renderer.view = view
            renderer.configure(source: source, framing: .init(size: window.bounds.size, photoAspectRatio: 4.0 / 3), enabled: true)
            clock = { [weak self] in self?.time ?? 0 }
            encode = { [weak self] command, pass in
                guard let self else { return nil }
                if self.rejectNextEncoder { self.rejectNextEncoder = false; return nil }
                self.command = command
                return command.makeRenderCommandEncoder(descriptor: pass)
            }
        }
        func drawFrame(_ index: Int64) throws {
            time += 0.1
            source.offer(center: try SampleFixture.sample(pts: 120 + index * 6),
                outer: try SampleFixture.sample(pts: 120 + index * 6), selection: source.selection(),
                sameCollection: true, receipt: time)
            renderer.draw(in: view)
        }
        func finish() async throws {
            let submitted = try #require(command)
            await submitted.completed()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            try #require(submitted.status == .completed)
        }
        isolated deinit { renderer.stop() }
    }

    @Test func encoderCreationFailure_nextFrameCanUpload() async throws {
        let harness = try Harness()
        harness.rejectNextEncoder = true
        try harness.drawFrame(0)
        try #require(harness.command == nil)

        try harness.drawFrame(1)
        try await harness.finish()

        #expect(harness.renderer.textures.completed?.frame.pair === harness.source.latest())
    }

    @Test func colorSelectionChange_revokesCompletedPixels() async throws {
        let harness = try Harness()
        try harness.drawFrame(0)
        try await harness.finish()
        try #require(harness.renderer.textures.completed != nil)

        harness.renderer.configureColor(recipe: liveRecipe(mode: .hncs), enabled: true, cameraReady: true, onStatus: nil)

        #expect(harness.renderer.textures.completed == nil)
        #expect(harness.view.alpha == 0)
    }
}
