import Foundation
import CoreImage
import ImageIO

private enum AuditFailure: Error { case checks([String]) }

@main struct ColorChainChecks {
    static func main() throws {
        let resources = ColorResources(resourceDirectory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        func pixels(_ image: CIImage) -> [Float] {
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var result = [Float](repeating: 0, count: w*h*4)
            result.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: image.extent,
                               format: .RGBAf, colorSpace: linear)
            }
            return result
        }
        let width = 33, height = 131
        let colors: [[Float]] = [[0,0,0], [0.001,0.002,0.003], [0.18,0.18,0.18], [1,1,1], [2,2,2],
            [4,1,0.2], [0.1,3,0.2], [0.2,0.1,2], [1,0.2,0.01], [0.02,0.3,1], [8,4,2]]
        let data: [Float] = (0..<(width*height)).flatMap { colors[$0 % colors.count]+[Float(1)] }
        let sourceURL = directory.appendingPathComponent("exposure.tiff")
        let raster = try PreviewRaster(linearRGBA: data, width: width, height: height)
        try context.writeTIFFRepresentation(of: raster.image, to: sourceURL, format: .RGBAf, colorSpace: linear, options: [:])
        let retained = try SourceImageFile(data: Data(contentsOf: sourceURL), fileExtension: "tiff")
        // Use full-source decoded floats, independent of ImageIO thumbnails.
        let decoded = pixels(CIImage(contentsOf: sourceURL, options: [.expandToHDR: true])!)
        func input(_ values: [Float]) throws -> ImportedImage {
            ImportedImage(sourceFile: retained, exportSettings: .native,
                linearRGB: (0..<(width*height)).flatMap { Array(values[($0*4)..<($0*4+3)]) },
                width: width, height: height,
                original: try PreviewRaster(linearRGBA: values, width: width, height: height), sourceDescription: "Audit")
        }
        let source = try input(decoded)
        func recipe(_ mode: ColorMode, _ ev: Double, revision: Int = ProcessingRecipe.currentPipelineRevision,
                    spatial: Bool = false, white: PhotoWhiteBalance? = nil) -> ProcessingRecipe {
            ProcessingRecipe(mode: mode, exposureEV: ev, illuminantKelvin: white?.modelKelvin ?? 6500,
                simulationIndex: 0, seed: 0, hncs: .standard,
                effects: EffectToggles(applyGrain: spatial, applySharpness: spatial),
                ffcs: FFCSSettings(applyReferenceAdjustments: spatial), photoWhiteBalance: white,
                pipelineRevision: revision)
        }
        var records = [[String: Any]](), failures = [String]()
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        func error(_ a: [Float], _ b: [Float]) -> Float {
            guard a.count == b.count else { return .greatestFiniteMagnitude }
            var maximum: Float = 0
            for i in a.indices { maximum = max(maximum, abs(a[i]-b[i])) }
            return maximum
        }
        for mode in ColorMode.allCases {
            for ev: Double in [-2,-1,-0.3,0,0.7,1,2] {
                let result = try ImagePipeline.process(resources: resources, source, recipe: recipe(mode, ev))
                var scaled = decoded
                for pixel in 0..<(width*height) { for c in 0..<3 { scaled[pixel*4+c] *= Float(exp2(ev)) } }
                let expected = try ImagePipeline.process(resources: resources, input(scaled), recipe: recipe(mode, 0))
                let actualPixels = pixels(result.image.image), expectedPixels = pixels(expected.image.image)
                let delta = error(actualPixels, expectedPixels)
                records.append(["mode": mode.rawValue, "exposureEV": ev, "maxErrorFromScalingSource": delta,
                    "gray2": Array(actualPixels[16..<19]), "saturated": Array(actualPixels[20..<23])])
                check(delta <= 0.00001, "\(mode.rawValue) EV \(ev) changed HDR exposure/color: \(delta)")
            }
        }
        // Frozen output from the production pipeline before this audit. Old
        // journals lack a version and must keep these values, even when wrong.
        let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../fixtures/color-pipeline/color-pipeline-v1-exposure.json")
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as! [String: Any]
        for row in golden["cases"] as! [[String: Any]] {
            let mode = ColorMode(rawValue: row["mode"] as! String)!, ev = (row["exposureEV"] as! NSNumber).doubleValue
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe(mode, ev))) as! [String: Any]
            object.removeValue(forKey: "pipelineRevision")
            let legacy = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
            let output = try ImagePipeline.process(resources: resources, source, recipe: legacy)
            let values = pixels(output.image.image)
            check(output.recipe.pipelineRevision == 1, "Binding metadata migrated a frozen pipeline")
            check(error(Array(values[16..<19]), (row["gray2"] as! [NSNumber]).map(\.floatValue)) < 0.00001 &&
                  error(Array(values[20..<23]), (row["saturated"] as! [NSNumber]).map(\.floatValue)) < 0.00001,
                  "Legacy \(mode) EV \(ev) changed")
        }
        // Exercise the real full-source row/halo/spatial paths, not only the
        // preview's whole-buffer dispatch. HEIF byte equality includes metadata.
        for mode in ColorMode.allCases {
            for spatial in [false, true] {
                for ev: Double in [-1,1] {
                    let target = recipe(mode, ev, spatial: spatial)
                    let processed = try ImagePipeline.process(resources: resources, source, recipe: target)
                    var scaled = decoded
                    for p in 0..<(width*height) { for c in 0..<3 { scaled[p*4+c] *= Float(exp2(ev)) } }
                    let oracle = try ImagePipeline.process(resources: resources, input(scaled), recipe: recipe(mode, 0, spatial: spatial))
                    check(error(pixels(processed.image.image), pixels(oracle.image.image)) < 0.00001,
                          "\(mode) spatial exposure differs from scaling the source")
                    let stem = "\(mode.rawValue)-\(spatial)-\(ev)"
                    let output = directory.appendingPathComponent(stem+".heic")
                    let direct = directory.appendingPathComponent(stem+"-direct.heic")
                    try ImagePipeline.writeHEIF(resources: resources, processed, to: output)
                    let bound = try ImagePipeline.writeHEIF(resources: resources, sourceFile: retained, recipe: target, to: direct, settings: .native)
                    let outputData = try Data(contentsOf: output), directData = try Data(contentsOf: direct)
                    check(outputData == directData && bound == processed.recipe,
                          "\(stem) direct and previewed full-source exports differ")
                    let fullReference = directory.appendingPathComponent(stem+"-whole.heic")
                    let targetContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                                                           .workingFormat: CIFormat.RGBAf.rawValue])
                    var expected = oracle.image.image.applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0,y: 0,z: 0,w: 1),
                        "inputMaxComponents": CIVector(x: CGFloat(ImagePipeline.maximumHDRValue), y: CGFloat(ImagePipeline.maximumHDRValue),
                                                        z: CGFloat(ImagePipeline.maximumHDRValue), w: 1)]).cropped(to: oracle.image.image.extent)
                    if #available(macOS 26, *) { expected = expected.settingContentHeadroom(oracle.image.headroom) }
                    try targetContext.writeHEIF10Representation(of: expected, to: fullReference,
                        colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, options: [:])
                    let stripError = error(pixels(CIImage(contentsOf: output, options: [.expandToHDR: true])!),
                                           pixels(CIImage(contentsOf: fullReference, options: [.expandToHDR: true])!))
                    check(stripError < 0.02, "\(stem) strip/halo export differs from the whole-image oracle: \(stripError)")
                }
            }
        }
        var rawRecords = [[String: Any]]()
        for (index, path) in CommandLine.arguments.dropFirst(3).enumerated() {
            let rawURL = URL(fileURLWithPath: path), rawData = try Data(contentsOf: rawURL)
            let photo = try ImagePipeline.load(data: rawData, fileExtension: "dng", previewMaximumEdge: 512)
            let raw = CIRAWFilter(imageURL: rawURL)!
            raw.neutralTemperature = 4200; raw.neutralTint = 12
            let frozen = PhotoWhiteBalance.asShot(raw)
            for mode in ColorMode.allCases {
                let target = recipe(mode, 0)
                let actual = try ImagePipeline.process(resources: resources, photo, recipe: target)
                let inspection = try ImagePipeline.inspectRAW(sourceFile: photo.sourceFile, recipe: actual.source.rawDecode)
                let configured = inspection["configured"] as! [String: Any], defaults = inspection["defaults"] as! [String: Any]
                check((configured["boost_amount"] as! NSNumber).floatValue == 0 &&
                      (configured["baseline_exposure"] as! NSNumber) == (defaults["baseline_exposure"] as! NSNumber) &&
                      (configured["local_tone_map_amount"] as! NSNumber) == (defaults["local_tone_map_amount"] as! NSNumber),
                      "\(mode) did not retain the contrast repair on RAW \(index)")
                let frozenRecipe = recipe(mode, 0.7, white: frozen)
                let replay = try ImagePipeline.process(resources: resources, actual.source, recipe: frozenRecipe)
                check(replay.source.whiteBalance == frozen && replay.recipe.photoWhiteBalance == frozen,
                      "\(mode) decoder and color engine disagree on frozen WB")
                // Independent Core Image decode with the frozen xy, to ensure
                // the pixels changed too, rather than only their metadata label.
                let oracle = CIRAWFilter(imageURL: rawURL)!
                oracle.boostAmount = 0; oracle.extendedDynamicRangeAmount = 1
                if mode == .hncs && oracle.isSharpnessSupported { oracle.sharpnessAmount = 0 }
                oracle.neutralChromaticity = CGPoint(x: frozen.x, y: frozen.y)
                if let orientation = (oracle.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value,
                   let value = CGImagePropertyOrientation(rawValue: orientation) { oracle.orientation = value }
                oracle.scaleFactor = Float(512 / max(oracle.nativeSize.width, oracle.nativeSize.height))
                var image = oracle.outputImage!
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let scale = min(1, 512 / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .cropped(to: CGRect(x: 0,y: 0,width: replay.source.width,height: replay.source.height))
                check(error(pixels(replay.source.original.image), pixels(image)) < 0.00001,
                      "\(mode) frozen WB was not applied to actual decoded pixels")
                let afterURL = directory.appendingPathComponent("raw-\(index)-\(mode.rawValue)-frozen.heic")
                let directURL = directory.appendingPathComponent("raw-\(index)-\(mode.rawValue)-direct.heic")
                try ImagePipeline.writeHEIF(resources: resources, replay, to: afterURL)
                let direct = try ImagePipeline.writeHEIF(resources: resources, sourceFile: photo.sourceFile, recipe: frozenRecipe,
                    to: directURL, settings: .native)
                let afterData = try Data(contentsOf: afterURL), directData = try Data(contentsOf: directURL)
                let replayError: Float = afterData == directData ? 0 : error(
                    pixels(CIImage(contentsOf: afterURL, options: [.expandToHDR: true])!),
                    pixels(CIImage(contentsOf: directURL, options: [.expandToHDR: true])!))
                check(replayError == 0 && direct == replay.recipe,
                      "\(mode) frozen-WB RAW replay/direct exports differ: pixels \(replayError), recipe equal \(direct == replay.recipe)")
                rawRecords.append(["source": path, "mode": mode.rawValue, "inspection": inspection,
                    "frozenWBSourceMatches": replay.source.whiteBalance == frozen,
                    "directReplayBytesIdentical": afterData == directData, "directReplayPixelError": replayError])
                print("CHECK RAW \(index) \(mode.rawValue): neutral input, frozen WB, full-source export"); fflush(stdout)
            }
        }
        try JSONSerialization.data(withJSONObject: ["exposure": records, "raw": rawRecords, "failures": failures], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("audit.json"))
        if !failures.isEmpty { throw AuditFailure.checks(failures) }
        print("PASS: three engines, HDR exposure, legacy replay, whole/strip/spatial export and frozen RAW white balance")
    }
}
