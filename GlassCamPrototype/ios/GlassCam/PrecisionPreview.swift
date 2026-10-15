import Foundation
import CoreImage
import MetalKit
import UIKit
import QuartzCore
import SwiftUI

/// High-precision HDR preview. Float32 input and working surfaces feed a half-float
/// drawable; half precision is final display storage, never engine math. This does
/// not assert native panel bit depth or ten-bit source decoding.
/// comparisonFraction controls processed pixels on the left; nil shows the effect
/// alone. The before/after wipe is a GPU crop/composite of the retained two rasters.
struct PrecisionPreview: UIViewRepresentable {
    let source: PreviewRaster
    var processed: PreviewRaster? = nil
    var comparisonFraction: CGFloat? = nil

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.sampleCount = 1
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        if let layer = view.layer as? CAMetalLayer {
            // Match render destination and compositor interpretation. Encoding
            // sRGB here as well would apply its transfer curve twice.
            layer.colorspace = context.coordinator.colorSpace
            layer.wantsExtendedDynamicRangeContent = true
        }
        view.delegate = context.coordinator
        context.coordinator.installStatusOverlay(in: view)
        context.coordinator.update(source: source, processed: processed,
                                   comparisonFraction: comparisonFraction, view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(source: source, processed: processed,
                                   comparisonFraction: comparisonFraction, view: view)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.delegate = nil
        coordinator.releaseImages()
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        let colorSpace: CGColorSpace
        private let queue: MTLCommandQueue?
        private let context: CIContext?
        private var source: PreviewRaster?
        private var processed: PreviewRaster?
        private var fraction: CGFloat?
        private weak var statusLabel: UILabel?
        private var renderSequence: UInt64 = 0

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            self.device = device
            self.colorSpace = colorSpace
            if let device {
                queue = device.makeCommandQueue()
                context = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: colorSpace,
                    .workingFormat: CIFormat.RGBAf.rawValue,
                    .cacheIntermediates: false
                ])
            } else {
                // iOS 17 devices support Metal. Do not silently substitute an
                // eight-bit renderer if device initialization ever fails.
                queue = nil
                context = nil
            }
            super.init()
        }

        func installStatusOverlay(in view: MTKView) {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            label.font = .preferredFont(forTextStyle: .footnote)
            label.isAccessibilityElement = true
            label.isHidden = true
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            statusLabel = label
            if device == nil || queue == nil || context == nil {
                showStatus("High-precision preview is unavailable: Metal could not initialize.")
            }
        }

        private func showStatus(_ message: String?) {
            statusLabel?.text = message
            statusLabel?.isHidden = message == nil
        }

        func update(source: PreviewRaster, processed: PreviewRaster?,
                    comparisonFraction: CGFloat?, view: MTKView) {
            let bounded = comparisonFraction.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
            guard self.source !== source || self.processed !== processed || fraction != bounded else { return }
            self.source = source
            self.processed = processed
            fraction = bounded
            view.setNeedsDisplay()
        }

        func releaseImages() {
            source = nil
            processed = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let source, let context, let queue,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  let drawable = view.currentDrawable else { return }
            guard let commandBuffer = queue.makeCommandBuffer() else {
                showStatus("High-precision preview is unavailable: Metal could not create a render command.")
                return
            }
            renderSequence &+= 1
            let sequence = renderSequence
            let size = CGSize(width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
            let bounds = CGRect(origin: .zero, size: size)
            let scale = min(size.width / CGFloat(source.width), size.height / CGFloat(source.height))
            let fitted = CGRect(x: (size.width - CGFloat(source.width) * scale) / 2,
                                y: (size.height - CGFloat(source.height) * scale) / 2,
                                width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
            func fit(_ raster: PreviewRaster) -> CIImage {
                raster.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
                    .cropped(to: fitted)
            }
            var output = fit(source)
            // A stale differently sized result must never distort a new import.
            if let processed, processed.width == source.width, processed.height == source.height {
                let effect = fit(processed)
                if let fraction {
                    if fraction >= 1 {
                        output = effect
                    } else if fraction > 0 {
                        let left = CGRect(x: fitted.minX, y: fitted.minY,
                                          width: fitted.width * fraction, height: fitted.height)
                        output = effect.cropped(to: left).composited(over: output)
                    }
                } else {
                    output = effect
                }
            }
            // Preserve highlight values above reference white for EDR presentation.
            output = output.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: CGFloat(ImagePipeline.maximumHDRValue), y: CGFloat(ImagePipeline.maximumHDRValue), z: CGFloat(ImagePipeline.maximumHDRValue), w: 1)
            ]).composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
                .cropped(to: bounds)
            let renderTask: CIRenderTask
            do {
                renderTask = try PreviewRendering.render(output, with: context, to: drawable.texture,
                                                         commandBuffer: commandBuffer, colorSpace: colorSpace)
            } catch {
                showStatus("High-precision preview could not prepare a GPU render. Change the view to retry.")
                return
            }
            // Hold bitmap ownership through GPU completion, including a SwiftUI
            // replacement or teardown while this command buffer remains in flight.
            let owners = [source, processed].compactMap { $0 }
            commandBuffer.addCompletedHandler { [weak self, renderTask] buffer in
                withExtendedLifetime((owners, renderTask)) {}
                let failed = buffer.status == .error
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.renderSequence == sequence else { return }
                    self.showStatus(failed ? "High-precision preview failed on the GPU. Change the view or reimport to retry." : nil)
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
