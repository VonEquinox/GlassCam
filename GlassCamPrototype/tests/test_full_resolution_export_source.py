"""Static architecture checks; not Apple compilation, pixel tests, or RSS proof."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class FullResolutionExportContracts(unittest.TestCase):
    def setUp(self):
        self.pipeline = (ROOT / 'ios/GlassCam/ImagePipeline.swift').read_text()
        self.export = self.pipeline.split('private static func exportFullSource', 1)[1]
        self.store = (ROOT / 'ios/GlassCam/SourceImageStore.swift').read_text()
        self.settings = (ROOT / 'ios/GlassCam/ExportSettings.swift').read_text()

    def test_original_file_is_retained_and_reloaded(self):
        self.assertIn('let sourceFile: SourceImageFile', self.pipeline)
        self.assertIn('let exportSettings: ExportSettings', self.pipeline)
        self.assertIn('settings ?? processed.source.exportSettings', self.pipeline)
        self.assertIn('try data.write(to: url', self.store)
        self.assertIn('fullSourceImage(processed.source.sourceFile)', self.export)
        self.assertIn('raw.scaleFactor = 1', self.pipeline)
        self.assertNotIn('source.linearRGB', self.export)
        self.assertNotIn('maximumEdge', self.export)

    def test_bounded_scratch_and_global_halo(self):
        self.assertIn('let stripRows = 64', self.export)
        self.assertIn('let inputStart = max(0, start - halo)', self.export)
        self.assertIn('outputOriginY: start', self.export)
        self.assertIn('fullHeight: height', self.export)
        self.assertNotIn('[Float](repeating: 0, count: width * height', self.export)
        self.assertIn('mmap(', self.store)
        self.assertIn('Data(bytesNoCopy:', self.store)
        self.assertIn('munmap(pointer, count)', self.store)
        self.assertIn('withExtendedLifetime((data, raster))', self.export)

    def test_exact_color_precedes_downsampling(self):
        color = self.export.index('FFCSEngine.exportLinearRGBStrip(')
        downsample = self.export.index('CILanczosScaleTransform')
        encode = self.export.index('writeHEIF10Representation')
        self.assertLess(color, downsample)
        self.assertLess(downsample, encode)
        self.assertIn('width <= sourceWidth, height <= sourceHeight', self.settings)
        self.assertIn('CIColorClamp', self.export)
        self.assertIn('kCGImagePropertyDepth', self.export)
        self.assertIn('== 10', self.export)

    def test_hncs_context_is_reused_across_strips(self):
        bridge = (ROOT / 'ios/GlassCam/HNCSEngine.swift').read_text()
        self.assertIn('private static let contextCache = ContextCache()', bridge)
        self.assertIn('cached.exposure == exposure, cached.kelvin == kelvin', bridge)
        self.assertIn('defer { withExtendedLifetime(owner) {} }', bridge)
        self.assertIn('deinit { hncs_destroy(pointer) }', bridge)

    def test_preview_resolution_is_independent(self):
        self.assertIn('previewMaximumEdge: Int = 2048', self.pipeline)
        self.assertIn('(256...4096).contains(previewMaximumEdge)', self.pipeline)
        self.assertIn('settings: ExportSettings', self.export)

if __name__ == '__main__':
    unittest.main()
