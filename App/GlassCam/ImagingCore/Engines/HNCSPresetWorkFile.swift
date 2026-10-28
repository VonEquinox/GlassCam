import Foundation

/// Mutable intermediate only: top-to-bottom Float32 RGB matches decoded bitmaps
/// and NumPy grain/spatial coordinates. originY always counts rows from the top.
/// Incomplete or cancelled passes are discarded automatically with this owner.
final class HNCSPresetWorkFile {
    let url: URL
    private let handle: FileHandle
    let width: Int
    let height: Int
    let byteCount: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Int.max / 12 / height else {
            throw PipelineError.invalidImage
        }
        self.width = width; self.height = height; byteCount = width * height * 12
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-hncs-work-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: ImageFileProtection.attributes) else {
            throw PipelineError.rendering
        }
        do { handle = try FileHandle(forUpdating: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func writeTopDownRows(_ rgb: [Float], originY: Int, rows: Int) throws {
        guard originY >= 0, rows > 0, originY <= height - rows,
              rgb.count == width * rows * 3 else { throw PipelineError.rendering }
        try handle.seek(toOffset: UInt64(originY * width * 12))
        try rgb.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }

    func prepareForSpatialPass() throws {
        try handle.synchronize()
        guard try handle.seekToEnd() == UInt64(byteCount) else { throw PipelineError.rendering }
    }

    func readTopDownRows(originY: Int, rows: Int) throws -> [Float] {
        guard originY >= 0, rows > 0, originY <= height - rows else { throw PipelineError.rendering }
        try handle.seek(toOffset: UInt64(originY * width * 12))
        let count = width * rows * 12
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw PipelineError.rendering
        }
        var rgb = [Float](repeating: 0, count: width * rows * 3)
        _ = rgb.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return rgb
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
