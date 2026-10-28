import Foundation
import ImageIO
import Darwin

/// Providers retain this owner through outstanding file requests, so dismissing
/// a sheet cannot delete a HEIF that is still being handed to a recipient.
public final class TemporaryHEIFFile: @unchecked Sendable {
    public let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassCam-\(UUID().uuidString).heic")
    public let captureDate: Date?
    public init(captureDate: Date? = nil) { self.captureDate = captureDate }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Owned capture fields, excluding RAW offsets, MakerNotes, stale geometry and
/// the input container's encoding/colour tags. No location data is collected.
public struct PhotoMetadata: @unchecked Sendable {
    private let tiff: [String: Any]
    private let exif: [String: Any]
    private let gps: [String: Any]
    private static let tiffKeys: [CFString] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription
    ]
    private static let exifKeys: [CFString] = [
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
        kCGImagePropertyExifExposureProgram, kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifISOSpeed, kCGImagePropertyExifDateTimeOriginal,
        kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTime,
        kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
        kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal,
        kCGImagePropertyExifSubsecTimeDigitized, kCGImagePropertyExifShutterSpeedValue,
        kCGImagePropertyExifApertureValue, kCGImagePropertyExifBrightnessValue,
        kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifMaxApertureValue,
        kCGImagePropertyExifSubjectDistance, kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifLightSource, kCGImagePropertyExifFlash,
        kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifExposureMode, kCGImagePropertyExifWhiteBalance,
        kCGImagePropertyExifDigitalZoomRatio, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifUserComment
    ]

    public init(properties: [String: Any]) {
        tiff = Self.select(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any], keys: Self.tiffKeys)
        exif = Self.select(properties[kCGImagePropertyExifDictionary as String] as? [String: Any], keys: Self.exifKeys)
        gps = (properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:])
            .compactMapValues(Self.snapshotValue)
    }
    public static func read(from url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw PipelineError.invalidImage
        }
        return PhotoMetadata(properties: properties)
    }
    package func addingCaptureProvenance(_ text: String) -> PhotoMetadata {
        var updated = exif
        updated[kCGImagePropertyExifUserComment as String] = text
        return PhotoMetadata(properties: [kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyExifDictionary as String: updated, kCGImagePropertyGPSDictionary as String: gps])
    }
    private static func snapshotValue(_ value: Any) -> Any? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : nil }
        if let values = value as? [Any] {
            guard !values.isEmpty else { return nil }
            let result = values.compactMap(snapshotValue)
            return result.count == values.count ? result : nil
        }
        return nil
    }
    private static func select(_ values: [String: Any]?, keys: [CFString]) -> [String: Any] {
        var result = [String: Any]()
        for key in keys {
            if let value = values?[key as String], let snapshot = snapshotValue(value) { result[key as String] = snapshot }
        }
        return result
    }

    public var captureDate: Date? {
        let candidates: [(String?, String?, String?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
             exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
             exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String),
            (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String,
             exif[kCGImagePropertyExifOffsetTimeDigitized as String] as? String,
             exif[kCGImagePropertyExifSubsecTimeDigitized as String] as? String),
            (tiff[kCGImagePropertyTIFFDateTime as String] as? String,
             exif[kCGImagePropertyExifOffsetTime as String] as? String,
             exif[kCGImagePropertyExifSubsecTime as String] as? String)
        ]
        for (text, offset, subseconds) in candidates {
            guard let text else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            formatter.timeZone = .current
            let zone = offset.flatMap { $0.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil ? $0 : nil }
            formatter.dateFormat = zone == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: text + (zone ?? "")) {
                let fraction = subseconds.flatMap { $0.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil ? Double("0." + $0) : nil } ?? 0
                return date.addingTimeInterval(fraction)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
        }
        return nil
    }

    /// Attach native ImageIO dictionaries before the one image encode. The XMP
    /// metadata bridge can report success while omitting new HEIF EXIF fields.
    /// Passing these through CIImage.properties preserves their native types.
    func encodingProperties(width: Int, height: Int, presetWhiteBalance: Bool = false) -> [String: Any] {
        var targetTIFF = tiff, targetExif = exif
        targetTIFF[kCGImagePropertyTIFFOrientation as String] = 1
        targetTIFF[kCGImagePropertyTIFFSoftware as String] = "GlassCam"
        targetExif[kCGImagePropertyExifPixelXDimension as String] = width
        targetExif[kCGImagePropertyExifPixelYDimension as String] = height
        targetExif[kCGImagePropertyExifCustomRendered as String] = 1
        if presetWhiteBalance { targetExif[kCGImagePropertyExifWhiteBalance as String] = 1 }
        var properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: targetTIFF,
            kCGImagePropertyExifDictionary as String: targetExif,
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyPixelWidth as String: width,
            kCGImagePropertyPixelHeight as String: height
        ]
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary as String] = gps }
        return properties
    }

    /// Validate the finalized file before publishing it. Metadata preservation
    /// failures must still retain the source, just like encoding failures.
    public func validate(in properties: [String: Any]) throws {
        let copiedTIFF = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let copiedExif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] {
            if tiff[key as String] != nil, copiedTIFF[key as String] == nil { throw PipelineError.metadata }
        }
        for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
                    kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
                    kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifLensModel,
                    kCGImagePropertyExifDateTimeOriginal] {
            if exif[key as String] != nil, copiedExif[key as String] == nil { throw PipelineError.metadata }
        }
        if let comment = exif[kCGImagePropertyExifUserComment as String] as? String,
           copiedExif[kCGImagePropertyExifUserComment as String] as? String != comment { throw PipelineError.metadata }
        if let originalDate = captureDate {
            guard let writtenDate = PhotoMetadata(properties: properties).captureDate,
                  abs(writtenDate.timeIntervalSince(originalDate)) < 0.01 else { throw PipelineError.metadata }
        }
    }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let file: TemporaryHEIFFile
}

/// Owns an immutable copy of the genuine capture/import bytes. Previews never
/// replace this file. Shared recipes retain this owner until exports finish.
public final class SourceImageFile: @unchecked Sendable {
    public let url: URL
    public let fileExtension: String?
    let pixelWidth: Int
    let pixelHeight: Int
    public let metadata: PhotoMetadata
    private let deletesOnRelease: Bool

    public init(data: Data, fileExtension: String?) throws {
        deletesOnRelease = true
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { throw PipelineError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        metadata = PhotoMetadata(properties: properties)
        pixelWidth = (5...8).contains(orientation) ? height.intValue : width.intValue
        pixelHeight = (5...8).contains(orientation) ? width.intValue : height.intValue
        self.fileExtension = fileExtension
        // Do not derive any path component from an untrusted imported name.
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-source-\(UUID().uuidString)")
        try data.write(to: url, options: ImageFileProtection.writeOptions)
    }

    /// The recovery journal, rather than this borrowed handle, owns this file.
    public init(retainedURL: URL, fileExtension: String?) throws {
        guard let source = CGImageSourceCreateWithURL(retainedURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { throw PipelineError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        metadata = PhotoMetadata(properties: properties)
        pixelWidth = (5...8).contains(orientation) ? height.intValue : width.intValue
        pixelHeight = (5...8).contains(orientation) ? width.intValue : height.intValue
        url = retainedURL; self.fileExtension = fileExtension; deletesOnRelease = false
    }

    deinit { if deletesOnRelease { try? FileManager.default.removeItem(at: url) } }
}

/// Disk-backed processing result, not a full-resolution Swift Float array.
/// Mapped pages and Apple decode/encode allocations still count toward RSS;
/// this is bounded application-owned tile scratch, NOT bounded total memory.
package final class ExportRasterFile {
    package let url: URL
    package let handle: FileHandle
    package init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-raster-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: ImageFileProtection.attributes) else {
            throw PipelineError.rendering
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    package func append(_ pixels: [Float]) throws {
        try pixels.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }
    package func mappedData(expectedBytes: Int) throws -> Data {
        try handle.synchronize()
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw PipelineError.rendering }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size == off_t(expectedBytes) else {
            throw PipelineError.rendering
        }
        guard let address = mmap(nil, expectedBytes, PROT_READ, MAP_PRIVATE, descriptor, 0),
              address != MAP_FAILED else { throw PipelineError.rendering }
        return Data(bytesNoCopy: address, count: expectedBytes,
                    deallocator: .custom { pointer, count in munmap(pointer, count) })
    }
    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
