import Foundation

/// A borrowed immutable burst handle. Staging and recovery directories are
/// durable owners; deallocation never deletes captured RAW data.
final class F5BurstSource: @unchecked Sendable {
    let directory: URL
    let manifest: F5BurstManifest
    init(directory: URL, verify: Bool = true) throws {
        self.directory = directory
        manifest = try JSONDecoder().decode(F5BurstManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("burst.json")))
        _ = try manifest.validate(directory: verify ? directory : nil)
    }
    var referenceDNG: URL? { try? manifest.frames.first(where: { $0.burstIndex == 1 })?.dng.url(in: directory) }
}

/// One transaction owns the budget, including across split brackets. Files are
/// synced before the immutable manifest becomes visible. Failed captures remain
/// inspectable and can never silently cause a sixth exposure.
final class F5BurstTransaction: @unchecked Sendable {
    enum State: String, Codable { case collecting, committed, failed, cancelled }
    struct Delivery: Codable {
        let requestID: Int64, sequenceCount: Int, dng: F5Blob
        let mosaic: F5Blob?
    }
    struct Intent: Codable {
        let id: UUID, createdAt: Date
        let snapshot: CaptureSnapshot?
        let purpose: String
        var state: State
        var frames: [F5FrameRecord]
        var error: String?
        var deliveries: [Delivery]? = nil
    }
    static var stagingRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCam/F5Staging", isDirectory: true)
    }
    static var samplesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F5Samples", isDirectory: true)
    }
    let directory: URL
    let id: UUID
    private let lock = NSLock()
    private var intent: Intent
    private var requests: [Int64: [Int]] = [:]
    private var finished = Set<Int64>()
    private var published: F5BurstSource?

    init(snapshot: CaptureSnapshot?, purpose: String, root: URL? = nil) throws {
        id = UUID()
        directory = (root ?? (purpose == "probe" ? Self.samplesRoot : Self.stagingRoot)).appendingPathComponent(id.uuidString, isDirectory: true)
        intent = Intent(id: id, createdAt: Date(), snapshot: snapshot, purpose: purpose, state: .collecting, frames: [], error: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var path = directory; try path.setResourceValues(values)
        try persist()
    }
    func register(requestID: Int64, indices: [Int]) throws {
        lock.lock(); defer { lock.unlock() }
        guard intent.state == .collecting, requests[requestID] == nil, !indices.isEmpty,
              indices.allSatisfy({ (0..<5).contains($0) }), Set(indices).count == indices.count,
              Set(requests.values.flatMap { $0 }).isDisjoint(with: indices),
              requests.values.reduce(indices.count, { $0 + $1.count }) <= 5 else {
            throw F5Failure(.duplicateFrame, "A request would exceed or reuse the five-frame budget.")
        }
        requests[requestID] = indices
    }
    func plannedIndex(requestID: Int64, sequenceCount: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard intent.state == .collecting, let indices = requests[requestID], (1...indices.count).contains(sequenceCount) else {
            throw F5Failure(.frameMissing, "Callback is not attributable to a registered bracket.")
        }
        return indices[sequenceCount - 1]
    }
    /// Preserve bytes before metadata interpretation, including callbacks that
    /// arrive after a cancellation. Content-addressed names never overwrite an
    /// earlier conflicting delivery with the same request/sequence identity.
    func retainDelivery(requestID: Int64, sequenceCount: Int, dng: Data, mosaic: Data? = nil) throws -> Delivery {
        lock.lock(); defer { lock.unlock() }
        let dh=F5Hash.data(dng),stem="delivery-\(requestID)-\(sequenceCount)-\(dh)"
        let db=F5Blob(path:stem+".dng",sha256:dh,bytes:dng.count)
        func retain(_ blob:F5Blob,_ data:Data) throws {
            let url=try blob.url(in:directory)
            if FileManager.default.fileExists(atPath:url.path) {try blob.verify(in:directory)}
            else {try CaptureJournal.writeProtected(data,to:url)}
        }
        try retain(db,dng)
        var mb:F5Blob?
        if let mosaic {
            let hash=F5Hash.data(mosaic),blob=F5Blob(path:stem+"-\(hash).raw",sha256:hash,bytes:mosaic.count)
            try retain(blob,mosaic);mb=blob
        }
        let delivery=Delivery(requestID:requestID,sequenceCount:sequenceCount,dng:db,mosaic:mb)
        var deliveries=intent.deliveries ?? []
        if !deliveries.contains(where:{$0.requestID==requestID && $0.sequenceCount==sequenceCount && $0.dng==db && $0.mosaic==mb}) {
            deliveries.append(delivery);intent.deliveries=deliveries;try persist()
        }
        return delivery
    }
    /// Paired processed callbacks are filtered by the AVFoundation delegate.
    /// Identical duplicate RAW callbacks are harmless; conflicting ones fail.
    @discardableResult
    func append(_ frame: F5FrameRecord, dng: Data, mosaic: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard intent.state == .collecting, let indices = requests[frame.requestID],
              (1...indices.count).contains(frame.sequenceCount), indices[frame.sequenceCount - 1] == frame.burstIndex else {
            throw F5Failure(.frameMissing, "Unregistered or late RAW callback.")
        }
        if let previous = intent.frames.first(where: { $0.callbackKey == frame.callbackKey }) {
            guard previous.dng.sha256 == F5Hash.data(dng), previous.mosaic.sha256 == F5Hash.data(mosaic) else {
                throw F5Failure(.duplicateFrame, "Two different payloads have the same callback identity.")
            }
            return false
        }
        guard intent.frames.count < 5, !intent.frames.contains(where: { $0.burstIndex == frame.burstIndex }),
              frame.dng.bytes == dng.count, frame.mosaic.bytes == mosaic.count,
              frame.dng.sha256 == F5Hash.data(dng), frame.mosaic.sha256 == F5Hash.data(mosaic) else {
            throw F5Failure(.damagedBundle, "RAW bytes do not match their immutable records.")
        }
        try frame.raster.validate()
        for (blob,bytes) in [(frame.dng,dng),(frame.mosaic,mosaic)] {
            let url=try blob.url(in:directory)
            if FileManager.default.fileExists(atPath:url.path) {try blob.verify(in:directory)}
            else {try CaptureJournal.writeProtected(bytes,to:url)}
        }
        intent.frames.append(frame); try persist()
        return true
    }
    func finishRequest(_ requestID: Int64, error: Error?) throws {
        lock.lock(); defer { lock.unlock() }
        guard intent.state == .collecting else { return }
        guard let indices = requests[requestID] else { throw F5Failure(.frameMissing, "Unknown terminal request callback.") }
        if let error { intent.state = .failed; intent.error = error.localizedDescription; try persist(); throw error }
        guard Set(intent.frames.filter { $0.requestID == requestID }.map(\.burstIndex)) == Set(indices) else {
            intent.state = .failed; intent.error = F5Code.frameMissing.rawValue; try persist()
            throw F5Failure(.frameMissing, "A bracket finished without all of its planned RAW frames.")
        }
        finished.insert(requestID)
    }
    func commit(hardware: String, osBuild: String, synthetic: Bool, flags: Set<F5Code>,
                profile: F5DeviceProfile?, framing: CaptureFraming) throws -> F5BurstSource {
        lock.lock(); defer { lock.unlock() }
        if let published { return published }
        guard intent.state == .collecting, finished == Set(requests.keys), intent.frames.count == 5,
              Set(requests.values.flatMap { $0 }) == Set(0..<5) else {
            throw F5Failure(.frameMissing, "Five complete RAW deliveries are required before commit.")
        }
        let frames = intent.frames.sorted { $0.burstIndex < $1.burstIndex }
        var manifest = F5BurstManifest(id: id, createdAt: intent.createdAt, hardwareModel: hardware, osBuild: osBuild,
            synthetic: synthetic, frames: frames, requestOrder: frames.map(\.burstIndex),
            timestampOrder: frames.sorted { $0.timestamp == $1.timestamp ? $0.burstIndex < $1.burstIndex : $0.timestamp < $1.timestamp }.map(\.burstIndex),
            flags: flags.sorted { $0.rawValue < $1.rawValue }, profile: profile, framing: framing)
        manifest.flags = try manifest.validate(directory: directory).sorted { $0.rawValue < $1.rawValue }
        if let profile {
            try CaptureJournal.writeProtected(F5Hash.json(profile), to: directory.appendingPathComponent("profile.json"))
            if let table = profile.likelihood.table {
                let package = F5ProfileStore.root.appendingPathComponent(profile.hash)
                try table.verify(in: package)
                let destination = try table.url(in: directory)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
                try CaptureJournal.writeProtected(Data(contentsOf: table.url(in: package), options: .mappedIfSafe), to: destination)
            }
        }
        try CaptureJournal.writeProtected(F5Hash.json(manifest), to: directory.appendingPathComponent("burst.json"))
        intent.state = .committed; try persist()
        let result = try F5BurstSource(directory: directory)
        published = result
        return result
    }
    @discardableResult
    func cancel(_ code: F5Code = .cancelled) -> F5BurstSource? {
        lock.lock(); defer { lock.unlock() }
        if let published { return published }
        if intent.state == .collecting {
            intent.state = code == .cancelled ? .cancelled : .failed; intent.error = code.rawValue
            try? persist() // Keep the previously synced intent if the device just locked.
            if requests.isEmpty,intent.frames.isEmpty,(intent.deliveries ?? []).isEmpty {
                // Configuration/qualification failed before any request could
                // expose the sensor. There are no originals to recover.
                try? FileManager.default.removeItem(at:directory)
            }
        }
        return nil
    }
    private func persist() throws { try CaptureJournal.writeProtected(F5Hash.json(intent), to: directory.appendingPathComponent("intent.json")) }

    static func pendingProduct(root: URL? = nil) throws -> (URL, Intent)? {
        let directory = root ?? stagingRoot
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        var candidates: [(URL, Intent)] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let intentURL = folder.appendingPathComponent("intent.json")
            guard FileManager.default.fileExists(atPath: intentURL.path) else { continue }
            let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: intentURL))
            if intent.purpose == "product", intent.snapshot != nil { candidates.append((folder, intent)) }
        }
        guard candidates.count <= 1 else { throw F5Failure(.damagedBundle, "Multiple unfinished F5 product transactions require review.") }
        return candidates.first
    }
}

enum F5ArchiveStore {
    static var root: URL {
        FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("F5Archives",isDirectory:true)
    }
    @discardableResult static func retain(_ source:F5BurstSource,captureID:UUID,root:URL?=nil) throws -> URL {
        let parent=root ?? Self.root,destination=parent.appendingPathComponent(captureID.uuidString,isDirectory:true)
        if FileManager.default.fileExists(atPath:destination.path) {
            let previous=try F5BurstSource(directory:destination)
            guard previous.manifest.id==source.manifest.id else {throw F5Failure(.damagedBundle,"RAW archive identity changed.")}
            return destination
        }
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:ImageFileProtection.attributes)
        let stage=parent.appendingPathComponent("Writing-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true,attributes:ImageFileProtection.attributes)
        do {
            var files=source.manifest.frames.flatMap{[$0.dng.path,$0.mosaic.path]}+["burst.json"]
            if let table=source.manifest.profile?.likelihood.table {files.append(table.path)}
            for optional in ["profile.json","quality.json","color-transform.json"] where FileManager.default.fileExists(atPath:source.directory.appendingPathComponent(optional).path) {files.append(optional)}
            for name in Set(files) {
                let input=source.directory.appendingPathComponent(name).resolvingSymlinksInPath()
                guard input.path.hasPrefix(source.directory.resolvingSymlinksInPath().path+"/"),!name.split(separator:"/").contains("..") else {throw F5Failure(.damagedBundle,"RAW archive path escapes the retained burst.")}
                let output=stage.appendingPathComponent(name)
                try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:ImageFileProtection.attributes)
                try CaptureJournal.writeProtected(Data(contentsOf:input,options:.mappedIfSafe),to:output)
            }
            _ = try F5BurstSource(directory:stage)
            try FileManager.default.moveItem(at:stage,to:destination)
            return destination
        } catch {try? FileManager.default.removeItem(at:stage);throw error}
    }
}

struct F5GateEvidence: Codable {
    let gate: String, result: String, profileID: String, hardwareModel: String, osBuild: String
    let physicalCameraID: String, buildRevision: String, calibrationSHA256: String, policySHA256: String
    let synthetic: Bool
    let targetDeviceName: String
}

enum F5ProfileStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassCam/F5Profiles", isDirectory: true)
    }
    static func validatePackage(at directory: URL) throws -> F5DeviceProfile {
        let profile = try JSONDecoder().decode(F5DeviceProfile.self,
            from: Data(contentsOf: directory.appendingPathComponent("profile.json")))
        try profile.validate(synthetic: false)
        let policyHash = try F5Hash.data(F5Hash.json(profile.policy))
        for gate in ["P0", "G1", "G2", "G3", "G4"] {
            let bytes = try Data(contentsOf: directory.appendingPathComponent("\(gate).json"))
            let evidence = try JSONDecoder().decode(F5GateEvidence.self, from: bytes)
            guard F5Hash.data(bytes) == profile.gateEvidence[gate], evidence.gate == gate, evidence.result == "PASS",
                  !evidence.synthetic, evidence.profileID == profile.id, evidence.hardwareModel == profile.hardwareModel,
                  evidence.targetDeviceName == F5Version.targetDeviceName,
                  evidence.osBuild == profile.osBuild, evidence.physicalCameraID == profile.physicalCameraID,
                  evidence.buildRevision == F5Version.build, evidence.calibrationSHA256 == profile.calibrationManifestSHA256,
                  evidence.policySHA256 == policyHash else { throw F5Failure(.unqualified, "\(gate) does not certify this device, policy and build.") }
        }
        guard try F5Hash.file(directory.appendingPathComponent("calibration.json")) == profile.calibrationManifestSHA256,
              try F5Hash.file(directory.appendingPathComponent("color-validation.json")) == profile.colorValidationSHA256 else {
            throw F5Failure(.profileMismatch, "Calibration provenance is missing or damaged.")
        }
        if let table = profile.likelihood.table { try table.verify(in: directory) }
        return profile
    }
    @discardableResult
    static func importPackage(at directory: URL) throws -> F5DeviceProfile {
        let profile = try validatePackage(at: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
        let destination = root.appendingPathComponent(profile.hash, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { return try validatePackage(at: destination) }
        let stage = root.appendingPathComponent("Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
        do {
            var files = ["profile.json", "P0.json", "G1.json", "G2.json", "G3.json", "G4.json", "calibration.json", "color-validation.json"]
            if let table = profile.likelihood.table { files.append(table.path) }
            for file in files {
                let input = directory.appendingPathComponent(file).resolvingSymlinksInPath()
                guard input.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), !file.contains("..") else {
                    throw F5Failure(.damagedBundle, "Profile file escapes package.")
                }
                let output = stage.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: ImageFileProtection.attributes)
                try CaptureJournal.writeProtected(Data(contentsOf: input), to: output)
            }
            _ = try validatePackage(at: stage)
            try FileManager.default.moveItem(at: stage, to: destination)
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
        return profile
    }
    static func candidates(hardware: String, os: String, physicalCameraID: String) -> [F5DeviceProfile] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { try? validatePackage(at: $0) }.filter {
            $0.hardwareModel == hardware && $0.osBuild == os && $0.physicalCameraID == physicalCameraID && $0.physicalCameraType == "main"
        }
    }
}
