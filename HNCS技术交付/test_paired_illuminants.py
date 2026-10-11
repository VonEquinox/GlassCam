"""Checks for the two direct RAW chart response model and its stale-data guard."""
import copy
import json
import unittest
import numpy as np
import hncs_pipeline as h
import hncs_paired_illuminants as p


class PairedIlluminantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile=json.loads(h.PROFILE.read_text())
        cls.assets=h.load_assets();cls.model=p.load_model()

    def test_both_real_chart_endpoints_reproduce_stored_fits(self):
        for endpoint in self.model["endpoints"]:
            with self.subTest(source=endpoint["source"]["sha256"]):
                params=p.colour_parameters(self.profile,self.assets,endpoint["source_wb"],"camera")
                np.testing.assert_array_equal(params["matrix"],endpoint["matrix"])
                np.testing.assert_array_equal(params["estimated_target_white_balance"],endpoint["target_wb"])
                self.assertEqual(params["cct"],endpoint["target_cct"])
                raw=np.array(endpoint["source_native_patches"])
                target=np.array(endpoint["target_native_patches"])*endpoint["target_wb"]
                prediction=(raw*np.array(endpoint["source_wb"])*endpoint["source_scale"])@np.array(params["matrix"]).T
                for space in ("legacy","lstar"):
                    self.assertLess(float(h.delta_e_2000(h.output_lab(prediction,params["cct"],self.assets,working_space=space),
                                                       h.output_lab(target,params["cct"],self.assets,working_space=space)).mean()),1.)

    def test_capture_neutral_gain_and_wb_scale_invariance(self):
        for wb in ([1.4,1,3.],[2.,1,2.],[3.,1,1.4]):
            result=p.colour_parameters(self.profile,self.assets,wb,"camera")
            matrix=np.array(result["matrix"])
            np.testing.assert_allclose(matrix@np.ones(3),np.ones(3),atol=2e-15,rtol=0)
            for level in (.01,.18,.8):
                raw=level/np.array(wb)
                np.testing.assert_allclose((raw*np.array(wb))@matrix.T,[level]*3,atol=2e-15,rtol=0)
            scaled=p.colour_parameters(self.profile,self.assets,np.array(wb)*1024,"camera")
            np.testing.assert_array_equal(result["matrix"],scaled["matrix"])
            self.assertEqual(result["cct"],scaled["cct"])

    def test_profile_guard_and_invalid_inputs(self):
        changed=copy.deepcopy(self.profile);changed["source_scale"]*=1.01
        with self.assertRaises(ValueError):p.colour_parameters(changed,self.assets,[2,1,2],"camera")
        for wb in ([0,1,1],[np.nan,1,1],[1,1],[-1,1,1]):
            with self.assertRaises(ValueError):p.colour_parameters(self.profile,self.assets,wb,"camera")

    def test_factory_override_and_range_flags(self):
        params=p.colour_parameters(self.profile,self.assets,[2,1,2],"camera",5550)
        self.assertEqual(params["cct"],5550)
        self.assertEqual(params["cct_source"],"manual")
        cool=p.colour_parameters(self.profile,self.assets,[3.5,1,1.],"camera")
        self.assertEqual(cool["paired_warm_weight"],0.)
        self.assertTrue(cool["paired_range_clamped"])


if __name__=="__main__":unittest.main()
