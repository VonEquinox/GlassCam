import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Three samples per stream, bounded age and no sample reuse. Same-collection
/// pairs take priority; split callbacks get a short nearest-neighbour window.
public final class PeripheralFrameSource {
    public init() {}
    public struct Configuration: Equatable {
        package init(outputIndex: Int? = nil, fieldOfViewRatio: Float = 1, epoch: UInt64 = 0,
                     geometryIdentity: String = "", captureMode: String = "independent-physical-inputs") {
            self.outputIndex = outputIndex; self.fieldOfViewRatio = fieldOfViewRatio; self.epoch = epoch
            self.geometryIdentity = geometryIdentity; self.captureMode = captureMode
        }
        public var outputIndex: Int?
        var fieldOfViewRatio: Float = 1
        public var epoch: UInt64 = 0
        var geometryIdentity = ""
        public var captureMode = "independent-physical-inputs"
    }
    public final class Pair {
        public let center: CVPixelBuffer, outer: CVPixelBuffer
        public let receipt: Double, observedAt: Double
        public let epoch: UInt64, serial: UInt64
        public let ratio: Float
        public let centerMetadata: PeripheralFrameMetadata?, outerMetadata: PeripheralFrameMetadata?
        public let centerSampleBuffer: CMSampleBuffer?
        public let calibration: PeripheralCalibration?
        let pairingMode: String
        public let captureMode:String
        let motionDistance: Double, motionGeneration: UInt64
        let motionSpeed: Double?
        let measuredFrameInterval: Double?
        var frameInterval: Double { measuredFrameInterval ?? max(centerMetadata?.frameInterval ?? 1.0/30,outerMetadata?.frameInterval ?? 1.0/30) }
        public var ptsDelta: Double? {
            guard let c = centerMetadata, let o = outerMetadata else { return nil }; return o.pts-c.pts
        }
        public init(center: CVPixelBuffer, outer: CVPixelBuffer, receipt: Double,
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
    private var frameObserver:(()->Void)?
    public func observeFrames(_ observer:(()->Void)?) {lock.lock();frameObserver=observer;lock.unlock()}
    public func diagnosticState() -> String {
        lock.lock(); defer { lock.unlock() }
        return "epoch=\(configuration.epoch) serial=\(serial) offer=\(lastOffer) ptsDelta=\(pair?.ptsDelta ?? .nan) buffered=\(centers.count),\(outers.count)"
    }
    public func configure(outputIndex: Int?, ratio: Float, calibration: PeripheralCalibration? = nil,
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
        pair = nil; centers = []; outers = []; lastCenterPTS = -.infinity; lastOuterPTS = -.infinity
    }
    public func selection() -> Configuration { lock.lock(); defer { lock.unlock() }; return configuration }
    public func latest() -> Pair? { lock.lock(); defer { lock.unlock() }; return active ? pair : nil }
    public func invalidate() { lock.lock(); defer { lock.unlock() }; active = false; configuration.epoch &+= 1; clear() }
    public func reset() { lock.lock(); defer { lock.unlock() }; configuration.epoch &+= 1; clear() }
    public func offer(center: CMSampleBuffer?, outer: CMSampleBuffer?, selection: Configuration,
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
