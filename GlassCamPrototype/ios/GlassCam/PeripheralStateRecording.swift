import Foundation
import AVFoundation
import CoreImage
import CryptoKit
import QuartzCore
import simd
import zlib

/// Exact inputs of the last completed analysis, including rejected publications.
/// Arrays use Swift copy-on-write; no extra image conversion runs in the matcher.
struct PeripheralAnalysisSnapshot {
    let pair: PeripheralFrameSource.Pair
    let reference: [UInt8]
    let warped: [UInt8]
    let metadata: [String: Any]
    var nativeStrips: [PeripheralNativeSeam.Strip] = []
    var refinement: PeripheralDenseRefinement?
}

struct PeripheralUnpairedInput {
    let stream: String
    let buffer: CVPixelBuffer
    let metadata: PeripheralFrameMetadata
    let receipt: Double
}

struct PeripheralSourceSnapshot {
    let pair: PeripheralFrameSource.Pair?
    let pending: [PeripheralUnpairedInput]
    let state: [String: Any]
}

enum PeripheralRecordJSON {
    static func clean(_ value: Any) -> Any {
        if let values = value as? [String: Any] { return values.mapValues(clean) }
        if let values = value as? [Any] { return values.map(clean) }
        if let n = value as? NSNumber, !n.doubleValue.isFinite {
            return n.doubleValue.isNaN ? "NaN" : (n.doubleValue > 0 ? "+Infinity" : "-Infinity")
        }
        return value
    }
    static func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: clean(value), options: [.prettyPrinted, .sortedKeys])
    }
    static func matrix(_ value: simd_float3x3) -> [[Float]] {
        (0..<3).map { [value[$0].x, value[$0].y, value[$0].z] }
    }
    static func frame(_ value: PeripheralFrameMetadata?) -> [String: Any] {
        guard let value else { return ["available": false] }
        var row: [String: Any] = ["available": true, "id": value.id, "pts": value.pts,
            "width": value.width, "height": value.height, "frameInterval": value.frameInterval,
            "pixelFormat": value.pixelFormat, "colorAttachments": value.colorAttachments]
        row["hostCaptureTime"] = value.hostCaptureTime ?? .nan
        if let intrinsic = value.intrinsic { row["K_columns"] = matrix(intrinsic) }
        return row
    }
    static func evidence(_ value: PeripheralEvidence) -> [String: Any] {
        var row: [String: Any] = ["status": value.status.rawValue, "reason": value.reason,
            "reliable": value.reliable, "appearance": value.appearance.rawValue,
            "coverage": value.coverage, "searchComplete": value.searchComplete]
        if let interval = value.interval { row["interval"] = [interval.lowerBound, interval.upperBound] }
        if let lower = value.confirmedSevereLowerBound { row["confirmedSevereLowerBound"] = lower }
        if let v = value.visibleSeam {
            row["visibleSeam"] = ["compatible":v.compatible,"coverage":v.coverage,
                "maximumObservableError":v.maximumObservableError ?? .nan,"reason":v.reason,
                "nativeSupportChecked":v.nativeSupportChecked]
        }
        row["permitsDisplay"] = value.permitsDisplay
        return row
    }
    static func alignment(_ value: PeripheralAlignmentResult?) -> [String: Any] {
        guard let value else { return ["available": false] }
        return ["available": true, "epoch": value.epoch, "pairID": value.pairID,"tolerance":value.tolerance,
            "directStitch":value.directStitch,
            "observedAt": value.receipt, "completedAt": value.completedAt, "expiresAt": value.expiresAt,
            "geometryID": value.geometryID, "photometryID": value.photometryID,
            "geometryExpiresAt": value.geometryExpiresAt, "photometryExpiresAt": value.photometryExpiresAt,
            "photoToOuter_columns": matrix(value.photoToOuter),
            "gain": [value.gain.x, value.gain.y, value.gain.z], "evidence": evidence(value.evidence),
            "centerPTS": value.centerPTS ?? .nan, "outerPTS": value.outerPTS ?? .nan,
            "motionDistance": value.motionDistance, "motionGeneration": value.motionGeneration,
            "seams": value.seams.rawValue, "photoAspectRatio": value.photoAspectRatio,
            "gateReasons":value.gateReasons,"geometryCertification":value.geometryExpiresAt.isFinite ? "certified-with-deadline" : "neverCertified",
            "photometryCertification":value.photometryExpiresAt.isFinite ? "certified-with-deadline" : "neverCertified",
            "visiblePhotometryID":value.visiblePhotometryID,
            "refinementID":value.refinement?.id ?? 0,
            "refinementSourcePairID":value.refinement?.sourcePairID ?? 0,
            "refinementAlgorithm":value.refinement?.algorithm ?? "none",
            "encodedAffinePhotometry":value.edgeGains.usesEncodedAffine,
            "edgeAffineModelSelected":(0..<4).map { value.edgeGains.affine($0) },
            "edgeEncodedSlope":value.edgeGains.encodedSlope.map { [$0.x,$0.y,$0.z] },
            "edgeEncodedBias":value.edgeGains.encodedBias.map { [$0.x,$0.y,$0.z] },
            "edgeGains":(0..<4).map { [value.edgeGains[$0].x,value.edgeGains[$0].y,value.edgeGains[$0].z] }]
    }
    static func edgeGains(_ gains: PeripheralEdgeGains) -> [String:Any] {
        ["linear":(0..<4).map { [gains[$0].x,gains[$0].y,gains[$0].z] },
         "encodedSlope":gains.encodedSlope.map { [$0.x,$0.y,$0.z] },
         "encodedBias":gains.encodedBias.map { [$0.x,$0.y,$0.z] },
         "affine":(0..<4).map { gains.affine($0) }]
    }
}

/// Manual, durable recordings. Only a tap retains full native buffers for I/O.
/// At most one save/export runs at a time; no record is silently evicted.
final class PeripheralStateRecorder {
    static let shared = PeripheralStateRecorder()
    static let relativeDirectory = "Documents/GlassCamStateRecords"
    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "dev.glasscam.state-records", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var render: [String: Any] = ["phase": "renderer-not-created"]
    private var history: [[String: Any]] = []
    private var gpuEvents: [[String: Any]] = []
    private var renderPair: PeripheralFrameSource.Pair?
    private var texturePair: PeripheralFrameSource.Pair?
    private var analysis: PeripheralAnalysisSnapshot?
    private var renderedFrame: PeripheralLiveFrame?

    init(directory: URL? = nil, maxBytes: Int = 512 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCamStateRecords", isDirectory: true)
        self.maxBytes = maxBytes
    }
    func updateRenderer(_ state: [String: Any], pair: PeripheralFrameSource.Pair?,
                        texturePair: PeripheralFrameSource.Pair?, analysis: PeripheralAnalysisSnapshot?,
                        renderedFrame: PeripheralLiveFrame? = nil) {
        lock.lock(); defer { lock.unlock() }
        render = state; renderPair = pair; self.texturePair = texturePair; self.analysis = analysis
        self.renderedFrame = renderedFrame
        history.append(state)
        if history.count > 180 { history.removeFirst(history.count - 180) }
    }
    func gpuEvent(_ state: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        gpuEvents.append(state)
        if gpuEvents.count > 90 { gpuEvents.removeFirst(gpuEvents.count - 90) }
    }
    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }; busy = true; return true
    }
    private func finish() { lock.lock(); busy = false; lock.unlock() }

    /// Captures metadata and immutable CVPixelBuffer ownership at the tap, never
    /// after queue scheduling. A stopped camera still produces a useful record.
    @discardableResult
    func record(pair: PeripheralFrameSource.Pair?, camera: [String: Any],
                unpaired: [PeripheralUnpairedInput] = [],
                completion: @escaping (Result<URL, Error>) -> Void) -> Bool {
        guard begin() else { return false }
        let tapTime = CACurrentMediaTime(), wallTime = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        let state = render, trace = history, gpu = gpuEvents, analysis = self.analysis, renderedFrame = self.renderedFrame
        let candidates: [(String, PeripheralFrameSource.Pair?)] = [
            ("tapPair", pair), ("renderCandidatePair", renderPair),
            ("texturePair", texturePair), ("analysisPair", analysis?.pair), ("renderModelPair", renderedFrame?.modelPair)]
        lock.unlock()
        let identifier = "record-\(UInt64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        queue.async { [self] in
            let staging = directory.appendingPathComponent(".pending-\(identifier)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var pairs: [String: PeripheralFrameSource.Pair] = [:], roles: [String: String] = [:]
                for (role, pair) in candidates {
                    guard let pair else { continue }
                    let key = "epoch-\(pair.epoch)-pair-\(pair.serial)-t\(String(pair.receipt.bitPattern, radix: 16))"
                    pairs[key] = pair; roles[role] = key
                }
                let estimated = pairs.values.reduce(0) { $0 + Self.byteCount($1.center) + Self.byteCount($1.outer) }
                    + unpaired.reduce(0) { $0 + Self.byteCount($1.buffer) }
                    + (analysis?.nativeStrips.reduce(0) { $0+$1.reference.count+$1.outer.count } ?? 0)
                    + (analysis?.reference.count ?? 0) + (analysis?.warped.count ?? 0) + 4 * 1024 * 1024
                    + (analysis?.refinement?.rgba.count ?? 0)*MemoryLayout<Float>.size
                    + (renderedFrame?.refinement?.rgba.count ?? 0)*MemoryLayout<Float>.size
                guard estimated < 256 * 1024 * 1024, try Self.directoryBytes(directory) + estimated <= maxBytes else {
                    throw RecordingError.storageFull
                }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var pairRows: [String: Any] = [:], files: [[String: Any]] = []
                for key in pairs.keys.sorted() {
                    let pair = pairs[key]!, target = staging.appendingPathComponent("pairs/\(key)", isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    var row: [String: Any] = ["epoch": pair.epoch, "pairID": pair.serial,
                        "receipt": pair.receipt, "observedAt": pair.observedAt, "ratio": pair.ratio,
                        "pairingMode": pair.pairingMode, "ptsDelta": pair.ptsDelta ?? .nan,
                        "motionDistance": pair.motionDistance, "motionGeneration": pair.motionGeneration,
                        "motionSpeed": pair.motionSpeed ?? .nan, "centerMetadata": PeripheralRecordJSON.frame(pair.centerMetadata),
                        "motionCoordinateDomain":"192-wide central raster; cumulative path length with per-step quantization allowance",
                        "motionDistanceUnit":"analysis pixels; only comparable within the same generation",
                        "measuredFrameInterval":pair.measuredFrameInterval ?? .nan,
                        "outerMetadata": PeripheralRecordJSON.frame(pair.outerMetadata)]
                    row["center"] = try Self.writeBuffer(pair.center, prefix: "pairs/\(key)/center", root: staging, files: &files)
                    row["outer"] = try Self.writeBuffer(pair.outer, prefix: "pairs/\(key)/outer", root: staging, files: &files)
                    if let calibration = pair.calibration {
                        row["calibration"] = ["identity": calibration.identity,
                            "R_columns": PeripheralRecordJSON.matrix(calibration.rotation),
                            "t_mm": [calibration.translation.x, calibration.translation.y, calibration.translation.z],
                            "outputRotation": calibration.outputRotation]
                    }
                    pairRows[key] = row
                }
                var pendingRows: [[String: Any]] = []
                if !unpaired.isEmpty {
                    try FileManager.default.createDirectory(at: staging.appendingPathComponent("unpaired"), withIntermediateDirectories: true)
                    for (index, input) in unpaired.enumerated() {
                        let buffer = try Self.writeBuffer(input.buffer, prefix: "unpaired/input-\(index)", root: staging, files: &files)
                        pendingRows.append(["stream": input.stream, "receipt": input.receipt,
                            "metadata": PeripheralRecordJSON.frame(input.metadata), "buffer": buffer])
                    }
                }
                var analysisRow = analysis?.metadata ?? ["available": false, "reason": "no-completed-analysis"]
                if let analysis {
                    analysisRow["pairKey"] = roles["analysisPair"]
                    if !analysis.reference.isEmpty {
                        try Self.write(Data(analysis.reference), name: "analysis-reference.rgba", root: staging, files: &files)
                        analysisRow["referenceFile"] = "analysis-reference.rgba"
                    }
                    if !analysis.warped.isEmpty {
                        try Self.write(Data(analysis.warped), name: "analysis-warped-halo.rgba", root: staging, files: &files)
                        analysisRow["warpedFile"] = "analysis-warped-halo.rgba"
                    }
                    var nativeRows: [[String:Any]] = []
                    for strip in analysis.nativeStrips {
                        let referenceName = "native-edge-\(strip.edge)-reference.rgba"
                        let outerName = "native-edge-\(strip.edge)-outer.rgba"
                        try Self.write(Data(strip.reference),name:referenceName,root:staging,files:&files)
                        try Self.write(Data(strip.outer),name:outerName,root:staging,files:&files)
                        nativeRows.append(["edge":strip.edge,"width":strip.width,"height":strip.height,
                            "nativeScale":strip.nativeScale,"referenceFile":referenceName,"outerFile":outerName,
                            "format":"RGBA8-sRGB-top-left-unadjusted"])
                    }
                    analysisRow["nativeStrips"] = nativeRows
                    if let refinement = analysis.refinement {
                        let name = "dense-refinement.rgba32f"
                        try Self.write(refinement.rgba.withUnsafeBytes { Data($0) },name:name,root:staging,files:&files)
                        analysisRow["denseRefinementField"] = ["file":name,"width":refinement.width,"height":refinement.height,
                            "format":"RGBA32Float-little-endian; dx, minus-dy in flow pixels; valid; 1",
                            "H_columns":PeripheralRecordJSON.matrix(refinement.homography),"id":refinement.id,
                            "sourcePairID":refinement.sourcePairID,"epoch":refinement.epoch,
                            "consistentFraction":refinement.consistentFraction,"elapsedMS":refinement.elapsedMS,
                            "algorithm":refinement.algorithm,"candidateScores":refinement.candidateScores]
                    }
                }
                var renderModel: [String:Any] = ["available":false]
                if let frame = renderedFrame {
                    renderModel = ["available":true,"mappingBasis":frame.mappingBasis,
                        "analysisPairID":frame.analysisPairID,"analysisObservedAt":frame.analysisObservedAt ?? .nan,
                        "modelPairKey":roles["renderModelPair"] ?? "none","currentPixelPairKey":roles["texturePair"] ?? "none",
                        "matrix_columns":PeripheralRecordJSON.matrix(frame.matrix),"gains":PeripheralRecordJSON.edgeGains(frame.gains),
                        "refinementStrength":frame.refinementStrength,"tolerance":frame.tolerance]
                    if let field = frame.refinement {
                        let name = "render-refinement.rgba32f"
                        try Self.write(field.rgba.withUnsafeBytes {Data($0)},name:name,root:staging,files:&files)
                        renderModel["field"] = ["file":name,"id":field.id,"sourcePairID":field.sourcePairID,
                            "width":field.width,"height":field.height,"H_columns":PeripheralRecordJSON.matrix(field.homography),
                            "format":"RGBA32Float-little-endian; dx, minus-dy in flow pixels; valid; 1"]
                    }
                }
                let metadata: [String: Any] = ["schemaVersion": 1, "implementation": "manual-native-recording-20261025",
                    "id": identifier, "wallTime": wallTime, "tapHostTime": tapTime,
                    "camera": camera, "renderer": state, "renderHistory": trace, "gpuEvents": gpu,
                    "roles": roles, "pairs": pairRows, "analysis": analysisRow,"renderModel":renderModel,"files": files,
                    "unpairedInputs": pendingRows,
                    "app": ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "test",
                            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "test",
                            "os": ProcessInfo.processInfo.operatingSystemVersionString],
                    "pixelContract": "Unscaled, unwarped camera-delivered CVPixelBuffer planes, including row stride. Not Bayer/ProRAW. Analysis RGBA is a separate derived input. Renderer alpha is submitted Metal opacity, not a measurement of the final Liquid Glass compositor."]
                try PeripheralRecordJSON.data(metadata).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                guard try Self.directoryBytes(directory) <= maxBytes else { throw RecordingError.storageFull }
                let saved = directory.appendingPathComponent(identifier, isDirectory: true)
                try FileManager.default.moveItem(at: staging, to: saved)
                finish(); completion(.success(saved))
            } catch {
                try? FileManager.default.removeItem(at: staging)
                finish(); completion(.failure(error))
            }
        }
        return true
    }
    func list(completion: @escaping ([URL]) -> Void) {
        queue.async { [self] in completion(records()) }
    }
    private func records() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    @discardableResult
    func export(completion: @escaping (Result<URL, Error>) -> Void) -> Bool {
        guard begin() else { return false }
        queue.async { [self] in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("GlassCam-records-\(UUID().uuidString).zip")
            do {
                let roots = records()
                guard !roots.isEmpty else { throw RecordingError.noRecords }
                try PeripheralRecordArchive.write(roots: roots, to: target)
                finish(); completion(.success(target))
            } catch {
                try? FileManager.default.removeItem(at: target)
                finish(); completion(.failure(error))
            }
        }
        return true
    }
    static func byteCount(_ buffer: CVPixelBuffer) -> Int {
        if !CVPixelBufferIsPlanar(buffer) { return CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) }
        return (0..<CVPixelBufferGetPlaneCount(buffer)).reduce(0) {
            $0 + CVPixelBufferGetBytesPerRowOfPlane(buffer, $1) * CVPixelBufferGetHeightOfPlane(buffer, $1)
        }
    }
    static func directoryBytes(_ root: URL) throws -> Int {
        let values: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: values) else { return 0 }
        var count = 0
        for case let url as URL in walker {
            let metadata = try url.resourceValues(forKeys: Set(values))
            if metadata.isRegularFile == true { count += metadata.fileSize ?? 0 }
        }
        return count
    }
    private static func write(_ data: Data, name: String, root: URL, files: inout [[String: Any]]) throws {
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
        files.append(["path": name, "bytes": data.count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    }
    static func writeBuffer(_ buffer: CVPixelBuffer, prefix: String, root: URL,
                            files: inout [[String: Any]]) throws -> [String: Any] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw RecordingError.pixelLock }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer), count = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        var planes: [[String: Any]] = []
        for p in 0..<count {
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, p) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, p) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, p) : CVPixelBufferGetBytesPerRow(buffer)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, p) : CVPixelBufferGetBaseAddress(buffer),
                  stride > 0, height > 0, stride * height < 128 * 1024 * 1024 else { throw RecordingError.pixelLock }
            let name = "\(prefix)-plane\(p).bin"
            try write(Data(bytes: base, count: stride * height), name: name, root: root, files: &files)
            planes.append(["index": p, "width": width, "height": height, "bytesPerRow": stride,
                           "bytes": stride * height, "file": name])
        }
        // Preserve typed attachments separately where CoreVideo supplies a plist.
        var attachments: [String: String] = [:]
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            if let values = CVBufferCopyAttachments(buffer, mode) as? [String: Any] {
                for (key, value) in values { attachments[key] = String(describing: value) }
                if PropertyListSerialization.propertyList(values, isValidFor: .binary) {
                    let name = "\(prefix)-attachments-\(mode.rawValue).plist"
                    try write(try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
                              name: name, root: root, files: &files)
                }
            }
        }
        return ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                "pixelFormat": CVPixelBufferGetPixelFormatType(buffer), "planar": planar,
                "planes": planes, "attachmentsDescription": attachments, "byteOrder": "little-endian"]
    }
    enum RecordingError: LocalizedError {
        case storageFull, pixelLock, noRecords, archiveTooLarge
        var errorDescription: String? {
            switch self {
            case .storageFull: return NSLocalizedString("Recording storage is full. Existing records are preserved.", comment: "")
            case .pixelLock: return NSLocalizedString("Could not copy the original camera pixels. Please record again.", comment: "")
            case .noRecords: return NSLocalizedString("No saved records to export.", comment: "")
            case .archiveTooLarge: return NSLocalizedString("The recording archive is too large.", comment: "")
            }
        }
    }
}

/// Streaming ZIP (stored entries): byte-for-byte transport without transcoding
/// pixels or accumulating all native frames in one in-memory archive.
enum PeripheralRecordArchive {
    static func write(roots: [URL], to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var central = Data(), entries = 0
        func number<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            let urls = walker.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let name = Data((root.lastPathComponent + "/" + String(url.path.dropFirst(root.path.count + 1))).utf8)
                let offset = try output.offset()
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                let size = try input.seekToEnd()
                guard size < UInt32.max, offset < UInt32.max, name.count < UInt16.max, entries < 65_534 else {
                    throw PeripheralStateRecorder.RecordingError.archiveTooLarge
                }
                try input.seek(toOffset: 0)
                var crc: uLong = 0
                while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
                    crc = data.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
                }
                var header = Data()
                number(UInt32(0x04034b50), to: &header); number(UInt16(20), to: &header)
                number(UInt16(0x0800), to: &header); number(UInt16(0), to: &header)
                number(UInt16(0), to: &header); number(UInt16(0x21), to: &header)
                number(UInt32(crc), to: &header); number(UInt32(size), to: &header); number(UInt32(size), to: &header)
                number(UInt16(name.count), to: &header); number(UInt16(0), to: &header); header.append(name)
                try output.write(contentsOf: header); try input.seek(toOffset: 0)
                while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
                number(UInt32(0x02014b50), to: &central); number(UInt16(20), to: &central); number(UInt16(20), to: &central)
                number(UInt16(0x0800), to: &central); number(UInt16(0), to: &central)
                number(UInt16(0), to: &central); number(UInt16(0x21), to: &central)
                number(UInt32(crc), to: &central); number(UInt32(size), to: &central); number(UInt32(size), to: &central)
                number(UInt16(name.count), to: &central)
                for _ in 0..<4 { number(UInt16(0), to: &central) }
                number(UInt32(0), to: &central); number(UInt32(offset), to: &central); central.append(name)
                entries += 1
            }
        }
        let centralOffset = try output.offset()
        guard centralOffset + UInt64(central.count) < UInt32.max else { throw PeripheralStateRecorder.RecordingError.archiveTooLarge }
        try output.write(contentsOf: central)
        var end = Data()
        number(UInt32(0x06054b50), to: &end); number(UInt16(0), to: &end); number(UInt16(0), to: &end)
        number(UInt16(entries), to: &end); number(UInt16(entries), to: &end)
        number(UInt32(central.count), to: &end); number(UInt32(centralOffset), to: &end); number(UInt16(0), to: &end)
        try output.write(contentsOf: end); try output.synchronize()
    }
}
