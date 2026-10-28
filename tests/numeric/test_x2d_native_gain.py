"""Regression vectors produced by original Phocus at non-unit input gains."""
import ctypes as c
import hashlib
import json
from pathlib import Path
from native_build import build_product
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


class X2DNativeGainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="x2d-native-gain-")
        path = build_product()
        cls.lib = c.CDLL(str(path))
        cls.lib.hncs_create_mode.argtypes = [c.c_double, c.c_double, c.c_int, c.c_int]
        cls.lib.hncs_create_mode.restype = c.c_void_p
        cls.lib.hncs_clone_with_native_gain.argtypes = [c.c_void_p, c.c_double]
        cls.lib.hncs_clone_with_native_gain.restype = c.c_void_p
        cls.lib.hncs_render_native.argtypes = [c.c_void_p] * 3 + [c.c_size_t]
        cls.lib.hncs_destroy.argtypes = [c.c_void_p]
        cls.manifest = json.loads((ROOT / "tests/fixtures/hncs/x2d-native-gain-goldens.json").read_text())
        vectors = ROOT / "tests/fixtures/hncs" / cls.manifest["vectors"]
        assert hashlib.sha256(vectors.read_bytes()).hexdigest() == cls.manifest["sha256"]
        cls.vectors = np.load(vectors, allow_pickle=False)

    @classmethod
    def tearDownClass(cls):
        cls.vectors.close()
        cls.temp.cleanup()

    def render(self, context, codes):
        source = np.ascontiguousarray(codes.astype(np.float64) / 65535.)
        output = np.empty_like(codes)
        self.assertEqual(self.lib.hncs_render_native(context, source.ctypes.data,
                                                   output.ctypes.data, codes.size // 3), 0)
        return output

    def test_original_nonunit_gain_outputs(self):
        for case in self.manifest["cases"]:
            with self.subTest(gain=case["gain"]):
                key = case["golden_prefix"]
                source, expected = self.vectors[key + "_input"], self.vectors[key + "_expected"]
                parent = self.lib.hncs_create_mode(0., case["cct"], case["space"], case["model"])
                self.assertTrue(parent)
                original = self.render(parent, source)
                child = self.lib.hncs_clone_with_native_gain(parent, case["gain"])
                self.assertTrue(child)
                try:
                    np.testing.assert_array_equal(self.render(child, source), expected)
                    np.testing.assert_array_equal(self.render(parent, source), original)
                finally:
                    self.lib.hncs_destroy(child)
                    self.lib.hncs_destroy(parent)

    def test_invalid_gain_and_parent_lifetime(self):
        self.assertFalse(self.lib.hncs_clone_with_native_gain(None, 1.))
        parent = self.lib.hncs_create_mode(0., 7523., 0, 0)
        source = self.vectors[self.manifest["cases"][0]["golden_prefix"] + "_input"]
        before = self.render(parent, source)
        try:
            for gain in [0., -1., float("nan"), float("inf"), -float("inf"), 1e-308, 1e308]:
                self.assertFalse(self.lib.hncs_clone_with_native_gain(parent, gain))
            child = self.lib.hncs_clone_with_native_gain(parent, 1.)
            self.assertTrue(child)
        finally:
            self.lib.hncs_destroy(parent)
        try:
            np.testing.assert_array_equal(self.render(child, source), before)
        finally:
            self.lib.hncs_destroy(child)


if __name__ == "__main__":
    unittest.main()
