"""Actual portable C++/Python HNCS composed-pipeline toggle regression."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from support import verify_effect_toggle_hncs


class HNCSEffectToggleNativeTests(unittest.TestCase):
    def test_all_eight_switch_routes_on_five_presets_and_both_odd_orientations(self):
        result = verify_effect_toggle_hncs.verify()
        self.assertTrue(result['passed'])
        self.assertEqual(result['cases'], 80)
        self.assertEqual(result['memory_spatial_cases'], result['file_spatial_cases'])
        self.assertGreater(result['memory_spatial_cases'], 0)
        self.assertGreater(result['pointwise_route_cases'], 0)
        self.assertEqual(result['final_code_mismatches'], 0)
        self.assertLessEqual(result['max_display_absolute_error'], result['display_tolerance'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
