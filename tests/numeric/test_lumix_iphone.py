"""Photographic adapter regressions, separate from the original RGB48 oracle."""
import concurrent.futures
import ctypes as C
import json
from pathlib import Path
from native_build import build_product
import sys
import tempfile
import unittest
import zipfile

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from prepare_lumix_resources import prepare


class LUMIXIPhone(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="glasscam-lumix-iphone-")
        directory = Path(cls.work.name)
        library = build_product()
        cls.assets = directory / "LUMIX"
        for name in ["source.zip", "pipeline.zip"]:
            prepare(ROOT / "vendor/lumix" / name, cls.assets)
        cls.lib = C.CDLL(str(library))
        cls.lib.lumix_create_pipeline.argtypes = [C.c_char_p, C.c_size_t, C.c_double,
            C.c_int, C.c_int, C.c_int, C.c_char_p, C.c_size_t]
        cls.lib.lumix_create_pipeline.restype = C.c_void_p
        cls.lib.lumix_destroy.argtypes = [C.c_void_p]
        cls.lib.lumix_process_rgb16.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t,
            C.c_double, C.c_double, C.c_int, C.c_void_p, C.c_char_p, C.c_size_t]
        cls.lib.lumix_process_iphone_rgba.argtypes = [C.c_void_p, C.c_void_p,
            C.c_size_t, C.c_size_t, C.c_double, C.c_void_p, C.c_size_t, C.c_char_p, C.c_size_t]

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def context(self, look=0, kelvin=6500, contrast=10, saturation=10, iso=100):
        error = C.create_string_buffer(1024)
        ctx = self.lib.lumix_create_pipeline(str(self.assets).encode(), look, kelvin,
            contrast, saturation, iso, error, len(error))
        self.assertTrue(ctx, error.value)
        self.addCleanup(self.lib.lumix_destroy, ctx)
        return ctx

    def render(self, ctx, values, ev=0):
        values = np.ascontiguousarray(values, dtype=np.float32).reshape(-1, 3)
        output = np.empty((len(values), 4), dtype=np.float32)
        error = C.create_string_buffer(1024)
        status = self.lib.lumix_process_iphone_rgba(ctx, values.ctypes.data, values.size,
            len(values), ev, output.ctypes.data, output.size, error, len(error))
        self.assertEqual(status, 1, error.value)
        self.assertTrue(np.isfinite(output).all())
        self.assertGreaterEqual(float(output.min()), 0)
        self.assertLessEqual(float(output.max()), 1)
        np.testing.assert_array_equal(output[:, 3], 1)
        return output

    def test_original_rgb48_fixtures_remain_bit_exact(self):
        # Independent samples from the pinned original application, not from
        # the new adapter. Replaying these must not rewrite the fixture archive.
        manifest = json.loads((self.assets / "pipeline-manifest.json").read_text())
        indices = {row["photoStyle"]: index for index, row in enumerate(manifest["looks"])}
        with zipfile.ZipFile(ROOT / "tests/fixtures/lumix/native-full-vectors.zip") as archive:
            for name in archive.namelist():
                if not name.endswith(".rgb16"):
                    continue
                # Negative EV introduces a double hyphen in the fixture name.
                fields = name[:-6].replace("--", "-NEG").split("-")
                style, kelvin, contrast, saturation, iso, white = map(int, fields[:6])
                ev, space = float(fields[6].replace("NEG", "-")), int(fields[7])
                ctx = self.context(indices[style], kelvin, contrast, saturation, iso)
                values = np.frombuffer(archive.read(name), dtype="<u2").reshape(-1, 6)
                source = np.ascontiguousarray(values[:, :3]); output = np.empty_like(source)
                error = C.create_string_buffer(1024)
                self.assertEqual(self.lib.lumix_process_rgb16(ctx, source.ctypes.data,
                    len(source), white, ev, space, output.ctypes.data, error, len(error)), 1, error.value)
                np.testing.assert_array_equal(output, values[:, 3:], err_msg=name)

    def test_saturated_ramps_cannot_wrap_to_black(self):
        ramp = np.linspace(0, 1, 4097, dtype=np.float32)
        colors = np.concatenate([ramp[:, None] * color for color in np.eye(3, dtype=np.float32)])
        # Exercise defaults and both ends of the public controls for every look.
        for look in range(16):
            for contrast, saturation in [(0, 0), (10, 10), (20, 20)]:
                with self.subTest(look=look, contrast=contrast, saturation=saturation):
                    output = self.render(self.context(look, contrast=contrast, saturation=saturation), colors)
                    steps = np.diff(output[:, :3].reshape(3, -1, 3), axis=1)
                    self.assertLess(float(np.abs(steps).max()), 0.025,
                                    "A neighboring saturated input caused a color discontinuity")

    def test_gray_ramps_have_no_large_reversals_and_preserve_endpoints(self):
        gray = np.repeat(np.linspace(0, 1, 4097, dtype=np.float32)[:, None], 3, axis=1)
        for look in range(16):
            result = self.render(self.context(look), gray)
            luma = result[:, :3] @ [.2126, .7152, .0722]
            # Original integer LUT nodes have small local reversals; preserve
            # those assets while excluding the large drops caused by wrapping.
            self.assertGreaterEqual(float(np.diff(luma).min()), -0.002)
            self.assertLess(float(result[0, :3].max()), 0.005)
            self.assertGreater(float(result[-1, :3].min()), 0.95)

    def test_iphone_iso_does_not_select_panasonic_sensor_compensation(self):
        values = np.random.default_rng(42).uniform(0, 1, (1024, 3))
        expected = self.render(self.context(), values)
        for iso in [50, 64, 80, 400]:
            np.testing.assert_array_equal(self.render(self.context(iso=iso), values), expected)

    def test_signed_gamut_inputs_strips_and_exposure(self):
        values = np.random.default_rng(69).uniform(-.25, 1, (4096, 3)).astype(np.float32)
        ctx = self.context(1, kelvin=4000, contrast=20, saturation=20)
        expected = self.render(ctx, values)
        with concurrent.futures.ThreadPoolExecutor(4) as executor:
            actual = np.concatenate(list(executor.map(lambda p: self.render(ctx, p), np.array_split(values, 4))))
        np.testing.assert_array_equal(actual, expected)
        np.testing.assert_array_equal(self.render(ctx, values, ev=1), self.render(ctx, values*2))

    def test_nonfinite_input_is_rejected_before_writing(self):
        ctx = self.context()
        for value in [float("nan"), float("inf"), -float("inf")]:
            source = np.array([[.2, .3, .4], [value, 0, 0]], dtype=np.float32)
            result = np.full((2, 4), -99, dtype=np.float32)
            error = C.create_string_buffer(1024)
            self.assertEqual(self.lib.lumix_process_iphone_rgba(ctx, source.ctypes.data,
                source.size, len(source), 0, result.ctypes.data, result.size, error, len(error)), 0)
            np.testing.assert_array_equal(result, -99)


if __name__ == "__main__":
    unittest.main()
