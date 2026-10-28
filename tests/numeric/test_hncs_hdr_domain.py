"""Independent colour-domain vectors and HDR spatial regressions."""
import ctypes as c
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


class HNCSHDRDomainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="hncs-hdr-domain-")
        library = Path(cls.temporary.name) / "core.so"
        subprocess.run(["clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off",
                        "-pthread", "-shared", "-fPIC",
                        *[str(ROOT / "core" / name) for name in ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp"]],
                        "-o", str(library)], check=True)
        cls.lib = c.CDLL(str(library))
        cls.lib.hncs_create_mode.argtypes = [c.c_double, c.c_double, c.c_int, c.c_int]
        cls.lib.hncs_create_mode.restype = c.c_void_p
        cls.lib.hncs_create_preset_whitepoint_with_policy.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_int]
        cls.lib.hncs_create_preset_whitepoint_with_policy.restype = c.c_void_p
        cls.lib.hncs_destroy.argtypes = [c.c_void_p]
        cls.lib.hncs_apple_hdr_work_scale.argtypes = [c.c_double]
        cls.lib.hncs_apple_hdr_work_scale.restype = c.c_double
        cls.lib.hncs_clone_with_apple_hdr_work_scale.argtypes = [c.c_void_p, c.c_double]
        cls.lib.hncs_clone_with_apple_hdr_work_scale.restype = c.c_void_p
        cls.lib.hncs_process_apple_hdr_work_float_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]
        cls.lib.hncs_finish_apple_hdr_work_linear_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_double, c.c_uint]
        cls.lib.hncs_prepare_apple_hdr_spatial.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p,
                                                         c.c_int, c.c_int, c.c_double, c.c_double]
        cls.lib.hncs_prepare_apple_hdr_spatial_file.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t, c.c_char_p,
            c.c_int, c.c_int, c.c_double, c.c_double, c.c_char_p, c.c_void_p, c.c_void_p]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def context(self, lstar=0):
        value = self.lib.hncs_create_preset_whitepoint_with_policy(
            0., .3127, .3290, 0., lstar, 0, 4, 2, b"standard", 1, 1)
        self.assertTrue(value)
        self.addCleanup(self.lib.hncs_destroy, value)
        return value

    def prepare_work(self, context, source, workers=1):
        source = np.ascontiguousarray(source, dtype=np.float32)
        work = np.empty_like(source)
        self.assertEqual(self.lib.hncs_process_apple_hdr_work_float_parallel(
            context, source.ctypes.data, work.ctypes.data, source.size // 3, workers), 0)
        return work

    def finish(self, context, work, scale, workers=1):
        work = np.ascontiguousarray(work, dtype=np.float32)
        output = np.empty((*work.shape[:-1], 4), np.float32)
        self.assertEqual(self.lib.hncs_finish_apple_hdr_work_linear_parallel(
            context, work.ctypes.data, output.ctypes.data, work.size // 3, scale, workers), 0)
        return output

    def test_working_primaries_survive_as_signed_extended_srgb(self):
        # Independent published working-primary matrices and Bradford D65 CAT.
        # Unit primary inputs avoid sharing the production transfer-table code.
        bradford = np.array([[.8951, .2664, -.1614], [-.7502, 1.7135, .0367], [.0389, -.0685, 1.0296]])
        xyz_to_srgb = np.array([[3.2404542, -1.5371385, -.4985314], [-.969266, 1.8760108, .041556], [.0556434, -.2040259, 1.0572252]])
        matrices = [np.array([[.64912, .18858, .12649], [.29886, .65745, .04369], [.00464, .04303, .77724]]),
                    np.array([[.87226, .07622, .01574], [.28112, .69989, .01899], [0., 0., .82521]])]
        for lstar, matrix in enumerate(matrices):
            context = self.lib.hncs_create_mode(0., 5500., lstar, 0)
            self.assertTrue(context)
            try:
                cat = np.linalg.inv(bradford) @ np.diag((bradford @ [.95047, 1., 1.08883]) /
                                                       (bradford @ matrix.sum(axis=1))) @ bradford
                expected = (xyz_to_srgb @ cat @ matrix).T
                actual = self.finish(context, np.eye(3, dtype=np.float32), 1.)
                np.testing.assert_allclose(actual[:, :3], expected, rtol=2e-6, atol=3e-7)
                self.assertLess(float(actual[:, :3].min()), -.01)
                self.assertGreater(float(actual[:, :3].max()), 1.)
                np.testing.assert_array_equal(actual[:, 3], 1.)
            finally:
                self.lib.hncs_destroy(context)

    def test_hdr_magnitude_is_present_before_spatial_processing(self):
        for lstar in [0, 1]:
            context = self.context(lstar)
            work = self.prepare_work(context, [[2., 2., 2.], [4., 4., 4.]])
            self.assertTrue(np.all(work[1] > work[0]))
            if lstar:
                linear = np.where(work <= .08, work / (24389. / 2700.), ((work + .16) / 1.16) ** 3)
            else:
                linear = work.astype(np.float64) ** (563. / 256.)
            np.testing.assert_allclose(linear[1] / linear[0], 2., rtol=2e-6)

    def test_sharpness_operates_on_bright_neutral_structure(self):
        work = np.full((9, 33, 3), 2., np.float32)
        work[:, 15:18] = 2.1
        scale = self.lib.hncs_apple_hdr_work_scale(float(work.max()))
        self.assertEqual(scale, 5.8829245141)
        off, on = work.copy(), work.copy()
        for sharp, image in [(0, off), (1, on)]:
            self.assertEqual(self.lib.hncs_prepare_apple_hdr_spatial(
                image.ctypes.data, 33, 9, b"standard", 0, sharp, 1.5, scale), 0)
        np.testing.assert_array_equal(off, (work.astype(np.float64) / scale).astype(np.float32))
        self.assertGreater(float(on[4, 15, 0]), float(off[4, 15, 0]) + 1e-4)
        self.assertLess(float(on[4, 14, 0]), float(off[4, 14, 0]) - 1e-4)
        np.testing.assert_array_equal(on[:, :, 0], on[:, :, 1])
        np.testing.assert_array_equal(on[:, :, 1], on[:, :, 2])
        self.assertTrue(np.all(np.isfinite(on)) and np.all((on >= 0) & (on <= 1)))

    def test_one_frame_scale_matches_all_strip_partitions_and_file_storage(self):
        context = self.context()
        h, w = 260, 257
        source = np.random.default_rng(19).uniform(0, 8, (h, w, 3)).astype(np.float32)
        whole = self.prepare_work(context, source, workers=4)
        for rows in [17, 64, 129]:
            partitioned = np.concatenate([self.prepare_work(context, source[y:y+rows]) for y in range(0, h, rows)])
            np.testing.assert_array_equal(partitioned, whole)
        scale = self.lib.hncs_apple_hdr_work_scale(float(whole.max()))
        packed = whole.copy()
        self.assertEqual(self.lib.hncs_prepare_apple_hdr_spatial(packed.ctypes.data, w, h, b"standard", 0, 1, 1.5, scale), 0)
        path = Path(self.temporary.name) / "frame.rgbf"
        whole.tofile(path)
        self.assertEqual(self.lib.hncs_prepare_apple_hdr_spatial_file(
            str(path).encode(), w, h, b"standard", 0, 1, 1.5, scale,
            self.temporary.name.encode(), None, None), 0)
        np.testing.assert_array_equal(np.fromfile(path, np.float32).reshape(whole.shape), packed)
        output_context = self.lib.hncs_clone_with_apple_hdr_work_scale(context, scale)
        self.assertTrue(output_context)
        try:
            complete = self.finish(output_context, packed, scale, workers=4)
            for rows in [31, 64]:
                pieces = [self.finish(output_context, packed[y:y+rows], scale) for y in range(0, h, rows)]
                np.testing.assert_array_equal(np.concatenate(pieces), complete)
        finally:
            self.lib.hncs_destroy(output_context)

    def test_invalid_scale_and_missing_scale_binding_are_rejected(self):
        context = self.context()
        for value in [-1., 65., float("inf"), float("nan")]:
            self.assertEqual(self.lib.hncs_apple_hdr_work_scale(value), -1.)
        for value in [0., .5, 65., float("nan")]:
            self.assertFalse(self.lib.hncs_clone_with_apple_hdr_work_scale(context, value))
        work, output = np.zeros((2, 3), np.float32), np.zeros((2, 4), np.float32)
        self.assertEqual(self.lib.hncs_finish_apple_hdr_work_linear_parallel(
            context, work.ctypes.data, output.ctypes.data, 2, 5.8829245141, 1), -1)
        self.assertEqual(self.lib.hncs_prepare_apple_hdr_spatial(work.ctypes.data, 2, 1, b"standard", 0, 0, 0., .5), -1)


if __name__ == "__main__":
    unittest.main()
