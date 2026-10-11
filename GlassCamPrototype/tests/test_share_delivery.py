"""Static share-delivery contracts, NOT Apple SDK/runtime or recipient validation.

Device tests still required: HEIC/JPEG type negotiation through real extensions,
orientation 1–8, 8/10-bit color/profile, 48 MP memory, concurrent requests,
queued/mid-codec cancellation, disk-full failure, and dismissal during transfer.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ShareDeliveryContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'ios/GlassCam/ShareDelivery.swift').read_text()

    def test_concrete_formats_are_registered_in_fidelity_order(self):
        self.assertIn('for type in [UTType.heic, UTType.jpeg]', self.source)
        self.assertIn('registerFileRepresentation(forTypeIdentifier: type.identifier', self.source)
        self.assertIn('registerDataRepresentation(forTypeIdentifier: type.identifier', self.source)
        self.assertIn('fileOptions: [], visibility: .all', self.source)
        self.assertIn('UIActivityItemsConfiguration(itemProviders:', self.source)
        self.assertNotIn('forTypeIdentifier: UTType.image.identifier', self.source)
        self.assertNotIn('UIImage(', self.source)
        self.assertNotIn('activityType', self.source)
        self.assertNotIn('com.tencent', self.source)

    def test_original_is_not_reencoded_or_renamed_as_jpeg(self):
        self.assertIn('guard compatibility else { return original.url }', self.source)
        self.assertIn('provider.suggestedName = file.url.deletingPathExtension().lastPathComponent', self.source)
        self.assertNotIn('writeHEIF', self.source)
        self.assertNotIn('ImagePipeline.process', self.source)

    def test_jpeg_is_lazy_cached_and_comes_from_final_file(self):
        factory = self.source.split('private final class ShareRepresentationStorage:', 1)[0]
        self.assertNotIn('writeJPEGRepresentation(', factory)
        self.assertIn('if let compatibilityFile { return compatibilityFile.url }', self.source)
        self.assertIn('CIImage(contentsOf: original.url', self.source)
        self.assertIn('compatibilityFile = file', self.source)
        self.assertLess(self.source.index('CGImageSourceGetType(source)'), self.source.index('compatibilityFile = file'))
        self.assertNotIn('processed.image', self.source)
        self.assertNotIn('PHPhotoLibrary', self.source)

    def test_orientation_sdr_and_full_dimensions_are_explicit(self):
        self.assertIn('.applyOrientationProperty: true', self.source)
        self.assertIn('translationX: -decoded.extent.minX', self.source)
        self.assertIn('y: -decoded.extent.minY', self.source)
        self.assertIn('CGColorSpace.sRGB', self.source)
        self.assertIn('.settingProperties([:])', self.source)
        self.assertIn('CIColorClamp', self.source)
        self.assertIn('kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 8', self.source)
        self.assertIn('kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == width', self.source)
        self.assertIn('kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == height', self.source)
        self.assertIn('kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) == 1', self.source)
        self.assertNotIn('CILanczosScaleTransform', self.source)

    def test_work_serialized_and_cancellation_is_cooperative(self):
        self.assertIn('private static let queue = DispatchQueue(', self.source)
        self.assertNotIn('attributes: .concurrent', self.source)
        self.assertEqual(self.source.count('Self.queue.async { [self] in'), 2)
        self.assertEqual(self.source.count('return progress'), 2)
        self.assertIn('if progress.isCancelled { throw CocoaError(.userCancelled) }', self.source)
        encode = self.source.index('try context.writeJPEGRepresentation(')
        after_encode = self.source[encode:]
        self.assertLess(after_encode.index('try Self.checkCancellation(progress)'),
                        after_encode.index('compatibilityFile = file'))
        self.assertIn('<= 100_000_000', self.source)

    def test_provider_and_callbacks_retain_files(self):
        self.assertEqual(self.source.count('{ [storage] completion in'), 2)
        self.assertEqual(self.source.count('withExtendedLifetime(self)'), 2)
        self.assertIn('private let original: TemporaryHEIFFile', self.source)
        self.assertIn('private var compatibilityFile: ShareCompatibilityFile?', self.source)
        self.assertEqual(self.source.count('removeItem(at:'), 1)
        self.assertIn('deinit { try? FileManager.default.removeItem(at: url) }', self.source)
        self.assertNotIn('weak self', self.source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
