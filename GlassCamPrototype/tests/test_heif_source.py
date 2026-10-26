"""Static source contracts only; these do NOT compile Swift or validate a HEIF file."""
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

class HEIFSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline=(ROOT/'ios/GlassCam/ImagePipeline.swift').read_text()
        cls.view=(ROOT/'ios/GlassCam/ContentView.swift').read_text()
        cls.store=(ROOT/'ios/GlassCam/SourceImageStore.swift').read_text()
        cls.bridge=(ROOT/'ios/GlassCam/HNCSEngine.swift').read_text()
        cls.share=(ROOT/'ios/GlassCam/ShareDelivery.swift').read_text()
        cls.core=(ROOT/'core/hncs.cpp').read_text()

    def test_dedicated_ten_bit_writer_has_float_input(self):
        export=self.pipeline.split('static func writeHEIF(',1)[1]
        self.assertIn('HNCSEngine.exportLinearRGBA(',export)
        self.assertIn('format: .RGBAf',export)
        self.assertIn('CGColorSpace.extendedLinearSRGB',export)
        self.assertIn('CGColorSpace.itur_2100_PQ',export)
        self.assertIn('normalizeHighlights(&rgb,',export)
        self.assertIn('restoreHighlights(&rgba, gains: gains)',export)
        self.assertIn('colorSpace?.isHDR() == true',export)
        self.assertIn('encodingContext.writeHEIF10Representation(',export)
        self.assertNotIn('UIImage(',export)
        self.assertNotIn('.RGBA8',export)
        self.assertNotIn('writeHEIFRepresentation(',export)

    def test_user_export_has_no_byte_image_fallback(self):
        for source in (self.pipeline,self.view):
            self.assertNotIn('pngData(',source)
            self.assertNotIn('jpegData(',source)
            self.assertNotIn('.png"',source)
            self.assertNotIn('.jpg"',source)
        self.assertIn('.heic"',self.store)
        self.assertIn('UTType.heic',self.share)
        self.assertIn('registerFileRepresentation',self.share)
        self.assertIn('registerDataRepresentation',self.share)

    def test_snapshot_not_live_controls_drives_export(self):
        export=self.pipeline.split('static func writeHEIF(',1)[1]
        self.assertIn('processed.source',export)
        self.assertIn('recipe: processed.recipe',export)
        self.assertIn('exposureEV: recipe.exposureEV',export)
        self.assertIn('illuminantKelvin: recipe.illuminantKelvin',export)
        self.assertIn('let source: ImportedImage',self.pipeline)
        self.assertIn('TemporaryHEIFFile',self.view)
        self.assertIn('[storage] completion',self.share)

    def test_c_float_route_bypasses_both_byte_encoders(self):
        export=self.core.split('extern "C" int hncs_process_linear_rgba(',1)[1].split('\nextern "C"',1)[0]
        self.assertIn('c->display_linear(c->render(p))',export)
        self.assertNotIn('srgb_encode[',export)
        self.assertNotIn('uint8_t(',export)
        self.assertIn('sizeof(float)/4',export)
        self.assertIn('hncs_process_phocus_linear_rgba_parallel(',self.bridge)
        self.assertIn('workerCount()',self.bridge)

if __name__=='__main__':unittest.main(verbosity=2)
