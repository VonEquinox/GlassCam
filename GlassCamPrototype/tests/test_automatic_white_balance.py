"""Independent NumPy oracle for the additive, per-photo virtual WB adapter.

This validates the model against the bundled reference response/CCT functions;
it does not claim a measured iPhone-to-X2D camera profile.
"""
import ctypes as c
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import reference_runtime as r


class AutomaticWhiteBalance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='glasscam-wb-')
        output = Path(cls.directory.name) / 'libwhitepoint.dylib'
        subprocess.run(['clang++', '-std=c++17', '-O2', '-fno-fast-math',
                        '-ffp-contract=off', '-shared', '-fPIC', '-pthread',
                        str(ROOT / 'core/hncs.cpp'), '-o', str(output)], check=True)
        cls.lib = c.CDLL(str(output))
        cls.lib.hncs_whitepoint_parameters.argtypes = [c.c_double, c.c_double, c.c_void_p, c.c_void_p]
        cls.lib.hncs_create_preset_whitepoint.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int]
        cls.lib.hncs_create_preset_whitepoint.restype = c.c_void_p
        cls.lib.hncs_create_preset_whitepoint_with_policy.argtypes = cls.lib.hncs_create_preset_whitepoint.argtypes + [c.c_int]
        cls.lib.hncs_create_preset_whitepoint_with_policy.restype = c.c_void_p
        cls.lib.hncs_source_to_native_matrix.argtypes = [c.c_void_p, c.c_void_p]
        cls.lib.hncs_preset_white_balance.argtypes = [c.c_void_p] * 4
        cls.lib.hncs_process_phocus_linear_rgba.argtypes = [c.c_void_p] * 3 + [c.c_size_t]
        cls.lib.hncs_destroy.argtypes = [c.c_void_p]
        cls.assets = r.assets()
        cls.response = cls.assets['camera_to_xyz'][2] @ np.diag(cls.assets['factory_wb'][1])

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def parameters(self, x, y):
        gains = np.zeros(3, dtype=np.float64)
        kelvin = c.c_double()
        status = self.lib.hncs_whitepoint_parameters(x, y, gains.ctypes.data, c.byref(kelvin))
        self.assertEqual(status, 0)
        return gains, kelvin.value

    def test_gains_and_cct_match_reference_for_temperature_and_tint(self):
        # Warm light, daylight, cool shade and the device's actual as-shot xy;
        # off-locus samples exercise tint independently of just a Kelvin slider.
        for x, y in [(0.44757, 0.40745), (0.34567, 0.35850), (0.3127, 0.3290),
                     (0.285, 0.299), (0.339429795742, 0.352590560913),
                     (0.34, 0.32), (0.34, 0.38)]:
            with self.subTest(x=x, y=y):
                neutral = np.linalg.solve(self.response, [x/y, 1, (1-x-y)/y])
                expected = neutral[1] / neutral
                actual, kelvin = self.parameters(x, y)
                np.testing.assert_allclose(actual, expected, rtol=0, atol=3e-15)
                reference_cct, _ = r.estimate_cct(expected, self.assets)
                self.assertEqual(kelvin, np.clip(reference_cct, 2000, 10000))

    def test_adapter_neutral_and_absolute_preset_gain_replacement(self):
        all_matrices = []
        for x, y in [(0.44757, 0.40745), (0.3127, 0.3290), (0.34, 0.32), (0.34, 0.38)]:
            white = np.array([x/y, 1, (1-x-y)/y])
            neutral = np.linalg.solve(self.response, white)
            baseline, _ = self.parameters(x, y)
            cat = np.linalg.inv(r.BRADFORD) @ np.diag((r.BRADFORD @ white) / (r.BRADFORD @ r.D65)) @ r.BRADFORD
            unbalanced = np.linalg.solve(self.response, cat @ r.SRGB_TO_XYZ)
            for key in ['standard', 'tungsten', 'daylight', 'cloudy', 'flash', 'square-crop', 'film-grain-artistic']:
                pointer = self.lib.hncs_create_preset_whitepoint(0, x, y, 0, 0, 0, 4, 2, key.encode(), 1)
                self.assertTrue(pointer, key)
                try:
                    capture = np.zeros(3); target = np.zeros(3); factory = c.c_double()
                    self.assertEqual(self.lib.hncs_preset_white_balance(pointer, capture.ctypes.data,
                                                                      target.ctypes.data, c.byref(factory)), 0)
                    np.testing.assert_allclose(capture, baseline, rtol=0, atol=3e-15)
                    configured = r.presets.settings(key).get('native_wb_gains')
                    desired = baseline if configured is None else np.array(configured) / configured[1]
                    np.testing.assert_allclose(target, desired, rtol=0, atol=3e-15)
                    actual = np.zeros((3, 3))
                    self.assertEqual(self.lib.hncs_source_to_native_matrix(pointer, actual.ctypes.data), 0)
                    expected = np.diag(desired / neutral[1]) @ unbalanced
                    np.testing.assert_allclose(actual, expected, rtol=0, atol=4e-15)
                    if key == 'standard':
                        # No double WB: a D65-balanced gray stays a virtual neutral.
                        np.testing.assert_allclose(actual @ np.ones(3), 1, rtol=0, atol=4e-7)
                        all_matrices.append(actual)
                finally:
                    self.lib.hncs_destroy(pointer)
        self.assertGreater(np.max(np.abs(all_matrices[-1] - all_matrices[-2])), 0.01)

    def test_invalid_whitepoints_and_constructor_arguments_fail_closed(self):
        for x, y in [(float('nan'), .3), (.3, float('inf')), (0, .3), (.3, 0), (-.3, .3), (.7, .4), (.99, .001)]:
            gains = np.zeros(3); kelvin = c.c_double()
            self.assertEqual(self.lib.hncs_whitepoint_parameters(x, y, gains.ctypes.data, c.byref(kelvin)), -1)
            self.assertFalse(self.lib.hncs_create_preset_whitepoint(0, x, y, 0, 0, 0, 4, 2, b'standard', 1))
        self.assertFalse(self.lib.hncs_create_preset_whitepoint(float('nan'), .3127, .329, 0, 0, 0, 4, 2, b'standard', 1))
        self.assertFalse(self.lib.hncs_create_preset_whitepoint(0, .3127, .329, 0, 0, 0, 4, 2, b'missing', 1))

    def test_photo_policy_preserves_tint_neutral_axis_and_uses_effective_cct(self):
        samples = [(.33209389448165894, .36442223191261292),
                   (.33567193150520325, .37427031993865967),
                   (.33416590094566345, .3648126423358917),
                   (.44757, .40745), (.3127, .3290), (.34, .32), (.34, .38)]
        for x, y in samples:
            capture, temperature = self.parameters(x, y)
            for preset in ['standard', 'nature', 'tungsten', 'daylight', 'cloudy', 'saturated', 'square-crop']:
                for override in [0, 3500, 7900]:
                    ctx = self.lib.hncs_create_preset_whitepoint_with_policy(0, x, y, override, 1, 0, 4, 2, preset.encode(), 1, 1)
                    self.assertTrue(ctx)
                    try:
                        baseline = np.zeros(3); target = np.zeros(3); factory = c.c_double()
                        self.assertEqual(self.lib.hncs_preset_white_balance(ctx, baseline.ctypes.data, target.ctypes.data, c.byref(factory)), 0)
                        np.testing.assert_array_equal(baseline, capture)
                        np.testing.assert_array_equal(target, capture)
                        self.assertEqual(factory.value, override or temperature)
                        matrix = np.zeros((3, 3))
                        self.assertEqual(self.lib.hncs_source_to_native_matrix(ctx, matrix.ctypes.data), 0)
                        np.testing.assert_allclose(matrix @ np.ones(3), 1, atol=4e-7, rtol=0)
                    finally:
                        self.lib.hncs_destroy(ctx)

    def test_nature_photo_policy_keeps_tone_curve_and_removes_reported_neutral_cast(self):
        gray = np.full((16, 3), .18, np.float32)
        outputs = {}
        for key, policy in [('nature', 0), ('nature', 1), ('standard', 1)]:
            ctx = self.lib.hncs_create_preset_whitepoint_with_policy(0, .33567193150520325, .37427031993865967,
                                                                   0, 1, 0, 4, 2, key.encode(), 1, policy)
            self.assertTrue(ctx)
            try:
                out = np.empty((len(gray), 4), np.float32)
                self.assertEqual(self.lib.hncs_process_phocus_linear_rgba(ctx, gray.ctypes.data, out.ctypes.data, len(gray)), 0)
                outputs[key, policy] = out[0, :3]
            finally:
                self.lib.hncs_destroy(ctx)
        np.testing.assert_allclose(outputs['nature', 0], [.26048735, .33648133, .23170701], rtol=0, atol=1e-7)
        fixed, corrected = outputs['nature', 0], outputs['nature', 1]
        self.assertGreater(fixed[1] / ((fixed[0] + fixed[2]) / 2), 1.25)
        self.assertLess(abs(corrected[1] / ((corrected[0] + corrected[2]) / 2) - 1), .025)
        self.assertGreater(np.max(np.abs(corrected - outputs['standard', 1])), .01,
                           'Photo WB must retain Nature tone response, not substitute Standard')

    def test_unknown_white_balance_policy_is_rejected(self):
        for policy in [-1, 2, 255]:
            self.assertFalse(self.lib.hncs_create_preset_whitepoint_with_policy(0, .3127, .3290,
                                                                            0, 1, 0, 4, 2, b'nature', 1, policy))


if __name__ == '__main__':
    unittest.main()
