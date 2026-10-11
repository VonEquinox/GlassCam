"""Regression gates for the supplied FFCS source and genuine C++ adaptation."""
import hashlib
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import verify_ffcs as v


class FFCSReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = v.load_source(ROOT / 'reference_ffcs')
        cls.golden = json.loads((ROOT / 'validation/ffcs_mobile_stage_goldens.json').read_text())

    def test_all_nine_original_test_functions(self):
        report = v.original_tests(self.source)
        self.assertEqual(len(report['tests']), 9)
        self.assertEqual(report['status'], 'pass')

    def test_original_reproduction_keeps_baseline(self):
        report = v.original_reproduction(self.source)
        self.assertTrue(report['baseline_unchanged'])
        self.assertEqual(report['cases'], 14)
        self.assertEqual(report['stage_maps'], 153)
        self.assertLessEqual(report['maximum_absolute_stage_error'], 1e-12)

    def test_golden_assets_and_complete_stage_maps(self):
        import numpy as np
        from ffcs.pipeline import REQUIRED_COLOR_STAGES
        self.assertEqual(set(self.golden['looks']), set(v.NAMES))
        self.assertNotIn('REALA ACE', self.golden['looks'])
        for name, expected in self.golden['looks'].items():
            with self.subTest(look=name):
                asset = self.source / 'implementation/ffcs/data/xh2s' / expected['asset']
                self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(), expected['asset_sha256'])
                mobile_asset = ROOT / 'ios/GlassCam/Resources/FFCS/xh2s' / expected['asset']
                self.assertEqual(hashlib.sha256(mobile_asset.read_bytes()).hexdigest(), expected['asset_sha256'])
                result = v.reference(self.golden['input'], name)
                self.assertEqual(set(result.stage_pixels), set(REQUIRED_COLOR_STAGES))
                for stage in REQUIRED_COLOR_STAGES:
                    np.testing.assert_allclose(result.stage_pixels[stage], expected['stages'][stage], rtol=0, atol=1e-12)

    def test_cpp_all_presets_stages_and_linear_mobile_contract(self):
        report = v.compare_cpp(self.source)
        self.assertEqual(report['presets'], 19)
        self.assertEqual(report['stage_comparisons'], 513)
        self.assertLess(report['maximum_absolute_stage_error'], 1e-12)
        self.assertEqual(report['linear_mobile_cases'], 57)
        self.assertLessEqual(report['linear_mobile_max_error'], 2e-7)

    def test_optimized_matches_baseline_at_borders_and_output_modes(self):
        import benchmark_ffcs as bench
        lib, _ = bench.setup()
        report = bench.regress(lib, self.source / 'implementation/ffcs/data/xh2s')
        self.assertEqual(report['both_output_bit_exact_cases'], 456)
        self.assertEqual(report['single_output_bit_exact_cases'], 912)
        self.assertEqual(report['status'], 'pass')


if __name__ == '__main__':
    unittest.main()
