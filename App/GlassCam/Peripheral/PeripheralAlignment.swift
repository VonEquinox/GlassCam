import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Opt-in live diagnostics. Pixel snapshots require a separate explicit flag.
enum PeripheralDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_TRACE"] == "1"
    static func trace(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        Logger(subsystem: "dev.glasscam.prototype", category: "PeripheralTrace")
            .notice("\(text, privacy: .public)")
    }
}

/// Frame timestamps remain in their original clock domain until explicitly
/// converted. K is copied into aligned SIMD storage, including its ABI padding.
struct PeripheralFrameMetadata {
    let id: UInt64
    let pts: Double
    let hostCaptureTime: Double?
    let width: Int, height: Int
    let frameInterval: Double
    let pixelFormat: UInt32
    let colorAttachments: [String:String]
    let intrinsic: simd_float3x3?
    init(_ sample: CMSampleBuffer, id: UInt64, clock: CMClock?) {
        self.id = id
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        pts = CMTimeGetSeconds(time)
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        frameInterval = duration.isFinite && duration >= 1.0/120 && duration <= 0.1 ? duration : 1.0/30
        if let clock {
            let converted = CMTimeGetSeconds(CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()))
            hostCaptureTime = converted.isFinite ? converted : nil
        } else { hostCaptureTime = nil }
        let pixel = CMSampleBufferGetImageBuffer(sample)
        width = pixel.map(CVPixelBufferGetWidth) ?? 0; height = pixel.map(CVPixelBufferGetHeight) ?? 0
        pixelFormat = pixel.map(CVPixelBufferGetPixelFormatType) ?? 0
        var colors: [String:String] = [:]
        if let pixel {
            for (name,key) in [("primaries",kCVImageBufferColorPrimariesKey),
                              ("transferFunction",kCVImageBufferTransferFunctionKey),("ycbcrMatrix",kCVImageBufferYCbCrMatrixKey)] {
                if let value = CVBufferCopyAttachment(pixel,key,nil) { colors[name] = String(describing:value) }
            }
        }
        colorAttachments = colors
        var matrix = matrix_identity_float3x3
        if let data = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count == MemoryLayout<simd_float3x3>.size {
            _ = withUnsafeMutableBytes(of: &matrix) { data.copyBytes(to: $0) }
            intrinsic = PeripheralAlignmentWorker.valid(matrix) && matrix[0][0] > 0 && matrix[1][1] > 0 &&
                abs(matrix[2][2]-1) < 0.001 ? matrix : nil
        } else { intrinsic = nil }
    }
}

struct PeripheralCalibration {
    let identity: String
    let rotation: simd_float3x3
    let translation: SIMD3<Float>
    let outputRotation: Float
    /// GDC and other output warps require image validation before any narrow search.
    static func decode(_ data: Data?, identity: String, outputRotation: Float) -> Self? {
        guard let data, data.count == MemoryLayout<simd_float4x3>.size else { return nil }
        var matrix = simd_float4x3()
        _ = withUnsafeMutableBytes(of: &matrix) { data.copyBytes(to: $0) }
        let r = simd_float3x3(matrix[0],matrix[1],matrix[2]), t = matrix[3]
        let orthogonal = r.transpose*r-matrix_identity_float3x3
        guard PeripheralAlignmentWorker.valid(r), t.x.isFinite, t.y.isFinite, t.z.isFinite,
              abs(simd_determinant(r)-1) < 0.01,
              (0..<3).allSatisfy({ simd_length(orthogonal[$0]) < 0.01 }),
              simd_length(t) > 0.1, simd_length(t) < 100 else { return nil }
        return .init(identity: identity,rotation: r,translation: t,outputRotation: outputRotation)
    }
    func fundamental(center: PeripheralFrameMetadata, outer: PeripheralFrameMetadata) -> simd_float3x3? {
        guard let kc = center.intrinsic, let ko = outer.intrinsic else { return nil }
        let angle = outputRotation * .pi/180, c = cos(angle), s = sin(angle)
        let q = simd_float3x3(SIMD3(c,s,0),SIMD3(-s,c,0),SIMD3(0,0,1))
        let r = q*rotation*q.transpose, t = q*translation
        let cross = simd_float3x3(SIMD3(0,t.z,-t.y),SIMD3(-t.z,0,t.x),SIMD3(t.y,-t.x,0))
        let f = ko.inverse.transpose*cross*r*kc.inverse
        return PeripheralAlignmentWorker.valid(f) ? f : nil
    }
}

/// Low resolution temporal sentinel. This is an empirical image-motion estimate,
/// not an IMU/rolling-shutter correction or a statistical bound. Failed matching
/// breaks the reuse generation instead of inventing zero motion.
enum PeripheralMotion {
    struct Raster { let values: [Float]; let width: Int; let height: Int }
    static func raster(_ buffer: CVPixelBuffer) -> Raster? {
        let width = 48, height = max(32,min(80,48*CVPixelBufferGetHeight(buffer)/max(1,CVPixelBufferGetWidth(buffer))))
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0) : CVPixelBufferGetBytesPerRow(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        func sample(_ x:Int,_ y:Int) -> Float {
            let xx = max(0,min(sourceWidth-1,x)), yy = max(0,min(sourceHeight-1,y))
            let row = base.advanced(by:yy*stride)
            if tenBit { return Float(row.assumingMemoryBound(to:UInt16.self)[xx] >> 6)/1023 }
            if planar { return Float(row.assumingMemoryBound(to:UInt8.self)[xx])/255 }
            let p = row.assumingMemoryBound(to:UInt8.self)+xx*4
            return (Float(p[2])*0.2126+Float(p[1])*0.7152+Float(p[0])*0.0722)/255
        }
        var out = [Float](repeating:0,count:width*height)
        for y in 0..<height { for x in 0..<width {
            let yy = (2*y+1)*sourceHeight/(2*height), xx = (2*x+1)*sourceWidth/(2*width)
            var value: Float = 0
            for v in -1...1 { for u in -1...1 {
                value += sample(xx+u*sourceWidth/(3*width),yy+v*sourceHeight/(3*height))
            } }
            out[y*width+x] = value/9
        } }
        return .init(values:out,width:width,height:height)
    }
    static func displacement(_ a: Raster,_ b: Raster, minimumMatches: Int = 6) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var distances: [Double] = []
        for fy in [0.25,0.5,0.75] { for fx in [0.25,0.5,0.75] {
            let x = Int(Double(a.width)*fx), y = Int(Double(a.height)*fy)
            var sample: [Float] = []
            for v in -3...3 { for u in -3...3 { sample.append(a.values[(y+v)*a.width+x+u]) } }
            let mean = sample.reduce(0,+)/49
            let variance = sample.reduce(Float(0)) { $0+($1-mean)*($1-mean) }
            guard variance > 0.001 else { continue }
            var scores: [(Float,Int,Int)] = []
            for dy in -3...3 { for dx in -3...3 {
                var total: Float = 0, squared: Float = 0, dot: Float = 0, i = 0
                for v in -3...3 { for u in -3...3 {
                    let value = b.values[(y+dy+v)*b.width+x+dx+u]
                    total += value; squared += value*value; dot += (sample[i]-mean)*value; i += 1
                } }
                let vb = squared-total*total/49
                scores.append((vb > 0.001 ? dot/sqrt(variance*vb) : -2,dx,dy))
            } }
            guard let best = scores.max(by: { $0.0 < $1.0 }), best.0 > 0.85,
                  abs(best.1) < 3, abs(best.2) < 3,
                  !scores.contains(where: { $0.0 > best.0-0.04 && hypot(Float($0.1-best.1),Float($0.2-best.2)) > 1.5 }) else { continue }
            // Fractional fits are used only to shorten reuse, never to certify
            // a stereo displacement. Quantization allowance is explicit.
            func refine(_ before:Float,_ after:Float) -> Double {
                let curvature = before-2*best.0+after
                guard curvature < -0.001 else { return 0 }
                return Double(max(-0.5,min(0.5,0.5*(before-after)/curvature)))
            }
            func score(_ dx:Int,_ dy:Int) -> Float { scores.first { $0.1 == dx && $0.2 == dy }?.0 ?? -2 }
            let dx = Double(best.1)+refine(score(best.1-1,best.2),score(best.1+1,best.2))
            let dy = Double(best.2)+refine(score(best.1,best.2-1),score(best.1,best.2+1))
            distances.append((hypot(dx,dy)+0.05)*192/Double(a.width))
        } }
        return distances.count >= minimumMatches ? distances.max() : nil
    }
}

/// Three samples per stream, bounded age and no sample reuse. Same-collection
/// pairs take priority; split callbacks get a short nearest-neighbour window.
final class PeripheralFrameSource {
    struct Configuration: Equatable {
        var outputIndex: Int?
        var fieldOfViewRatio: Float = 1
        var epoch: UInt64 = 0
        var geometryIdentity = ""
        var captureMode = "independent-physical-inputs"
    }
    final class Pair {
        let center: CVPixelBuffer, outer: CVPixelBuffer
        let receipt: Double, observedAt: Double
        let epoch: UInt64, serial: UInt64
        let ratio: Float
        let centerMetadata: PeripheralFrameMetadata?, outerMetadata: PeripheralFrameMetadata?
        let centerSampleBuffer: CMSampleBuffer?
        let calibration: PeripheralCalibration?
        let pairingMode: String
        let captureMode:String
        let motionDistance: Double, motionGeneration: UInt64
        let motionSpeed: Double?
        let measuredFrameInterval: Double?
        var frameInterval: Double { measuredFrameInterval ?? max(centerMetadata?.frameInterval ?? 1.0/30,outerMetadata?.frameInterval ?? 1.0/30) }
        var ptsDelta: Double? {
            guard let c = centerMetadata, let o = outerMetadata else { return nil }; return o.pts-c.pts
        }
        init(center: CVPixelBuffer, outer: CVPixelBuffer, receipt: Double,
             configuration: Configuration, serial: UInt64,
             centerMetadata: PeripheralFrameMetadata? = nil, outerMetadata: PeripheralFrameMetadata? = nil,
             calibration: PeripheralCalibration? = nil, pairingMode: String = "fixture",
             motionDistance: Double = 0,motionGeneration: UInt64 = 0,motionSpeed: Double? = nil,
             measuredFrameInterval: Double? = nil,centerSampleBuffer:CMSampleBuffer? = nil) {
            self.center = center; self.outer = outer; self.receipt = receipt
            self.centerMetadata = centerMetadata; self.outerMetadata = outerMetadata
            self.centerSampleBuffer = centerSampleBuffer
            let times = [centerMetadata?.hostCaptureTime,outerMetadata?.hostCaptureTime].compactMap { $0 }
            observedAt = times.count == 2 ? min(receipt,times.min()!) : receipt
            epoch = configuration.epoch; ratio = configuration.fieldOfViewRatio; self.serial = serial
            self.calibration = calibration; self.pairingMode = pairingMode
            captureMode=configuration.captureMode
            self.motionDistance = motionDistance; self.motionGeneration = motionGeneration; self.motionSpeed = motionSpeed
            self.measuredFrameInterval = measuredFrameInterval
        }
    }
    private struct Pending { let sample: CMSampleBuffer; let metadata: PeripheralFrameMetadata; let receipt: Double }
    private let lock = NSLock()
    private var configuration = Configuration()
    private var calibration: PeripheralCalibration?
    private var pair: Pair?
    private var centers: [Pending] = [], outers: [Pending] = []
    private var serial: UInt64 = 0, frameID: UInt64 = 0
    private var lastCenterPTS = -Double.infinity, lastOuterPTS = -Double.infinity
    private var active = true
    private var lastOffer = "none"
    private let pairingQueue = DispatchQueue(label:"dev.glasscam.peripheral.pairing")
    private var flushScheduled = false
    private var previousRaster: PeripheralMotion.Raster?
    private var previousRasterPTS: Double?
    private var motionDistance = 0.0
    private var motionGeneration: UInt64 = 0
    private var submittedCenterPTS: Double?
    private var frameObserver:(()->Void)?
    func observeFrames(_ observer:(()->Void)?) {lock.lock();frameObserver=observer;lock.unlock()}
    func diagnosticState() -> String {
        lock.lock(); defer { lock.unlock() }
        return "epoch=\(configuration.epoch) serial=\(serial) offer=\(lastOffer) ptsDelta=\(pair?.ptsDelta ?? .nan) buffered=\(centers.count),\(outers.count)"
    }
    func recordingSnapshot() -> PeripheralSourceSnapshot {
        lock.lock(); defer { lock.unlock() }
        var pending: [PeripheralUnpairedInput] = []
        for (name, value) in [("center", centers.last), ("outer", outers.last)] {
            if let value, let buffer = CMSampleBufferGetImageBuffer(value.sample) {
                pending.append(.init(stream: name, buffer: buffer, metadata: value.metadata, receipt: value.receipt))
            }
        }
        return .init(pair: pair, pending: pending, state: ["active": active,
            "epoch": configuration.epoch, "serial": serial, "lastOffer": lastOffer,
            "outputIndex": configuration.outputIndex ?? -1, "fieldOfViewRatio": configuration.fieldOfViewRatio,
            "geometryIdentity": configuration.geometryIdentity,
            "captureMode":configuration.captureMode,
            "pendingCenterCount": centers.count, "pendingOuterCount": outers.count,
            "lastCenterPTS": lastCenterPTS, "lastOuterPTS": lastOuterPTS,
            "submittedCenterPTS": submittedCenterPTS ?? .nan])
    }
    func configure(outputIndex: Int?, ratio: Float, calibration: PeripheralCalibration? = nil,
                   captureMode:String = "independent-physical-inputs") {
        lock.lock(); defer { lock.unlock() }
        let valid = ratio.isFinite && ratio > 1.02, index = valid ? outputIndex : nil
        if configuration.outputIndex != index || abs(configuration.fieldOfViewRatio-ratio) > 0.0001 ||
            configuration.geometryIdentity != (calibration?.identity ?? "") || configuration.captureMode != captureMode {
            configuration.epoch &+= 1; clear()
        }
        configuration.outputIndex = index; configuration.fieldOfViewRatio = valid ? ratio : 1
        configuration.geometryIdentity = calibration?.identity ?? ""; self.calibration = calibration
        configuration.captureMode=captureMode
    }
    private func clear() {
        flushScheduled = false; previousRaster = nil; previousRasterPTS = nil; motionDistance = 0; motionGeneration &+= 1
        pair = nil; centers = []; outers = []; lastCenterPTS = -.infinity; lastOuterPTS = -.infinity; submittedCenterPTS = nil
    }
    func selection() -> Configuration { lock.lock(); defer { lock.unlock() }; return configuration }
    func latest() -> Pair? { lock.lock(); defer { lock.unlock() }; return active ? pair : nil }
    func recordSubmittedCenter(_ pts: Double) { lock.lock(); defer { lock.unlock() }; submittedCenterPTS = pts }
    func displaySkew(outerPTS: Double?) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let outerPTS, let submittedCenterPTS else { return nil }; return outerPTS-submittedCenterPTS
    }
    func invalidate() { lock.lock(); defer { lock.unlock() }; active = false; configuration.epoch &+= 1; clear() }
    func reset() { lock.lock(); defer { lock.unlock() }; configuration.epoch &+= 1; clear() }
    func offer(center: CMSampleBuffer?, outer: CMSampleBuffer?, selection: Configuration,
               clock: CMClock? = nil, sameCollection: Bool? = nil, receipt: Double = CACurrentMediaTime()) {
        lock.lock(); var notify:(()->Void)?
        defer {lock.unlock();notify?()}
        guard active, selection == configuration, selection.outputIndex != nil else { return }
        func pending(_ sample: CMSampleBuffer?) -> Pending? {
            guard let sample, CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil else { return nil }
            frameID &+= 1
            let meta = PeripheralFrameMetadata(sample,id: frameID,clock: clock)
            guard meta.pts.isFinite else { return nil }
            return Pending(sample: sample,metadata: meta,receipt: receipt)
        }
        if let c = pending(center), c.metadata.pts > lastCenterPTS, !centers.contains(where: { $0.metadata.pts == c.metadata.pts }) {
            centers.append(c); centers = Array(centers.suffix(3))
        }
        if let o = pending(outer), o.metadata.pts > lastOuterPTS, !outers.contains(where: { $0.metadata.pts == o.metadata.pts }) {
            outers.append(o); outers = Array(outers.suffix(3))
        }
        centers.removeAll { receipt-$0.receipt > 0.05 }; outers.removeAll { receipt-$0.receipt > 0.05 }
        guard !centers.isEmpty, !outers.isEmpty else { lastOffer = "awaiting-stream"; return }
        let same = sameCollection ?? (center != nil && outer != nil)
        var best: (Int,Int,Double)?
        if same {
            let ci = centers.count-1, oi = outers.count-1
            best = (ci,oi,abs(centers[ci].metadata.pts-outers[oi].metadata.pts))
        } else {
            for ci in centers.indices { for oi in outers.indices {
                let delta = abs(centers[ci].metadata.pts-outers[oi].metadata.pts)
                if delta < (best?.2 ?? .infinity) { best = (ci,oi,delta) }
            } }
            let oldest = min(centers.first!.receipt,outers.first!.receipt)
            if centers.count == 1 && outers.count == 1 && receipt-oldest < 0.008 {
                lastOffer = "nearest-wait"
                if !flushScheduled {
                    flushScheduled = true
                    pairingQueue.asyncAfter(deadline:.now()+0.008) { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let valid = self.active && self.configuration == selection
                        if valid { self.flushScheduled = false }
                        self.lock.unlock()
                        if valid { self.offer(center:nil,outer:nil,selection:selection,sameCollection:false) }
                    }
                }
                return
            }
        }
        guard let (ci,oi,delta) = best, delta <= 1.0/60 else { lastOffer = "unsynchronized"; return }
        let c = centers[ci], o = outers[oi]
        guard let cb = CMSampleBufferGetImageBuffer(c.sample), let ob = CMSampleBufferGetImageBuffer(o.sample) else { return }
        var speed: Double?
        if let raster = PeripheralMotion.raster(cb) {
            if let previousRaster, let previousRasterPTS,
               c.metadata.pts > previousRasterPTS, c.metadata.pts-previousRasterPTS < 0.10,
               let displacement = PeripheralMotion.displacement(previousRaster,raster) {
                motionDistance += displacement; speed = displacement/(c.metadata.pts-previousRasterPTS)
            } else { motionGeneration &+= 1; motionDistance = 0 }
            previousRaster = raster; previousRasterPTS = c.metadata.pts
        } else { motionGeneration &+= 1; previousRaster = nil }
        serial &+= 1
        pair = Pair(center: cb,outer: ob,receipt: receipt,configuration: configuration,serial: serial,
                    centerMetadata: c.metadata,outerMetadata: o.metadata,calibration: calibration,
                    pairingMode: same ? "same-collection" : "nearest-buffered",motionDistance: motionDistance,motionGeneration: motionGeneration,motionSpeed: speed,
                    measuredFrameInterval:(1.0/120...0.1).contains(c.metadata.pts-lastCenterPTS) ? c.metadata.pts-lastCenterPTS : nil,
                    centerSampleBuffer:c.sample)
        lastCenterPTS = c.metadata.pts; lastOuterPTS = o.metadata.pts
        centers.removeFirst(ci+1); outers.removeFirst(oi+1)
        centers.removeAll { $0.metadata.pts <= lastCenterPTS }; outers.removeAll { $0.metadata.pts <= lastOuterPTS }; lastOffer = "paired"
        notify=frameObserver
    }
}

/// Synchronizer owns sample delivery. Always forward a valid center frame even
/// when an auxiliary stream is absent/dropped; only the perimeter becomes black.
#if os(iOS)
final class PeripheralFrameSynchronizer: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    let queue = DispatchQueue(label: "dev.glasscam.preview.synchronized", qos: .userInteractive)
    let source: PeripheralFrameSource
    let outputs: [AVCaptureVideoDataOutput]
    let deliveries: [any PeripheralFrameInput]
    let clockProvider: () -> CMClock?
    private var lastDiagnosticTime = -Double.infinity
    init(source: PeripheralFrameSource, outputs: [AVCaptureVideoDataOutput], deliveries: [any PeripheralFrameInput], clock: @escaping () -> CMClock?) {
        self.source = source; self.outputs = outputs; self.deliveries = deliveries; self.clockProvider = clock
        deliveries.first?.observeSubmissions { [weak source] pts in source?.recordSubmittedCenter(pts) }
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
        source.offer(center: center, outer: outer, selection: selection, clock: clockProvider(), sameCollection: center != nil && outer != nil)
    }
}

#endif

/// Only boundaries adjoining a real peripheral pane need seam verification.
/// Horizontal means the two image rows; their order is immaterial across CI's
/// bottom-left and the display's top-left coordinate systems.
struct PeripheralSeams: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    init(photo: CGRect, window: CGSize) {
        self = []
        if photo.minY > 0.5 || window.height-photo.maxY > 0.5 { insert(.horizontal) }
        if photo.minX > 0.5 || window.width-photo.maxX > 0.5 { insert(.vertical) }
    }
    static let horizontal = Self(rawValue: 1)
    static let vertical = Self(rawValue: 2)
    static let all: Self = [.horizontal, .vertical]
}

struct PeripheralAlignmentResult {
    let epoch: UInt64
    let receipt: Double
    let photoAspectRatio: Double
    let photoToOuter: simd_float3x3
    let residual: Double
    let gain: SIMD3<Float>
    let seams: PeripheralSeams
    let expiresAt: Double
    var evidence = PeripheralEvidence.unknown("legacy-result")
    var pairID: UInt64 = 0
    var geometryID: UInt64 = 0
    var photometryID: UInt64 = 0
    var completedAt = 0.0
    var geometryExpiresAt = 0.0
    var photometryExpiresAt = 0.0
    var centerPTS: Double?
    var outerPTS: Double?
    var motionDistance = 0.0
    var motionGeneration: UInt64 = 0
    var inputPair: PeripheralFrameSource.Pair?
    var edgeGains = PeripheralEdgeGains()
    var gateReasons: [String] = []
    var nativeSeam: PeripheralNativeSeam?
    var visiblePhotometryID: UInt64 = 0
    var refinement: PeripheralDenseRefinement?
    var tolerance = PeripheralTolerance.defaultValue
    var directStitch = false
    func evidence(forEdge edge:Int) -> PeripheralEvidence {
        guard let nativeSeam else { return evidence }
        if evidence.reliable && (evidence.interval?.upperBound ?? 1) > PeripheralGlassPolicy.darkeningThreshold {
            return .unknown("physical-candidate-set-crosses-darkening-threshold")
        }
        guard !gateReasons.contains("capture-skew-outside-pair-domain") else { return .unknown("capture-skew-outside-pair-domain") }
        let rows = nativeSeam.diagnostics.filter { $0["edge"] as? Int == edge }
        guard !rows.isEmpty else { return .unknown("no-peripheral-pane-on-this-edge") }
        let passed = rows.filter { $0["passed"] as? Bool == true }.count
        var result = PeripheralEvidence.unknown("current-native-grayscale-edge")
        result.confirmedSevereLowerBound = evidence.confirmedSevereLowerBound
        result.visibleSeam = .init(compatible:passed == rows.count,coverage:Double(passed)/Double(rows.count),
            maximumObservableError:rows.compactMap { $0["visibleErrorUpper"] as? Double }.max(),
            reason:"current-native-grayscale-edge",nativeSupportChecked:true)
        return result
    }
    var permitsAnyDisplay:Bool { evidence.permitsDisplay || (0..<4).contains { evidence(forEdge:$0).permitsDisplay } }
    func renderOuterImage() -> CIImage? {
        guard let pair = inputPair else { return nil }
        let raw = CIImage(cvPixelBuffer:pair.outer)
        guard let refinement else { return raw }
        return refinement.outerImage(raw,centerSize:CGSize(width:CVPixelBufferGetWidth(pair.center),
            height:CVPixelBufferGetHeight(pair.center)),ratio:pair.ratio)
    }
    func isFresh(for epoch: UInt64, at time: Double) -> Bool {
        self.epoch == epoch && time.isFinite && time >= receipt && time <= expiresAt
    }
}

/// Pure coverage contract shared by candidate selection and the final renderer.
/// Corners suffice for a finite, nonsingular homography with positive denominator.
enum PeripheralProjection {
    static func margin(_ matrix: simd_float3x3, window: CGRect, width: Int, height: Int) -> Float? {
        guard width > 0, height > 0, window.width > 0, window.height > 0,
              PeripheralAlignmentWorker.valid(matrix), abs(matrix[2][2]) > 0.00001 else { return nil }
        let normalized = matrix * (1/matrix[2][2])
        guard abs(simd_determinant(normalized)) > 1e-8 else { return nil }
        let norm = (0..<3).reduce(Float(0)) { $0+simd_length_squared(normalized[$1]) }
        let inverse = normalized.inverse
        let invNorm = (0..<3).reduce(Float(0)) { $0+simd_length_squared(inverse[$1]) }
        guard norm*invNorm < 1e6 else { return nil }
        var margin = Float.infinity
        for (x,y) in [(window.minX,window.minY),(window.maxX,window.minY),
                      (window.minX,window.maxY),(window.maxX,window.maxY)] {
            let p = SIMD2(Float(x),Float(y))
            guard let uv = PeripheralAlignmentWorker.project(p,using: normalized),
                  let dx = PeripheralAlignmentWorker.project(p+SIMD2(0.001,0),using: normalized),
                  let dy = PeripheralAlignmentWorker.project(p+SIMD2(0,0.001),using: normalized) else { return nil }
            let a = (dx-uv)*1000, b = (dy-uv)*1000
            let determinant = a.x*b.y-a.y*b.x
            guard determinant > 0.00001, simd_length(a) < 8, simd_length(b) < 8 else { return nil }
            margin = min(margin,min(min(uv.x,1-uv.x)*Float(width),min(uv.y,1-uv.y)*Float(height)))
        }
        return margin
    }
}

final class PeripheralAlignmentWorker {
    static let measurementInterval = 1.0/12.0
    static let registrationInterval = 0.4
    static let measurementLifetime = 0.20
    static func expectedMeasurementInterval(frameInterval: Double) -> Double {
        guard frameInterval.isFinite, frameInterval >= 1.0/120, frameInterval <= 0.1 else { return measurementInterval }
        return ceil(measurementInterval/frameInterval-1e-6)*frameInterval
    }
    private struct Registration {
        let epoch: UInt64
        let matrix: simd_float3x3
        var verifiedAt: Double
        let id: UInt64
        var refinementID: UInt64 = 0
    }
    private struct EpipolarVerification {
        let identity: String
        let measuredAt: Double
        let center: simd_float3x3
        let outer: simd_float3x3
    }
    private var epipolarVerification: EpipolarVerification?
    private struct Photometry {
        var gain: SIMD3<Float>
        var measuredAt: Double
        var updatedAt: Double
        var id: UInt64
        var geometryID: UInt64
    }
    private let queue = DispatchQueue(label: "dev.glasscam.peripheral.registration",qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastRequest = -Double.infinity
    private var result: PeripheralAlignmentResult?
    private var diagnostic: PeripheralAnalysisSnapshot?
    private var runtime: [String:Any] = ["phase":"idle","completedCount":0]
    func runtimeState() -> [String:Any] { lock.lock(); defer { lock.unlock() }; return runtime }
    private func stage(_ name:String) {
        lock.lock(); runtime["phase"] = name; runtime["stageAt"] = CACurrentMediaTime(); lock.unlock()
    }
    private var registration: Registration?
    private var photometry: Photometry?
    private var edgePhotometry: (gain: PeripheralEdgeGains, observedAt: Double)?
    private var lastRegistrationAttempt = -Double.infinity
    private var analysisEpoch: UInt64?
    private var analysisDimensions = SIMD2<Int>(0,0)
    private var analysisSeams: PeripheralSeams = .all
    private var nextGeometryID: UInt64 = 0
    private let recorder = PeripheralDiagnosticRecorder.shared
    private let signposter = OSSignposter(subsystem: "dev.glasscam.prototype",category: "PeripheralAnalysis")
    private let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    func latest() -> PeripheralAlignmentResult? { lock.lock(); defer { lock.unlock() }; return result }
    func latestDiagnostic() -> PeripheralAnalysisSnapshot? { lock.lock(); defer { lock.unlock() }; return diagnostic }
    var isAnalyzing: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    func denseRefinementStatus() -> [String:Any] { ["busy":false,"status":"disabled-for-direct-stitch"] }
    @discardableResult
    func request(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1)) -> Bool {
        lock.lock()
        guard !busy, pair.receipt-lastRequest >= Self.measurementInterval else { lock.unlock(); return false }
        busy = true; lastRequest = pair.receipt; lock.unlock()
        lock.lock(); runtime["phase"] = "queued"; runtime["pairID"] = pair.serial
        runtime["queuedAt"] = CACurrentMediaTime(); lock.unlock()
        let tolerance = PeripheralTolerance.shared.value
        queue.async { [self,pair] in
            let value = autoreleasepool { analyze(pair,seams: seams,window: window,tolerance:tolerance) }
            lock.lock()
            // Includes diagnostic enqueue/callback scheduling in the deadline.
            if let value, value.isFresh(for: pair.epoch,at: CACurrentMediaTime()) { result = value }
            runtime["phase"] = value == nil ? "finished-without-publication" : "published"
            runtime["completedCount"] = (runtime["completedCount"] as? Int ?? 0)+1
            runtime["finishedAt"] = CACurrentMediaTime()
            busy = false; lock.unlock()
        }
        return true
    }
    func analyze(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1),
                 now: () -> Double = CACurrentMediaTime,
                 acquisitionCandidate: simd_float3x3? = nil,
                 tolerance requestedTolerance: Double = PeripheralTolerance.defaultValue) -> PeripheralAlignmentResult? {
        let started = CACurrentMediaTime()
        stage("starting")
        let tolerance = PeripheralTolerance.normalized(requestedTolerance)
        let interval = signposter.beginInterval("Analyze")
        defer { signposter.endInterval("Analyze",interval) }
        var diagnosticReference: [UInt8] = [], diagnosticWarped: [UInt8] = []
        var diagnosticNative: [PeripheralNativeSeam.Strip] = []
        var diagnosticRefinement: PeripheralDenseRefinement?
        var diagnosticState: [String: Any] = ["available": true, "published": false,
            "implementation":"fixed-field-of-view-direct-stitch-v5",
            "measurementDomain":"original-pixels-fixed-field-of-view",
            "tolerance":tolerance,
            "epoch": pair.epoch, "pairID": pair.serial, "startedAt": started,
            "seams": seams.rawValue,
            "window": [window.minX, window.minY, window.width, window.height]]
        defer {
            diagnosticState["finishedAt"] = CACurrentMediaTime()
            diagnosticState["elapsedMS"] = (CACurrentMediaTime() - started) * 1000
            let snapshot = PeripheralAnalysisSnapshot(pair: pair, reference: diagnosticReference,
                warped: diagnosticWarped, metadata: diagnosticState,nativeStrips:diagnosticNative,refinement:diagnosticRefinement)
            lock.lock(); diagnostic = snapshot; lock.unlock()
        }
        func reject(_ reason: String) -> PeripheralAlignmentResult? {
            diagnosticState["reason"] = reason
            PeripheralDiagnostics.trace("alignment rejected: \(reason), age=\(now()-pair.observedAt) pair=\(pair.serial) elapsedMS=\((CACurrentMediaTime()-started)*1000)")
            return nil
        }
        guard now() >= pair.observedAt, now()-pair.observedAt < Self.measurementLifetime,
              !seams.isEmpty else { return reject("expired-input-or-no-seams") }
        let center = CIImage(cvPixelBuffer: pair.center), outer = CIImage(cvPixelBuffer: pair.outer)
        guard center.extent.width > 0, outer.extent.width > 0,
              abs(center.extent.width/center.extent.height-outer.extent.width/outer.extent.height) < 0.01 else { return reject("frame-aspect") }
        let w = 192, h = Int((192*center.extent.height/center.extent.width).rounded())
        guard (96...320).contains(h) else { return reject("analysis-dimensions") }
        if analysisEpoch != pair.epoch || analysisDimensions != SIMD2(w,h) || analysisSeams != seams {
            registration = nil; photometry = nil; edgePhotometry = nil; epipolarVerification = nil; lastRegistrationAttempt = -.infinity
            analysisEpoch = pair.epoch; analysisDimensions = SIMD2(w,h); analysisSeams = seams
        }
        let bounds = CGRect(x: 0,y: 0,width: w,height: h), width = CGFloat(w), height = CGFloat(h)
        let ratio = CGFloat(pair.ratio), tx = width*(1-ratio)/2, ty = height*(1-ratio)/2
        let reference = center.transformed(by: CGAffineTransform(scaleX: width/center.extent.width,y: height/center.extent.height)).cropped(to: bounds)
        let floating = outer.transformed(by: CGAffineTransform(scaleX: width*ratio/outer.extent.width,y: height*ratio/outer.extent.height))
            .transformed(by: CGAffineTransform(translationX: tx,y: ty))
        let readback = signposter.beginInterval("CIReadback")
        stage("reference-readback")
        let referenceBytes = bitmap(reference,bounds: bounds,width: w,height: h)
        diagnosticReference = referenceBytes
        diagnosticState["width"] = w; diagnosticState["height"] = h
        diagnosticState["referenceFormat"] = "RGBA8-sRGB-top-left"
        signposter.endInterval("CIReadback",readback)
        let halo = max(8,Int(Double(min(w,h))*0.16))+2
        diagnosticState["padding"] = halo
        let searchBounds = bounds.insetBy(dx: -CGFloat(halo),dy: -CGFloat(halo))
        // The displayed seam is a fixed field-of-view crop. Measure exactly
        // that crop: fitting a homography/flow first would hide its real error.
        let candidates: [(matrix: simd_float3x3,refreshed: Bool,refinement:PeripheralDenseRefinement?)] =
            [(matrix_identity_float3x3,registration == nil,nil)]
        var selected: (matrix: simd_float3x3,refreshed: Bool,measurement: SeamMeasurement,bytes: [UInt8],margin: Float,refinement:PeripheralDenseRefinement?,outerImage:CIImage,grayScore:Double)?
        var comparisons = 0
        var candidateDiagnostics: [[String: Any]] = []
        diagnosticState["candidateCount"] = candidates.count
        for candidate in candidates {
            stage("candidate-matching")
            guard now()-pair.observedAt < Self.measurementLifetime else { break }
            let transform = Self.samplingTransform(homography: candidate.matrix,width: w,height: h,ratio: pair.ratio)
            candidateDiagnostics.append(["H_columns": PeripheralRecordJSON.matrix(candidate.matrix),
                "photoToOuter_columns": PeripheralRecordJSON.matrix(transform), "refreshed": candidate.refreshed,
                "margin": PeripheralProjection.margin(transform,window:window,
                    width:CVPixelBufferGetWidth(pair.outer),height:CVPixelBufferGetHeight(pair.outer)) ?? -.infinity,
                "requiredMargin": candidate.refreshed ? 4 : 2])
            let candidateOuter = outer
            let candidateFloating = candidateOuter.transformed(by:CGAffineTransform(scaleX:width*ratio/outer.extent.width,y:height*ratio/outer.extent.height))
                .transformed(by:CGAffineTransform(translationX:tx,y:ty))
            guard let margin = PeripheralProjection.margin(transform,window: window,
                width: CVPixelBufferGetWidth(pair.outer),height: CVPixelBufferGetHeight(pair.outer)), margin >= (candidate.refreshed ? 4 : 2),
                let warped = Self.warp(candidateFloating,by: candidate.matrix) else { continue }
            let bytes = bitmap(warped,bounds: searchBounds,width: w+2*halo,height: h+2*halo)
            let grayScore = Self.grayBoundaryScore(referenceBytes,bytes,width:w,height:h,padding:halo,seams:seams)
            candidateDiagnostics[candidateDiagnostics.count-1]["currentGrayBoundaryScore"] = grayScore
            if let old = selected, grayScore < old.grayScore-0.001 { continue }
            // F is enabled only after CURRENT image correspondences independently
            // validate its output coordinate convention; no assumed horizontal line.
            let empiricalF = Self.analysisFundamental(pair,homography: candidate.matrix,width: w,height: h)
            if let empiricalF { diagnosticState["runtimeF_bitmap_columns"] = PeripheralRecordJSON.matrix(empiricalF) }
            diagnosticState["F_coordinateDomain"] = "top-left-analysis-reference-to-top-left-warped-without-halo"
            let certifiedEpipolar: Bool
            if let verification = epipolarVerification, let calibration = pair.calibration,
               verification.identity == calibration.identity, pair.observedAt-verification.measuredAt <= Self.registrationInterval,
               let c = pair.centerMetadata, let o = pair.outerMetadata, let kc = c.intrinsic, let ko = o.intrinsic,
               Self.intrinsicDrift(kc,from:verification.center,width:c.width,height:c.height) < 0.5,
               Self.intrinsicDrift(ko,from:verification.outer,width:o.width,height:o.height) < 0.5 {
                certifiedEpipolar = true
            } else { certifiedEpipolar = false }
            let matchingInterval = signposter.beginInterval("SeamMatching")
            let measurement = Self.measureSeams(reference: referenceBytes,warped: bytes,width: w,height: h,
                warpedPadding: halo,seams: seams,certifiedGeometry: registration != nil,
                previousGain: photometry?.gain,allowPartial: true,
                fundamental: empiricalF,epipolarCertified: certifiedEpipolar,comparisonBudget: max(0,120_000_000-comparisons),deadline: pair.observedAt+Self.measurementLifetime,clock: now)
            signposter.endInterval("SeamMatching",matchingInterval)
            guard let measured = measurement else { continue }
            if measured.epipolarVerified, !certifiedEpipolar,
               let identity = pair.calibration?.identity, let kc = pair.centerMetadata?.intrinsic, let ko = pair.outerMetadata?.intrinsic {
                epipolarVerification = .init(identity:identity,measuredAt:pair.observedAt,center:kc,outer:ko)
            }
            comparisons += measured.comparisons
            // Rank mapping proposals by the CURRENT overlapping grayscale
            // boundary. A count of unique correlation peaks is not a measure
            // of how well the proposed image actually joins the photograph.
            // This score supplies no certificate; native checks below do that.
            if let old = selected {
                if grayScore < old.grayScore-0.001 { continue }
                if abs(grayScore-old.grayScore) <= 0.001 && measured.evidence.coverage < old.measurement.evidence.coverage { continue }
                if abs(grayScore-old.grayScore) <= 0.001 && measured.evidence.coverage == old.measurement.evidence.coverage {
                    let oldError = old.measurement.evidence.interval?.upperBound ?? .infinity
                    let newError = measured.evidence.interval?.upperBound ?? .infinity
                    let saferCoverage = old.margin < 4 && margin >= 4 && newError <= oldError+1/Double(min(w,h))
                    if !saferCoverage && newError >= oldError-1/Double(min(w,h)) { continue }
                }
            }
            selected = (candidate.matrix,candidate.refreshed,measured,bytes,margin,candidate.refinement,candidateOuter,grayScore)
        }
        diagnosticState["candidates"] = candidateDiagnostics
        diagnosticState["comparisons"] = comparisons
        guard let selected else {
            if recorder.recordsPixels {
                let bytes = bitmap(floating,bounds:searchBounds,width:w+2*halo,height:h+2*halo)
                recorder.record(reference:referenceBytes,warped:bytes,width:w,height:h,padding:halo,
                    pair:pair,reason:"no-renderable-candidate",status:"unavailable",matrix:nil,
                    comparisons:comparisons,coverage:0,segments:[],gain:photometry?.gain ?? SIMD3(repeating:1))
            }
            return reject("no-renderable-candidate")
        }
        let measured = selected.measurement
        diagnosticRefinement = selected.refinement
        diagnosticState["denseRefinement"] = denseRefinementStatus()
        diagnosticState["activeRefinementID"] = selected.refinement?.id ?? 0
        diagnosticState["geometryInput"] = "normalized-grayscale-and-native-structure"
        diagnosticState["structuredColorDifferenceControlsOpacity"] = false
        // Direct display has no fitted H or RGB model to certify. Repeating a
        // full search on nine interior patches delayed seam publication while
        // contributing no measurement used by the actual shade estimator.
        let interior:SeamMeasurement?=nil
        let currentGeometryVerified = measured.geometryVerified || interior?.geometryVerified == true
        diagnosticState["interiorGeometryVerified"] = false
        diagnosticState["interiorSearch"]="disabled-unused-by-direct-stitch"
        diagnosticState["interiorSupport"] = interior?.segments.filter { $0.status == .measured }.count ?? 0
        diagnosticState["epipolarFailureReason"] = measured.epipolarVerified ? "none" : "factory-F-not-validated-by-all-independent-probes"
        diagnosticWarped = selected.bytes
        diagnosticState["H_columns"] = PeripheralRecordJSON.matrix(selected.matrix)
        diagnosticState["coverageMargin"] = selected.margin
        diagnosticState["geometryVerified"] = measured.geometryVerified
        diagnosticState["photometryVerified"] = measured.photometryVerified
        diagnosticState["epipolarVerified"] = measured.epipolarVerified
        diagnosticState["epipolarProbeDistancesAnalysisPixels"] = measured.epipolarProbeDistances
        diagnosticState["epipolarProbeThresholdAnalysisPixels"] = 1
        diagnosticState["measurementEvidence"] = PeripheralRecordJSON.evidence(measured.evidence)
        diagnosticState["segments"] = measured.segments.map { segment -> [String: Any] in
            var row: [String: Any] = ["index": segment.index, "point": [segment.point.x,segment.point.y],
                "status": segment.status.rawValue, "searchComplete": segment.searchComplete,
                "gradientEigenvalues": [segment.gradientEigenvalues.x,segment.gradientEigenvalues.y],
                "observableNormal": [segment.observableNormal.x,segment.observableNormal.y]]
            if let range = segment.interval { row["interval"] = [range.lowerBound,range.upperBound] }
            if let best = segment.best { row["bestDisplacement"] = [best.x,best.y] }
            if let fb = segment.forwardBackward { row["forwardBackward"] = fb }
            if let noise = segment.noiseScale { row["analysisNoiseMAD"] = noise }
            if let range = segment.normalInterval { row["normalInterval"] = [range.lowerBound,range.upperBound] }
            row["signalStandardDeviation"] = segment.signalStandardDeviation
            row["repeatedStructure"] = segment.repeatedStructure
            return row
        }
        let geometryID: UInt64
        var verifiedAt = selected.refreshed ? -Double.infinity : registration?.verifiedAt ?? -.infinity
        if selected.refreshed { nextGeometryID &+= 1; geometryID = nextGeometryID }
        else { geometryID = registration?.id ?? 0 }
        if currentGeometryVerified { verifiedAt = pair.observedAt }
        registration = .init(epoch: pair.epoch,matrix: selected.matrix,verifiedAt: verifiedAt,id: geometryID)
        registration?.refinementID = selected.refinement?.id ?? 0
        let photoMeasurement = measured.photometryVerified ? measured : (interior ?? measured)
        if photoMeasurement.photometryVerified {
            let target = photoMeasurement.gain
            if var old = photometry, old.geometryID == geometryID {
                let dt = max(0,pair.observedAt-old.updatedAt), beta = Float(1-exp(-dt/0.12))
                for c in 0..<3 {
                    let delta = log(target[c])-log(old.gain[c])
                    old.gain[c] = exp(log(old.gain[c])+max(-Float(dt)*1.3863,min(Float(dt)*1.3863,beta*delta)))
                }
                old.measuredAt = pair.observedAt; old.updatedAt = pair.observedAt; old.id &+= 1; photometry = old
            } else { photometry = .init(gain: target,measuredAt: pair.observedAt,updatedAt: pair.observedAt,id: 1,geometryID: geometryID) }
        }
        let geometryExpiry = verifiedAt+Self.registrationInterval+0.10
        let photoExpiry = (photometry?.geometryID == geometryID ? photometry?.measuredAt ?? -.infinity : -.infinity)+Self.measurementLifetime
        var evidence = measured.evidence
        var gateReasons: [String] = []
        let screenScale = Double(min(w,h))/min(Double(w)*window.width,Double(h)*window.height)
        let confirmedLarge = max(evidence.confirmedSevereLowerBound ?? 0,
            evidence.reliable ? evidence.interval?.lowerBound ?? 0 : 0)*screenScale > 0.10
        if !confirmedLarge && now() > geometryExpiry { gateReasons.append(verifiedAt.isFinite ? "global-geometry-expired" : "geometry-never-certified") }
        if !confirmedLarge && now() > photoExpiry { gateReasons.append(photometry == nil ? "photometry-never-certified" : "photometry-expired") }
        if let delta = pair.ptsDelta {
            // Current paired images themselves are checked below. Unknown
            // temporal flow is not a fabricated zero, nor a blanket 1ms veto.
            if abs(delta) > min(1.0/60,pair.frameInterval) { gateReasons.append("capture-skew-outside-pair-domain") }
        }
        let gain = photometry?.gain ?? SIMD3(repeating: 1)
        if measured.photometryVerified, (0..<3).contains(where: { abs(log(gain[$0]/measured.gain[$0])) > 0.08 }) {
            evidence.appearance = .mismatch; evidence.reason = "photometry-settling"
        }
        let nativeStarted = CACurrentMediaTime()
        stage("native-boundary-readback")
        let strips = PeripheralNativeSeam.read(center:center,outerImage:selected.outerImage,ratio:pair.ratio,matrix:selected.matrix,
            analysisWidth:w,analysisHeight:h,seams:seams,context:context)
        diagnosticNative = strips
        diagnosticState["nativeReadbackMS"] = (CACurrentMediaTime()-nativeStarted)*1000
        let photoStarted = CACurrentMediaTime()
        var edgeGains = PeripheralEdgeGains()
        diagnosticState["nativePhotometryMS"] = (CACurrentMediaTime()-photoStarted)*1000
        let verifyStarted = CACurrentMediaTime()
        stage("native-boundary-verification")
        let native = PeripheralNativeSeam.evaluate(strips,gains:edgeGains,segments:measured.segments,
            analysisWidth:w,analysisHeight:h,geometryVerified:currentGeometryVerified || now() <= geometryExpiry,
            severe:evidence.confirmedSevereLowerBound,tolerance:tolerance)
        edgeGains = native.gains; edgePhotometry = (edgeGains,pair.observedAt)
        diagnosticState["nativeVerificationMS"] = (CACurrentMediaTime()-verifyStarted)*1000
        evidence.visibleSeam = native.evidence
        if native.evidence.compatible && !evidence.reliable { evidence.reason = "native-visible-seam" }
        if !native.evidence.compatible { evidence.appearance = .mismatch }
        diagnosticState["nativeSeamTiles"] = native.diagnostics
        diagnosticState["geometryReacquisition"] = ["attempted":false,"lastSuccess":verifiedAt,
            "support":interior?.segments.filter { $0.status == .measured }.count ?? 0,
            "failureReason":currentGeometryVerified ? "none" : "insufficient-independent-distributed-correspondences",
            "nextRegistrationRetry":lastRegistrationAttempt+Self.registrationInterval]
        diagnosticState["photometryReacquisition"] = ["attempted":true,
            "lastSuccess":photometry?.measuredAt ?? -.infinity,
            "failureReason":photoMeasurement.photometryVerified ? "none" : "insufficient-unsaturated-physical-correspondences",
            "visiblePhotometryVerified":native.evidence.compatible]
        diagnosticState["edgeGains"] = (0..<4).map { [edgeGains[$0].x,edgeGains[$0].y,edgeGains[$0].z] }
        diagnosticState["visiblePhotometryModel"] = "original-camera-colors-no-display-correction"
        diagnosticState["edgeEncodedSlope"] = edgeGains.encodedSlope.map { [$0.x,$0.y,$0.z] }
        diagnosticState["edgeEncodedBias"] = edgeGains.encodedBias.map { [$0.x,$0.y,$0.z] }
        diagnosticState["edgeAffineModelSelected"] = (0..<4).map { edgeGains.affine($0) }
        // Native appearance certifies its own current pixels and applied gains;
        // it cannot extend the independent physical geometry/photo certificates.
        let pairedTimingValid = !gateReasons.contains("capture-skew-outside-pair-domain")
        if !pairedTimingValid { evidence.visibleSeam = nil }
        if !confirmedLarge && (!gateReasons.isEmpty && !native.evidence.compatible || !pairedTimingValid) {
            evidence = .unknown(gateReasons.joined(separator:","))
        }
        let oneCompleteEdge = (0..<4).contains { edge in
            let rows = native.diagnostics.filter { $0["edge"] as? Int == edge }
            return !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        }
        let expires = (pairedTimingValid && oneCompleteEdge) || evidence.visibleSeam?.compatible == true || confirmedLarge ? pair.observedAt+Self.measurementLifetime :
            min(pair.observedAt+Self.measurementLifetime,min(geometryExpiry,photoExpiry))
        let publicationExpired = now()-pair.observedAt >= Self.measurementLifetime
        diagnosticState["gateReasons"] = gateReasons
        diagnosticState["evidence"] = PeripheralRecordJSON.evidence(evidence)
        diagnosticState["reason"] = publicationExpired ? "expired-before-publication" : evidence.reason
        recorder.record(reference: referenceBytes,warped: selected.bytes,width: w,height: h,padding: halo,
            pair: pair,reason: publicationExpired ? "expired-before-publication" : evidence.reason,
            status: publicationExpired ? "expired" : evidence.status.rawValue,matrix: selected.matrix,
            comparisons: comparisons,coverage: evidence.coverage,segments: measured.segments,gain: gain,
            severeLowerBound: evidence.confirmedSevereLowerBound)
        guard now()-pair.observedAt < Self.measurementLifetime else { return reject("expired-before-publication") }
        PeripheralDiagnostics.trace("alignment status=\(evidence.status.rawValue) pair=\(pair.serial) ms=\((CACurrentMediaTime()-started)*1000) comparisons=\(comparisons) coverage=\(evidence.coverage) margin=\(selected.margin)")
        var value = PeripheralAlignmentResult(epoch: pair.epoch,receipt: pair.observedAt,
            photoAspectRatio: Double(center.extent.width/center.extent.height),
            photoToOuter: Self.samplingTransform(homography: selected.matrix,width: w,height: h,ratio: pair.ratio),
            residual: evidence.interval?.upperBound ?? .nan,gain: gain,seams: seams,
            expiresAt: evidence.permitsDisplay ? max(pair.observedAt,expires) : pair.observedAt+Self.measurementLifetime)
        value.evidence = evidence; value.pairID = pair.serial; value.geometryID = geometryID
        value.photometryID = photometry?.id ?? 0; value.completedAt = now()
        value.geometryExpiresAt = geometryExpiry; value.photometryExpiresAt = photoExpiry
        value.centerPTS = pair.centerMetadata?.pts; value.outerPTS = pair.outerMetadata?.pts
        value.motionDistance = pair.motionDistance; value.motionGeneration = pair.motionGeneration
        value.inputPair = pair; value.edgeGains = edgeGains; value.gateReasons = gateReasons; value.nativeSeam = native
        value.visiblePhotometryID = pair.serial
        value.refinement = nil
        value.directStitch = true
        value.tolerance = tolerance
        diagnosticState["published"] = true
        diagnosticState["result"] = PeripheralRecordJSON.alignment(value)
        return value
    }
    static func intrinsicDrift(_ k: simd_float3x3,from previous: simd_float3x3,width: Int,height: Int) -> Float {
        let delta = k*previous.inverse
        return [SIMD2<Float>(0,0),SIMD2(Float(width),0),SIMD2(0,Float(height)),SIMD2(Float(width),Float(height))].map { p in
            guard let mapped = project(p,using:delta) else { return Float.infinity }
            return simd_distance(p,mapped)*192/Float(max(1,width))
        }.max() ?? .infinity
    }
    static func bufferToCI(width: Int,height: Int,bufferWidth: Int,bufferHeight: Int,ratio: Float) -> simd_float3x3 {
        let w = Float(width), h = Float(height)
        return simd_float3x3(SIMD3(w*ratio/Float(bufferWidth),0,0),SIMD3(0,-h*ratio/Float(bufferHeight),0),
                            SIMD3(w*(1-ratio)/2,h*(1+ratio)/2,1))
    }
    static func analysisFundamental(_ pair: PeripheralFrameSource.Pair,homography: simd_float3x3,width: Int,height: Int) -> simd_float3x3? {
        guard let c = pair.centerMetadata, let o = pair.outerMetadata,
              let f = pair.calibration?.fundamental(center: c,outer: o) else { return nil }
        let a = Self.bufferToCI(width: width,height: height,bufferWidth: c.width,bufferHeight: c.height,ratio: 1)
        let b = homography*Self.bufferToCI(width: width,height: height,bufferWidth: o.width,bufferHeight: o.height,ratio: pair.ratio)
        let value = b.inverse.transpose*f*a.inverse
        // CI uses lower-left coordinates, while render(toBitmap:) rows are
        // top-to-bottom (verified by a nonsymmetric CV buffer + nonzero extent).
        let flip = simd_float3x3(SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,Float(height),1))
        let bitmapF = flip.transpose*value*flip
        return Self.valid(bitmapF) ? bitmapF : nil
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
    static func grayBoundaryScore(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int,padding:Int,seams:PeripheralSeams)->Double {
        var score=0.0,correlationSum=0.0,count=0
        func luma(_ pixels:[UInt8],_ i:Int)->Double {
            (Double(pixels[i])*0.2126+Double(pixels[i+1])*0.7152+Double(pixels[i+2])*0.0722)/255
        }
        for side in 0..<4 {
            guard side<2 ? seams.contains(.horizontal):seams.contains(.vertical) else {continue}
            let length=side<2 ? width:height
            for start in stride(from:0,to:length,by:16) {
                var n=0.0,sa=0.0,sb=0.0,aa=0.0,bb=0.0,ab=0.0
                for t in start..<min(length,start+16) {for d in 0..<8 {
                    let x=side<2 ? t:(side==2 ? d:width-1-d)
                    let y=side<2 ? (side==0 ? d:height-1-d):t
                    let u=luma(a,(y*width+x)*4),v=luma(b,((y+padding)*(width+2*padding)+x+padding)*4)
                    n += 1;sa += u;sb += v;aa += u*u;bb += v*v;ab += u*v
                }}
                let va=max(0,aa-sa*sa/n),vb=max(0,bb-sb*sb/n)
                let value:Double
                if max(va,vb)/n < 4/(255*255) {value=1}
                else if min(va,vb)/n < 0.25/(255*255) {value=0}
                else {value=max(0,min(1,(ab-sa*sb/n)/sqrt(max(1e-12,va*vb))))}
                if value>=0.8 {score += 1}
                correlationSum += value;count += 1
            }
        }
        return score+0.25*correlationSum/Double(max(1,count))
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

    struct SegmentEvidence {
        let index: Int
        let point: SIMD2<Float>
        let status: PeripheralEvidence.Status
        let interval: ClosedRange<Double>?
        let best: SIMD2<Float>?
        let forwardBackward: Float?
        let searchComplete: Bool
        let gradientEigenvalues: SIMD2<Float>
        let observableNormal: SIMD2<Float>
        let noiseScale: Float?
        var normalInterval: ClosedRange<Double>? = nil
        var peak: Float? = nil
        var signalStandardDeviation: Float = 0
        var repeatedStructure = false
        /// Maximum distance from the best candidate to another feasible 2D
        /// candidate, plus half-pixel quantization per axis. Not a covariance.
        var displacementUncertainty:Float? = nil
    }
    struct SeamMeasurement {
        /// Diagnostic only. Unknown is NaN, never a fabricated zero.
        let residual: Double
        let gain: SIMD3<Float>
        let offsets: [Int: SIMD2<Float>]
        let comparisons: Int
        let uncertainAnchors: Set<Int>
        let evidence: PeripheralEvidence
        let segments: [SegmentEvidence]
        let geometryVerified: Bool
        let photometryVerified: Bool
        let boundaryMismatch: Double
        let epipolarVerified: Bool
        var epipolarProbeDistances: [Float] = []
    }

    /// Complete declared candidate domains, full 17x17 support and explicit
    /// ambiguity. A hint never removes a candidate or certifies a global peak.
    /// Optional F is in the SAME CI analysis coordinates as these two images.
    static func measureSeams(reference: [UInt8], warped: [UInt8], width: Int, height: Int,
                             warpedPadding: Int = 0, seams: PeripheralSeams = .all,
                             previousOffsets: [Int: SIMD2<Float>]? = nil, certifiedGeometry: Bool = false,
                             previousGain: SIMD3<Float>? = nil, allowPartial: Bool = false,
                             fundamental: simd_float3x3? = nil,epipolarCertified: Bool = false,
                             comparisonBudget: Int = 90_000_000, deadline: Double = .infinity, clock: () -> Double = CACurrentMediaTime,
                             anchorPoints: [SIMD2<Int>]? = nil) -> SeamMeasurement? {
        guard width >= 64, height >= 64, width <= 512, height <= 512, warpedPadding >= 0, warpedPadding <= max(width,height),
              reference.count == width*height*4, !seams.isEmpty else { return nil }
        let bw = width+2*warpedPadding, bh = height+2*warpedPadding
        guard warped.count == bw*bh*4 else { return nil }
        let radius = max(8,Int(Double(min(width,height))*0.16)), patch = 8, side = 17
        func luma(_ bytes: [UInt8], _ w: Int, _ h: Int) -> [Float] {
            var raw = [Float](repeating: 0,count: w*h)
            for i in raw.indices { raw[i] = (Float(bytes[i*4])*0.2126+Float(bytes[i*4+1])*0.7152+Float(bytes[i*4+2])*0.0722)/255 }
            var horizontal = raw, out = raw
            for y in 0..<h { for x in 1..<w-1 { let i = y*w+x; horizontal[i] = (raw[i-1]+2*raw[i]+raw[i+1])*0.25 } }
            for y in 1..<h-1 { for x in 0..<w { let i = y*w+x; out[i] = (horizontal[i-w]+2*horizontal[i]+horizontal[i+w])*0.25 } }
            return out
        }
        let a = luma(reference,width,height), b = luma(warped,bw,bh)
        struct Plane {
            let values: [Float], width: Int, height: Int
            let sum: [Double], squared: [Double], invalid: [Int]
            init(_ values: [Float], _ bytes: [UInt8], _ width: Int, _ height: Int) {
                self.values = values; self.width = width; self.height = height
                let stride = width+1
                var s = [Double](repeating: 0,count: stride*(height+1)), q = s
                var bad = [Int](repeating: 0,count: s.count)
                for y in 0..<height {
                    var row = 0.0, row2 = 0.0, missing = 0
                    for x in 0..<width {
                        let v = Double(values[y*width+x]); row += v; row2 += v*v
                        // Filter support is valid only if its original pixels are valid.
                        var valid = true
                        for yy in max(0,y-1)...min(height-1,y+1) { for xx in max(0,x-1)...min(width-1,x+1) {
                            if bytes[(yy*width+xx)*4+3] != 255 { valid = false }
                        } }
                        if !valid { missing += 1 }
                        let i = (y+1)*stride+x+1
                        s[i] = s[i-stride]+row; q[i] = q[i-stride]+row2; bad[i] = bad[i-stride]+missing
                    }
                }
                sum = s; squared = q; invalid = bad
            }
            func statistics(_ x: Int, _ y: Int) -> (mean: Float, variance: Float)? {
                guard x >= 8, y >= 8, x+8 < width, y+8 < height else { return nil }
                let stride = width+1, x0 = x-8, y0 = y-8, x1 = x+9, y1 = y+9
                let i = y1*stride+x1, j = y0*stride+x1, k = y1*stride+x0, l = y0*stride+x0
                guard invalid[i]-invalid[j]-invalid[k]+invalid[l] == 0 else { return nil }
                let total = sum[i]-sum[j]-sum[k]+sum[l]
                let variance = squared[i]-squared[j]-squared[k]+squared[l]-total*total/289
                return (Float(total/289),Float(max(0,variance)))
            }
        }
        let pa = Plane(a,reference,width,height), pb = Plane(b,warped,bw,bh)
        var comparisons = 0, exhausted = false
        struct Peak { let value: Float; let dx: Int; let dy: Int }
        func search(_ source: Plane, _ target: Plane, x: Int, y: Int, tx: Int, ty: Int,
                    line: SIMD3<Float>? = nil) -> (peaks: [Peak], complete: Bool) {
            guard let stats = source.statistics(x,y), stats.variance > 0.000001 else { return ([],true) }
            var centered = [Float](); centered.reserveCapacity(289)
            for v in -patch...patch { for u in -patch...patch { centered.append(source.values[(y+v)*source.width+x+u]-stats.mean) } }
            var peaks: [Peak] = [], complete = true
            for dy in -radius...radius {
                if clock() > deadline { exhausted = true; return (peaks,false) }
                let yy = ty+dy
                let lo = max(-radius,patch-tx), hi = min(radius,target.width-patch-1-tx)
                guard yy >= patch, yy+patch < target.height, lo <= hi else { complete = false; continue }
                if lo != -radius || hi != radius { complete = false }
                var dots = [Float](repeating: 0,count: hi-lo+1)
                // Complete 2D fallback uses vectorized row correlation. This
                // changes arithmetic cost, never which candidate may compete.
                if line == nil {
                    let cost = dots.count*289
                    guard comparisons+cost <= comparisonBudget else { exhausted = true; return (peaks,false) }
                    var row = dots
                    target.values.withUnsafeBufferPointer { values in
                        centered.withUnsafeBufferPointer { kernel in
                            dots.withUnsafeMutableBufferPointer { output in
                                row.withUnsafeMutableBufferPointer { scratch in
                                    for v in 0..<side {
                                        let start = (yy+v-patch)*target.width+tx+lo-patch
                                        vDSP_conv(values.baseAddress!+start,1,kernel.baseAddress!+v*side,1,
                                                  scratch.baseAddress!,1,vDSP_Length(output.count),vDSP_Length(side))
                                        vDSP_vadd(output.baseAddress!,1,scratch.baseAddress!,1,output.baseAddress!,1,vDSP_Length(output.count))
                                    }
                                }
                            }
                        }
                    }
                    comparisons += cost
                }
                for dx in lo...hi {
                    let xx = tx+dx
                    if let line {
                        let denominator = hypot(line.x,line.y)
                        if denominator < 0.000001 || abs(line.x*Float(xx)+line.y*Float(yy)+line.z)/denominator > 1.5 { continue }
                    }
                    guard let other = target.statistics(xx,yy) else { complete = false; continue }
                    guard other.variance > 0.000001 else { continue }
                    var dot = dots[dx-lo]
                    if line != nil {
                        guard comparisons+289 <= comparisonBudget else { exhausted = true; return (peaks,false) }
                        dot = 0; var index = 0
                        for v in -patch...patch {
                            let start = (yy+v)*target.width+xx-patch
                            for u in 0..<side { dot += centered[index]*target.values[start+u]; index += 1 }
                        }
                        comparisons += 289
                    }
                    let value = max(-1,min(1,dot/sqrt(stats.variance*other.variance)))
                    peaks.append(.init(value: value,dx: dx,dy: dy))
                }
            }
            return (peaks,complete)
        }
        var validatedF: simd_float3x3?
        var epipolarProbeDistances: [Float] = []
        if let fundamental, epipolarCertified { validatedF = fundamental }
        else if let fundamental {
            var checks = 0
            for fy: Float in [0.25,0.75] { for fx: Float in [0.25,0.50,0.75] {
                let x = Int(Float(width)*fx), y = Int(Float(height)*fy)
                let probe = search(pa,pb,x: x,y: y,tx: x+warpedPadding,ty: y+warpedPadding)
                guard probe.complete, let best = probe.peaks.max(by: { $0.value < $1.value }), best.value > 0.90,
                      !probe.peaks.contains(where: { $0.value >= best.value-0.04 && hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) > 2 }) else { epipolarProbeDistances.append(.nan); continue }
                let line = fundamental*SIMD3(Float(x)+0.5,Float(y)+0.5,1)
                let distance = abs(line.x*(Float(x+best.dx)+0.5)+line.y*(Float(y+best.dy)+0.5)+line.z)/max(1e-8,hypot(line.x,line.y))
                epipolarProbeDistances.append(distance)
                if distance < 1 { checks += 1 }
            } }
            if checks == 6 { validatedF = fundamental }
        }
        var anchors: [(Int,Int)] = []
        // Every segment is represented; a separate scan includes the real edge,
        // corners and gaps between these inward-supported geometry patches.
        func locations(_ length: Int) -> [Int] {
            stride(from: 0,to: length,by: 16).map { min(length-10,max(10,$0+8)) }
        }
        if seams.contains(.horizontal) { for y in [10,height-11] { for x in locations(width) { anchors.append((x,y)) } } }
        if seams.contains(.vertical) { for x in [10,width-11] { for y in locations(height) { anchors.append((x,y)) } } }
        if let anchorPoints { anchors = anchorPoints.map { ($0.x,$0.y) } }
        var segments: [SegmentEvidence] = [], offsets: [Int:SIMD2<Float>] = [:]
        var uncertain: Set<Int> = []
        var gainSamples: [[Float]] = [[],[],[]]
        var severe: [(point: SIMD2<Float>,displacement: SIMD2<Float>,lower: Double)] = []
        func linear(_ value: UInt8) -> Float {
            let v = Float(value)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4)
        }
        func addGain(_ x: Int,_ y: Int,_ dx: Int,_ dy: Int) {
            var blocks: [[Float]] = [[],[],[]]
            for v in stride(from: -6,through: 6,by: 4) { for u in stride(from: -6,through: 6,by: 4) {
                let ia = ((y+v)*width+x+u)*4, ib = ((y+dy+v+warpedPadding)*bw+x+dx+u+warpedPadding)*4
                for c in 0..<3 where reference[ia+c] > 12 && reference[ia+c] < 243 && warped[ib+c] > 12 && warped[ib+c] < 243 {
                    blocks[c].append(log(linear(reference[ia+c])/linear(warped[ib+c])))
                }
            } }
            for c in 0..<3 where blocks[c].count >= 8 { let sorted = blocks[c].sorted(); gainSamples[c].append(sorted[sorted.count/2]) }
        }
        for (index,point) in anchors.enumerated() {
            let (x,y) = point
            var xx:Float = 0,xy:Float = 0,yy:Float = 0,noise: [Float] = []
            for v in -7...7 { for u in -7...7 {
                let i = (y+v)*width+x+u
                let gx = (a[i+1]-a[i-1])*0.5, gy = (a[i+width]-a[i-width])*0.5
                xx += gx*gx; xy += gx*gy; yy += gy*gy
                if gx*gx+gy*gy < 0.0001 {
                    let raw = (Float(reference[i*4])*0.2126+Float(reference[i*4+1])*0.7152+Float(reference[i*4+2])*0.0722)/255
                    noise.append(abs(raw-a[i]))
                }
            } }
            let delta = hypot(xx-yy,2*xy), angle = 0.5*atan2(2*xy,xx-yy)
            let information = SIMD2(max(0,(xx+yy-delta)/2),(xx+yy+delta)/2)
            // Diagnostic ISP-domain scale, not a sensor-noise variance or a
            // calibrated covariance. No probability is inferred from this MAD.
            let noiseScale: Float? = noise.count >= 32 ? noise.sorted()[noise.count/2]*1.4826 : nil
            let line = validatedF.map { $0 * SIMD3(Float(x)+0.5,Float(y)+0.5,1) }.map {
                SIMD3($0.x,$0.y,$0.z+($0.x+$0.y)*(0.5-Float(warpedPadding)))
            }
            let forward = search(pa,pb,x: x,y: y,tx: x+warpedPadding,ty: y+warpedPadding,line: line)
            var status: PeripheralEvidence.Status = exhausted ? .budgetExceeded : .unobservable
            var interval: ClosedRange<Double>?, bestOffset: SIMD2<Float>?, fb: Float?
            var normalInterval: ClosedRange<Double>?, peak: Float?
            var reverseOffset: SIMD2<Float>?
            var displacementUncertainty:Float?
            var repeatedStructure = false
            let signal = sqrt(max(0,pa.statistics(x,y)?.variance ?? 0)/289)
            peak = forward.peaks.max(by: { $0.value < $1.value })?.value
            if forward.complete, let best = forward.peaks.max(by: { $0.value < $1.value }), best.value >= 0.85 {
                peak = best.value
                let feasible = forward.peaks.filter { $0.value >= best.value-0.025 }
                if signal >= 2/255, information.y > 0.0001 {
                    let normal = SIMD2<Float>(cos(angle),sin(angle))
                    let projected = feasible.map { simd_dot(normal,SIMD2(Float($0.dx),Float($0.dy))) }.sorted()
                    let gap = zip(projected,projected.dropFirst()).map { $1-$0 }.max() ?? 0
                    repeatedStructure = gap > 4 && (projected.last ?? 0)-(projected.first ?? 0) > 8 && best.value > 0.90
                }
                // The reverse diagnostic searches its entire *physical* overlap
                // with the cropped central camera. Missing pixels are never padded.
                let reverse = search(pb,pa,x: x+warpedPadding+best.dx,y: y+warpedPadding+best.dy,tx: x+best.dx,ty: y+best.dy,
                    line: validatedF.map {
                        let line = $0.transpose*SIMD3(Float(x+best.dx)+0.5,Float(y+best.dy)+0.5,1)
                        return SIMD3(line.x,line.y,line.z+0.5*(line.x+line.y))
                    })
                if let back = reverse.peaks.max(by: { $0.value < $1.value }), back.value >= 0.85 {
                    // Test the independently selected reverse optimum, not the
                    // most convenient member of its ambiguous candidate set.
                    fb = hypot(Float(back.dx+best.dx),Float(back.dy+best.dy))
                    reverseOffset = SIMD2(Float(back.dx+best.dx),Float(back.dy+best.dy))
                }
                if !exhausted, let reverseOffset, best.value > 0.95, signal >= 2/255 {
                    let normal = SIMD2<Float>(cos(angle),sin(angle))
                    let projected = feasible.map { simd_dot(normal,SIMD2(Float($0.dx),Float($0.dy))) }
                    let minimum = projected.min() ?? 0, maximum = projected.max() ?? 0
                    let edge = information.y > 0.0001 && information.x/information.y < 0.10
                    let norm = SIMD2(Float(best.dx),Float(best.dy))
                    let normalBounded = edge && maximum-minimum <= 2 &&
                        max(abs(minimum),abs(maximum)) < Float(radius-1) && abs(simd_dot(normal,reverseOffset)) <= 1
                    if normalBounded {
                        let closest = minimum <= 0 && maximum >= 0 ? Float(0) : min(abs(minimum),abs(maximum))
                        let lower = max(0,Double(closest)-sqrt(0.5))/Double(min(width,height))
                        let upper = (Double(max(abs(minimum),abs(maximum)))+sqrt(0.5))/Double(min(width,height))
                        normalInterval = lower...upper
                    }
                    let unique2D = (fb ?? .infinity) <= 1 && !feasible.contains { hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) > 2 } &&
                        !feasible.contains { abs($0.dx) >= radius-1 || abs($0.dy) >= radius-1 }
                    if normalBounded || unique2D {
                        let observed = normalBounded ? normal*simd_dot(normal,norm) : norm
                        let lower = max(0,Double(simd_length(observed))-sqrt(0.5))/Double(min(width,height))
                        if lower > 0.10 { severe.append((SIMD2(Float(x),Float(y)),observed,lower)) }
                    }
                }
                if !exhausted, let fb, fb <= 1, signal >= 2/255,
                   !feasible.contains(where: { abs($0.dx) >= radius-1 || abs($0.dy) >= radius-1 }) {
                    let distances = feasible.map { hypot(Double($0.dx),Double($0.dy))/Double(min(width,height)) }
                    // Integer candidates do not specify a continuous exact
                    // displacement. Include half-pixel quantization per axis.
                    let quantization = sqrt(0.5)/Double(min(width,height))
                    interval = max(0,distances.min()!-quantization)...(distances.max()!+quantization)
                    let spread = feasible.map { hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) }.max() ?? 0
                    status = spread <= 2 ? .measured : .ambiguous
                    bestOffset = SIMD2(Float(best.dx),Float(best.dy))
                    if status == .measured {
                        displacementUncertainty=spread+sqrt(0.5)
                        offsets[index] = bestOffset!
                        addGain(x,y,best.dx,best.dy)
                    }
                }
            }
            if status != .measured { uncertain.insert(index) }
            segments.append(.init(index: index,point: SIMD2(Float(x),Float(y)),status: status,
                interval: interval,best: bestOffset,forwardBackward: fb,searchComplete: forward.complete && !exhausted,
                gradientEigenvalues: information,observableNormal: SIMD2(cos(angle),sin(angle)),noiseScale: noiseScale,
                normalInterval:normalInterval,peak:peak,signalStandardDeviation:signal,repeatedStructure:repeatedStructure,
                displacementUncertainty:displacementUncertainty))
        }
        // Independent correspondence validation, not just source-point spread.
        // These matched points have full-domain uniqueness and a reverse check.
        let inliers = segments.filter { $0.status == .measured && ($0.interval?.upperBound ?? 1) < 3/Double(min(width,height)) }
        let positions = inliers.map(\.point)
        let mean = positions.reduce(SIMD2<Float>(repeating:0),+)/Float(max(1,positions.count))
        var xx:Float = 0,xy:Float = 0,yy:Float = 0
        for p in positions {
            let d = (p-mean)/SIMD2(Float(width),Float(height))
            xx += d.x*d.x; xy += d.x*d.y; yy += d.y*d.y
        }
        let distributed = (xx*yy-xy*xy)/Float(max(1,positions.count*positions.count)) > 0.001
        let geometryVerified = distributed && positions.count >= 6 &&
            (positions.map(\.x).max() ?? 0)-(positions.map(\.x).min() ?? 0) > Float(width)*0.4 &&
            (positions.map(\.y).max() ?? 0)-(positions.map(\.y).min() ?? 0) > Float(height)*0.4
        var gain = previousGain ?? SIMD3<Float>(repeating: 1)
        var photometryVerified = gainSamples.allSatisfy { $0.count >= 6 }
        if photometryVerified {
            for c in 0..<3 { let values = gainSamples[c].sorted(); gain[c] = exp(values[values.count/2]) }
        }
        if !(0..<3).allSatisfy({ gain[$0].isFinite && (0.5...2).contains(gain[$0]) }) {
            gain = previousGain ?? SIMD3(repeating: 1); photometryVerified = false
        }
        func encode(_ c: Float) -> Float { c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055 }
        // Inspect every actual boundary pixel, including narrow salient defects.
        // A global robust offset is used only for STRUCTURE, never displacement.
        var pixels: [(Int,Int)] = []
        if seams.contains(.horizontal) { for y in Array(0..<4)+Array(height-4..<height) { for x in 0..<width { pixels.append((x,y)) } } }
        if seams.contains(.vertical) { for x in Array(0..<4)+Array(width-4..<width) { for y in 0..<height { pixels.append((x,y)) } } }
        var residuals: [SIMD3<Float>] = [], invalidBoundary = false
        for (x,y) in pixels {
            let nearest = segments.min { simd_distance_squared($0.point,SIMD2(Float(x),Float(y))) < simd_distance_squared($1.point,SIMD2(Float(x),Float(y))) }
            let offset = nearest?.status == .measured ? nearest?.best ?? .zero : .zero
            let xx = x+warpedPadding+Int(offset.x.rounded()), yy = y+warpedPadding+Int(offset.y.rounded())
            guard xx >= 0, yy >= 0, xx < bw, yy < bh else { invalidBoundary = true; continue }
            let ia = (y*width+x)*4, ib = (yy*bw+xx)*4
            guard reference[ia+3] == 255, warped[ib+3] == 255 else { invalidBoundary = true; continue }
            var d = SIMD3<Float>(repeating: 0)
            for c in 0..<3 { d[c] = Float(reference[ia+c])/255-encode(linear(warped[ib+c])*gain[c]) }
            residuals.append(d)
        }
        var common = SIMD3<Float>(repeating: 0)
        if !residuals.isEmpty { for c in 0..<3 { let sorted = residuals.map { $0[c] }.sorted(); common[c] = sorted[sorted.count/2] } }
        let brightness = (common.x+common.y+common.z)/3
        let chroma = max(abs(common.x-brightness),max(abs(common.y-brightness),abs(common.z-brightness)))
        let mismatch = residuals.filter { simd_length($0-SIMD3(repeating: brightness)) > 0.25 }.count
        let boundaryMismatch = Double(mismatch)/Double(max(1,residuals.count))
        // Small geometry residuals can still move an edge. Do not relabel that
        // as occlusion; scan disagreements prevent unobserved regions being certified.
        let appearance: PeripheralEvidence.Appearance = invalidBoundary || chroma > 0.06 || abs(brightness) > 0.08 || boundaryMismatch > 0.04 ? .mismatch : .compatible
        let measured = segments.compactMap { $0.searchComplete ? $0.interval : nil }
        let allMeasured = measured.count == segments.count && !segments.isEmpty
        let lower = measured.map(\.lowerBound).max(), upper = measured.map(\.upperBound).max()
        let status: PeripheralEvidence.Status = exhausted ? .budgetExceeded :
            (segments.contains { $0.status == .ambiguous } ? .ambiguous : (allMeasured ? .measured : .unobservable))
        var evidence = PeripheralEvidence(status: status,interval: allMeasured ? lower!...upper! : nil,
            appearance: appearance,reason: exhausted ? "comparison-budget" : (allMeasured ? "full-support-matches" : "unresolved-segments"),
            searchComplete: segments.allSatisfy(\.searchComplete),coverage: Double(measured.count)/Double(max(1,segments.count)))
        // Corroborate a severe local structure across distinct supported
        // segments. An isolated low-confidence maximum cannot use this path.
        for i in severe.indices { for j in severe.indices where j > i {
            if simd_distance(severe[i].point,severe[j].point) >= 12 &&
                simd_distance(severe[i].displacement,severe[j].displacement) <= 2 {
                evidence.confirmedSevereLowerBound = max(evidence.confirmedSevereLowerBound ?? 0,
                    min(severe[i].lower,severe[j].lower))
            }
        } }
        if evidence.confirmedSevereLowerBound != nil { evidence.reason = "corroborated-local-displacement" }
        // Strict callers may still use nil, but no successful value can represent
        // unobservable geometry as a reliable zero. Production requests all states.
        if !allowPartial && (!evidence.reliable || (!certifiedGeometry && !geometryVerified) || appearance == .mismatch) { return nil }
        return .init(residual: evidence.reliable ? offsets.values.map { Double(simd_length($0))/Double(min(width,height)) }.max() ?? .nan : .nan,gain: gain,offsets: offsets,
            comparisons: comparisons,uncertainAnchors: uncertain,evidence: evidence,segments: segments,
            geometryVerified: geometryVerified,photometryVerified: photometryVerified,boundaryMismatch: boundaryMismatch,
            epipolarVerified: validatedF != nil,epipolarProbeDistances:epipolarProbeDistances)
    }
}

/// Optional exact analysis-byte replay. No capture buffer is retained by the
/// recorder, no PNG work runs on the matcher, and storage/memory are hard bounded.
final class PeripheralDiagnosticRecorder {
    static let shared = PeripheralDiagnosticRecorder()
    private struct Frame { let a: [UInt8], b: [UInt8], metadata: [String:Any] }
    private let enabled: Bool
    private let directory: URL
    private let clock: () -> Double
    init(enabled: Bool? = nil,directory: URL? = nil,clock: @escaping () -> Double = CACurrentMediaTime) {
        self.enabled = enabled ?? (ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_FRAME_RING"] == "1")
        self.directory = directory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("GlassCamPeripheralEvents")
        self.clock = clock
    }
    var statistics: (events:Int,bytes:Int,writing:Bool) {
        lock.lock(); defer { lock.unlock() }; return (writtenEvents,storedBytes,writing)
    }
    private let writer = DispatchQueue(label: "dev.glasscam.peripheral.diagnostic",qos: .utility)
    private let lock = NSLock()
    private var ring: [Frame] = [], event: [Frame] = []
    private var postFrames = 0, writtenEvents = 0
    private var writing = false
    private var previousStatus: String?
    private var previousEpoch: UInt64?
    private var previousReason: String?
    private var pendingTrigger: String?
    func trigger(_ reason: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if !writing && postFrames == 0 { pendingTrigger = reason }
    }
    var recordsPixels: Bool { enabled }
    private var dropped = 0
    private var storedBytes = 0
    private var lastAttemptAt = -Double.infinity
    func record(reference: [UInt8],warped: [UInt8],width: Int,height: Int,padding: Int,
                pair: PeripheralFrameSource.Pair,reason: String,status: String,matrix: simd_float3x3?,
                comparisons: Int,coverage: Double,segments: [PeripheralAlignmentWorker.SegmentEvidence],gain: SIMD3<Float>,severeLowerBound: Double? = nil) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard reference.count+warped.count <= 1_000_000, writtenEvents < 3 else { dropped += 1; return }
        var metadata: [String:Any] = ["epoch":pair.epoch,"pairID":pair.serial,"observedAt":pair.observedAt,
            "hostReceipt":pair.receipt,"width":width,"height":height,"padding":padding,
            "status":status,"reason":reason,"comparisons":comparisons,"coverage":coverage,
            "pairingMode":pair.pairingMode,"droppedDiagnosticFrames":dropped,
            "homographyAvailable":matrix != nil]
        if let matrix { metadata["H_columns"] = (0..<3).map { [matrix[$0].x,matrix[$0].y,matrix[$0].z] } }
        if let pendingTrigger { metadata["externalTrigger"] = pendingTrigger }
        metadata["implementation"] = "seam-evidence-20261023"
        metadata["schemaVersion"] = 1
        if let severeLowerBound { metadata["confirmedSevereLowerBound"] = severeLowerBound }
        metadata["gain"] = [gain.x,gain.y,gain.z]
        metadata["segments"] = segments.map { segment -> [String:Any] in
            var value: [String:Any] = ["index":segment.index,"point":[segment.point.x,segment.point.y],
                "status":segment.status.rawValue,"searchComplete":segment.searchComplete,
                "gradientEigenvalues":[segment.gradientEigenvalues.x,segment.gradientEigenvalues.y],
                "observableNormal":[segment.observableNormal.x,segment.observableNormal.y]]
            if let interval = segment.interval { value["empiricalInterval"] = [interval.lowerBound,interval.upperBound] }
            if let best = segment.best { value["bestDisplacement"] = [best.x,best.y] }
            if let fb = segment.forwardBackward { value["forwardBackward"] = fb }
            if let noise = segment.noiseScale { value["analysisNoiseMAD"] = noise }
            return value
        }
        func frameMetadata(_ value: PeripheralFrameMetadata?) -> [String:Any] {
            guard let value else { return [:] }
            var result: [String:Any] = ["id":value.id,"pts":value.pts,"dimensions":[value.width,value.height],
                "captureClockMapped":value.hostCaptureTime != nil,"pixelFormat":value.pixelFormat,
                "colorAttachments":value.colorAttachments,"frameInterval":value.frameInterval]
            if let time = value.hostCaptureTime { result["hostCaptureTime"] = time }
            if let k = value.intrinsic { result["K_columns"] = (0..<3).map { [k[$0].x,k[$0].y,k[$0].z] } }
            return result
        }
        metadata["centerMetadata"] = frameMetadata(pair.centerMetadata)
        metadata["outerMetadata"] = frameMetadata(pair.outerMetadata)
        if let calibration = pair.calibration {
            metadata["calibrationIdentity"] = calibration.identity
            metadata["R_columns"] = (0..<3).map { [calibration.rotation[$0].x,calibration.rotation[$0].y,calibration.rotation[$0].z] }
            metadata["t_mm"] = [calibration.translation.x,calibration.translation.y,calibration.translation.z]
        }
        let frame = Frame(a:reference,b:warped,metadata:metadata)
        ring.append(frame); if ring.count > 24 { ring.removeFirst() }
        if postFrames > 0 { event.append(frame); postFrames -= 1 }
        else if !writing && clock()-lastAttemptAt >= 5 &&
            (pendingTrigger != nil || (previousStatus == nil && status != "measured") ||
             (previousStatus != nil && (status != previousStatus || pair.epoch != previousEpoch || reason != previousReason))) {
            event = ring; postFrames = 12; pendingTrigger = nil
        }
        previousStatus = status; previousEpoch = pair.epoch; previousReason = reason
        guard !writing, !event.isEmpty, postFrames == 0 else { return }
        let frames = event; event = []
        let bytes = frames.reduce(0) { $0+$1.a.count+$1.b.count }
        guard storedBytes+bytes < 64*1024*1024 else { writtenEvents = 3; return }
        writing = true; lastAttemptAt = clock()
        let eventID = writtenEvents
        writer.async { [self] in
            var success = false
            var committedBytes = bytes
            let directory = self.directory.appendingPathComponent(UUID().uuidString)
            do {
                let parent = directory.deletingLastPathComponent()
                try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
                let existing = try FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)
                guard existing.count < 3 else {
                    lock.lock(); writing = false; writtenEvents = 3; lock.unlock(); return
                }
                var existingBytes = 0
                if let enumerator = FileManager.default.enumerator(at:parent,includingPropertiesForKeys:[.fileSizeKey]) {
                    for case let url as URL in enumerator { existingBytes += (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 }
                }
                guard existingBytes+bytes < 64*1024*1024 else {
                    lock.lock(); writing = false; writtenEvents = 3; lock.unlock(); return
                }
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                var records: [[String:Any]] = []
                for (index,frame) in frames.enumerated() {
                    let a = "\(index)-reference.rgba", b = "\(index)-warped-halo.rgba"
                    var row = frame.metadata; row["referenceFile"] = a; row["warpedFile"] = b
                    row["referenceSHA256"] = SHA256.hash(data:Data(frame.a)).map { String(format:"%02x",$0) }.joined()
                    row["warpedSHA256"] = SHA256.hash(data:Data(frame.b)).map { String(format:"%02x",$0) }.joined()
                    records.append(row)
                }
                let data = try JSONSerialization.data(withJSONObject:["eventID":eventID,"frames":records],options:[.prettyPrinted,.sortedKeys])
                committedBytes += data.count
                guard existingBytes+committedBytes < 64*1024*1024 else {
                    try? FileManager.default.removeItem(at:directory)
                    lock.lock(); writing = false; writtenEvents = 3; lock.unlock(); return
                }
                for (index,frame) in frames.enumerated() {
                    try Data(frame.a).write(to:directory.appendingPathComponent("\(index)-reference.rgba"),options:.atomic)
                    try Data(frame.b).write(to:directory.appendingPathComponent("\(index)-warped-halo.rgba"),options:.atomic)
                }
                try data.write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
                success = true
            } catch {
                try? FileManager.default.removeItem(at:directory)
                PeripheralDiagnostics.trace("diagnostic write failed: \(error.localizedDescription)")
            }
            lock.lock(); writing = false; if success { writtenEvents += 1; storedBytes += committedBytes }; lock.unlock()
        }
    }
}
