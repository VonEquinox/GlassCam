import Foundation
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import CoreImage
import ImageIO

/// One logical image with fidelity-ordered representations. The recipient selects
/// a supported type; this is not an app-specific routing rule or a JPEG export UI.
/// https://developer.apple.com/documentation/foundation/nsitemprovider/registeredcontenttypes
/// https://developer.apple.com/documentation/foundation/nsitemprovider/registeredtypeidentifiers
/// HEIC and JPEG both conform to public.image. Do not register arbitrary bytes as
/// public.image or a UIImage object: concrete types describe the payload honestly.
/// Real recipient extensions (including WeChat) still require device validation.
enum ShareDelivery {
    #if canImport(UIKit)
    static func makeConfiguration(for file: TemporaryHEIFFile) -> UIActivityItemsConfiguration {
        UIActivityItemsConfiguration(itemProviders: [makeProvider(for: file)])
    }
    #endif

    static func makeProvider(for file: TemporaryHEIFFile) -> NSItemProvider {
        let storage = ShareRepresentationStorage(original: file)
        let provider = NSItemProvider()
        // Extensionless suggested name avoids naming negotiated JPEG bytes .heic.
        provider.suggestedName = file.url.deletingPathExtension().lastPathComponent
        // Register all original representations before any lower-fidelity form.
        for type in [UTType.heic, UTType.jpeg] {
            let compatibility = type == .jpeg
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                                 fileOptions: [], visibility: .all) { [storage] completion in
                storage.requestFile(compatibility: compatibility) { result in
                    switch result {
                    case .success(let url): completion(url, false, nil)
                    case .failure(let error): completion(nil, false, error)
                    }
                }
            }
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier,
                                                 visibility: .all) { [storage] completion in
                storage.requestData(compatibility: compatibility, completion: completion)
            }
        }
        return provider
    }
}

/// Ownership graph has no cycle: configuration -> provider -> storage -> files.
/// Each queued request also owns storage until its completion returns. Dismissing
/// the sheet releases UI ownership only; never delete either file in onDismiss or
/// activity completion. File representations are copied by NSItemProvider (not
/// open-in-place). Receivers must consume/copy their URL during their callback.
/// https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)
private final class ShareRepresentationStorage: @unchecked Sendable {
    // Shared serial queue bounds concurrent full-resolution codec work to one.
    // Apple codecs may still allocate full-frame surfaces; this is NOT a bounded
    // peak-RSS claim. Profile 48 MP exports and cancellation on physical devices.
    private static let queue = DispatchQueue(label: "GlassCam.share-delivery", qos: .userInitiated)
    private let original: TemporaryHEIFFile
    // Accessed only on queue; a successful conversion is reused by later loads.
    private var compatibilityFile: ShareCompatibilityFile?

    init(original: TemporaryHEIFFile) { self.original = original }

    func requestFile(compatibility: Bool,
                     completion: @escaping (Result<URL, Error>) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Self.queue.async { [self] in
            withExtendedLifetime(self) {
                autoreleasepool {
                    do {
                        try Self.checkCancellation(progress)
                        let url = try representationURL(compatibility: compatibility, progress: progress)
                        try Self.checkCancellation(progress)
                        progress.completedUnitCount = 1
                        completion(.success(url))
                    } catch { completion(.failure(error)) }
                }
            }
        }
        return progress
    }

    func requestData(compatibility: Bool,
                     completion: @escaping (Data?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Self.queue.async { [self] in
            withExtendedLifetime(self) {
                autoreleasepool {
                    do {
                        try Self.checkCancellation(progress)
                        let url = try representationURL(compatibility: compatibility, progress: progress)
                        // Read off the main thread. Data owns its bytes, independent
                        // of file deletion after the provider finishes its callback.
                        let data = try Data(contentsOf: url)
                        try Self.checkCancellation(progress)
                        progress.completedUnitCount = 1
                        completion(data, nil)
                    } catch { completion(nil, error) }
                }
            }
        }
        return progress
    }

    private static func checkCancellation(_ progress: Progress) throws {
        if progress.isCancelled { throw CocoaError(.userCancelled) }
    }

    private func representationURL(compatibility: Bool, progress: Progress) throws -> URL {
        guard compatibility else { return original.url }
        if let compatibilityFile { return compatibilityFile.url }
        try Self.checkCancellation(progress)
        let file = ShareCompatibilityFile()
        // Decode the finalized, full-resolution HEIF already delivered to the
        // original representation. Never rerender a recipe or use the UI preview.
        guard let decoded = CIImage(contentsOf: original.url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              !decoded.extent.isEmpty, !decoded.extent.isInfinite,
              decoded.extent.width.isFinite, decoded.extent.height.isFinite,
              decoded.extent.width >= 1, decoded.extent.height >= 1,
              decoded.extent.width <= 65_535, decoded.extent.height <= 65_535,
              decoded.extent.width * decoded.extent.height <= 100_000_000 else {
            throw ShareDeliveryError.invalidDimensions
        }
        let width = Int(decoded.extent.width.rounded(.down))
        let height = Int(decoded.extent.height.rounded(.down))
        let metadata = try PhotoMetadata.read(from: original.url)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ShareDeliveryError.colorSpace
        }
        var toneMapParameters: [String: Any] = ["inputTargetHeadroom": 1.0]
        if #available(iOS 26, macOS 26, *) {
            toneMapParameters["inputSourceHeadroom"] = max(1, decoded.contentHeadroom)
        }
        let normalized = decoded.applyingFilter("CIToneMapHeadroom", parameters: toneMapParameters)
            .transformed(by: CGAffineTransform(translationX: -decoded.extent.minX,
                                                                     y: -decoded.extent.minY))
        // Only recipients that request JPEG receive a tone-mapped SDR derivative.
        // Saving and the preferred HEIF representation retain the original HDR.
        let image = normalized.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                       "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            // Alpha clamping expands the extent; restore the finite image bounds.
            .cropped(to: bounds)
            .settingProperties(metadata.encodingProperties(width: width, height: height))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          .workingFormat: CIFormat.RGBAh.rawValue,
                                          .cacheIntermediates: false])
        try Self.checkCancellation(progress)
        // Synchronous Apple encoding cannot be interrupted mid-call; cancellation
        // is checked before and afterward and never delivers a canceled payload.
        try context.writeJPEGRepresentation(of: image, to: file.url, colorSpace: sRGB,
                                            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
        try ImageFileProtection.apply(to: file.url)
        try Self.checkCancellation(progress)
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == height,
              (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 8,
              ((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw ShareDeliveryError.encoding
        }
        try metadata.validate(in: properties)
        compatibilityFile = file // Publish only complete, checked files.
        return file.url
    }
}

/// Failure/cancellation removes a partial JPEG automatically; successful files
/// remain alive as long as the provider or any in-flight request retains storage.
private final class ShareCompatibilityFile {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassCam-share-\(UUID().uuidString).jpg")
    deinit { try? FileManager.default.removeItem(at: url) }
}

private enum ShareDeliveryError: LocalizedError {
    case invalidDimensions, colorSpace, encoding
    var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "This image is too large or could not be decoded for compatible sharing. The original HEIF is still available."
        case .colorSpace: return "Could not prepare the color space for sharing."
        case .encoding: return "Could not create a compatible sharing image. The original HEIF is still available."
        }
    }
}
