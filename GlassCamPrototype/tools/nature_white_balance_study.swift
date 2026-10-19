// Offline study of existing iPhone DNGs and frozen capture recipes.
// Compile with the production Swift sources and C++ core; no device access.
import Foundation
import CoreImage
import ImageIO

private struct StudyFailure: Error { let message: String }

@main struct NatureWhiteBalanceStudy {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: linear,
        .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StudyFailure(message: message) }
    }

    static func pixels(_ image: CIImage, width: Int, height: Int) -> [Float] {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let resized = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                                  y: CGFloat(height) / image.extent.height))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes {
            context.render(resized, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: linear)
        }
        return rgba
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw StudyFailure(message: "Usage: nature-study <existing-checkpoint-directory> <output-directory>")
        }
        let inputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = [:]
        for lens in ["main", "tele", "ultra"] {
            try autoreleasepool {
                let checkpoint = inputDirectory.appendingPathComponent("native-checkpoint-\(lens)")
                let raw = checkpoint.appendingPathComponent("source.dng")
                let record = try JSONDecoder().decode(CaptureJournal.Record.self,
                    from: Data(contentsOf: checkpoint.appendingPathComponent("capture.json")))
                let input = try ImagePipeline.load(data: Data(contentsOf: raw), fileExtension: "dng",
                    previewMaximumEdge: 1024, rawDecode: .current.withoutDecoderSharpness)
                let before = record.snapshot.recipe
                try check(before.hncs.presetKey == "nature" && before.hncs.whiteBalancePolicy == .preset,
                          "Original recipe did not retain Nature's fixed WB")
                var settings = before.hncs; settings.whiteBalancePolicy = .photo
                let after = ProcessingRecipe(mode: before.mode, exposureEV: before.exposureEV,
                    illuminantKelvin: before.illuminantKelvin, simulationIndex: before.simulationIndex,
                    seed: before.seed, hncs: settings, effects: before.effects, ffcs: before.ffcs,
                    photoWhiteBalance: before.photoWhiteBalance)
                let decoderPixels = pixels(input.original.image, width: input.width, height: input.height)
                let mask = stride(from: 0, to: decoderPixels.count, by: 4).filter { index in
                    let channels = decoderPixels[index..<(index + 3)]
                    let mean = channels.reduce(0, +) / 3
                    return mean > 0.08 && mean < 0.8 && channels.max()! - channels.min()! < mean * 0.20
                }
                try check(!mask.isEmpty, "No comparable source pixels")
                func statistics(_ image: CIImage, name: String) throws -> [String: Any] {
                    let values = pixels(image, width: input.width, height: input.height)
                    try check(values.allSatisfy(\.isFinite), "Non-finite output")
                    let raster = try PreviewRaster(linearRGBA: values, width: input.width, height: input.height)
                    try context.writePNGRepresentation(of: raster.image,
                        to: output.appendingPathComponent("\(lens)-\(name).png"), format: .RGBA8,
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
                    var sum = [Double](repeating: 0, count: 3)
                    for index in mask { for channel in 0..<3 { sum[channel] += Double(values[index + channel]) } }
                    let mean = sum.map { $0 / Double(mask.count) }
                    return ["sample_pixels": mask.count, "mean_linear_rgb": mean,
                            "green_over_red_blue": mean[1] / ((mean[0] + mean[2]) / 2)]
                }
                var comparisons: [String: Any] = ["apple": try statistics(input.original.image, name: "apple")]
                var grays: [String: Any] = [:], exports: [String: Any] = [:]
                for (name, recipe) in [("before", before), ("after", after)] {
                    let preview = try ImagePipeline.process(input, recipe: recipe)
                    comparisons[name] = try statistics(preview.image.image, name: name)
                    let gray = try HNCSEngine.exportLinearRGBA(linearSRGB: [Float](repeating: 0.18, count: 16 * 3),
                        width: 4, height: 4, exposureEV: 0, illuminantKelvin: input.whiteBalance.modelKelvin!,
                        settings: recipe.hncs, effects: .init(applyGrain: false, applySharpness: false, applyExtraCrop: false),
                        whiteBalance: input.whiteBalance)
                    grays[name] = Array(gray.prefix(3))
                    if name == "after" {
                        try check(abs(gray[1] / ((gray[0] + gray[2]) / 2) - 1) < 0.025,
                                  "Corrected Nature introduced neutral green cast")
                    }
                    let file = output.appendingPathComponent("\(lens)-\(name)-48mp.heic")
                    print("Offline full-source export:", lens, name); fflush(stdout)
                    let resolved = try ImagePipeline.writeHEIF(sourceFile: input.sourceFile, recipe: recipe,
                        to: file, settings: record.snapshot.output)
                    try check(resolved.photoWhiteBalance == input.whiteBalance && resolved.hncs == recipe.hncs,
                              "Full export changed frozen WB")
                    try JSONEncoder().encode(resolved).write(to: output.appendingPathComponent("\(lens)-\(name)-recipe.json"))
                    guard let image = CIImage(contentsOf: file, options: [.applyOrientationProperty: true, .expandToHDR: true]),
                          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                        throw StudyFailure(message: "HEIF readback failed")
                    }
                    let width = (metadata[kCGImagePropertyPixelWidth as String] as! NSNumber).intValue
                    let height = (metadata[kCGImagePropertyPixelHeight as String] as! NSNumber).intValue
                    let depth = (metadata[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? 0
                    try check(min(width, height) == 6048 && max(width, height) == 8064,
                              "48MP output dimensions changed")
                    try check(depth == 10 && image.colorSpace?.isHDR() == true, "10-bit HDR lost")
                    let maximum = pixels(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]),
                                         width: 1, height: 1).prefix(3).max()!
                    try check(maximum.isFinite && maximum > 1, "RAW superwhite highlights lost")
                    let values = try statistics(image, name: name + "-heif")
                    exports[name] = ["file": file.path, "width": width, "height": height, "depth": depth,
                                     "hdr": true, "decoded_peak": maximum, "same_source_low_chroma_mask": values]
                }
                report[lens] = ["source": raw.path, "source_white_balance": input.whiteBalance.description,
                                "xy": [input.whiteBalance.x, input.whiteBalance.y],
                                "synthetic_18_percent_gray": grays,
                                "preview_same_source_low_chroma_mask": comparisons, "full_source_exports": exports]
                print("PASS: existing", lens, "RAW before/after, frozen WB, 48MP 10-bit HDR readback"); fflush(stdout)
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("existing-photo-comparison.json"))
    }
}
