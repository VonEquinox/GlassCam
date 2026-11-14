import CMetalImage

/// Packed pixel handoffs shared by preview and strip export.
enum FloatRasterOperations {
    static func validate(_ values: [Float],
                         range: ClosedRange<Float> = -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude) throws {
        let success = values.withUnsafeBufferPointer {
            gc_float_range_valid($0.baseAddress, $0.count, range.lowerBound, range.upperBound)
        }
        guard success == 1 else { throw PipelineError.rendering }
    }

    static func rgb(fromRGBA input: [Float]) throws -> [Float] {
        guard input.count % 4 == 0 else { throw PipelineError.rendering }
        var output = [Float](repeating: 0, count: input.count / 4 * 3)
        let success = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                gc_float_rgba_to_rgb(source.baseAddress, input.count / 4, $0.baseAddress)
            }
        }
        guard success == 1 else { throw PipelineError.rendering }
        return output
    }

    static func rgba(fromRGB input: [Float]) throws -> [Float] {
        guard input.count % 3 == 0, input.count / 3 <= Int.max / 4 else { throw PipelineError.rendering }
        var output = [Float](repeating: 0, count: input.count / 3 * 4)
        let success = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                gc_float_rgb_to_rgba(source.baseAddress, input.count / 3, $0.baseAddress)
            }
        }
        guard success == 1 else { throw PipelineError.rendering }
        return output
    }
}
