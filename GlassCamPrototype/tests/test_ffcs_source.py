"""Current v0.2 reference gates; historical v0.1 reports remain immutable."""
import hashlib,json,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import verify_ffcs as historical
import verify_ffcs_v020 as v
class FFCSReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=v.load();cls.golden=json.loads((ROOT/'validation/ffcs-v020-stage-goldens.json').read_text())
    def test_all_nine_original_test_functions(self):
        # Preserve the original nine-function gate in addition to the 61-test
        # upstream regression run recorded in ffcs-v020-upstream.json.
        report=historical.original_tests(self.source)
        self.assertEqual(len(report['tests']),9)
    def test_original_reproduction_keeps_baseline(self):
        report=historical.original_reproduction(self.source)
        self.assertTrue(report['baseline_unchanged']);self.assertEqual(report['cases'],19);self.assertEqual(report['stage_maps'],198)
    def test_golden_assets_and_complete_stage_maps(self):
        import numpy as np
        from ffcs.pipeline import REQUIRED_COLOR_STAGES
        self.assertEqual(self.golden['source'],v.source_stamp(self.source))
        self.assertEqual(self.golden['unique_native_assets'],50);self.assertEqual(self.golden['configured_cases'],86)
        for expected in self.golden['records']:
            with self.subTest(camera=expected['camera'],look=expected['look']):
                asset=self.source/'implementation/ffcs/data'/expected['asset']
                self.assertEqual(v.sha(asset),expected['asset_sha256'])
                mobile=ROOT/'ios/GlassCam/Resources/FFCS'/expected['asset']
                self.assertEqual(v.sha(mobile),expected['asset_sha256'])
                result=v.reference(self.golden['input'],expected['camera'],expected['look'])
                self.assertEqual(set(result.stage_pixels),set(REQUIRED_COLOR_STAGES))
                self.assertEqual(result.metadata['approximation_metrics']['camera_asset_substitution'],expected['substitution'])
                for stage in REQUIRED_COLOR_STAGES:np.testing.assert_allclose(result.stage_pixels[stage],expected['stages'][stage],rtol=0,atol=1e-12)
    def test_cpp_all_presets_stages_and_linear_mobile_contract(self):
        report=v.compare(self.source)
        self.assertEqual(report['configured_family_cases'],86);self.assertEqual(report['unique_native_assets'],50)
        self.assertEqual(report['encoded_cases'],134);self.assertEqual(report['stage_comparisons'],1206)
        self.assertLess(report['maximum_absolute_stage_error'],1e-12);self.assertEqual(report['linear_reference_cases'],48)
        self.assertLessEqual(report['linear_mobile_max_error'],2e-7)
    def test_optimized_matches_baseline_at_borders_and_output_modes(self):
        import benchmark_ffcs as bench
        lib,_=bench.setup();report=bench.regress(lib,self.source/'implementation/ffcs/data/xh2s')
        self.assertEqual(report['both_output_bit_exact_cases'],456);self.assertEqual(report['single_output_bit_exact_cases'],912)
if __name__=='__main__':unittest.main()
