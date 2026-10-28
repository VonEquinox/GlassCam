"""Frozen original HDR filter outputs, composition and public-buffer contracts."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


class X2DHDRPostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="x2d-hdr-post-")
        library = Path(cls.temp.name) / "post.so"
        subprocess.run(["clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off",
                        "-shared", "-fPIC", "-pthread", str(ROOT / "core/hncs.cpp"),
                        str(ROOT / "core/hncs_spatial.cpp"), str(ROOT / "core/hncs_numpy_rng.cpp"),
                        str(ROOT / "tools/x2d_hdr_post_model_bridge.cpp"), "-o", str(library)], check=True)
        cls.lib = c.CDLL(str(library))
        cls.lib.hdr_post_model.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int, c.c_double, c.c_double, c.c_int]
        cls.lib.hncs_render_x2d_hdr_post.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_double, c.c_double, c.c_int]
        cls.lib.hncs_apply_x2d_hdr_gradation.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
        cls.lib.hncs_render_x2d_hdr_sharpness.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_double]
        cls.manifest = json.loads((ROOT / "validation/x2d-hdr-post-goldens.json").read_text())
        path = ROOT / "validation" / cls.manifest["vectors"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == cls.manifest["vectors_sha256"]
        cls.vectors = np.load(path, allow_pickle=False)

    @classmethod
    def tearDownClass(cls):
        cls.vectors.close()
        cls.temp.cleanup()

    def test_original_stages_and_combined_public_api(self):
        for case in self.manifest["cases"]:
            with self.subTest(case=case):
                source = np.ascontiguousarray(self.vectors[case["prefix"] + "_input"])
                expected = self.vectors[case["prefix"] + "_expected"]
                actual = np.empty_like(expected)
                self.assertEqual(self.lib.hdr_post_model(source.ctypes.data, actual.ctypes.data, source.size // 3,
                                 case["stage"], case["amount"], case["saturation"], case["lstar"]), 0)
                np.testing.assert_array_equal(actual, expected)
                if case["stage"] == 2:
                    inplace = source.copy()
                    self.assertEqual(self.lib.hncs_render_x2d_hdr_post(inplace.ctypes.data, inplace.ctypes.data,
                                     inplace.size // 3, case["amount"], case["saturation"], case["lstar"]), 0)
                    np.testing.assert_array_equal(inplace, expected)

    def test_invalid_parameters_and_partial_overlap_do_not_write(self):
        source = np.arange(12, dtype=np.uint16)
        output = np.full(12, 1973, dtype=np.uint16)
        render = self.lib.hncs_render_x2d_hdr_post
        for amount, saturation, space in [(-.1, 50., 0), (100.1, 50., 0), (50., -.1, 0),
                (50., 100.1, 0), (float("nan"), 50., 0), (50., float("inf"), 0), (50., 50., 2)]:
            self.assertEqual(render(source.ctypes.data, output.ctypes.data, 4, amount, saturation, space), -1)
            self.assertTrue(np.all(output == 1973))
        self.assertEqual(render(None, output.ctypes.data, 4, 50., 50., 0), -1)
        self.assertEqual(render(source.ctypes.data, None, 4, 50., 50., 0), -1)
        self.assertEqual(render(source.ctypes.data, output.ctypes.data, c.c_size_t(-1).value, 50., 50., 0), -1)
        before = source.copy()
        self.assertEqual(render(source.ctypes.data, source.ctypes.data + 2, 3, 50., 50., 0), -1)
        np.testing.assert_array_equal(source, before)
        self.assertEqual(render(None, None, 0, 50., 50., 0), 0)

    def test_original_hdr_gradation(self):
        manifest = json.loads((ROOT / "validation/x2d-hdr-gradation-goldens.json").read_text())
        path = ROOT / "validation" / manifest["vectors"]
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), manifest["vectors_sha256"])
        with np.load(path, allow_pickle=False) as vectors:
            for case in manifest["cases"]:
                if not case["recover_hue"]:
                    continue
                source = np.ascontiguousarray(vectors[case["prefix"] + "_input"])
                expected = vectors[case["prefix"] + "_expected"]
                actual = np.empty_like(source)
                self.assertEqual(self.lib.hncs_apply_x2d_hdr_gradation(case["preset"].encode(),
                                 source.ctypes.data, actual.ctypes.data, source.size // 3), 0)
                np.testing.assert_array_equal(actual, expected)
                self.assertEqual(self.lib.hncs_apply_x2d_hdr_gradation(case["preset"].encode(),
                                 source.ctypes.data, source.ctypes.data, source.size // 3), 0)
                np.testing.assert_array_equal(source, expected)

    def test_original_hdr_sharpness_factory_presets(self):
        manifest = json.loads((ROOT / "validation/x2d-hdr-sharpness-goldens.json").read_text())
        path = ROOT / "validation" / manifest["vectors"]
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), manifest["vectors_sha256"])
        with np.load(path, allow_pickle=False) as vectors:
            for preset, key in [(b"standard", "a100_r1.0"), (b"nature", "a180_r0.8")]:
                source = np.ascontiguousarray(vectors[key + "_source"])
                expected, actual = vectors[key + "_native"], np.empty_like(source)
                h, w = source.shape[:2]
                self.assertEqual(self.lib.hncs_render_x2d_hdr_sharpness(source.ctypes.data,
                                 actual.ctypes.data, w, h, preset, 1.5), 0)
                np.testing.assert_array_equal(actual, expected)
                for invalid in [-1., float("nan"), float("inf"), 1e308]:
                    self.assertEqual(self.lib.hncs_render_x2d_hdr_sharpness(source.ctypes.data,
                                     actual.ctypes.data, w, h, preset, invalid), -1)
                self.assertEqual(self.lib.hncs_render_x2d_hdr_sharpness(source.ctypes.data,
                                 source.ctypes.data, w, h, preset, 1.5), -1)


if __name__ == "__main__":
    unittest.main()
