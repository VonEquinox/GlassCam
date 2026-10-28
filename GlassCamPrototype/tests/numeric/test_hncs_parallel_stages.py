"""Compare production parallel stages with their untouched serial oracles."""
import ctypes as c
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


class HNCSParallelStages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="hncs-parallel-stages-")
        path = Path(cls.directory.name) / "libhncs.dylib"
        subprocess.run(["clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
                        "-shared", "-fPIC", "-pthread", str(ROOT / "core/hncs.cpp"), "-o", str(path)], check=True)
        cls.lib = c.CDLL(str(path))
        cls.lib.hncs_create_preset_whitepoint.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int]
        cls.lib.hncs_create_preset_whitepoint.restype = c.c_void_p
        cls.lib.hncs_destroy.argtypes = [c.c_void_p]
        cls.stages = [("hncs_process_linear_rgba", 4), ("hncs_process_preset_work_float", 3),
                      ("hncs_finish_preset_work_linear", 4), ("hncs_process_phocus_work_float", 3),
                      ("hncs_finish_phocus_work_linear", 4), ("hncs_process_phocus_linear_rgba", 4)]
        for name, _ in cls.stages:
            getattr(cls.lib, name).argtypes = [c.c_void_p] * 3 + [c.c_size_t]
            getattr(cls.lib, name + "_parallel").argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_all_parallel_boundaries_are_bit_identical(self):
        rng = np.random.default_rng(17102026)
        pixels = rng.uniform(-0.2, 1.2, (131079, 3)).astype(np.float32)
        pixels[:8] = [[0, 0, 0], [1, 1, 1], [-1, -1, -1], [2, 2, 2],
                      [1, 0, 0], [0, 1, 0], [0, 0, 1], [.5, .5, .5]]
        for index, preset in enumerate(["standard", "nature", "lighten", "extra-contrast",
                                        "high", "film-grain-artistic", "square-crop", "tungsten",
                                        "saturated", "grayscale-red-filter"]):
            ctx = self.lib.hncs_create_preset_whitepoint([-2, 0, 2][index % 3], .33943, .35259,
                0, index % 2, (index // 2) % 2, 4, 2, preset.encode(), index % 2)
            self.assertTrue(ctx)
            try:
                for name, channels in self.stages:
                    for count in [1, 32767, 65535, 65536, 65539, len(pixels)]:
                        expected = np.zeros((count, channels), np.float32)
                        self.assertEqual(getattr(self.lib, name)(ctx, pixels.ctypes.data, expected.ctypes.data, count), 0)
                        for workers in [1, 2, 3, 4]:
                            actual = np.full_like(expected, -100)
                            self.assertEqual(getattr(self.lib, name + "_parallel")(
                                ctx, pixels.ctypes.data, actual.ctypes.data, count, workers), 0)
                            self.assertEqual(actual.tobytes(), expected.tobytes(), (preset, name, count, workers))
            finally:
                self.lib.hncs_destroy(ctx)

    def test_invalid_inputs_fail_without_changing_the_contract(self):
        ctx = self.lib.hncs_create_preset_whitepoint(0, .3127, .329, 0, 0, 0, 4, 2, b"nature", 1)
        try:
            pixels = np.zeros((65539, 3), np.float32)
            output = np.zeros((65539, 4), np.float32)
            for name, _ in self.stages:
                run = getattr(self.lib, name + "_parallel")
                for workers in [1, 2, 3, 4]:
                    self.assertEqual(run(ctx, None, None, 0, workers), 0)
                    self.assertEqual(run(None, None, None, 0, workers), -1)
                    self.assertEqual(run(ctx, None, output.ctypes.data, 1, workers), -1)
                    self.assertEqual(run(ctx, pixels.ctypes.data, None, 1, workers), -1)
                    self.assertEqual(run(ctx, pixels.ctypes.data, output.ctypes.data, 2**64 - 1, workers), -1)
                    for bad in [np.nan, np.inf]:
                        pixels[-1, 2] = bad
                        self.assertEqual(run(ctx, pixels.ctypes.data, output.ctypes.data, len(pixels), workers), -1)
                    pixels[-1, 2] = 0
                for workers in [0, 5]:
                    self.assertEqual(run(ctx, None, None, 0, workers), -1)
        finally:
            self.lib.hncs_destroy(ctx)


if __name__ == "__main__":
    unittest.main()
