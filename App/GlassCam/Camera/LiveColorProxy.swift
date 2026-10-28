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
        private(set) var revision: UInt64 = 0
        private var sessionGeneration: UInt64 = 0
        private(set) var presentationRevision: UInt64 = 0
        private var hasWindow = false
        private var lastPresentedReceiptTime: CFTimeInterval?
        private static let maximumFrameAge: CFTimeInterval = 0.5
        private let now: () -> CFTimeInterval
        private var onStatus: ((LiveColorProxyStatus) -> Void)?
        private var lastStatus: LiveColorProxyStatus?
        // Retained timing for instrumentation, never used to manufacture timestamps.
        private(set) var lastPresentedTimestamp: CMTime = .invalid

        override convenience init() { self.init(now: CACurrentMediaTime) }
        init(now: @escaping () -> CFTimeInterval) {
            self.now = now
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
        func updateWindowAvailability() {
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
        func tick() {
            guard active, hasWindow, let source, let view else { return }
            let generation = source.currentGeneration()
            if generation != sessionGeneration || !source.isCurrent(generation) {
                sessionGeneration = generation
                waitForFrame("Live color waiting for a current camera frame · system preview")
                guard source.isCurrent(generation) else { return }
            }
            if let receipt = lastPresentedReceiptTime, now() - receipt > Self.maximumFrameAge {
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
            guard now() - frame.receivedHostTime <= Self.maximumFrameAge else {
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
            guard now() - frame.receivedHostTime <= Self.maximumFrameAge else {
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
            output = Self.fit(output, aperture: aperture, size: size)
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
                    self.completeFrame(frame, source: source, revision: ticket,
                                       presentation: presentationTicket, failed: failed)
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        static func fit(_ image: CIImage, aperture: CGRect, size: CGSize) -> CIImage {
            let bounds = CGRect(origin: .zero, size: size)
            let scale = min(size.width / aperture.width, size.height / aperture.height)
            return image.cropped(to: aperture)
                .transformed(by: CGAffineTransform(translationX: -aperture.minX, y: -aperture.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (size.width - aperture.width * scale) / 2,
                                                   y: (size.height - aperture.height * scale) / 2))
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
                .cropped(to: bounds)
        }
        func completeFrame(_ frame: LiveCameraFrame, source: LiveCameraFrameSource,
                   revision ticket: UInt64, presentation presentationTicket: UInt64, failed: Bool) {
            inFlight = false
            guard active, hasWindow, view?.window != nil, revision == ticket,
                  presentationRevision == presentationTicket,
                  source.isCurrent(frame.generation) else { return }
            if failed { fail("Live color failed on the GPU. Showing system preview."); return }
            guard now() - frame.receivedHostTime <= Self.maximumFrameAge else {
                waitForFrame("Live color paused: GPU frame expired · system preview"); return
            }
            lastPresentedTimestamp = frame.presentationTime
            lastPresentedReceiptTime = frame.receivedHostTime
            view?.alpha = 1
            report(.init(isShowingEffect: true, text: "EXPERIMENTAL APPROX. COLOR · 8-BIT SOURCE · COLOR ONLY"))
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
