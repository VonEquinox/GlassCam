import ImagingCore
import Capture
import Foundation
import ImageIO

struct F5PhotographicMetadata: Codable, Equatable, Sendable {
    let tiff: [String: String], exifText: [String: String], exifNumbers: [String: [Double]]
    var photoMetadata: PhotoMetadata {
        var exif: [String: Any] = exifText
        let integerKeys = [kCGImagePropertyExifExposureProgram, kCGImagePropertyExifMeteringMode,
            kCGImagePropertyExifLightSource, kCGImagePropertyExifFlash, kCGImagePropertyExifExposureMode,
            kCGImagePropertyExifWhiteBalance, kCGImagePropertyExifFocalLenIn35mmFilm].map { $0 as String }
        for (key, values) in exifNumbers {
            if key == kCGImagePropertyExifISOSpeedRatings as String {
                exif[key] = values.compactMap { UInt32(exactly: $0).map { NSNumber(value: $0) } }
            } else if integerKeys.contains(key), let first = values.first, let integer = UInt32(exactly: first) {
                exif[key] = NSNumber(value: integer)
            } else if key == kCGImagePropertyExifLensSpecification as String {
                exif[key] = values
            } else { exif[key] = values.first }
        }
        return PhotoMetadata(properties: [kCGImagePropertyTIFFDictionary as String: tiff,
                                           kCGImagePropertyExifDictionary as String: exif])
    }
}

public enum F5BayerLayout {
    public static func validate(fourCC: UInt32, metadata:F5DNGMetadata) throws {
        let colors:[Int]
        // CVPixelBuffer Bayer constants describe the full buffer origin; DNG
        // CFAPattern describes ActiveArea's origin (DNG 1.7.1, CFARepeatPatternDim).
        switch fourCC {
        case 0x72676734:colors=[0,1,1,2] // rgg4
        case 0x67726234:colors=[1,0,2,1] // grb4
        case 0x62676734:colors=[2,1,1,0] // bgg4
        case 0x67627234:colors=[1,2,0,1] // gbr4
        default:throw F5Failure(.unsupportedRAW,"Unsupported Bayer buffer color pattern.")
        }
        for y in 0..<2 {for x in 0..<2 {
            let expected=colors[((y+metadata.activeArea.top)&1)*2+((x+metadata.activeArea.left)&1)]
            guard metadata.cfa[y*2+x].color==expected else {throw F5Failure(.unsupportedRAW,"The delivered Bayer buffer and DNG disagree about CFA origin.")}
        }}
    }
}

/// Narrow, bounds-checked DNG metadata reader. Pixels come from AVCapturePhoto's
/// original Bayer buffer, copied before the callback returns, never CIRAWFilter.
/// Adobe DNG 1.7.1, pp. 22, 99–105, 111–116 defines these tag/phase semantics.
public struct F5DNGMetadata: Codable, Equatable, Sendable {
    struct Opcode: Codable, Equatable, Sendable {
        let list: Int, id: UInt32, version: UInt32, flags: UInt32
        let parameters: Data
        var optional: Bool { flags & 1 != 0 }
        var action: String {
            if version > 0x01070100 { return optional ? "optional_skipped" : "unsupported_mandatory" }
            if list == 1 && (id == 4 || id == 5) { return "exclude_original_bad_sample" }
            if list == 2 && id == 9 { return "gain_in_prediction_only" }
            if list == 3 && id == 1 { return "geometry_after_reconstruction_once" }
            if list == 3 && id == 9 { return "gain_after_reconstruction_once" }
            return optional ? "optional_skipped" : "unsupported_mandatory"
        }
    }
    public let width: Int, height: Int, bits: Int, orientation: Int
    public let activeArea: F5Area, cropOrigin: [Double], cropSize: [Double]
    public let cfa: [F5Phase]
    let linearization: [Double], blackRepeat: [Int], blackLevel: [Double]
    let blackDeltaH: [Double], blackDeltaV: [Double], whiteLevel: [Double], noiseProfile: [Double]
    let colorMatrix1: [Double], colorMatrix2: [Double], forwardMatrix1: [Double], forwardMatrix2: [Double]
    let cameraCalibration1: [Double], cameraCalibration2: [Double], analogBalance: [Double]
    let illuminant1: Int, illuminant2: Int
    let asShotNeutral: [Double], asShotWhiteXY: [Double]
    let calibrationSignature: String, profileSignature: String
    let opcodes: [Opcode]
    public let exposureTime: Double?, iso: Double?, aperture: Double?
    let sourceSHA256: String
    let photographic: F5PhotographicMetadata?
    var baselineExposure: Double? = nil
    var baselineSharpness: Double? = nil

    public static func read(_ data: Data) throws -> F5DNGMetadata {
        let reader = try F5TIFF(data)
        let ifds = try reader.directories()
        let candidates = try ifds.filter { try reader.numbers($0[262]).first == 32803 && (reader.numbers($0[254]).first ?? 0) == 0 }
        guard candidates.count == 1, let raw = candidates.first, let root = ifds.first else {
            throw F5Failure(.unsupportedRAW, "DNG must contain one original CFA IFD; previews and LinearRaw are not Bayer observations.")
        }
        func values(_ tag: Int) throws -> [Double] { try reader.numbers(raw[tag] ?? root[tag]) }
        func integer(_ tag: Int, default fallback: Int? = nil) throws -> Int {
            let array = try values(tag)
            if array.isEmpty, let fallback { return fallback }
            guard array.count == 1, let value = array.first, value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value else {
                throw F5Failure(.unsupportedRAW, "Missing or invalid DNG tag \(tag).")
            }
            return Int(value)
        }
        let width = try integer(256), height = try integer(257), bits = try integer(258)
        guard width >= 2, height >= 2, width <= 32768, height <= 32768,
              try integer(277, default: 1) == 1, try integer(339,default:1)==1, try integer(50711, default: 1) == 1,
              try values(33421) == [2, 2], (8...16).contains(bits) else {
            throw F5Failure(.unsupportedRAW, "Only rectangular, single-plane Bayer DNG is supported.")
        }
        let activeValues = try values(50829)
        let a = activeValues.isEmpty ? [0.0, 0, Double(height), Double(width)] : activeValues
        guard a.count == 4, a.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 32768 && $0.rounded() == $0 }) else {
            throw F5Failure(.unsupportedRAW, "Invalid ActiveArea.")
        }
        let area = F5Area(top: Int(a[0]), left: Int(a[1]), bottom: Int(a[2]), right: Int(a[3]))
        try area.validate(width: width, height: height)
        let pattern = try values(33422), planes = try values(50710)
        let planeColors = planes.isEmpty ? [0.0, 1, 2] : planes
        guard pattern.count == 4, planeColors == [0, 1, 2], pattern.allSatisfy({ [0.0, 1, 2].contains($0) }) else {
            throw F5Failure(.unsupportedRAW, "Unsupported CFA color mapping.")
        }
        var green = 0
        let cfa: [F5Phase] = pattern.map { value in
            if value == 0 { return .r }; if value == 2 { return .b }
            green += 1; return green == 1 ? .g1 : .g2
        }
        let orientation = try integer(274)
        let descriptor = F5RasterDescriptor(width: width, height: height, rowBytes: width * 2,
            byteOrder: .little, activeArea: area, cfa: cfa, orientation: orientation, bitsPerSample: bits)
        try descriptor.validate()
        let linearization = try values(50712)
        guard linearization.isEmpty || (linearization.count >= 2 && zip(linearization, linearization.dropFirst()).allSatisfy({ $0 <= $1 })) else {
            throw F5Failure(.unsupportedRAW, "LinearizationTable must be monotonic.")
        }
        let repeatValues = try values(50713)
        guard repeatValues.isEmpty || (repeatValues.count==2 && repeatValues.allSatisfy({$0>=1 && $0<=256 && $0.rounded()==$0})) else {
            throw F5Failure(.unsupportedRAW,"Invalid BlackLevelRepeatDim.")
        }
        let blackRepeat = repeatValues.isEmpty ? [1, 1] : repeatValues.map { Int($0) }
        let blacks = try values(50714), dh = try values(50715), dv = try values(50716)
        guard blackRepeat.count == 2, blackRepeat.allSatisfy({ (1...256).contains($0) }),
              blacks.isEmpty || blacks.count == blackRepeat[0] * blackRepeat[1],
              dh.isEmpty || dh.count == area.width, dv.isEmpty || dv.count == area.height else {
            throw F5Failure(.unsupportedRAW, "Invalid black repeat or delta dimensions.")
        }
        let white = try values(50717), defaultScale = try values(50718)
        guard white.isEmpty || (white.count == 1 && white[0] > 0), defaultScale.isEmpty || defaultScale == [1, 1] else {
            throw F5Failure(.unsupportedRAW, "This profile requires a single RAW plane and square input samples.")
        }
        let origin = try values(50719), size = try values(50720)
        let cropOrigin = origin.isEmpty ? [0.0, 0] : origin
        let cropSize = size.isEmpty ? [Double(area.width), Double(area.height)] : size
        guard cropOrigin.count == 2, cropSize.count == 2, cropOrigin.allSatisfy({ $0 >= 0 }), cropSize.allSatisfy({ $0 > 0 }),
              cropOrigin[0] + cropSize[0] <= Double(area.width), cropOrigin[1] + cropSize[1] <= Double(area.height) else {
            throw F5Failure(.unsupportedRAW, "DefaultCrop is outside ActiveArea.")
        }
        // Third-illuminant profiles need a dedicated, SDK-verified interpolator.
        guard try values(52529).isEmpty else { throw F5Failure(.colorTransformInvalid, "Three-illuminant DNG profiles are not certified by this decoder revision.") }
        var opcodes: [Opcode] = []
        for (list, tag) in [(1, 51008), (2, 51009), (3, 51022)] {
            if let field = raw[tag] ?? root[tag] { opcodes += try parseOpcodes(reader.bytes(field), list: list) }
        }
        let exposureIFDs = ifds.filter { $0[33434] != nil || $0[34855] != nil }
        func exposure(_ tag: Int) throws -> Double? {
            for ifd in exposureIFDs { if let value = try reader.numbers(ifd[tag]).first { return value } }
            return nil
        }
        var tiff: [String: String] = [:], exifText: [String: String] = [:], exifNumbers: [String: [Double]] = [:]
        for (tag, key) in [(271, kCGImagePropertyTIFFMake), (272, kCGImagePropertyTIFFModel),
                           (306, kCGImagePropertyTIFFDateTime), (315, kCGImagePropertyTIFFArtist),
                           (33432, kCGImagePropertyTIFFCopyright)] {
            let value = try reader.string(root[tag])
            if !value.isEmpty { tiff[key as String] = value }
        }
        func field(_ tag: Int) -> F5TIFF.Field? { ifds.first(where: { $0[tag] != nil })?[tag] }
        for (tag, key) in [(36867, kCGImagePropertyExifDateTimeOriginal), (36868, kCGImagePropertyExifDateTimeDigitized),
                           (36880, kCGImagePropertyExifOffsetTime), (36881, kCGImagePropertyExifOffsetTimeOriginal),
                           (36882, kCGImagePropertyExifOffsetTimeDigitized), (37520, kCGImagePropertyExifSubsecTime),
                           (37521, kCGImagePropertyExifSubsecTimeOriginal), (37522, kCGImagePropertyExifSubsecTimeDigitized),
                           (42035, kCGImagePropertyExifLensMake), (42036, kCGImagePropertyExifLensModel)] {
            let value = try reader.string(field(tag))
            if !value.isEmpty { exifText[key as String] = value }
        }
        for (tag, key) in [(33434, kCGImagePropertyExifExposureTime), (33437, kCGImagePropertyExifFNumber),
                           (34850, kCGImagePropertyExifExposureProgram), (34855, kCGImagePropertyExifISOSpeedRatings),
                           (37377, kCGImagePropertyExifShutterSpeedValue), (37378, kCGImagePropertyExifApertureValue),
                           (37379, kCGImagePropertyExifBrightnessValue), (37380, kCGImagePropertyExifExposureBiasValue),
                           (37383, kCGImagePropertyExifMeteringMode), (37384, kCGImagePropertyExifLightSource),
                           (37385, kCGImagePropertyExifFlash), (37386, kCGImagePropertyExifFocalLength),
                           (41986, kCGImagePropertyExifExposureMode), (41987, kCGImagePropertyExifWhiteBalance),
                           (41988, kCGImagePropertyExifDigitalZoomRatio), (41989, kCGImagePropertyExifFocalLenIn35mmFilm),
                           (42034, kCGImagePropertyExifLensSpecification)] {
            let value = try reader.numbers(field(tag))
            if !value.isEmpty { exifNumbers[key as String] = value }
        }
        return try F5DNGMetadata(width: width, height: height, bits: bits, orientation: orientation,
            activeArea: area, cropOrigin: cropOrigin, cropSize: cropSize, cfa: cfa,
            linearization: linearization, blackRepeat: blackRepeat, blackLevel: blacks.isEmpty ? [0] : blacks,
            blackDeltaH: dh, blackDeltaV: dv, whiteLevel: white.isEmpty ? [Double((1 << bits) - 1)] : white,
            noiseProfile: values(51041), colorMatrix1: values(50721), colorMatrix2: values(50722),
            forwardMatrix1: values(50964), forwardMatrix2: values(50965),
            cameraCalibration1: values(50723), cameraCalibration2: values(50724), analogBalance: values(50727),
            illuminant1: integer(50778), illuminant2: integer(50779, default: 0),
            asShotNeutral: values(50728), asShotWhiteXY: values(50729),
            calibrationSignature: reader.string(raw[50931] ?? root[50931]),
            profileSignature: reader.string(raw[50932] ?? root[50932]), opcodes: opcodes,
            exposureTime: exposure(33434), iso: exposure(34855), aperture: exposure(33437), sourceSHA256: F5Hash.data(data),
            photographic: .init(tiff: tiff, exifText: exifText, exifNumbers: exifNumbers),
            baselineExposure: values(50730).first, baselineSharpness: values(50732).first)
    }

    func auditOpcodes() throws {
        for opcode in opcodes {
            if opcode.action == "unsupported_mandatory" || (opcode.version > 0x01070100 && !opcode.optional) {
                throw F5Failure(.unsupportedOpcode, "Mandatory opcode \(opcode.id), list \(opcode.list), cannot be ignored.")
            }
        }
    }
    func linearized(_ code: Double) -> Double {
        guard !linearization.isEmpty else { return code }
        // Half-code interval boundaries interpolate the same monotonic mapping.
        let position = min(Double(linearization.count - 1), max(0, code))
        let lower = Int(position), upper = min(linearization.count - 1, lower + 1)
        return linearization[lower] + (position - Double(lower)) * (linearization[upper] - linearization[lower])
    }
    public func black(x: Int, y: Int) -> Double {
        blackLevel[(y % blackRepeat[0]) * blackRepeat[1] + x % blackRepeat[1]] +
        (blackDeltaH.isEmpty ? 0 : blackDeltaH[x]) + (blackDeltaV.isEmpty ? 0 : blackDeltaV[y])
    }
    private static func parseOpcodes(_ data: Data, list: Int) throws -> [Opcode] {
        let bytes = F5Bytes(data, little: false)
        let count = Int(try bytes.u32(0))
        guard count <= 4096 else { throw F5Failure(.unsupportedOpcode, "Excessive opcode count.") }
        var offset = 4, result: [Opcode] = []
        for _ in 0..<count {
            let id = try bytes.u32(offset), version = try bytes.u32(offset + 4), flags = try bytes.u32(offset + 8)
            let length = Int(try bytes.u32(offset + 12)); offset += 16
            result.append(.init(list: list, id: id, version: version, flags: flags, parameters: try bytes.slice(offset, length)))
            offset += length
        }
        guard offset == data.count else { throw F5Failure(.unsupportedOpcode, "Trailing or truncated opcode bytes.") }
        return result
    }
}

struct F5Bytes {
    let data: Data, little: Bool
    init(_ data: Data, little: Bool) { self.data = data; self.little = little }
    func slice(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw F5Failure(.damagedBundle, "Truncated RAW metadata.")
        }
        return data.subdata(in: offset..<(offset + count))
    }
    func unsigned(_ offset: Int, _ count: Int) throws -> UInt64 {
        guard count > 0, count <= 8, offset >= 0, offset <= data.count, count <= data.count - offset else {
            throw F5Failure(.damagedBundle, "Invalid TIFF offset.")
        }
        var result: UInt64 = 0
        for i in 0..<count { result |= UInt64(data[offset + i]) << (8 * (little ? i : count - 1 - i)) }
        return result
    }
    func u16(_ p: Int) throws -> UInt16 { UInt16(try unsigned(p, 2)) }
    func u32(_ p: Int) throws -> UInt32 { UInt32(try unsigned(p, 4)) }
    func f32(_ p: Int) throws -> Double { Double(Float(bitPattern: try u32(p))) }
    func f64(_ p: Int) throws -> Double { Double(bitPattern: try unsigned(p, 8)) }
}

private struct F5TIFF {
    struct Field { let type: Int, count: Int, offset: Int }
    let reader: F5Bytes
    init(_ data: Data) throws {
        guard data.count >= 8, (data[0] == 73 && data[1] == 73) || (data[0] == 77 && data[1] == 77) else {
            throw F5Failure(.unsupportedRAW, "Not a TIFF/DNG file.")
        }
        reader = F5Bytes(data, little: data[0] == 73)
        guard try reader.u16(2) == 42 else { throw F5Failure(.unsupportedRAW, "BigTIFF is not supported by this audited decoder.") }
    }
    private func stride(_ type: Int) throws -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: throw F5Failure(.unsupportedRAW, "Unsupported TIFF field type \(type).")
        }
    }
    func directories() throws -> [[Int: Field]] {
        var pending = [Int(try reader.u32(4))], visited = Set<Int>(), result: [[Int: Field]] = []
        while !pending.isEmpty {
            let offset = pending.removeFirst()
            if offset == 0 { continue }
            guard visited.insert(offset).inserted, visited.count <= 64 else { throw F5Failure(.damagedBundle, "Cyclic or excessive TIFF directories.") }
            let count = Int(try reader.u16(offset))
            guard count <= 4096 else { throw F5Failure(.damagedBundle, "Excessive TIFF tags.") }
            var fields: [Int: Field] = [:]
            for i in 0..<count {
                let p = offset + 2 + i * 12, tag = Int(try reader.u16(p)), type = Int(try reader.u16(p + 2))
                let n = Int(try reader.u32(p + 4)), itemBytes = try stride(type)
                guard n <= 16_777_216, n <= Int.max / itemBytes, fields[tag] == nil else { throw F5Failure(.damagedBundle, "Invalid TIFF count or duplicate tag.") }
                let bytes = n * itemBytes, start = bytes <= 4 ? p + 8 : Int(try reader.u32(p + 8))
                guard start <= reader.data.count, bytes <= reader.data.count - start else { throw F5Failure(.damagedBundle, "TIFF field exceeds file.") }
                fields[tag] = Field(type: type, count: n, offset: start)
            }
            result.append(fields)
            for tag in [330, 34665] {
                for value in try numbers(fields[tag]) {
                    guard value >= 0, value < Double(reader.data.count), value.rounded() == value else { throw F5Failure(.damagedBundle, "Invalid sub-IFD.") }
                    pending.append(Int(value))
                }
            }
            pending.append(Int(try reader.u32(offset + 2 + count * 12)))
        }
        return result
    }
    func bytes(_ field: Field) throws -> Data { try reader.slice(field.offset, field.count * stride(field.type)) }
    func string(_ field: Field?) throws -> String {
        guard let field else { return "" }
        guard field.type == 2, field.count <= 65536 else { throw F5Failure(.damagedBundle, "Invalid TIFF string.") }
        return String(data: try bytes(field).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }
    func numbers(_ field: Field?) throws -> [Double] {
        guard let f = field else { return [] }
        guard f.count <= 1_048_576 else { throw F5Failure(.damagedBundle, "Excessive numeric metadata.") }
        let step = try stride(f.type)
        return try (0..<f.count).map { i in
            let p = f.offset + i * step
            let value: Double
            switch f.type {
            case 1, 3, 4, 7, 13: value = Double(try reader.unsigned(p, step))
            case 6: value = Double(Int8(bitPattern: UInt8(try reader.unsigned(p, 1))))
            case 8: value = Double(Int16(bitPattern: try reader.u16(p)))
            case 9: value = Double(Int32(bitPattern: try reader.u32(p)))
            case 5, 10:
                let a = try reader.u32(p), b = try reader.u32(p + 4)
                guard b != 0 else { throw F5Failure(.damagedBundle, "Zero rational denominator.") }
                value = f.type == 5 ? Double(a) / Double(b) : Double(Int32(bitPattern: a)) / Double(Int32(bitPattern: b))
            case 11: value = try reader.f32(p)
            case 12: value = try reader.f64(p)
            default: throw F5Failure(.unsupportedRAW, "Expected a numeric DNG field.")
            }
            guard value.isFinite else { throw F5Failure(.nonfinite, "Non-finite DNG field.") }
            return value
        }
    }
}

enum F5EventKind: UInt32, Sendable { case interval, upperCensored, lowerCensored, badSensor, syntheticRepaired, outsideActive, unsupportedOpcode }
struct F5RawEvent: Sendable {
    let x: Double, y: Double, color: Int, phase: Int, frame: Int
    let code: UInt16, kind: F5EventKind
    let lower: Double, upper: Double, exposure: Double, eta: Double, kappa: Double, readSigma: Double, uniformProbability: Double
}

/// Keeps five integer rasters; floating-point observations are created per tile.
final class F5CanonicalFrame: @unchecked Sendable {
    let record: F5FrameRecord
    let codes: Data
    let profile: F5DeviceProfile
    let exposure: Double
    let codeDivisor: Int
    let corrections: F5RAWCorrections
    init(record: F5FrameRecord, codes: Data, profile: F5DeviceProfile, mainExposure: Double) throws {
        try profile.validate(synthetic:profile.qualification == .synthetic,requireProduct:false)
        try record.raster.validate(); try record.metadata.auditOpcodes()
        guard codes.count == record.raster.byteCount, mainExposure > 0 else { throw F5Failure(.damagedBundle, "RAW byte count does not match its stride.") }
        self.record = record; self.codes = codes; self.profile = profile; exposure = record.actualExposure / mainExposure
        codeDivisor = profile.bufferCodeMapping?.divisor ?? 1 // Identity fallback is synthetic-only.
        corrections = try F5RAWCorrections(metadata: record.metadata)
    }
    func event(x: Int, y: Int) -> F5RawEvent {
        let a = record.raster.activeArea, phase = record.raster.phase(x: x, y: y), noise = profile.noise[phase.rawValue]
        let px = x + a.left, py = y + a.top, offset = py * record.raster.rowBytes + px * 2
        let code: UInt16 = record.raster.byteOrder == .little ? UInt16(codes[offset]) | UInt16(codes[offset + 1]) << 8 : UInt16(codes[offset]) << 8 | UInt16(codes[offset + 1])
        let black = record.metadata.black(x: x, y: y) + profile.blackResidualByPhase[phase.rawValue]
        let lower = (record.metadata.linearized((Double(code) - 0.5) / Double(codeDivisor)) - black) / profile.whiteScale
        let upper = (record.metadata.linearized((Double(code) + 0.5) / Double(codeDivisor)) - black) / profile.whiteScale
        let kind: F5EventKind
        let range = profile.rawCodeRange ?? [0, (1 << record.raster.bitsPerSample) - 1]
        if Int(code) < range[0] || Int(code) > range[1] || corrections.isBad(x: px, y: py, code: UInt16(Int(code) / codeDivisor)) { kind = .badSensor }
        else if Int(code) >= noise.upperCensorCode { kind = .upperCensored }
        else if Int(code) <= noise.lowerCensorCode { kind = .lowerCensored }
        else { kind = .interval }
        let count = Double(range[1] - range[0] + 1)
        let q = kind == .upperCensored ? Double(range[1] - noise.upperCensorCode + 1) / count :
            (kind == .lowerCensored ? Double(noise.lowerCensorCode - range[0] + 1) / count : 1 / count)
        return .init(x: Double(x) + 0.5, y: Double(y) + 0.5, color: phase.color, phase: phase.rawValue, frame: record.burstIndex,
            code: code, kind: kind, lower: kind == .upperCensored ? noise.upperThreshold : lower,
            upper: kind == .lowerCensored ? noise.lowerThreshold : upper, exposure: exposure,
            eta: noise.gain * corrections.response(x: px, y: py), kappa: noise.kappa, readSigma: noise.readSigma, uniformProbability: q)
    }
}

/// DNG GainMap parameters are relative to the image at their opcode stage.
/// Stage2 and Stage3 both start at ActiveArea's origin, before DefaultCrop.
struct F5DNGGainMap: Sendable {
    let area: F5Area, rowPitch: Int, colPitch: Int, rows: Int, columns: Int
    let firstPlane: Int, planes: Int, mapPlanes: Int
    let originX: Double, originY: Double, spacingX: Double, spacingY: Double
    let values: [Double], width: Int, height: Int
    init(_ opcode: F5DNGMetadata.Opcode, width: Int, height: Int, imagePlanes: Int) throws {
        let b = F5Bytes(opcode.parameters, little: false)
        area = try .init(top: Int(b.u32(0)), left: Int(b.u32(4)), bottom: Int(b.u32(8)), right: Int(b.u32(12)))
        try area.validate(width: width, height: height)
        firstPlane = Int(try b.u32(16)); planes = Int(try b.u32(20))
        rowPitch = Int(try b.u32(24)); colPitch = Int(try b.u32(28))
        rows = Int(try b.u32(32)); columns = Int(try b.u32(36))
        spacingY = try b.f64(40); spacingX = try b.f64(48)
        originY = try b.f64(56); originX = try b.f64(64); mapPlanes = Int(try b.u32(72))
        guard opcode.id == 9, [2,3].contains(opcode.list), firstPlane < imagePlanes,
              planes > 0, planes <= imagePlanes - firstPlane, (1...imagePlanes).contains(mapPlanes),
              rowPitch > 0, colPitch > 0, (1...1024).contains(rows), (1...1024).contains(columns),
              [spacingX,spacingY,originX,originY].allSatisfy(\.isFinite), spacingX > 0, spacingY > 0,
              b.data.count == 76 + rows * columns * mapPlanes * 4 else {
            throw F5Failure(.unsupportedOpcode, "Unsupported gain-map layout.")
        }
        // A sparse Stage3 operation has no defined continuous 2× extension.
        guard opcode.list != 3 || (rowPitch == 1 && colPitch == 1) else {
            throw F5Failure(.unsupportedOpcode, "Sparse post-reconstruction gain maps need a separately audited sampling policy.")
        }
        values = try (0..<(rows * columns * mapPlanes)).map { try b.f32(76 + $0 * 4) }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw F5Failure(.unsupportedOpcode, "Invalid gain-map value.") }
        self.width = width; self.height = height
    }
    func value(x: Int, y: Int) -> Double { value(point: SIMD2(Double(x) + 0.5, Double(y) + 0.5), plane: 0) }
    func value(point: SIMD2<Double>, plane: Int) -> Double {
        guard point.x >= Double(area.left), point.x < Double(area.right), point.y >= Double(area.top), point.y < Double(area.bottom),
              plane >= firstPlane, plane < firstPlane + planes,
              (Int(floor(point.x)) - area.left) % colPitch == 0, (Int(floor(point.y)) - area.top) % rowPitch == 0 else { return 1 }
        let u = min(Double(columns - 1), max(0, (point.x / Double(width) - originX) / spacingX))
        let v = min(Double(rows - 1), max(0, (point.y / Double(height) - originY) / spacingY))
        let ix = Int(u), iy = Int(v), fx = u - Double(ix), fy = v - Double(iy), channel = min(plane, mapPlanes - 1)
        func entry(_ x: Int, _ y: Int) -> Double { values[(y * columns + x) * mapPlanes + channel] }
        let a = entry(ix, iy), b = entry(min(ix + 1, columns - 1), iy)
        let c = entry(ix, min(iy + 1, rows - 1)), d = entry(min(ix + 1, columns - 1), min(iy + 1, rows - 1))
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

struct F5RAWCorrections: Sendable {
    var badCodes: Set<UInt16> = [], badPoints: Set<Int> = [], badAreas: [F5Area] = [], gains: [F5DNGGainMap] = []
    let width: Int, activeArea: F5Area
    init(metadata: F5DNGMetadata) throws {
        width = metadata.width; activeArea = metadata.activeArea
        for opcode in metadata.opcodes {
            if opcode.action == "optional_skipped" { continue }
            let b = F5Bytes(opcode.parameters, little: false)
            if opcode.list == 1 && opcode.id == 4 {
                let code = try b.u32(0)
                guard code <= 65535, try b.u32(4) <= 3, b.data.count == 8 else { throw F5Failure(.unsupportedOpcode, "Invalid bad-pixel constant.") }
                badCodes.insert(UInt16(code))
            } else if opcode.list == 1 && opcode.id == 5 {
                let count = Int(try b.u32(4)), rectangles = Int(try b.u32(8))
                guard try b.u32(0) <= 3, count <= 1_000_000, rectangles <= 65536,
                      b.data.count == 12 + count * 8 + rectangles * 16 else { throw F5Failure(.unsupportedOpcode, "Invalid bad-pixel list.") }
                for i in 0..<count {
                    let y = Int(try b.u32(12 + i * 8)), x = Int(try b.u32(16 + i * 8))
                    guard x < metadata.width, y < metadata.height else { throw F5Failure(.unsupportedOpcode, "Bad pixel outside raster.") }
                    badPoints.insert(y * width + x)
                }
                for i in 0..<rectangles { badAreas.append(try Self.area(b, offset: 12 + count * 8 + i * 16, metadata: metadata)) }
            } else if opcode.list == 2 && opcode.id == 9 {
                gains.append(try .init(opcode, width: activeArea.width, height: activeArea.height, imagePlanes: 1))
            } else if opcode.list == 3 && opcode.id == 9 {
                // Validate here, but apply only to reconstructed camera RGB.
                _ = try F5DNGGainMap(opcode, width: activeArea.width, height: activeArea.height, imagePlanes: 3)
            }
        }
    }
    private static func area(_ b: F5Bytes, offset: Int, metadata: F5DNGMetadata) throws -> F5Area {
        let a = try F5Area(top: Int(b.u32(offset)), left: Int(b.u32(offset + 4)), bottom: Int(b.u32(offset + 8)), right: Int(b.u32(offset + 12)))
        try a.validate(width: metadata.width, height: metadata.height); return a
    }
    func isBad(x: Int, y: Int, code: UInt16) -> Bool {
        badCodes.contains(code) || badPoints.contains(y * width + x) || badAreas.contains(where: { x >= $0.left && x < $0.right && y >= $0.top && y < $0.bottom })
    }
    func response(x: Int, y: Int) -> Double {
        // DNG Stage2 is allocated with ActiveArea.Size(), before DefaultCrop.
        gains.reduce(1) { $0 / $1.value(x: x - activeArea.left, y: y - activeArea.top) }
    }
}
