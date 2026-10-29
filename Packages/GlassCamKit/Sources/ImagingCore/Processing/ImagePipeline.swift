import Foundation
import CoreImage
import ImageIO

/// Explicit cancellation crosses the GCD decoder queue; it does not depend on
/// Swift task-local cancellation surviving a synchronous DispatchQueue hop.
final class ImageOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

public struct ImportedImage: @unchecked Sendable {
    public let sourceFile: SourceImageFile
    let exportSettings: ExportSettings
    let linearRGB: [Float]
    public let width: Int
    public let height: Int
    public let original: PreviewRaster
    let sourceDescription: String
    public let whiteBalance: PhotoWhiteBalance
    let rawDecode: RAWDecodeRecipe
    /// Pinned input settings before any color engine overrides. Retain these
    /// across re-decodes so changing engines cannot inherit the previous one.
    let baseRAWDecode: RAWDecodeRecipe
    let previewMaximumEdge: Int
    let sourceISO: Int?

    init(sourceFile: SourceImageFile, exportSettings: ExportSettings, linearRGB: [Float],
         width: Int, height: Int, original: PreviewRaster, sourceDescription: String,
         whiteBalance: PhotoWhiteBalance = .renderedD65, rawDecode: RAWDecodeRecipe = .current,
         sourceISO: Int? = nil, baseRAWDecode: RAWDecodeRecipe? = nil,
         previewMaximumEdge: Int? = nil) {
        self.sourceFile = sourceFile; self.exportSettings = exportSettings; self.linearRGB = linearRGB
        self.width = width; self.height = height; self.original = original
        self.sourceDescription = sourceDescription; self.whiteBalance = whiteBalance; self.rawDecode = rawDecode
        self.baseRAWDecode = baseRAWDecode ?? rawDecode
        self.previewMaximumEdge = previewMaximumEdge ?? max(width, height)
        self.sourceISO = sourceISO
    }
}

public struct ProcessedImage: @unchecked Sendable {
    public let image: PreviewRaster
    let comparisonSource: PreviewRaster
    // Snapshot belongs to this rendered preview, not the current slider positions.
    // Source and processed previews retain immutable Float32 rasters for GPU display.
    public let source: ImportedImage
    public let recipe: ProcessingRecipe
    public var exposureEV: Double { recipe.exposureEV }
    public var illuminantKelvin: Double { recipe.illuminantKelvin }
}

/// Experimental source adaptation. This is not a calibrated camera-native RGB profile.
/// Core Image honors embedded profiles and converts to extended linear sRGB.
/// Only the display preview is reduced. Export always reloads the immutable source.
public enum ImagePipeline {
    static let maximumEdge: CGFloat = 2048
    // PQ represents up to 10,000 nits; Core Image's HDR reference white is 203 nits.
    public static let maximumHDRValue: Float = 10_000 / 203

    // A cancelled detached task may finish its current decoder call. Serialize the
    // complete decode/render stage so superseded RAW decodes never overlap.
    static let decodeQueue = DispatchQueue(label: "dev.glasscam.decode", qos: .userInitiated)

    /// Export from the retained full-resolution capture, with its immutable recipe.
    /// Full-resolution color processing precedes reduction to the output size.
    /// Native processing reuses bounded buffers; system RAW/CI/HEIF operations
    /// may allocate full-size internal surfaces.
    public static func writeHEIF(resources: ColorResources, _ processed: ProcessedImage, to url: URL,
                          settings: ExportSettings? = nil,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        try decodeQueue.sync {
            try autoreleasepool {
                try exportFullSource(resources: resources, processed.source.sourceFile, whiteBalance: processed.source.whiteBalance,
                    recipe: processed.recipe, to: url, settings: settings ?? processed.source.exportSettings, rawDecode: processed.source.rawDecode,
                    isCancelled: isCancelled, progress: progress)
            }
        }
    }

    /// Automatic capture needs only the final HEIF and its review image. Read
    /// the as-shot metadata without decoding/processing a discarded RAW preview.
    @discardableResult
    public static func writeHEIF(resources: ColorResources, sourceFile: SourceImageFile, recipe: ProcessingRecipe, to url: URL,
                          settings: ExportSettings, rawDecode: RAWDecodeRecipe = .current,
                          isCancelled: @escaping @Sendable () -> Bool = { false },
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws -> ProcessingRecipe {
        try decodeQueue.sync {
            try autoreleasepool {
                try checkExportCancellation(isCancelled)
                guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
                var whiteBalance = PhotoWhiteBalance.renderedD65
                var resolvedRAWDecode = rawDecode
                var captureISO: Int?
                if ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? "") {
                    guard let raw = CIRAWFilter(imageURL: sourceFile.url) else { throw PipelineError.invalidImage }
                    let frozenWhite = recipe.photoWhiteBalance?.origin == .appleRAW ? recipe.photoWhiteBalance : nil
                    resolvedRAWDecode = try configureRAW(raw, recipe: recipe.sourceDecodeRecipe(rawDecode), whiteBalance: frozenWhite)
                    whiteBalance = frozenWhite ?? .asShot(raw)
                    captureISO = sourceISO(in: raw.properties)
                }
                let resolved = recipe.resolvingWhiteBalance(whiteBalance).resolvingLUMIXSourceISO(captureISO)
                try exportFullSource(resources: resources, sourceFile, whiteBalance: whiteBalance, recipe: resolved,
                    to: url, settings: settings, rawDecode: resolvedRAWDecode, isCancelled: isCancelled, progress: progress,
                    onSourceDimensions: onSourceDimensions)
                return resolved
            }
        }
    }

    /// Characterized scene-linear RGB enters without another RAW decode.
    package static func writeLinearHEIF(resources: ColorResources, _ image: any SceneLinearImage, metadata: PhotoMetadata, recipe: ProcessingRecipe, to url: URL,
                           isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) throws -> ProcessingRecipe {
        try decodeQueue.sync {
            let white = try image.validatedWhiteBalance()
            let resolved = recipe.resolvingWhiteBalance(white).resolvingLUMIXSourceISO(image.sourceISO)
            try exportLinearSource(resources: resources, image.image,metadata:metadata,recipe:resolved,to:url,settings:.native,rawDecode:.sceneLinear,
                isCancelled:isCancelled,progress:progress)
            return resolved
        }
    }

    static func checkExportCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func exportFullSource(resources: ColorResources, _ sourceFile: SourceImageFile, whiteBalance: PhotoWhiteBalance,
                                          recipe: ProcessingRecipe, to url: URL,
                                          settings: ExportSettings, rawDecode: RAWDecodeRecipe, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          onSourceDimensions: ((Int, Int) -> Void)? = nil) throws {
        try checkExportCancellation(isCancelled)
        progress(0)
        let stabilizeRAWDecode = recipe.pipelineRevision >= 2 && rawDecode.sharpnessAmount != 0 &&
            ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? "")
        let decoded = try fullSourceImage(sourceFile, whiteBalance: whiteBalance, rawDecode: rawDecode,
            stabilizeRAWDecode: stabilizeRAWDecode)
        try exportLinearSource(resources: resources, decoded, metadata: sourceFile.metadata, recipe: recipe, to: url, settings: settings,
            rawDecode: rawDecode, isCancelled: isCancelled, progress: progress,
            onSourceDimensions: onSourceDimensions, releaseSourceCache: stabilizeRAWDecode,
            sourceIsRAW: ["dng", "raw"].contains(sourceFile.fileExtension?.lowercased() ?? ""))
    }

}
