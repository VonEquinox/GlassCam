"""Executable revision/provenance and absolute target-WB reference contracts.

These exercise the pinned, unmodified revision-8 source helpers. They do not
claim iPhone sensor calibration or execute Apple's image/preview stack.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import reference_runtime as r


class Revision8ReferenceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = r.assets()

    def test_render_revision_and_asset_colour_revision_are_distinct(self):
        self.assertEqual(r.RENDER_PATH_REVISION, 8)
        self.assertEqual(r.COLOUR_PATH_REVISION, 2)
        provenance = json.loads((r.ASSETS / 'provenance.json').read_text())
        self.assertEqual(provenance['colour_path_revision'], r.COLOUR_PATH_REVISION)
        self.assertNotEqual(provenance['colour_path_revision'], r.RENDER_PATH_REVISION)

    def test_bad_asset_revision_fails_before_hash_or_npz_loading(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for revision in [None, 1, 3, 8, '2', False]:
                with self.subTest(revision=revision):
                    provenance = {'files': {'deliberately_missing.npz': 'not-a-hash'}}
                    if revision is not None:
                        provenance['colour_path_revision'] = revision
                    (root / 'provenance.json').write_text(json.dumps(provenance))
                    with mock.patch.object(r, 'ASSETS', root), mock.patch.object(r.np, 'load') as load:
                        with self.assertRaisesRegex(ValueError, 'colour path revision'):
                            r.assets()
                        load.assert_not_called()

    def test_malformed_provenance_and_tampered_assets_are_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'provenance.json').write_text('{ malformed')
            with mock.patch.object(r, 'ASSETS', root), mock.patch.object(r.np, 'load') as load:
                with self.assertRaises(json.JSONDecodeError):
                    r.assets()
                load.assert_not_called()
            (root / 'tampered.npz').write_bytes(b'changed')
            (root / 'provenance.json').write_text(json.dumps({
                'colour_path_revision': 2, 'files': {'tampered.npz': '0' * 64}}))
            with mock.patch.object(r, 'ASSETS', root), mock.patch.object(r.np, 'load') as load:
                with self.assertRaisesRegex(ValueError, 'Asset hash mismatch: tampered.npz'):
                    r.assets()
                load.assert_not_called()

    def test_absolute_target_gains_are_desired_over_capture_baseline(self):
        baseline = np.array(r.presets.settings('cloudy')['native_wb_gains'])
        desired = np.array(r.presets.settings('tungsten')['native_wb_gains'])
        colour = {'matrix': np.eye(3).tolist(), 'cct': 6500, 'cct_source': 'x2d_capture_wb',
                  'estimated_target_white_balance': baseline.tolist(), 'illuminant_mode': 'calibration'}
        untouched = copy.deepcopy(colour)
        actual = r.apply_target_white_balance(colour, desired, self.assets, {}, baseline, True)
        expected_matrix = np.diag(desired / baseline)
        np.testing.assert_allclose(actual['matrix'], expected_matrix, rtol=0, atol=1e-14)
        pixels = np.array([[.2, .2, .2], [.1, .3, .8], [1., 0., 0.]])
        np.testing.assert_allclose(pixels @ np.array(actual['matrix']).T,
                                   pixels * (desired / baseline), rtol=0, atol=1e-14)
        # Applying absolute gains directly would double the capture's baseline WB.
        self.assertFalse(np.allclose(actual['matrix'], np.diag(desired)))
        self.assertFalse(np.allclose(actual['matrix'], np.eye(3)))
        self.assertEqual(actual['cct'], 6500)
        self.assertEqual(actual['cct_source'], 'x2d_capture_wb')
        self.assertTrue(actual['target_white_balance_override_applied'])
        self.assertEqual(actual['target_white_balance_source'], 'preset_absolute_gains')
        self.assertEqual(colour, untouched)

    def test_capture_baseline_and_target_gains_are_normalized_independently(self):
        baseline = np.array(r.presets.settings('daylight')['native_wb_gains'])
        desired = np.array(r.presets.settings('flash')['native_wb_gains'])
        colour = {'matrix': np.eye(3).tolist(), 'cct': 5500,
                  'estimated_target_white_balance': baseline.tolist(), 'illuminant_mode': 'calibration'}
        original = r.apply_target_white_balance(colour, desired, self.assets, {}, baseline, True)
        scaled = r.apply_target_white_balance(colour, desired * 7, self.assets, {}, baseline * 11, True)
        np.testing.assert_allclose(original['matrix'], scaled['matrix'], rtol=0, atol=1e-14)
        np.testing.assert_allclose(scaled['target_white_balance_override'], desired, rtol=0, atol=1e-14)
        self.assertEqual(scaled['matrix'][1][1], 1)
        # Daylight and Flash share the same CCT but carry different target gains.
        self.assertEqual(r.presets.settings('daylight')['color_temperature'],
                         r.presets.settings('flash')['color_temperature'])
        self.assertFalse(np.allclose(original['matrix'], np.eye(3)))

    def test_adaptive_target_override_preserves_capture_light_and_factory_selection(self):
        baseline = np.array(r.presets.settings('cloudy')['native_wb_gains'])
        desired = np.array(r.presets.settings('tungsten')['native_wb_gains'])
        matrix = np.array([[.9, .08, .02], [.04, .93, .03], [.01, .1, .89]])
        colour = {'matrix': matrix.tolist(), 'cct': 6100, 'cct_source': 'virtual_x2d_capture_wb',
                  'estimated_target_white_balance': baseline.tolist(), 'illuminant_mode': 'adaptive',
                  'white_balance_bridge_neutral_gain': .83, 'cross_illuminant_assumption': True}
        result = r.apply_target_white_balance(colour, desired, self.assets, {}, [2, 1, 1.5], False)
        np.testing.assert_allclose(result['matrix'], matrix * (desired / baseline)[:, None],
                                   rtol=0, atol=1e-14)
        self.assertEqual(result['cct'], colour['cct'])
        self.assertEqual(result['cct_source'], colour['cct_source'])
        self.assertEqual(result['white_balance_bridge_neutral_gain'], .83)
        self.assertLess(result['estimated_target_cct'], 4000)

    def test_factory_override_does_not_replace_source_or_preset_white_balance(self):
        baseline = np.array(r.presets.settings('cloudy')['native_wb_gains'])
        desired = np.array(r.presets.settings('tungsten')['native_wb_gains'])
        profile = {'matrix': np.eye(3).tolist(), 'source_wb': baseline.tolist(),
                   'target_wb': baseline.tolist(), 'target_cct': 6500}
        result = r.render_colour_parameters(profile, self.assets, baseline, 'camera',
                                             'calibration', cct_override=4500,
                                             target_reference=True, target_wb_override=desired)
        self.assertEqual(result['cct'], 4500)
        self.assertEqual(result['cct_source'], 'manual')
        np.testing.assert_allclose(result['matrix'], np.diag(desired / baseline), rtol=0, atol=1e-14)
        np.testing.assert_allclose(result['estimated_target_white_balance'], desired, rtol=0, atol=1e-14)
        self.assertLess(result['estimated_target_cct'], 4000)
        self.assertFalse(result['factory_cct_clamped'])
        np.testing.assert_array_equal(profile['source_wb'], baseline)

    def test_missing_target_is_noop_and_invalid_target_gains_fail(self):
        colour = {'matrix': np.eye(3).tolist(), 'cct': 6500,
                  'estimated_target_white_balance': [2, 1, 1.5], 'illuminant_mode': 'adaptive'}
        actual = r.apply_target_white_balance(colour, None, self.assets, {}, [2, 1, 1.5], False)
        self.assertFalse(actual['target_white_balance_override_applied'])
        self.assertEqual({k: v for k, v in actual.items() if k != 'target_white_balance_override_applied'}, colour)
        for target in [[1, 0, 1], [-1, 1, 1], [1, np.nan, 1], [1, 1, np.inf], [1, 1], [[1, 1, 1]]]:
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, 'finite positive gains'):
                    r.apply_target_white_balance(colour, target, self.assets, {}, [2, 1, 1.5], False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
