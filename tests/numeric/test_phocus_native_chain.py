"""Replay frozen original-Phocus outputs through the shipping C++ stage APIs."""
import ctypes as c
import hashlib
import json
from pathlib import Path
from native_build import build_product
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


class NativePhocusChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="phocus-native-golden-")
        library = build_product()
        cls.lib = c.CDLL(str(library))
        cls.lib.hncs_create_preset.argtypes = [c.c_double] * 3 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_void_p, c.c_void_p]
        cls.lib.hncs_create_preset.restype = c.c_void_p
        cls.lib.hncs_destroy.argtypes = [c.c_void_p]
        cls.lib.hncs_process_phocus_work_float_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]
        cls.lib.hncs_apply_spatial_native_sharpness.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double]
        cls.lib.hncs_apply_phocus_post_spatial.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
        cls.lib.hncs_native_sharpness_enabled.argtypes = [c.c_char_p]
        cls.golden = json.loads((ROOT / "tests/fixtures/hncs/phocus-native-chain-goldens.json").read_text())
        path = ROOT / "tests/fixtures/hncs" / cls.golden["vectors"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == cls.golden["sha256"]
        cls.vectors = np.load(path, allow_pickle=False)

    @classmethod
    def tearDownClass(cls):
        cls.vectors.close()
        cls.temporary.cleanup()

    def test_original_binary_work_sharpness_and_final_codes(self):
        for case in self.golden["cases"]:
            key, name = case["preset"].encode(), case["vector_key"]
            with self.subTest(preset=case["preset"]):
                source = self.vectors[name + "_source"]
                h, w = source.shape[:2]
                context = self.lib.hncs_create_preset(case["exposure_ev"], case["capture_cct"], 0,
                    case["space"], 0, 4, 2, key, int(case["tone"]), None, None)
                self.assertTrue(context)
                try:
                    for workers in [1, 4]:
                        work = np.empty_like(source)
                        self.assertEqual(self.lib.hncs_process_phocus_work_float_parallel(
                            context, source.ctypes.data, work.ctypes.data, h * w, workers), 0)
                        np.testing.assert_array_equal(work.view(np.uint32), self.vectors[name + "_work"].view(np.uint32))
                        self.assertEqual(self.lib.hncs_apply_spatial_native_sharpness(
                            work.ctypes.data, w, h, key, 0, 1, case["baseline_sharpness"]), 0)
                        expected_sharp = self.vectors[name + "_sharpness"]
                        np.testing.assert_array_equal(work.view(np.uint32),
                            (expected_sharp.astype(np.float32) / np.float32(65535.)).view(np.uint32))
                        codes = np.rint(work * np.float32(65535.)).astype(np.uint16)
                        final = np.empty_like(codes)
                        self.assertEqual(self.lib.hncs_apply_phocus_post_spatial(key, codes.ctypes.data, final.ctypes.data, h * w), 0)
                        np.testing.assert_array_equal(final, self.vectors[name + "_final_codes"])
                finally:
                    self.lib.hncs_destroy(context)

    def test_source_parameter_gates_and_invalid_calls(self):
        # Standard and tool presets inherit original Standard USM; they must
        # not be rejected by the older portable model's optional-stage flags.
        for key in [b"standard", b"nature", b"cloudy", b"film-grain-artistic", b"grayscale-blue-filter"]:
            self.assertEqual(self.lib.hncs_native_sharpness_enabled(key), 1)
        self.assertEqual(self.lib.hncs_native_sharpness_enabled(None), -1)
        self.assertEqual(self.lib.hncs_native_sharpness_enabled(b"missing"), -1)
        pixels = np.zeros((1, 1, 3), np.float32)
        for baseline in [-1., float("nan"), float("inf"), 1e308]:
            self.assertEqual(self.lib.hncs_apply_spatial_native_sharpness(
                pixels.ctypes.data, 1, 1, b"standard", 0, 1, baseline), -1)


if __name__ == "__main__":
    unittest.main()
