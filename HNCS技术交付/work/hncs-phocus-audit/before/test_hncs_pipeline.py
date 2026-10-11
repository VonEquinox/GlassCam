"""Numerical checks independent of RAW size or a mounted Phocus installation."""
import unittest
from pathlib import Path

import numpy as np
import hncs_pipeline as hncs


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = hncs.load_assets()

    def test_published_ciede2000_pairs(self):
        path = hncs.WORK / "evidence/ciede2000testdata.txt"
        data = np.loadtxt(path)
        errors = hncs.delta_e_2000(data[:, :3], data[:, 3:6])
        np.testing.assert_allclose(errors, data[:, 6], atol=5e-5, rtol=0)
        np.testing.assert_allclose(hncs.delta_e_2000(data[:, 3:6], data[:, :3]), errors, atol=1e-12)

    def test_known_mapping_recovery(self):
        rng = np.random.default_rng(42)
        source = rng.uniform(.01, .5, (50, 3))
        matrix = np.array([[1.03,-.02,-.01],[-.01,1.02,-.01],[.02,-.04,1.02]])
        fitted = hncs.fit_matrix(source, source @ matrix.T)
        np.testing.assert_allclose(fitted, matrix, atol=1e-12)
        np.testing.assert_allclose(fitted @ np.ones(3), np.ones(3), atol=1e-12)
        with self.assertRaises(ValueError):
            hncs.fit_matrix(np.ones((24, 3)), np.ones((24, 3)))

    def test_lut_coordinate_units_and_edges(self):
        grid = self.assets["grid"]
        cb0, cb1, cr0, cr1, divisor = grid
        xx, yy = np.meshgrid(np.arange(cb0, cb1+1), np.arange(cr0, cr1+1))
        identity = np.stack([xx, yy], axis=-1)
        points = np.array([[0,0],[.33,.12],[-3,4],[4,-3]])
        expected = np.clip(points, [cb0/divisor,cr0/divisor], [cb1/divisor,cr1/divisor])
        np.testing.assert_allclose(hncs.lookup_chroma(points, identity, grid), expected, atol=1e-15)

    def test_gray_black_and_stripe_invariance(self):
        gray = np.repeat(np.linspace(0,1,100)[:, None], 3, axis=1)
        output = hncs.hncs_codes(gray, 8543, self.assets)
        np.testing.assert_array_equal(output[:,0], output[:,1])
        np.testing.assert_array_equal(output[:,1], output[:,2])
        self.assertTrue(np.all(output[0] == 0))
        self.assertTrue(np.all(np.diff(output[:,0].astype(int)) >= 0))
        pixels = np.random.default_rng(1).uniform(-.1,1.1,(10,12,3))
        full = hncs.hncs_codes(pixels,8543,self.assets)
        stripes = np.concatenate([hncs.hncs_codes(part,8543,self.assets) for part in np.array_split(pixels,3)])
        np.testing.assert_array_equal(full,stripes)

    def test_display_gray_and_preview_edges(self):
        codes = np.full((17,21,3), 32768, dtype=np.uint16)
        srgb = hncs.srgb_from_hncs(codes, self.assets)
        self.assertLess(np.max(np.ptp(srgb,axis=-1)),1e-4)
        preview = hncs.make_preview(codes,self.assets,maximum=10)
        self.assertEqual(preview.size,(7,6))
        np.testing.assert_array_equal(np.asarray(preview),np.broadcast_to(np.asarray(preview)[0,0],(6,7,3)))

    def test_srgb_conversion_against_littlecms(self):
        from PIL import Image,ImageCms
        icc = ImageCms.getOpenProfile(str(hncs.ASSETS/"HasselbladLStarRGB.icc"))
        transform = ImageCms.buildTransform(icc,ImageCms.createProfile("sRGB"),"RGB","RGB",renderingIntent=1)
        codes = np.random.default_rng(99).integers(0,256,(32,32,3),dtype=np.uint8)
        reference = np.asarray(ImageCms.applyTransform(Image.fromarray(codes),transform)).astype(int)
        manual = np.rint(hncs.srgb_from_hncs(codes.astype(float)*257,self.assets)*255).astype(int)
        self.assertLessEqual(int(np.max(np.abs(reference-manual))),1)

    def test_nonfinite_rejected(self):
        with self.assertRaises(ValueError):
            hncs.hncs_codes([[np.nan,0,0]],8543,self.assets)


if __name__ == "__main__":
    unittest.main()
