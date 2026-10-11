"""Numerical checks independent of RAW size or a mounted Phocus installation."""
import unittest
import json
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
        # The X2D II constructor disables gray suppression; the factory LUT can
        # impart a small chroma to the ideal gray axis. Native vectors below are
        # the reference, rather than an invented exact-neutral requirement.
        self.assertTrue(np.all(output[0] == 0))
        self.assertTrue(np.all(np.diff(output[:,0].astype(int)) >= 0))
        pixels = np.random.default_rng(1).uniform(-.1,1.1,(10,12,3))
        full = hncs.hncs_codes(pixels,8543,self.assets)
        stripes = np.concatenate([hncs.hncs_codes(part,8543,self.assets) for part in np.array_split(pixels,3)])
        np.testing.assert_array_equal(full,stripes)

    def test_original_native_constructor_pixel_vectors(self):
        fixture=hncs.ROOT/"work/hncs-phocus-audit/evidence/native_kernel_vectors.npz"
        with np.load(fixture,allow_pickle=False) as vectors:
            for key in vectors.files:
                if not key.endswith("_source"):continue
                space,intent,cct,_=key.split("_")
                with self.subTest(space=space,intent=intent,cct=cct):
                    output=hncs.hncs_codes(vectors[key].astype(float)/65535,int(cct),self.assets,
                                          intent,working_space=space)
                    np.testing.assert_array_equal(output,vectors[key.replace("_source","_output")])

    def test_native_white_balance_temperatures(self):
        cases=[([3.0961562250467036,1,1.4125250692805533],7625,-.00348857057127788),
               ([3.06964111328125,1,1.41644287109375],7523,-.0029978693702864215),
               ([1.745325,1,2.66163],3029,.0023608162301916448),
               ([2.5807854005,1,1.8029560805],5019,-.0031438693618597207),
               ([3.14375,1,1.32796725],8607,-.0013610530633383436)]
        for wb,expected_temp,expected_tint in cases:
            temp,tint=hncs.estimate_cct(wb,self.assets)
            self.assertEqual(temp,expected_temp)
            self.assertAlmostEqual(tint,expected_tint,places=12)

    def test_display_gray_and_preview_edges(self):
        codes = np.full((17,21,3), 32768, dtype=np.uint16)
        srgb = hncs.srgb_from_hncs(codes, self.assets)
        self.assertLess(np.max(np.ptp(srgb,axis=-1)),1e-4)
        preview = hncs.make_preview(codes,self.assets,maximum=10)
        self.assertEqual(preview.size,(7,6))
        np.testing.assert_array_equal(np.asarray(preview),np.broadcast_to(np.asarray(preview)[0,0],(6,7,3)))

    def test_srgb_conversion_against_littlecms(self):
        from PIL import Image,ImageCms
        codes = np.random.default_rng(99).integers(0,256,(32,32,3),dtype=np.uint8)
        for space,name in (("lstar","HasselbladLStarRGB.icc"),("legacy","HasselbladRGB.icc")):
            icc = ImageCms.getOpenProfile(str(hncs.ASSETS/name))
            transform = ImageCms.buildTransform(icc,ImageCms.createProfile("sRGB"),"RGB","RGB",renderingIntent=1)
            reference = np.asarray(ImageCms.applyTransform(Image.fromarray(codes),transform)).astype(int)
            manual = np.rint(hncs.srgb_from_hncs(codes.astype(float)*257,self.assets,space)*255).astype(int)
            self.assertLessEqual(int(np.max(np.abs(reference-manual))),1)

    def test_nonfinite_rejected(self):
        with self.assertRaises(ValueError):
            hncs.hncs_codes([[np.nan,0,0]],8543,self.assets)

    def test_bridge_preserves_calibration_pixels_and_neutral_exposure(self):
        profile=json.loads(hncs.PROFILE.read_text())
        original=np.array(profile["matrix"])
        adapted,target_wb,gain=hncs.bridge_white_balance(profile,profile["source_wb"])
        np.testing.assert_array_equal(adapted,original)
        np.testing.assert_array_equal(target_wb,profile["target_wb"])
        self.assertEqual(gain,1.)
        pixels=np.random.default_rng(17).uniform(0,.7,(2000,3))
        np.testing.assert_array_equal(
            hncs.hncs_codes(pixels @ adapted.T,profile["target_cct"],self.assets,working_space="legacy"),
            hncs.hncs_codes(pixels @ original.T,profile["target_cct"],self.assets,working_space="legacy"))
        for wb in ([1.7,1,3.],[2.5,1,1.6],[3.5,1,1.]):
            scene,virtual,gain=hncs.bridge_white_balance(profile,wb)
            np.testing.assert_allclose(scene@np.ones(3),np.ones(3),atol=3e-15,rtol=0)
            for level in (.01,.18,.8):
                # A raw neutral defined by the selected source WB stays neutral
                # at the same exposure before the independent HNCS colour core.
                raw_neutral=level/np.array(wb)
                mapped=(raw_neutral*np.array(wb))@scene.T
                np.testing.assert_allclose(mapped,np.full(3,level),atol=2e-15,rtol=0)
            scaled,scaled_wb,_=hncs.bridge_white_balance(profile,np.array(wb)*1024)
            np.testing.assert_allclose(scene,scaled,atol=2e-15,rtol=0)
            np.testing.assert_allclose(virtual,scaled_wb,atol=2e-15,rtol=0)

    def test_render_resolves_capture_temperature_and_override(self):
        profile=json.loads(hncs.PROFILE.read_text())
        wb=[2.4404296875,1,1.7275390625] # DSC05218 capture WB
        adaptive=hncs.render_colour_parameters(profile,self.assets,wb,"camera","adaptive")
        self.assertEqual(adaptive["cct"],5472)
        self.assertTrue(adaptive["white_balance_bridge_enabled"])
        fixed=hncs.render_colour_parameters(profile,self.assets,wb,"camera","calibration")
        self.assertEqual(fixed["cct"],profile["target_cct"])
        np.testing.assert_array_equal(fixed["matrix"],profile["matrix"])
        manual=hncs.render_colour_parameters(profile,self.assets,wb,"camera","adaptive",5550)
        self.assertEqual(manual["cct"],5550)
        self.assertEqual(manual["cct_source"],"manual")
        np.testing.assert_array_equal(manual["matrix"],adaptive["matrix"])
        reference=hncs.render_colour_parameters(profile,self.assets,profile["target"]["camera_wb"][:3],
                                                "camera","adaptive",target_reference=True)
        self.assertEqual(reference["cct"],7523)
        self.assertFalse(reference["white_balance_bridge_enabled"])
        np.testing.assert_array_equal(reference["matrix"],np.eye(3))
        extreme=hncs.render_colour_parameters(profile,self.assets,[10,1,.5],"camera","adaptive")
        self.assertTrue(extreme["factory_cct_clamped"])
        self.assertTrue(2000<=extreme["cct"]<=10000)

    def test_bridge_rejects_invalid_neutrals(self):
        profile=json.loads(hncs.PROFILE.read_text())
        for wb in ([0,1,1],[np.nan,1,1],[1,1],[-1,1,1]):
            with self.assertRaises(ValueError):hncs.bridge_white_balance(profile,wb)
        with self.assertRaises(ValueError):hncs.bridge_white_balance(profile,[1000,1,.1])


if __name__ == "__main__":
    unittest.main()
