import Testing
import NativeTestSupport
import CoreImage

enum HDRColorMetric {
    // User-approved acceptance for the decoded, quality-1.0 HEIF pair.
    static let encodedMaximum = 3.0

    static func statistics(reference: CIImage, actual: CIImage) throws -> [Double] {
        try #require(reference.extent == actual.extent)
        let width = Int(reference.extent.width), height = Int(reference.extent.height)
        func pixels(_ image: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: width * height * 4)
            values.withUnsafeMutableBytes {
                ImagePipelineTests.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: image.extent, format: .RGBAf, colorSpace: ImagePipelineTests.pq)
            }
            return values
        }
        let first = pixels(reference), second = pixels(actual)
        let state = try #require(hdr_metric_create())
        defer { hdr_metric_destroy(state) }
        let status = first.withUnsafeBufferPointer { a in second.withUnsafeBufferPointer { b in
            hdr_metric_add(state, a.baseAddress, b.baseAddress, width * height)
        } }
        try #require(status == 0)
        var result = [Double](repeating: 0, count: 12)
        try #require(hdr_metric_finish(state, &result, result.count) == 0)
        return result
    }
    static func maximum(reference: CIImage, actual: CIImage) throws -> Double {
        try statistics(reference: reference, actual: actual)[5]
    }
}
