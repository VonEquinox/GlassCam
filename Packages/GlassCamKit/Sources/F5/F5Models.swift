import ImagingCore
import Capture
import Foundation
import CryptoKit

// All F5 geometry uses unrotated, ActiveArea-relative input-pixel units.
// Device certification is data, never a default inferred from an iPhone name.
public enum F5Hash {
    public static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum F5Phase: Int, Codable, CaseIterable, Sendable {
    case r = 0, g1 = 1, g2 = 2, b = 3
    public var color: Int { self == .r ? 0 : (self == .b ? 2 : 1) }
    public var name: String { ["R", "G1", "G2", "B"][rawValue] }
}

public struct F5Area: Codable, Equatable, Sendable {
    public let top: Int, left: Int, bottom: Int, right: Int
    public var width: Int { right - left }
    public var height: Int { bottom - top }
    public func validate(width: Int, height: Int) throws {
        guard top >= 0, left >= 0, bottom > top, right > left, bottom <= height, right <= width else {
            throw F5Failure(.damagedBundle, "ActiveArea lies outside the stored sensor raster.")
        }
    }
}

public struct F5RasterDescriptor: Codable, Equatable, Sendable {
    public init(width: Int,
         height: Int,
         rowBytes: Int,
         byteOrder: ByteOrder,
         activeArea: F5Area,
         cfa: [F5Phase],
         orientation: Int,
         bitsPerSample: Int) {
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.byteOrder = byteOrder
        self.activeArea = activeArea
        self.cfa = cfa
        self.orientation = orientation
        self.bitsPerSample = bitsPerSample
    }

    public enum ByteOrder: String, Codable, Sendable { case little, big }
    public let width: Int, height: Int, rowBytes: Int
    public let byteOrder: ByteOrder
    public let activeArea: F5Area
    /// Repeat pattern starts at ActiveArea, not at the stored file's (0,0).
    public let cfa: [F5Phase]
    public let orientation: Int
    public let bitsPerSample: Int
    package var byteCount: Int { rowBytes * height } // Call validate before using.
    public func validate() throws {
        guard width >= 2, height >= 2, width <= 32768, height <= 32768,
              rowBytes >= width * 2, rowBytes <= width * 2 + 65536, rowBytes % 2 == 0,
              height <= Int.max / rowBytes, (8...16).contains(bitsPerSample),
              (1...8).contains(orientation), cfa.count == 4, Set(cfa) == Set(F5Phase.allCases) else {
            throw F5Failure(.unsupportedRAW, "Expected a bounded single-plane, 16-bit stored Bayer raster.")
        }
        try activeArea.validate(width: width, height: height)
        guard cfa[0].color != cfa[1].color, cfa[0].color != cfa[2].color,
              cfa[1].color != cfa[3].color, cfa[2].color != cfa[3].color else {
            throw F5Failure(.unsupportedRAW, "Invalid Bayer phase arrangement.")
        }
    }
    public func phase(x: Int, y: Int) -> F5Phase { cfa[(y & 1) * 2 + (x & 1)] }
}

public struct F5Blob: Codable, Equatable, Sendable {
    public let path: String, sha256: String
    public let bytes: Int
    public func url(in directory: URL) throws -> URL {
        // Bundles are imported data. Never follow paths or symlinks outside them.
        guard !path.isEmpty, !path.hasPrefix("/"), path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }),
              bytes > 0, F5Hash.isSHA256(sha256) else { throw F5Failure(.damagedBundle, "Invalid blob descriptor.") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let result = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(root.path + "/") else { throw F5Failure(.damagedBundle, "Blob escapes its bundle.") }
        return result
    }
    func verify(in directory: URL) throws {
        let url = try url(in: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == bytes, try F5Hash.file(url) == sha256 else {
            throw F5Failure(.damagedBundle, "Blob length or SHA-256 does not match: \(path)")
        }
    }
}

public struct F5FrameRecord: Codable, Sendable {
    public init(id: String,
         requestID: Int64,
         burstIndex: Int,
         sequenceCount: Int,
         role: Role,
         physicalCameraID: String,
         formatSignature: String,
         rawFourCC: UInt32,
         dng: F5Blob,
         mosaic: F5Blob,
         raster: F5RasterDescriptor,
         requestedExposure: Double,
         actualExposure: Double,
         actualISO: Double,
         aperture: Double,
         focus: Double,
         oisPolicy: String,
         timestamp: Double,
         callbackUptime: Double,
         clockID: String,
         rollingShutterLineTime: Double? = nil,
         metadata: F5DNGMetadata,
         requestedISO: Double? = nil) {
        self.id = id
        self.requestID = requestID
        self.burstIndex = burstIndex
        self.sequenceCount = sequenceCount
        self.role = role
        self.physicalCameraID = physicalCameraID
        self.formatSignature = formatSignature
        self.rawFourCC = rawFourCC
        self.dng = dng
        self.mosaic = mosaic
        self.raster = raster
        self.requestedExposure = requestedExposure
        self.actualExposure = actualExposure
        self.actualISO = actualISO
        self.aperture = aperture
        self.focus = focus
        self.oisPolicy = oisPolicy
        self.timestamp = timestamp
        self.callbackUptime = callbackUptime
        self.clockID = clockID
        self.rollingShutterLineTime = rollingShutterLineTime
        self.metadata = metadata
        self.requestedISO = requestedISO
    }

    public enum Role: String, Codable, Sendable { case main = "L", short = "S" }
    public let id: String, requestID: Int64
    public let burstIndex: Int, sequenceCount: Int
    public let role: Role
    public let physicalCameraID: String
    public let formatSignature: String, rawFourCC: UInt32
    public let dng: F5Blob, mosaic: F5Blob
    public let raster: F5RasterDescriptor
    public let requestedExposure: Double, actualExposure: Double, actualISO: Double
    public let aperture: Double, focus: Double
    public let oisPolicy: String
    public let timestamp: Double, callbackUptime: Double, clockID: String
    public let rollingShutterLineTime: Double?
    public let metadata: F5DNGMetadata
    // Older probe bundles did not record the requested ISO. Never reconstruct it
    // from EXIF: delivered ISO can differ from the manual bracket request.
    public var requestedISO: Double? = nil
    var callbackKey: String { "\(requestID):\(sequenceCount):raw" }
}

public struct F5BurstManifest: Codable, Sendable {
    public var revision = "f5-burst-v1"
    public let id: UUID, createdAt: Date
    let hardwareModel: String, osBuild: String
    public let synthetic: Bool
    public let frames: [F5FrameRecord]
    let requestOrder: [Int], timestampOrder: [Int]
    public var flags: [F5Code]
    public let profile: F5DeviceProfile?
    public let framing: CaptureFraming

    var captureSpanMS: Double {
        guard let first = frames.map(\.timestamp).min(), let last = frames.map(\.timestamp).max() else { return 0 }
        return (last - first) * 1000
    }
    /// Returns acquisition quality failures separately from structural corruption.
    public func validate(directory: URL?, requireFive: Bool = true) throws -> Set<F5Code> {
        guard revision == "f5-burst-v1", !frames.isEmpty, frames.count <= 5,
              (!requireFive || frames.count == 5), framing.isValid else { throw F5Failure(.frameMissing, "A burst requires exactly five attributable RAW frames.") }
        guard Set(frames.map(\.id)).count == frames.count,
              Set(frames.map(\.callbackKey)).count == frames.count,
              Set(frames.map(\.burstIndex)).count == frames.count else { throw F5Failure(.duplicateFrame, "Repeated frame identity.") }
        let roles: [F5FrameRecord.Role] = [.main, .main, .short, .main, .main]
        guard frames.allSatisfy({ (0..<5).contains($0.burstIndex) && $0.role == roles[$0.burstIndex] }),
              requestOrder == frames.map(\.burstIndex).sorted(),
              timestampOrder == frames.sorted(by: { $0.timestamp == $1.timestamp ? $0.burstIndex < $1.burstIndex : $0.timestamp < $1.timestamp }).map(\.burstIndex) else {
            throw F5Failure(.damagedBundle, "Burst indices, roles, or independent order records are inconsistent.")
        }
        var failures = Set(flags)
        if frames.count != 5 { failures.insert(.frameMissing) }
        let first = frames[0]
        if Set(frames.map(\.physicalCameraID)).count != 1 { failures.insert(.physicalCameraChanged) }
        guard Set(frames.map(\.clockID)).count == 1, !first.clockID.isEmpty else { throw F5Failure(.damagedBundle, "Incomparable capture timestamps.") }
        for frame in frames {
            try frame.raster.validate()
            guard frame.sequenceCount > 0, frame.actualExposure.isFinite, frame.actualExposure > 0,
                  frame.requestedExposure.isFinite, frame.requestedExposure > 0, frame.actualISO.isFinite, frame.actualISO > 0,
                  frame.aperture.isFinite, frame.aperture > 0, frame.focus.isFinite, (0...1).contains(frame.focus),
                  frame.timestamp.isFinite, frame.callbackUptime.isFinite, ["on", "off", "unavailable"].contains(frame.oisPolicy),
                  frame.mosaic.bytes == frame.raster.byteCount else { throw F5Failure(.damagedBundle, "Invalid delivered metadata.") }
            if let requestedISO = frame.requestedISO {
                guard requestedISO.isFinite, requestedISO > 0 else { throw F5Failure(.damagedBundle, "Invalid requested ISO.") }
                if abs(frame.actualISO / requestedISO - 1) > 0.01 { failures.insert(.exposureAdjusted) }
            }
            if abs(frame.actualExposure / frame.requestedExposure - 1) > 0.01 { failures.insert(.exposureAdjusted) }
            if frame.raster != first.raster || frame.rawFourCC != first.rawFourCC || frame.formatSignature != first.formatSignature {
                failures.insert(.profileMismatch)
            }
            if frame.metadata.analogBalance != first.metadata.analogBalance || frame.metadata.colorMatrix1 != first.metadata.colorMatrix1 ||
                frame.metadata.colorMatrix2 != first.metadata.colorMatrix2 || frame.metadata.cameraCalibration1 != first.metadata.cameraCalibration1 ||
                frame.metadata.cameraCalibration2 != first.metadata.cameraCalibration2 {failures.insert(.profileMismatch)}
            if abs(frame.actualISO / first.actualISO - 1) > 0.001 {
                failures.insert(.isoChanged); failures.insert(.nonuniformMains)
            }
            if abs(frame.aperture - first.aperture) > 0.001 { failures.insert(.apertureChanged) }
            if abs(frame.focus - first.focus) > 0.001 { failures.insert(.focusChanged) }
            if frame.oisPolicy != first.oisPolicy { failures.insert(.profileMismatch) }
            if let directory {
                let original=try Data(contentsOf:frame.dng.url(in:directory),options:.mappedIfSafe)
                let parsed=try F5DNGMetadata.read(original)
                guard original.count==frame.dng.bytes,parsed.sourceSHA256==frame.dng.sha256,parsed==frame.metadata,
                      parsed.width==frame.raster.width,parsed.height==frame.raster.height,parsed.bits==frame.raster.bitsPerSample,
                      parsed.orientation==frame.raster.orientation,parsed.activeArea==frame.raster.activeArea,parsed.cfa==frame.raster.cfa,
                      parsed.exposureTime==frame.actualExposure,parsed.iso==frame.actualISO,parsed.aperture==frame.aperture else {
                    throw F5Failure(.damagedBundle,"Stored metadata does not match the original delivered DNG.")
                }
                if !synthetic {try F5BayerLayout.validate(fourCC:frame.rawFourCC,metadata:parsed)}
                try frame.mosaic.verify(in: directory)
            }
        }
        let mains = frames.filter { $0.role == .main }.map(\.actualExposure).sorted()
        if mains.count == 4 {
            let median = (mains[1] + mains[2]) / 2
            if mains.contains(where: { abs($0 / median - 1) > 0.01 }) { failures.insert(.nonuniformMains) }
            if let short = frames.first(where: { $0.role == .short }), short.actualExposure >= mains[0] { failures.insert(.nonuniformMains) }
            if let short = frames.first(where: { $0.role == .short }), short.actualExposure > median / 8 * 1.01 {
                failures.insert(.shortExposureLimited); failures.insert(.highlightNotGuaranteed)
            }
        }
        if captureSpanMS > 750 { failures.insert(.longCaptureWindow) }
        return failures
    }
}

public struct F5ExposurePlan: Equatable, Sendable {
    public let main: Double, short: Double, iso: Double
    public let flags: Set<F5Code>
    public var durations: [Double] { [main, main, short, main, main] }
    public static func make(ae: Double, iso: Double, minimum: Double, maximum: Double,
                     quantum: Double, certifiedMotionCap: Double? = nil,
                     calibratedVelocity95: Double? = nil, textureExposureBound: Double? = nil,
                     highlightExposureBound: Double? = nil, allowClampedProbe: Bool = false) throws -> F5ExposurePlan {
        guard [ae, iso, minimum, maximum, quantum].allSatisfy({ $0.isFinite && $0 > 0 }), maximum >= minimum else {
            throw F5Failure(.unsupportedRAW, "No valid manual exposure range.")
        }
        var flags = Set<F5Code>()
        let cap: Double
        if let v = calibratedVelocity95, v.isFinite, v >= 0 { cap = 0.35 / max(v, 1e-9) }
        else if let calibrated = certifiedMotionCap, calibrated.isFinite, calibrated > 0 { cap = calibrated }
        else { cap = 1 / 120; flags.insert(.motionUncertain) }
        let texture: Double
        if let bound = textureExposureBound, bound.isFinite, bound > 0 { texture = bound }
        else { texture = ae / 2; flags.insert(.meteringUncertain) }
        func quantize(_ t: Double) -> Double { max(minimum, min(maximum, floor(t / quantum) * quantum)) }
        let main = quantize(min(ae, cap, texture))
        if main > cap { flags.insert(.motionUncertain) }
        var short = quantize(main / 8)
        if let bound = highlightExposureBound, bound.isFinite, bound > 0 {
            short = [8.0, 16, 32].map { quantize(main / $0) }.first(where: { $0 <= bound }) ?? quantize(main / 32)
            if short > bound { flags.insert(.highlightNotGuaranteed) }
        } else { flags.insert(.highlightNotGuaranteed) }
        guard short < main else { throw F5Failure(.unsupportedRAW, "The device cannot deliver a shorter exposure at the same ISO.") }
        if short > main / 8 * (1 + 1e-12) {
            guard allowClampedProbe else { throw F5Failure(.shortExposureLimited, "The exposure range cannot provide an eight-times-shorter frame at the same ISO.") }
            flags.insert(.shortExposureLimited); flags.insert(.highlightNotGuaranteed)
        }
        return .init(main: main, short: short, iso: iso, flags: flags)
    }
    public static func groups(maxBracketCount: Int) throws -> [[Int]] {
        switch maxBracketCount {
        case 5...: return [[0, 1, 2, 3, 4]]
        case 3...4: return [[0, 1, 2], [3, 4]]
        case 2: return [[0, 1], [2, 3], [4]]
        case 1: return [[0], [1], [2], [3], [4]]
        default: throw F5Failure(.unsupportedRAW, "Manual Bayer brackets are unavailable.")
        }
    }
}

struct F5NoisePhase: Codable, Sendable {
    let kappa: Double, readSigma: Double, lowerThreshold: Double, upperThreshold: Double
    let lowerCensorCode: Int, upperCensorCode: Int
    let gain: Double
    func validate() throws {
        guard kappa.isFinite, kappa > 0, readSigma.isFinite, readSigma > 0,
              lowerThreshold.isFinite, upperThreshold.isFinite, upperThreshold > lowerThreshold,
              gain.isFinite, gain > 0, lowerCensorCode >= 0, upperCensorCode <= 65535,
              upperCensorCode > lowerCensorCode else { throw F5Failure(.profileMismatch, "Invalid phase noise/censor calibration.") }
    }
}

public struct F5Policy: Codable, Sendable {
    var version = "f5-policy-v1"
    var lambdaY = 0.0001, lambdaC = 0.0004, lambdaMotion = 0.00001
    var outlierProbability = 0.001
    var blockSize = 256, coarseStep = 8, meshSpacing = 32, qualitySize = 32
    var maxCycles = 50, maxGeometryRounds = 3, pcgSteps = 30
    var relativeObjectiveTolerance = 1e-5, standardizedGradientTolerance = 0.01
    var maximumWorkingBytes = 1_288_490_188, maximumProcessingSeconds = 5.0
    var minimumReferenceSharpness = 0.0, maximumResidualSigma = 3.0
    var maximumWarpJacobianDeviation = 0.0, minimumModeInformation = 1.0
    var maximumModeCondition = 1000.0, ambiguityNLLGap = 4.0
    var maximumCycleError = 0.5
    var lineBlurEnabled = false, rowColumnNoiseEnabled = false, learnedInitializerEnabled = false
    public func validate() throws {
        guard version == "f5-policy-v1", [lambdaY, lambdaC, lambdaMotion, outlierProbability,
              relativeObjectiveTolerance, standardizedGradientTolerance, maximumProcessingSeconds,
              minimumReferenceSharpness, maximumResidualSigma, maximumWarpJacobianDeviation,
              minimumModeInformation, maximumModeCondition, ambiguityNLLGap, maximumCycleError].allSatisfy(\.isFinite),
              lambdaY > 0, lambdaC >= lambdaY, lambdaMotion > 0, (0.0001...0.02).contains(outlierProbability),
              blockSize >= 8, blockSize <= 256, coarseStep == 8, meshSpacing == 32, qualitySize == 32,
              (1...50).contains(maxCycles), (1...3).contains(maxGeometryRounds), (1...100).contains(pcgSteps),
              relativeObjectiveTolerance > 0, standardizedGradientTolerance > 0, maximumWorkingBytes > 0,
              maximumWorkingBytes <= 1_288_490_188, maximumProcessingSeconds > 0,
              maximumResidualSigma > 0, maximumWarpJacobianDeviation >= 0, minimumModeInformation > 0,
              maximumModeCondition > 1, ambiguityNLLGap > 0, maximumCycleError > 0,
              !lineBlurEnabled, !rowColumnNoiseEnabled, !learnedInitializerEnabled else {
            throw F5Failure(.profileMismatch, "Unsupported or invalid reconstruction policy.")
        }
    }
}

/// A measured relation to the unprocessed DNG SDK Stage1 integers. The divisor
/// maps native code units into DNG code units; it is not a right-shift of pixels.
/// W0 and residual black stay in DNG linearized units. Censor codes and the
/// outlier distribution stay in native integer units, preserving every bit.
struct F5BufferCodeMapping: Codable, Equatable, Sendable {
    let divisor: Int
    let dngStage1Rounding: String
    let evidenceSHA256: String
    func validate() throws {
        guard (1...256).contains(divisor), dngStage1Rounding == "floor", F5Hash.isSHA256(evidenceSHA256) else {
            throw F5Failure(.profileMismatch, "The native-buffer/DNG code mapping has no valid audit record.")
        }
    }
}

public struct F5DeviceProfile: Codable, Sendable {
    package enum Qualification: String, Codable, Sendable { case unqualified = "UNQUALIFIED", qualified = "QUALIFIED", synthetic = "SYNTHETIC_ONLY" }
    package let version: String, id: String, hardwareModel: String, osBuild: String, physicalCameraID: String
    public let physicalCameraType: String, formatSignature: String, rawFourCC: UInt32
    public let width: Int, height: Int, cfa: [F5Phase]
    public let isoRange: [Double], focusRange: [Double], aperture: Double, oisPolicy: String
    let decoderRevision: String, buildRevision: String
    package let qualification: Qualification
    let gateEvidence: [String: String]
    let calibrationManifestSHA256: String, colorValidationSHA256: String
    let whiteScale: Double, noise: [F5NoisePhase], blackResidualByPhase: [Double]
    public let handheldMaxExposure: Double?
    let likelihood: F5LikelihoodDescriptor
    public let policy: F5Policy
    let rawCodeRange: [Int]?
    let targetDeviceName: String?
    var bufferCodeMapping: F5BufferCodeMapping? = nil
    public var hash: String { (try? F5Hash.data(F5Hash.json(self))) ?? "" }

    public func validate(synthetic: Bool, requireProduct: Bool = true) throws {
        guard version == "1.0", decoderRevision == F5Version.decoder, !id.isEmpty,
              physicalCameraType == "main", whiteScale.isFinite, whiteScale > 0,
              noise.count == 4, blackResidualByPhase.count == 4, blackResidualByPhase.allSatisfy(\.isFinite),
              width > 0, height > 0, cfa.count == 4, Set(cfa) == Set(F5Phase.allCases),
              isoRange.count == 2, focusRange.count == 2, isoRange.allSatisfy(\.isFinite), focusRange.allSatisfy(\.isFinite),
              isoRange[0] > 0, isoRange[1] >= isoRange[0], focusRange[0] >= 0, focusRange[1] <= 1,
              focusRange[1] >= focusRange[0], aperture.isFinite, aperture > 0,
              ["on", "off", "unavailable"].contains(oisPolicy) else { throw F5Failure(.profileMismatch, "The physical main-camera profile is incomplete.") }
        try noise.forEach { try $0.validate() }; try policy.validate(); try likelihood.validate()
        if let mapping = bufferCodeMapping { try mapping.validate() }
        if !synthetic, bufferCodeMapping == nil {
            throw F5Failure(.profileMismatch, "A measured native-buffer/DNG code mapping is required for real RAW observations.")
        }
        if let range = rawCodeRange {
            guard range.count == 2, range[0] >= 0, range[1] <= 65535, range[0] < range[1],
                  noise.allSatisfy({ $0.lowerCensorCode >= range[0] && $0.upperCensorCode <= range[1] }) else {
                throw F5Failure(.profileMismatch, "The delivered ADC code range and censor thresholds disagree.")
            }
        }
        if synthetic {
            guard qualification == .synthetic, hardwareModel == "SYNTHETIC_NOT_IPHONE" else { throw F5Failure(.profileMismatch, "Synthetic observations require a synthetic-only profile.") }
        } else if requireProduct {
            guard qualification == .qualified, buildRevision == F5Version.build, rawCodeRange != nil,
                  targetDeviceName == F5Version.targetDeviceName,
                  F5Hash.isSHA256(calibrationManifestSHA256), F5Hash.isSHA256(colorValidationSHA256),
                  ["P0", "G1", "G2", "G3", "G4"].allSatisfy({ F5Hash.isSHA256(gateEvidence[$0] ?? "") }) else {
                throw F5Failure(.unqualified, "This main camera has not completed F5 calibration and device acceptance.")
            }
        }
    }
    public func matches(_ frame: F5FrameRecord, hardware: String, os: String) -> Bool {
        hardwareModel == hardware && osBuild == os && physicalCameraID == frame.physicalCameraID &&
        formatSignature == frame.formatSignature && rawFourCC == frame.rawFourCC &&
        width == frame.raster.width && height == frame.raster.height && cfa == frame.raster.cfa &&
        isoRange.count == 2 && (isoRange[0]...isoRange[1]).contains(frame.actualISO) &&
        focusRange.count == 2 && (focusRange[0]...focusRange[1]).contains(frame.focus) &&
        abs(aperture - frame.aperture) <= 0.001 && oisPolicy == frame.oisPolicy
    }
}

enum F5Version {
    static let build = "f5-effective-v2.0.1"
    static let decoder = "f5-effective-v2"
    // Explicit F5 scene-HDR extension. DNG's unit-range opcode clipping would
    // discard recovered highlights; G1 must qualify this linear extension.
    static let opcodeRangePolicy = "f5-scene-linear-unclipped-v1"
    static let colorBridge = "f5-dng-linear-d50-v1"
    static let targetDeviceName = "iPhone 18 Pro Max"
}

/// A LUT is admitted only with measured error bounds against the exact PG model.
/// The descriptor is hashed together with its binary, immutable table payload.
struct F5LikelihoodDescriptor: Codable, Sendable {
    let revision: String
    let table: F5Blob?
    let nllMaximumError: Double, standardizedScoreMaximumError: Double
    let gaussianMinimumElectrons: Double?
    let exactMaximumElectrons: Double
    func validate() throws {
        guard revision == "f5-pg-v1", nllMaximumError.isFinite, nllMaximumError >= 0, nllMaximumError < 1e-4,
              standardizedScoreMaximumError.isFinite, standardizedScoreMaximumError >= 0, standardizedScoreMaximumError < 1e-3,
              exactMaximumElectrons.isFinite, exactMaximumElectrons > 0,
              gaussianMinimumElectrons.map({ $0.isFinite && $0 > 0 && $0 <= exactMaximumElectrons }) ?? true else {
            throw F5Failure(.profileMismatch, "The likelihood approximation has no passing error certificate.")
        }
    }
}

struct F5QualityReport: Codable, Sendable {
    enum Support: String, Codable, Sendable { case fullSR = "FULL_SR", nativeFusion = "NATIVE_FUSION", referenceOnly = "REFERENCE_ONLY", highlightMissing = "HIGHLIGHT_MISSING", invalid = "INVALID" }
    struct Tile: Codable, Sendable {
        let x: Int, y: Int, width: Int, height: Int
        var support: Support
        var flags: [F5Code]
        var validFractions: [Double], upperCensoredFractions: [Double], lowerCensoredFractions: [Double]
        var residualRMS: Double, minimumInformation: Double, conditionNumber: Double
        var shortOnly: Bool
        var diagnosticSampleCount: Int = 0
        var motionInformationRank: Int = 0
        var shortInformation: Double = 0
        var highNativeDifference: Double? = nil
        var excludedFrames: [Int] = []
        var registrationNLLGaps: [Double] = []
    }
    struct Epoch: Codable, Sendable {
        let id: Int, validEventCount: Int, scale: Int
        var objectives: [Double], standardizedGradient: Double
        var stopReason: String
        var standardizedMotionGradient: Double = 0
        var completedCycles: Int = 0
        var geometryRound: Int = 0
    }
    var schemaVersion = "1.0", outputSemantics = "camera_linear_no_wb"
    let referenceFrameID: String, profileSHA256: String, captureSpanMS: Double, actualFrameCount: Int
    var solveStatus: String, flags: [F5Code], objectiveEpochs: [Epoch], tiles: [Tile]
    var processingSeconds: Double = 0, allocatedBytes: Int = 0
    var qualityClassCounts: [String: Int] { Dictionary(tiles.map { ($0.support.rawValue, 1) }, uniquingKeysWith: +) }
}
