import Foundation
import ImageIO
import Darwin

/// Owns an immutable copy of the genuine capture/import bytes. Previews never
/// replace this file. Shared recipes retain this owner until exports finish.
final class SourceImageFile: @unchecked Sendable {
    let url: URL
    let fileExtension: String?
    let pixelWidth: Int
    let pixelHeight: Int

    init(data: Data, fileExtension: String?) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { throw PipelineError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        pixelWidth = (5...8).contains(orientation) ? height.intValue : width.intValue
        pixelHeight = (5...8).contains(orientation) ? width.intValue : height.intValue
        self.fileExtension = fileExtension
        // Do not derive any path component from an untrusted imported name.
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-source-\(UUID().uuidString)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Disk-backed processing result, not a full-resolution Swift Float array.
/// Mapped pages and Apple decode/encode allocations still count toward RSS;
/// this is bounded application-owned tile scratch, NOT bounded total memory.
final class ExportRasterFile {
    let url: URL
    let handle: FileHandle
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-raster-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw PipelineError.rendering
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    func append(_ pixels: [Float]) throws {
        try pixels.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }
    func mappedData(expectedBytes: Int) throws -> Data {
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
