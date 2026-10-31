// This product includes DNG technology under license by Adobe.
import Foundation
import CoreGraphics
import CMetalF5
import Capture

/// TIFF/DNG metadata stays in Swift; bounded unchanged RGB strip packing and
/// file IO use C++. The camera DNG owns its original as-shot white specification.
enum F5FloatArchive {
    private struct Tag { let id: UInt16, type: UInt16, count: UInt32, data: Data }
    private final class Cancellation {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func integers(_ id: UInt16, _ values: [UInt32], short: Bool = false) -> Tag {
        var data = Data()
        for value in values { if short { append(UInt16(value),to: &data) } else { append(value,to: &data) } }
        return .init(id: id,type: short ? 3 : 4,count: UInt32(values.count),data: data)
    }
    private static func bytes(_ id: UInt16, _ data: Data, type: UInt16 = 1) -> Tag {
        .init(id: id,type: type,count: UInt32(data.count),data: data)
    }
    private static func text(_ id: UInt16, _ value: String) -> Tag { bytes(id,Data((value + "\0").utf8),type: 2) }
    private static func rationals(_ id: UInt16, _ values: [Double], signed: Bool = false) throws -> Tag {
        var data = Data()
        for value in values {
            guard value.isFinite, signed || value >= 0, abs(value) < 1e6 else { throw F5Failure(.encodeMetadataInvalid,"Invalid RAW archive rational.") }
            let limit = signed ? Double(Int32.max) : Double(UInt32.max)
            let denominator = UInt32(min(1e9,floor(limit / max(1,abs(value)))))
            let numerator = (value * Double(denominator)).rounded()
            append(signed ? UInt32(bitPattern: Int32(numerator)) : UInt32(numerator),to: &data)
            append(denominator,to: &data)
        }
        return .init(id: id,type: signed ? 10 : 5,count: UInt32(values.count),data: data)
    }

    static func write(input: URL, to output: URL, width: Int, height: Int, reference: F5FrameRecord,
                      cameraDNG: Bool, whiteScale: Double, cancelled: @escaping () -> Bool = { false }) throws {
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              UInt64(width) * UInt64(height) * 12 < UInt64(UInt32.max) - 1024 * 1024 else {
            throw F5Failure(.encodeMetadataInvalid,"RAW archive exceeds classic TIFF dimensions.")
        }
        let stripRows = 16, strips = (height + stripRows - 1) / stripRows
        let sizes = (0..<strips).map { UInt32(width * min(stripRows,height - $0 * stripRows) * 12) }
        let m = reference.metadata
        var tags = [integers(254,[0]),integers(256,[UInt32(width)]),integers(257,[UInt32(height)]),
            integers(258,[32,32,32],short: true),integers(259,[1],short: true),
            integers(262,[cameraDNG ? 34892 : 2],short: true),text(271,m.photographic?.tiff["Make"] ?? "GlassCam"),
            text(272,m.photographic?.tiff["Model"] ?? "Bayer reconstruction"),
            integers(273,[UInt32](repeating: 0,count: strips)),integers(274,[UInt32(reference.raster.orientation)],short: true),
            integers(277,[3],short: true),integers(278,[UInt32(stripRows)]),integers(279,sizes),
            integers(284,[1],short: true),text(305,"GlassCam " + F5Version.build),
            integers(339,[3,3,3],short: true),integers(34665,[0])]
        if let date = m.photographic?.tiff["DateTime"] { tags.append(text(306,date)) }
        var exif = try [rationals(33434,[reference.actualExposure]),rationals(33437,[reference.aperture]),
            integers(34855,[UInt32(min(65535,reference.actualISO.rounded()))],short: true),
            bytes(36864,Data("0231".utf8),type: 7),integers(40962,[UInt32(width)]),integers(40963,[UInt32(height)])]
        if let date = m.photographic?.exifText["DateTimeOriginal"] { exif.append(text(36867,date)) }
        if let zone = m.photographic?.exifText["OffsetTimeOriginal"] { exif.append(text(36881,zone)) }
        if cameraDNG {
            guard let white = m.whiteLevel.first else { throw F5Failure(.colorTransformInvalid,"Missing RAW white scale.") }
            let black = (m.blackLevel.max() ?? 0) + (m.blackDeltaH.max() ?? 0) + (m.blackDeltaV.max() ?? 0)
            let ratio = whiteScale / (white - black)
            guard ratio.isFinite, ratio > 0 else { throw F5Failure(.colorTransformInvalid,"Invalid archive normalization.") }
            tags += [bytes(50706,Data([1,4,0,0])),bytes(50707,Data([1,4,0,0])),
                text(50708,"GlassCam Balanced LinearRaw"),bytes(50710,Data([0,1,2])),integers(50713,[1,1],short: true),
                try rationals(50714,[0,0,0]),integers(50717,[1,1,1]),try rationals(50718,[1,1]),
                integers(50719,[0,0]),integers(50720,[UInt32(width),UInt32(height)]),
                try rationals(50730,[(m.baselineExposure ?? 0) + log2(ratio)],signed: true),
                try rationals(50732,[m.baselineSharpness ?? 0]),integers(50778,[UInt32(m.illuminant1)],short: true)]
            for (id,values) in [(UInt16(50721),m.colorMatrix1),(50722,m.colorMatrix2),(50723,m.cameraCalibration1),
                (50724,m.cameraCalibration2),(50964,m.forwardMatrix1),(50965,m.forwardMatrix2)] where !values.isEmpty {
                tags.append(try rationals(id,values,signed: true))
            }
            for (id,values) in [(UInt16(50727),m.analogBalance),(50728,m.asShotNeutral),(50729,m.asShotWhiteXY)] where !values.isEmpty {
                tags.append(try rationals(id,values))
            }
            if m.illuminant2 != 0 { tags.append(integers(50779,[UInt32(m.illuminant2)],short: true)) }
            if !m.calibrationSignature.isEmpty { tags.append(text(50931,m.calibrationSignature)) }
            if !m.profileSignature.isEmpty { tags.append(text(50932,m.profileSignature)) }
        } else {
            guard let space = CGColorSpace(name: CGColorSpace.linearSRGB), let profile = space.copyICCData() else {
                throw F5Failure(.colorTransformInvalid,"Linear sRGB ICC profile is unavailable.")
            }
            tags.append(bytes(34675,profile as Data,type: 7))
        }
        let exifOffset = 8 + 2 + tags.count * 12 + 4
        let extraOffset = exifOffset + 2 + exif.count * 12 + 4
        let extraCount = (tags + exif).reduce(0) { $0 + ($1.data.count > 4 ? ($1.data.count + 1) / 2 * 2 : 0) }
        let pixelOffset = (extraOffset + extraCount + 15) / 16 * 16
        guard UInt64(pixelOffset) + UInt64(width) * UInt64(height) * 12 <= UInt32.max else {
            throw F5Failure(.encodeMetadataInvalid,"RAW archive exceeds TIFF offset limits.")
        }
        var offsets = [UInt32](), position = UInt32(pixelOffset)
        for size in sizes { offsets.append(position); position += size }
        tags[tags.firstIndex { $0.id == 273 }!] = integers(273,offsets)
        tags[tags.firstIndex { $0.id == 34665 }!] = integers(34665,[UInt32(exifOffset)])
        var header = Data([73,73,42,0,8,0,0,0]), extra = Data()
        func emit(_ tags: [Tag]) {
            append(UInt16(tags.count),to: &header)
            for tag in tags.sorted(by: { $0.id < $1.id }) {
                append(tag.id,to: &header); append(tag.type,to: &header); append(tag.count,to: &header)
                if tag.data.count <= 4 { header.append(tag.data); header.append(Data(count: 4 - tag.data.count)) }
                else {
                    append(UInt32(extraOffset + extra.count),to: &header); extra.append(tag.data)
                    if extra.count % 2 != 0 { extra.append(0) }
                }
            }
            append(UInt32(0),to: &header)
        }
        emit(tags); emit(exif); header.append(extra); header.append(Data(count: pixelOffset - header.count))
        try CaptureJournal.writeProtected(header,to: output)
        let reader = try FileHandle(forReadingFrom: input), writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }
        let provider = Cancellation(cancelled)
        var callbacks = gc_f5_curve_callbacks(context: Unmanaged.passUnretained(provider).toOpaque(),prepare: nil,cancelled: { context in
            guard let context else { return 1 }
            return Unmanaged<Cancellation>.fromOpaque(context).takeUnretainedValue().check() ? 1 : 0
        },progress: nil)
        var error = gc_f5_curve_error()
        _ = gc_f5_curve_write_rgb(reader.fileDescriptor,writer.fileDescriptor,UInt32(width),UInt32(height),UInt64(pixelOffset),&callbacks,&error)
        withExtendedLifetime(provider) {}
        try F5CurvatureNative.check(error)
        try writer.synchronize()
    }
}
