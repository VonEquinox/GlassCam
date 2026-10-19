import Foundation
import AVFoundation
import CoreImage
import Vision
import QuartzCore
import simd

/// A separate bounded mailbox; it never steals frames from LiveColorProxy.
final class PeripheralFrameSource {
    struct Configuration: Equatable {
        var outputIndex: Int?
        var fieldOfViewRatio: Float = 1
        var epoch: UInt64 = 0
    }
    final class Pair {
        let center: CVPixelBuffer
        let outer: CVPixelBuffer
        let receipt: Double
        let epoch: UInt64
        let serial: UInt64
        let ratio: Float
        init(center: CVPixelBuffer, outer: CVPixelBuffer, receipt: Double,
             configuration: Configuration, serial: UInt64) {
            self.center = center; self.outer = outer; self.receipt = receipt
            epoch = configuration.epoch; ratio = configuration.fieldOfViewRatio; self.serial = serial
        }
    }
    private let lock = NSLock()
    private var configuration = Configuration()
    private var pair: Pair?
    private var serial: UInt64 = 0
    private var active = true

    func configure(outputIndex: Int?, ratio: Float) {
        lock.lock(); defer { lock.unlock() }
        let valid = ratio.isFinite && ratio > 1.02
        let index = valid ? outputIndex : nil
        if configuration.outputIndex != index || abs(configuration.fieldOfViewRatio - ratio) > 0.0001 {
            configuration.epoch &+= 1; pair = nil
        }
        configuration.outputIndex = index
        configuration.fieldOfViewRatio = valid ? ratio : 1
    }
    func selection() -> Configuration { lock.lock(); defer { lock.unlock() }; return configuration }
    func latest() -> Pair? { lock.lock(); defer { lock.unlock() }; return active ? pair : nil }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; configuration.epoch &+= 1; pair = nil
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        configuration.epoch &+= 1; pair = nil
    }
    func offer(center: CMSampleBuffer, outer: CMSampleBuffer?, selection: Configuration) {
        lock.lock(); defer { lock.unlock() }
        guard active, selection == configuration, selection.outputIndex != nil,
              let outer, let c = CMSampleBufferGetImageBuffer(center),
              let o = CMSampleBufferGetImageBuffer(outer) else { pair = nil; return }
        let a = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(center))
        let b = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(outer))
        guard a.isFinite, b.isFinite, abs(a - b) <= 1.0 / 60 else { pair = nil; return }
        serial &+= 1
        pair = Pair(center: c, outer: o, receipt: CACurrentMediaTime(), configuration: selection, serial: serial)
    }
}

/// Synchronizer owns sample delivery. Always forward a valid center frame even
/// when an auxiliary stream is absent/dropped; only the perimeter becomes black.
#if os(iOS)
final class PeripheralFrameSynchronizer: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    let queue = DispatchQueue(label: "dev.glasscam.preview.synchronized", qos: .userInteractive)
    let source: PeripheralFrameSource
    let outputs: [AVCaptureVideoDataOutput]
    let deliveries: [CameraFrameDelivery]
    init(source: PeripheralFrameSource, outputs: [AVCaptureVideoDataOutput], deliveries: [CameraFrameDelivery]) {
        self.source = source; self.outputs = outputs; self.deliveries = deliveries
    }
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        func sample(_ index: Int) -> CMSampleBuffer? {
            guard outputs.indices.contains(index),
                  let data = collection.synchronizedData(for: outputs[index]) as? AVCaptureSynchronizedSampleBufferData,
                  !data.sampleBufferWasDropped else { return nil }
            return data.sampleBuffer
        }
        guard let center = sample(0) else { source.reset(); return }
        deliveries[0].receive(center)
        let selection = source.selection()
        let outer = selection.outputIndex.flatMap(sample)
        source.offer(center: center, outer: outer, selection: selection)
    }
}

#endif

struct PeripheralAlignmentResult {
    let epoch: UInt64
    let receipt: Double
    let photoAspectRatio: Double
    /// Top-left normalized center/photo coordinates -> top-left outer texture UV.
    let photoToOuter: simd_float3x3
    let residual: Double
    let gain: SIMD3<Float>
}

/// Registration is bounded to one worker and small analysis images. A legal
/// homography is NOT a quality score: local seam patches measure the residual.
final class PeripheralAlignmentWorker {
    private let queue = DispatchQueue(label: "dev.glasscam.peripheral.registration", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastRequest = -Double.infinity
    private var result: PeripheralAlignmentResult?
    private let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    func latest() -> PeripheralAlignmentResult? { lock.lock(); defer { lock.unlock() }; return result }
    func request(_ pair: PeripheralFrameSource.Pair) {
        lock.lock()
        guard !busy, pair.receipt - lastRequest >= 0.12 else { lock.unlock(); return }
        busy = true; lastRequest = pair.receipt; lock.unlock()
        queue.async { [self, pair] in
            let value = autoreleasepool { analyze(pair) }
            lock.lock(); result = value; busy = false; lock.unlock()
        }
    }

    func analyze(_ pair: PeripheralFrameSource.Pair, now: () -> Double = CACurrentMediaTime) -> PeripheralAlignmentResult? {
        guard now() - pair.receipt < 0.6 else { return nil }
        let center = CIImage(cvPixelBuffer: pair.center)
        let outer = CIImage(cvPixelBuffer: pair.outer)
        guard center.extent.width > 0, outer.extent.width > 0,
              abs(center.extent.width / center.extent.height - outer.extent.width / outer.extent.height) < 0.01 else { return nil }
        let w = 192, h = Int((192 * center.extent.height / center.extent.width).rounded())
        guard h >= 96 && h <= 320 else { return nil }
        let width = CGFloat(w), height = CGFloat(h), ratio = CGFloat(pair.ratio)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let reference = center.transformed(by: CGAffineTransform(scaleX: width / center.extent.width,
                                                                 y: height / center.extent.height)).cropped(to: bounds)
        let tx = width * (1 - ratio) / 2, ty = height * (1 - ratio) / 2
        let floating = outer.transformed(by: CGAffineTransform(scaleX: width * ratio / outer.extent.width,
                                                               y: height * ratio / outer.extent.height))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: floating.cropped(to: bounds), orientation: .up)
        do { try VNImageRequestHandler(ciImage: reference, orientation: .up).perform([request]) }
        catch { return nil }
        guard let observation = request.results?.first else { return nil }
        let homography = observation.warpTransform
        guard Self.valid(homography), abs(simd_determinant(homography)) > 0.00001 else { return nil }
        guard let warped = Self.warp(floating, by: homography) else { return nil }
        let referenceBytes = bitmap(reference, bounds: bounds, width: w, height: h)
        let warpedBytes = bitmap(warped, bounds: bounds, width: w, height: h)
        guard let measured = Self.measureSeams(reference: referenceBytes, warped: warpedBytes, width: w, height: h) else { return nil }
        // Vision H maps floating -> reference in CI pixels (bottom-left).
        // Metal samples target -> source, in normalized top-left coordinates.
        let matrix = Self.samplingTransform(homography: homography, width: w, height: h, ratio: pair.ratio)
        guard Self.valid(matrix), now() - pair.receipt < 0.6 else { return nil }
        return .init(epoch: pair.epoch, receipt: pair.receipt,
                     photoAspectRatio: Double(center.extent.width / center.extent.height), photoToOuter: matrix,
                     residual: measured.residual, gain: measured.gain)
    }

    static func samplingTransform(homography: simd_float3x3, width: Int, height: Int, ratio: Float) -> simd_float3x3 {
        let w = Float(width), h = Float(height)
        let tx = w * (1-ratio) / 2, ty = h * (1-ratio) / 2
        let toCI = simd_float3x3(SIMD3(w, 0, 0), SIMD3(0, -h, 0), SIMD3(0, h, 1))
        let fromFloating = simd_float3x3(SIMD3(1 / (w * ratio), 0, 0),
            SIMD3(0, -1 / (h * ratio), 0),
            SIMD3(-tx / (w * ratio), 1 + ty / (h * ratio), 1))
        return fromFloating * homography.inverse * toCI
    }

    private func bitmap(_ image: CIImage, bounds: CGRect, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        }
        return bytes
    }
    static func valid(_ matrix: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { i in (0..<3).allSatisfy { matrix[i][$0].isFinite } }
    }
    static func project(_ point: SIMD2<Float>, using matrix: simd_float3x3) -> SIMD2<Float>? {
        let v = matrix * SIMD3(point.x, point.y, 1)
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite, v.z > 0.00001 else { return nil }
        return SIMD2(v.x / v.z, v.y / v.z)
    }
    static func warp(_ image: CIImage, by matrix: simd_float3x3) -> CIImage? {
        let e = image.extent
        let points = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY),
                      CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)]
        let values = points.compactMap { project(SIMD2(Float($0.x), Float($0.y)), using: matrix) }
        guard values.count == 4 else { return nil }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: CGFloat(values[0].x), y: CGFloat(values[0].y)),
            "inputTopRight": CIVector(x: CGFloat(values[1].x), y: CGFloat(values[1].y)),
            "inputBottomRight": CIVector(x: CGFloat(values[2].x), y: CGFloat(values[2].y)),
            "inputBottomLeft": CIVector(x: CGFloat(values[3].x), y: CGFloat(values[3].y))])
    }

    /// Local normalized cross-correlation AFTER warping. Textureless, ambiguous,
    /// occluded or uncovered patches do not vote as perfectly aligned pixels.
    static func measureSeams(reference: [UInt8], warped: [UInt8], width: Int, height: Int)
        -> (residual: Double, gain: SIMD3<Float>)? {
        guard width >= 64, height >= 64, reference.count == width * height * 4,
              warped.count == reference.count else { return nil }
        func luma(_ image: [UInt8]) -> [Float] {
            stride(from: 0, to: image.count, by: 4).map {
                (Float(image[$0]) * 0.2126 + Float(image[$0 + 1]) * 0.7152 + Float(image[$0 + 2]) * 0.0722) / 255
            }
        }
        let a = luma(reference), b = luma(warped)
        let anchors: [(Double, Double, Int)] = [(0.16,0.10,0),(0.50,0.10,0),(0.84,0.10,0),
            (0.16,0.90,1),(0.50,0.90,1),(0.84,0.90,1),
            (0.10,0.3,2),(0.10,0.7,2),(0.90,0.3,3),(0.90,0.7,3)]
        let radius = max(8, Int(Double(min(width, height)) * 0.16))
        let patch = 4
        var errors: [Double] = [], sides = Set<Int>()
        var redA: Float = 0, greenA: Float = 0, blueA: Float = 0
        var redB: Float = 0, greenB: Float = 0, blueB: Float = 0
        for (nx, ny, side) in anchors {
            let x = Int(nx * Double(width)), y = Int(ny * Double(height))
            var sample: [Float] = []
            for dy in -patch...patch { for dx in -patch...patch { sample.append(a[(y+dy)*width+x+dx]) } }
            let meanA = sample.reduce(0,+) / Float(sample.count)
            let varianceA = sample.reduce(Float(0)) { $0 + ($1-meanA)*($1-meanA) }
            guard varianceA > 0.012 else { continue }
            func score(_ dx: Int, _ dy: Int) -> Float {
                let xx = x + dx, yy = y + dy
                guard xx >= patch, yy >= patch, xx + patch < width, yy + patch < height else { return -2 }
                var sum: Float = 0, sum2: Float = 0, dot: Float = 0
                var i = 0
                for v in -patch...patch { for u in -patch...patch {
                    let value = b[(yy+v)*width+xx+u]
                    sum += value; sum2 += value*value; dot += (sample[i]-meanA)*value; i += 1
                } }
                let variance = sum2 - sum*sum / Float(sample.count)
                guard variance > 0.012 else { return -2 }
                return dot / sqrt(varianceA * variance)
            }
            var candidates: [(Float, Int, Int)] = []
            // Include every integer offset. Subsampling before the confidence
            // gate can miss a real odd-pixel match (or zero at an odd radius).
            for dy in -radius...radius {
                for dx in -radius...radius { candidates.append((score(dx,dy),dx,dy)) }
            }
            // A textured seam that fails to match is an occlusion/registration
            // failure, not permission to discard that patch and report zero.
            guard let best = candidates.max(by: { $0.0 < $1.0 }), best.0 > 0.65 else { return nil }
            let competing = candidates.filter { abs($0.1-best.1) > 4 || abs($0.2-best.2) > 4 }.map(\.0).max() ?? -2
            guard best.0 - competing > 0.025,
                  abs(best.1) < radius-1, abs(best.2) < radius-1 else { return nil }
            errors.append(hypot(Double(best.1),Double(best.2)) / Double(min(width,height)))
            sides.insert(side)
            for dy in -patch...patch { for dx in -patch...patch {
                let ia = ((y+dy)*width+x+dx)*4
                let ib = ((y+best.2+dy)*width+x+best.1+dx)*4
                guard reference[ia+3] == 255, warped[ib+3] == 255 else { return nil }
                redA += Float(reference[ia]); greenA += Float(reference[ia+1]); blueA += Float(reference[ia+2])
                redB += Float(warped[ib]); greenB += Float(warped[ib+1]); blueB += Float(warped[ib+2])
            } }
        }
        guard errors.count >= 6, sides.count == 4 else { return nil }
        // Use the worst supported seam patch, not the size of the fitted warp.
        guard let error = errors.max() else { return nil }
        let gain = SIMD3(redA / max(1,redB), greenA / max(1,greenB), blueA / max(1,blueB))
        guard [gain.x,gain.y,gain.z].allSatisfy({ $0.isFinite && (0.5...2).contains($0) }) else { return nil }
        return (error, gain)
    }
}
