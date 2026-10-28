import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Opt-in live diagnostics. Pixel snapshots require a separate explicit flag.
public enum PeripheralDiagnostics {
    public static let isEnabled = ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_TRACE"] == "1"
    public static func trace(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        Logger(subsystem: "dev.glasscam.prototype", category: "PeripheralTrace")
            .notice("\(text, privacy: .public)")
    }
}

/// Optional exact analysis-byte replay. No capture buffer is retained by the
/// recorder, no PNG work runs on the matcher, and storage/memory are hard bounded.
public final class PeripheralDiagnosticRecorder {
    public static let shared = PeripheralDiagnosticRecorder()
    private struct Frame { let a: [UInt8], b: [UInt8], metadata: [String:Any] }
    private let enabled: Bool
    private let directory: URL
    private let clock: () -> Double
    public init(enabled: Bool? = nil,directory: URL? = nil,clock: @escaping () -> Double = CACurrentMediaTime) {
        self.enabled = enabled ?? (ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_FRAME_RING"] == "1")
        self.directory = directory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("GlassCamPeripheralEvents")
        self.clock = clock
    }
    var statistics: (events:Int,bytes:Int,writing:Bool) {
        lock.lock(); defer { lock.unlock() }; return (writtenEvents,storedBytes,writing)
    }
    let writer = DispatchQueue(label: "dev.glasscam.peripheral.diagnostic",qos: .utility)
    private let lock = NSLock()
    private var ring: [Frame] = [], event: [Frame] = []
    private var postFrames = 0, writtenEvents = 0
    private var writing = false
    private var previousStatus: String?
    private var previousEpoch: UInt64?
    private var previousReason: String?
    private var pendingTrigger: String?
    public func trigger(_ reason: String) {
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
