import Foundation
import AVFoundation
import CoreImage
import Vision
import QuartzCore
import simd
import OSLog

/// Opt-in diagnostics for the live peripheral path; never records camera pixels.
enum PeripheralDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_TRACE"] == "1"
    static func trace(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        Logger(subsystem: "dev.glasscam.prototype", category: "PeripheralTrace")
            .notice("\(text, privacy: .public)")
    }
}

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
    private var pendingCenter: CMSampleBuffer?
    private var pendingOuter: CMSampleBuffer?
    private var serial: UInt64 = 0
    private var active = true
    private var lastOffer = "none"
    private var lastTimeDelta = 0.0

    func diagnosticState() -> String {
        lock.lock(); defer { lock.unlock() }
        return "output=\(String(describing: configuration.outputIndex)) ratio=\(configuration.fieldOfViewRatio) epoch=\(configuration.epoch) serial=\(serial) offer=\(lastOffer) ptsDelta=\(lastTimeDelta)"
    }

    func configure(outputIndex: Int?, ratio: Float) {
        lock.lock(); defer { lock.unlock() }
        let valid = ratio.isFinite && ratio > 1.02
        let index = valid ? outputIndex : nil
        if configuration.outputIndex != index || abs(configuration.fieldOfViewRatio - ratio) > 0.0001 {
            configuration.epoch &+= 1; pair = nil; pendingCenter = nil; pendingOuter = nil
        }
        configuration.outputIndex = index
        configuration.fieldOfViewRatio = valid ? ratio : 1
    }
    func selection() -> Configuration { lock.lock(); defer { lock.unlock() }; return configuration }
    func latest() -> Pair? { lock.lock(); defer { lock.unlock() }; return active ? pair : nil }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; configuration.epoch &+= 1; pair = nil; pendingCenter = nil; pendingOuter = nil
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        configuration.epoch &+= 1; pair = nil; pendingCenter = nil; pendingOuter = nil
    }
    /// Independent inputs can arrive in separate synchronizer callbacks. Keep
    /// at most one unmatched sample from each input, and never reuse a sample.
    /// An absent output in a callback is not evidence that the stream dropped.
    func offer(center: CMSampleBuffer?, outer: CMSampleBuffer?, selection: Configuration) {
        lock.lock(); defer { lock.unlock() }
        guard active, selection == configuration, selection.outputIndex != nil else { return }
        if let center { pendingCenter = center }
        if let outer { pendingOuter = outer }
        guard let center = pendingCenter, let outer = pendingOuter else {
            lastOffer = pendingCenter == nil ? "awaiting-center" : "awaiting-outer"
            return
        }
        guard CMSampleBufferDataIsReady(center), CMSampleBufferDataIsReady(outer),
              let c = CMSampleBufferGetImageBuffer(center), let o = CMSampleBufferGetImageBuffer(outer) else {
            lastOffer = "missing-image"; pair = nil; pendingCenter = nil; pendingOuter = nil
            return
        }
        let a = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(center))
        let b = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(outer))
        lastTimeDelta = abs(a - b)
        guard a.isFinite, b.isFinite else {
            lastOffer = "invalid-time"; pair = nil; pendingCenter = nil; pendingOuter = nil
            return
        }
        guard abs(a - b) <= 1.0 / 60 else {
            // Keep only the newer sample for the next callback. Do not relax
            // the time limit merely because both cameras are delivering frames.
            lastOffer = "unsynchronized"; pair = nil
            if a < b { pendingCenter = nil } else { pendingOuter = nil }
            return
        }
        lastOffer = "paired"
        serial &+= 1
        pair = Pair(center: c, outer: o, receipt: CACurrentMediaTime(), configuration: selection, serial: serial)
        pendingCenter = nil; pendingOuter = nil
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
    private var lastDiagnosticTime = -Double.infinity
    init(source: PeripheralFrameSource, outputs: [AVCaptureVideoDataOutput], deliveries: [CameraFrameDelivery]) {
        self.source = source; self.outputs = outputs; self.deliveries = deliveries
    }
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        if PeripheralDiagnostics.isEnabled, CACurrentMediaTime() - lastDiagnosticTime >= 1 {
            lastDiagnosticTime = CACurrentMediaTime()
            let streams = outputs.enumerated().map { index, output -> String in
                guard let data = collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData else {
                    return "\(index):absent"
                }
                return "\(index):dropped=\(data.sampleBufferWasDropped) reason=\(data.droppedReason.rawValue) timestamp=\(CMTimeGetSeconds(data.timestamp)) pts=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(data.sampleBuffer)))"
            }.joined(separator: " ")
            PeripheralDiagnostics.trace("synchronizer \(streams)")
        }
        func sample(_ index: Int) -> CMSampleBuffer? {
            guard outputs.indices.contains(index),
                  let data = collection.synchronizedData(for: outputs[index]) as? AVCaptureSynchronizedSampleBufferData,
                  !data.sampleBufferWasDropped else { return nil }
            return data.sampleBuffer
        }
        let center = sample(0)
        if let center { deliveries[0].receive(center) }
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
    private var savedDiagnosticSnapshot = false
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
        func reject(_ reason: String) -> PeripheralAlignmentResult? {
            PeripheralDiagnostics.trace("alignment rejected: \(reason), age=\(now()-pair.receipt), ratio=\(pair.ratio)")
            return nil
        }
        guard now() - pair.receipt < 0.6 else { return reject("expired-input") }
        let center = CIImage(cvPixelBuffer: pair.center)
        let outer = CIImage(cvPixelBuffer: pair.outer)
        guard center.extent.width > 0, outer.extent.width > 0,
              abs(center.extent.width / center.extent.height - outer.extent.width / outer.extent.height) < 0.01 else { return reject("frame-aspect \(center.extent) vs \(outer.extent)") }
        let w = 192, h = Int((192 * center.extent.height / center.extent.width).rounded())
        guard h >= 96 && h <= 320 else { return reject("analysis-dimensions") }
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
        catch { return reject("vision-error \(error.localizedDescription)") }
        guard let observation = request.results?.first else { return reject("vision-no-result") }
        let homography = observation.warpTransform
        guard Self.valid(homography), abs(simd_determinant(homography)) > 0.00001 else { return reject("invalid-homography") }
        guard let warped = Self.warp(floating, by: homography) else { return reject("warp-failed") }
        let referenceBytes = bitmap(reference, bounds: bounds, width: w, height: h)
        let warpedBytes = bitmap(warped, bounds: bounds, width: w, height: h)
        saveDiagnosticSnapshot(pair, images: ["center": center, "outer": outer,
            "reference": reference, "overlap": floating.cropped(to: bounds), "warped": warped.cropped(to: bounds)],
            homography: homography)
        guard let measured = Self.measureSeams(reference: referenceBytes, warped: warpedBytes, width: w, height: h) else { return reject("seam-confidence") }
        // Vision H maps floating -> reference in CI pixels (bottom-left).
        // Metal samples target -> source, in normalized top-left coordinates.
        let matrix = Self.samplingTransform(homography: homography, width: w, height: h, ratio: pair.ratio)
        guard Self.valid(matrix), now() - pair.receipt < 0.6 else { return reject("expired-or-invalid-result") }
        return .init(epoch: pair.epoch, receipt: pair.receipt,
                     photoAspectRatio: Double(center.extent.width / center.extent.height), photoToOuter: matrix,
                     residual: measured.residual, gain: measured.gain)
    }

    private func saveDiagnosticSnapshot(_ pair: PeripheralFrameSource.Pair,
                                         images: [String: CIImage], homography: simd_float3x3) {
        guard !savedDiagnosticSnapshot, pair.serial >= 60,
              ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_SNAPSHOT"] == "1" else { return }
        savedDiagnosticSnapshot = true
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GlassCamPeripheralProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            for (name, image) in images {
                let scale = min(1, 512 / max(image.extent.width, image.extent.height))
                let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                try context.writePNGRepresentation(of: reduced, to: directory.appendingPathComponent(name + ".png"),
                    format: .RGBA8, colorSpace: colorSpace, options: [:])
            }
            let metadata: [String: Any] = ["ratio": pair.ratio, "serial": pair.serial,
                "homography_columns": (0..<3).map { [homography[$0].x, homography[$0].y, homography[$0].z] },
                "center_dimensions": [CVPixelBufferGetWidth(pair.center), CVPixelBufferGetHeight(pair.center)],
                "outer_dimensions": [CVPixelBufferGetWidth(pair.outer), CVPixelBufferGetHeight(pair.outer)]]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
            PeripheralDiagnostics.trace("saved one preview-only diagnostic pair: \(directory.path)")
        } catch { PeripheralDiagnostics.trace("preview diagnostic snapshot failed: \(error.localizedDescription)") }
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

    func bitmap(_ image: CIImage, bounds: CGRect, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
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

    /// Measure displacement after registration. Distinct two-dimensional
    /// features establish geometry; smooth/one-dimensional seams also need
    /// photometric agreement. The aperture problem is not an occlusion.
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
        let radius = max(8, Int(Double(min(width, height)) * 0.16))
        // Perceptual samples preserve dark texture; a 17px patch gives natural
        // features enough support without changing the geometric error limits.
        let patch = min(8, max(4, min(width, height) / 16))
        let linear = (0..<256).map { value -> Float in
            let s = Float(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func tensor(_ x: Int, _ y: Int) -> (minor: Float, major: Float, normal: SIMD2<Float>) {
            var xx: Float = 0, xy: Float = 0, yy: Float = 0
            for dy in -4...4 { for dx in -4...4 {
                let i = (y+dy)*width+x+dx
                let gx = (a[i+1]-a[i-1]) * 0.5, gy = (a[i+width]-a[i-width]) * 0.5
                xx += gx*gx; xy += gx*gy; yy += gy*gy
            } }
            let delta = hypot(xx-yy,2*xy)
            let angle = 0.5 * atan2(2*xy,xx-yy)
            return ((xx+yy-delta)*0.5,(xx+yy+delta)*0.5,SIMD2(cos(angle),sin(angle)))
        }
        let seamAnchors: [(Double,Double)] = [(0.16,0.10),(0.50,0.10),(0.84,0.10),
            (0.16,0.90),(0.50,0.90),(0.84,0.90),(0.10,0.30),(0.10,0.70),(0.90,0.30),(0.90,0.70)]
        var anchors = seamAnchors.map { (x: Int($0.0*Double(width)), y: Int($0.1*Double(height)), seam: true) }
        // Seek real corners throughout the image. Fixed seam patches alone can
        // all land on a wall or a straight edge even in a well-aligned scene.
        for row in 0..<4 { for column in 0..<4 {
            var best: (strength: Float, x: Int, y: Int)?
            for y in stride(from: max(patch+1,row*height/4), to: min(height-patch-1,(row+1)*height/4), by: 4) {
                for x in stride(from: max(patch+1,column*width/4), to: min(width-patch-1,(column+1)*width/4), by: 4) {
                    guard anchors.allSatisfy({ (x-$0.x)*(x-$0.x)+(y-$0.y)*(y-$0.y) > 4*patch*patch }) else { continue }
                    let strength = tensor(x,y).minor
                    if strength > (best?.strength ?? 0.003) { best = (strength,x,y) }
                }
            }
            if let best { anchors.append((best.x,best.y,false)) }
        } }
        struct AmbiguousPatch {
            let x: Int, y: Int
            let offsets: [(Int,Int)]
            let normal: SIMD2<Float>?
            let flat: Bool
        }
        var ambiguous: [AmbiguousPatch] = []
        var errors: [Double] = [], points: [SIMD2<Float>] = []
        var sumA = SIMD3<Float>(repeating: 0), sumB = SIMD3<Float>(repeating: 0)
        for (x,y,seam) in anchors {
            var sample: [Float] = []
            for dy in -patch...patch { for dx in -patch...patch { sample.append(a[(y+dy)*width+x+dx]) } }
            let meanA = sample.reduce(0,+) / Float(sample.count)
            let varianceA = sample.reduce(Float(0)) { $0 + ($1-meanA)*($1-meanA) }
            if varianceA <= 0.012 {
                if seam { ambiguous.append(.init(x: x,y: y,offsets: [(0,0)],normal: nil,flat: true)) }
                continue
            }
            func score(_ dx: Int, _ dy: Int) -> Float {
                let xx = x+dx, yy = y+dy
                guard xx >= patch, yy >= patch, xx+patch < width, yy+patch < height else { return -2 }
                var sum: Float = 0, sum2: Float = 0, dot: Float = 0, i = 0
                for v in -patch...patch { for u in -patch...patch {
                    let value = b[(yy+v)*width+xx+u]
                    sum += value; sum2 += value*value; dot += (sample[Int(i)]-meanA)*value; i += 1
                } }
                let variance = sum2-sum*sum/Float(sample.count)
                guard variance > 0.012 else { return -2 }
                return dot/sqrt(varianceA*variance)
            }
            var candidates: [(Float,Int,Int)] = []
            for dy in -radius...radius { for dx in -radius...radius { candidates.append((score(dx,dy),dx,dy)) } }
            guard let best = candidates.max(by: { $0.0 < $1.0 }), best.0 > 0.65 else {
                // Auxiliary corners may belong to an interior object at another
                // depth. A failed textured seam itself is never discarded.
                if !seam { continue }
                PeripheralDiagnostics.trace("seam rejected at \(x),\(y): no correlation")
                return nil
            }
            let competing = candidates.filter { abs($0.1-best.1) > 4 || abs($0.2-best.2) > 4 }.map(\.0).max() ?? -2
            if best.0-competing <= 0.025 {
                if seam {
                    let structure = tensor(x,y)
                    let normal = structure.major > 0.0001 && structure.minor/structure.major < 0.10 ? structure.normal : nil
                    ambiguous.append(.init(x: x,y: y, offsets: candidates.filter { $0.0 >= best.0-0.025 }.map { ($0.1,$0.2) },
                                           normal: normal,flat: false))
                }
                continue
            }
            guard abs(best.1) < radius-1, abs(best.2) < radius-1 else {
                if !seam { continue }; return nil
            }
            errors.append(hypot(Double(best.1),Double(best.2))/Double(min(width,height)))
            points.append(SIMD2(Float(x)/Float(width),Float(y)/Float(height)))
            for dy in -patch...patch { for dx in -patch...patch {
                let ia = ((y+dy)*width+x+dx)*4, ib = ((y+best.2+dy)*width+x+best.1+dx)*4
                guard reference[ia+3] == 255, warped[ib+3] == 255 else { return nil }
                sumA += SIMD3(linear[Int(reference[ia])],linear[Int(reference[ia+1])],linear[Int(reference[ia+2])])
                sumB += SIMD3(linear[Int(warped[ib])],linear[Int(warped[ib+1])],linear[Int(warped[ib+2])])
            } }
        }
        // A blank scene or repeating stripes cannot certify a homography.
        // Require several spatially distributed, unambiguous 2D correspondences.
        guard points.count >= 6,
              (points.map(\.x).max()! - points.map(\.x).min()!) > 0.4,
              (points.map(\.y).max()! - points.map(\.y).min()!) > 0.4 else {
            PeripheralDiagnostics.trace("seam rejected: insufficient distributed features (\(points.count))")
            return nil
        }
        let mean = points.reduce(SIMD2<Float>(repeating: 0),+)/Float(points.count)
        var xx: Float = 0,xy: Float = 0,yy: Float = 0
        for point in points { let d = point-mean; xx += d.x*d.x; xy += d.x*d.y; yy += d.y*d.y }
        guard (xx*yy-xy*xy)/Float(points.count*points.count) > 0.001 else { return nil }
        let gain = sumA/simd_max(sumB,SIMD3<Float>(repeating: 0.000001))
        guard [gain.x,gain.y,gain.z].allSatisfy({ $0.isFinite && (0.5...2).contains($0) }) else { return nil }
        let corrected = (0..<256).map { index -> SIMD3<Float> in
            let value = gain*linear[index]
            func encode(_ c: Float) -> Float { c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055 }
            return SIMD3(encode(value.x),encode(value.y),encode(value.z))
        }
        for pending in ambiguous {
            func agrees(_ dx: Int,_ dy: Int) -> Bool {
                var total: Float = 0,large = 0,count = 0
                for v in -patch...patch { for u in -patch...patch {
                    let ia = ((pending.y+v)*width+pending.x+u)*4
                    let ib = ((pending.y+dy+v)*width+pending.x+dx+u)*4
                    guard reference[ia+3] == 255, warped[ib+3] == 255 else { return false }
                    for c in 0..<3 {
                        let difference = abs(Float(reference[ia+c])/255-corrected[Int(warped[ib+c])][c])
                        total += difference; if difference > 0.15 { large += 1 }; count += 1
                    }
                } }
                return total/Float(count) < 0.06 && Float(large)/Float(count) < 0.10
            }
            let plausible = pending.offsets.filter { agrees($0.0,$0.1) }
            guard !plausible.isEmpty else {
                PeripheralDiagnostics.trace("seam rejected at \(pending.x),\(pending.y): appearance differs")
                return nil
            }
            if pending.flat { continue }
            // A straight edge constrains motion normal to that edge. Its
            // invisible tangential ambiguity is resolved by the distributed 2D
            // features above. For 2D patches, bound ALL plausible displacements.
            let bound = plausible.map { dx,dy -> Float in
                if let normal = pending.normal { return abs(simd_dot(normal,SIMD2(Float(dx),Float(dy)))) }
                return hypot(Float(dx),Float(dy))
            }.max()!
            guard bound < Float(radius-1) else { return nil }
            errors.append(Double(bound)/Double(min(width,height)))
        }
        guard let error = errors.max() else { return nil }
        return (error,gain)
    }
}
