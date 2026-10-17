"""Static wiring contracts; not an Apple SDK compile or a display-precision test."""
import unittest
import json
import sys
import numpy as np
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]


class PrecisionPreviewSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline = (ROOT / 'ios/GlassCam/ImagePipeline.swift').read_text()
        cls.preview = ((ROOT / 'ios/GlassCam/PreviewRaster.swift').read_text() + '\n' +
                       (ROOT / 'ios/GlassCam/PrecisionPreview.swift').read_text())
        cls.process = cls.pipeline.split('static func process(', 1)[1].split('static func writeHEIF(', 1)[0]

    def test_both_engines_use_float_preview_output(self):
        self.assertIn('var rgba: [Float]', self.process)
        self.assertIn('HNCSEngine.exportLinearRGBA(', self.process)
        self.assertIn('FFCSEngine.exportLinearRGBA(', self.process)
        for forbidden in ('[UInt8]', 'CGImage(', 'UIImage(', '.process(', 'CGDataProvider', '.RGBA8'):
            self.assertNotIn(forbidden, self.process)

    def test_source_and_processed_are_owned_float_rasters(self):
        self.assertIn('let original: PreviewRaster', self.pipeline)
        self.assertIn('let image: PreviewRaster', self.pipeline)
        self.assertIn('PreviewRaster(linearRGBA: pixels', self.pipeline)
        self.assertIn('private let storage: Data', self.preview)
        self.assertIn('Data($0)', self.preview)
        self.assertIn('format: .RGBAf, colorSpace: space', self.preview)
        self.assertNotIn('createCGImage', self.pipeline)
        self.assertIn('linearRGBA.allSatisfy({ $0.isFinite })', self.preview)
        self.assertIn('width <= Int.max / 16 / height', self.preview)

    def test_float_render_target_preserves_hdr(self):
        self.assertIn('view.colorPixelFormat = .rgba16Float', self.preview)
        self.assertIn('view.framebufferOnly = false', self.preview)
        self.assertIn('view.sampleCount = 1', self.preview)
        self.assertIn('layer.colorspace = context.coordinator.colorSpace', self.preview)
        self.assertIn('PreviewDisplay.configure(layer, headroom:', self.preview)
        self.assertIn('layer.contentsHeadroom = CGFloat(peak)', self.preview)
        self.assertIn('layer.toneMapMode = .ifSupported', self.preview)
        self.assertIn('CGColorSpace.extendedLinearSRGB', self.preview)
        self.assertIn('.workingFormat: CIFormat.RGBAf.rawValue', self.preview)
        self.assertIn('PreviewRendering.render(output, with: context, to: drawable.texture,', self.preview)
        self.assertIn('destination.colorSpace = colorSpace', self.preview)
        self.assertIn('destination.isFlipped = true', self.preview)
        self.assertIn('CIColorClamp', self.preview)
        self.assertIn('ImagePipeline.maximumHDRValue', self.preview)
        self.assertNotIn('CIVector(x: 1, y: 1, z: 1, w: 1)', self.preview)
        for forbidden in ('UIImage(', 'createCGImage', '.bgra8Unorm', '.RGBA8', '.RGBAh'):
            self.assertNotIn(forbidden, self.preview)

    def test_wipe_is_gpu_only_and_redraw_is_demand_driven(self):
        self.assertIn('view.isPaused = true', self.preview)
        self.assertIn('view.enableSetNeedsDisplay = true', self.preview)
        self.assertIn('self.source !== source || self.processed !== processed || fraction != bounded', self.preview)
        self.assertIn('effect.cropped(to: left).composited(over: output)', self.preview)
        self.assertIn('processed.width == source.width', self.preview)
        self.assertIn('commandBuffer.present(drawable)', self.preview)
        self.assertIn('commandBuffer.commit()', self.preview)
        self.assertIn('withExtendedLifetime((owners, renderTask))', self.preview)
        self.assertNotIn('HNCSEngine.', self.preview)
        self.assertNotIn('FFCSEngine.', self.preview)
        self.assertNotIn('toBitmap:', self.preview.split('func draw(in', 1)[1])

    def test_errors_are_visible_without_byte_fallback(self):
        self.assertIn('installStatusOverlay(in: view)', self.preview)
        self.assertIn('device == nil || queue == nil || context == nil', self.preview)
        self.assertIn('buffer.status == .error', self.preview)
        self.assertIn('DispatchQueue.main.async', self.preview)
        self.assertIn('statusLabel?.isHidden = message == nil', self.preview)
        self.assertIn('thumbnail.bitsPerComponent', self.pipeline)
        self.assertIn('not sensor-native bit depth', self.pipeline)

    def test_no_second_exif_orientation_transform(self):
        self.assertIn('kCGImageSourceCreateThumbnailWithTransform', self.pipeline)
        self.assertIn('raw.orientation = orientation', self.pipeline)
        self.assertNotIn('.oriented(', self.preview)
        self.assertIn('source precision limits', self.pipeline)


def storage_precision_report():
    # Pure software IEEE-754 binary16 model. This does not run Core Image,
    # Metal, the compositor, source decoding, or an Apple physical panel.
    linear = np.linspace(0, 1, 4096, dtype=np.float64)
    stored = linear.astype(np.float16).astype(np.float64)
    def encode_srgb(x):
        return np.where(x <= 0.0031308, 12.92 * x, 1.055 * x ** (1 / 2.4) - 0.055)
    swatches = np.array([[0, 0, 0, 1], [1, 1, 1, 1], [1, 0, 0, 1],
                         [0, 1, 0, 1], [0, 0, 1, 1], [0.5, 0.25, 0.125, 0.5]], dtype=np.float64)
    # Every positive binary16 level in [0,1], including subnormals. For
    # round-to-nearest, the limiting error for each monotone half-bin occurs
    # at its midpoint; evaluate both neighboring storage outcomes there.
    levels = np.arange(0, 0x3c01, dtype=np.uint16).view(np.float16).astype(np.float64)
    midpoints = (levels[:-1] + levels[1:]) / 2
    bin_linear = np.max((levels[1:] - levels[:-1]) / 2)
    bin_encoded = np.max(np.maximum(encode_srgb(midpoints) - encode_srgb(levels[:-1]),
                                   encode_srgb(levels[1:]) - encode_srgb(midpoints)))
    ten_bit_step = 1 / 1023
    return {
        "scope": "Software float16 final-display-storage quantization only; not an Apple SDK, GPU, compositor, source-depth, orientation, or physical-panel test",
        "input_sample_count": len(linear),
        "all_binary16_bins_checked": len(midpoints),
        "all_bin_linear_limit": float(bin_linear),
        "all_bin_srgb_limit": float(bin_encoded),
        "distinct_float16_linear_levels": int(np.unique(stored).size),
        "linear_max_absolute_error": float(np.max(np.abs(linear - stored))),
        "srgb_encoded_max_absolute_error": float(np.max(np.abs(encode_srgb(linear) - encode_srgb(stored)))),
        "declared_comparison_budget": "half one normalized 10-bit step (1 / (2 * 1023)); bounds checked in both linear and sRGB-encoded domains",
        "error_budget": ten_bit_step / 2,
        "primary_and_alpha_swatches_exact": bool(np.array_equal(swatches, swatches.astype(np.float16).astype(np.float64))),
        "opaque_alpha_exact": bool(np.all(np.ones(4096).astype(np.float16) == 1)),
        "range_is_sdr": bool(stored.min() == 0 and stored.max() == 1),
    }


class PrecisionPreviewNumericContracts(unittest.TestCase):
    def test_half_storage_exceeds_eight_bit_and_meets_quantization_budget(self):
        result = storage_precision_report()
        self.assertGreater(result['distinct_float16_linear_levels'], 256)
        self.assertLessEqual(result['linear_max_absolute_error'], result['error_budget'])
        self.assertLessEqual(result['srgb_encoded_max_absolute_error'], result['error_budget'])
        self.assertTrue(result['range_is_sdr'])

    def test_all_binary16_storage_bins_meet_budget(self):
        result = storage_precision_report()
        self.assertEqual(result['all_binary16_bins_checked'], 15360)
        self.assertLessEqual(result['all_bin_linear_limit'], result['error_budget'])
        self.assertLessEqual(result['all_bin_srgb_limit'], result['error_budget'])

    def test_primary_and_alpha_values_survive_display_storage(self):
        result = storage_precision_report()
        self.assertTrue(result['primary_and_alpha_swatches_exact'])
        self.assertTrue(result['opaque_alpha_exact'])


if __name__ == '__main__':
    if '--write-report' in sys.argv:
        sys.argv.remove('--write-report')
        (ROOT / 'validation/precision-preview-storage.json').write_text(
            json.dumps(storage_precision_report(), indent=2) + '\n')
    unittest.main(verbosity=2)
