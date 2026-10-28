"""Tests of matrix conventions, illuminant recovery and anchor preservation."""
import json
import unittest
import numpy as np
import hncs_pipeline as h
import hncs_dual_illuminant as d


class DualIlluminantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets=h.load_assets()
        cls.profile=json.loads(h.PROFILE.read_text())
        cls.model=d.load_model()

    def test_external_row_and_dcp_column_matrices_are_inverses(self):
        source=json.loads((d.CASE/"sources/dual_illuminant_report_v3_adobe_illuminant_order.json").read_text())
        for i in (1,2):
            row=np.array(source[f"color_matrix_{i}"])
            cm=np.array(source[f"dcp_color_matrix_{i}"])
            np.testing.assert_allclose(cm@row.T,np.eye(3),atol=1e-14,rtol=0)
            self.assertGreater(np.max(abs(cm@row-np.eye(3))),.1)

    def test_measured_source_wb_recovers_reference_illuminants(self):
        for wb,temp in (([1.62,1,2.67],2856),([2.53,1,1.62],5003)):
            recovered,_,_,_=d.source_illuminant(wb,self.model["sony"],self.assets)
            self.assertAlmostEqual(recovered,temp,delta=2)

    def test_synthetic_intermediate_illuminant_is_recovered(self):
        # Robertson table has a 250-mired line: construct a 4000 K neutral in
        # XYZ first, then encode it with the Sony profile. This exercises the
        # inverse solution rather than passing in a temperature directly.
        line=self.assets["robertson"][np.argmin(abs(self.assets["robertson"][:,0]-250))]
        self.assertEqual(line[0],250)
        u,v=line[1:3];denominator=2*u-8*v+4
        white=d.xy_xyz([3*u/denominator,2*v/denominator])
        cm,_=d.interpolate_cm(self.model["sony"],4000)
        neutral=cm@white;wb=neutral[1]/neutral
        temperature,_,_,_=d.source_illuminant(wb,self.model["sony"],self.assets)
        self.assertAlmostEqual(temperature,4000,delta=1e-5)

    def test_mired_midpoint_clamps_and_inverts_after_interpolation(self):
        camera=self.model["sony"];low,high=camera["temperatures"]
        middle=2/(1/low+1/high)
        cm,weight=d.interpolate_cm(camera,middle)
        self.assertAlmostEqual(weight,.5,places=14)
        endpoints=np.array(camera["xyz_to_native"])
        np.testing.assert_allclose(cm,endpoints.mean(axis=0),atol=1e-15,rtol=0)
        self.assertGreater(np.max(abs(np.linalg.inv(cm)-np.mean(np.linalg.inv(endpoints),axis=0))),.01)
        np.testing.assert_array_equal(d.interpolate_cm(camera,1000)[0],endpoints[0])
        np.testing.assert_array_equal(d.interpolate_cm(camera,12000)[0],endpoints[1])

    def test_anchor_pixels_and_capture_neutral_exposure(self):
        p=self.profile
        result=d.colour_parameters(p,self.assets,p["source_wb"],"calibration")
        np.testing.assert_array_equal(result["matrix"],p["matrix"])
        self.assertEqual(result["cct"],p["target_cct"])
        pixels=np.random.default_rng(28).uniform(0,.9,(1000,3))
        for space in ("legacy","lstar"):
            np.testing.assert_array_equal(
                h.hncs_codes(pixels@np.array(result["matrix"]).T,result["cct"],self.assets,working_space=space),
                h.hncs_codes(pixels@np.array(p["matrix"]).T,p["target_cct"],self.assets,working_space=space))
        for wb in ([1.62,1,2.67],[2.53,1,1.62],[3.,1,1.3]):
            result=d.colour_parameters(p,self.assets,wb,"camera")
            matrix=np.array(result["matrix"])
            raw=.18/np.array(wb)
            np.testing.assert_allclose((raw*np.array(wb))@matrix.T,[.18]*3,atol=1e-15,rtol=0)
        self.assertFalse(np.allclose(d.colour_parameters(p,self.assets,[1.62,1,2.67],"camera")["matrix"],p["matrix"]))

    def test_explicit_mode_and_factory_override(self):
        wb=[2.4404296875,1,1.7275390625]
        result=h.render_colour_parameters(self.profile,self.assets,wb,"camera","dual",5550)
        self.assertEqual(result["cct"],5550)
        self.assertTrue(result["experimental_dual_illuminant"])
        reference=h.render_colour_parameters(self.profile,self.assets,self.profile["target"]["camera_wb"][:3],
                                             "camera","dual",target_reference=True)
        self.assertEqual(reference["cct"],7523)
        self.assertFalse(reference["white_balance_bridge_enabled"])
        with self.assertRaises(ValueError):d.source_illuminant([0,1,1],self.model["sony"],self.assets)


if __name__=="__main__":unittest.main()
