"""Replay original native HDR colors without loading vendor frameworks."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np

ROOT=Path(__file__).resolve().parents[2]


class X2DHDRTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix="x2d-hdr-")
        library=Path(cls.temp.name)/"core.so"
        subprocess.run(["clang++","-std=c++17","-O2","-fno-fast-math","-ffp-contract=off",
                        "-shared","-fPIC","-pthread",str(ROOT/"core/hncs.cpp"),"-o",str(library)],check=True)
        cls.lib=c.CDLL(str(library))
        cls.lib.hncs_create_mode.argtypes=[c.c_double,c.c_double,c.c_int,c.c_int]
        cls.lib.hncs_create_mode.restype=c.c_void_p
        cls.lib.hncs_destroy.argtypes=[c.c_void_p]
        cls.lib.hncs_render_x2d_hdr_color.argtypes=[c.c_void_p,c.c_double,c.c_void_p,c.c_void_p,c.c_size_t]
        cls.manifest=json.loads((ROOT/"validation/x2d-hdr-goldens.json").read_text())
        path=ROOT/"validation"/cls.manifest["vectors"]
        assert hashlib.sha256(path.read_bytes()).hexdigest()==cls.manifest["vectors_sha256"]
        cls.vectors=np.load(path,allow_pickle=False)

    @classmethod
    def tearDownClass(cls):
        cls.vectors.close();cls.temp.cleanup()

    def test_original_hdr_colors_and_context_reuse(self):
        for case in self.manifest["cases"]:
            with self.subTest(space=case["space"],gain=case["gain"]):
                key=case["prefix"]
                source=np.ascontiguousarray(self.vectors[key+"_input"].astype(np.float64)/65535.)
                expected=self.vectors[key+"_expected"];actual=np.empty_like(expected)
                context=self.lib.hncs_create_mode(0.,case["cct"],case["space"],0)
                self.assertTrue(context)
                try:
                    for _ in range(2):
                        self.assertEqual(self.lib.hncs_render_x2d_hdr_color(context,case["gain"],source.ctypes.data,
                                                                          actual.ctypes.data,source.size//3),0)
                        np.testing.assert_array_equal(actual,expected)
                finally:self.lib.hncs_destroy(context)

    def test_unsupported_gain_reproduction_and_nonfinite_input(self):
        source=np.zeros((2,3),np.float64);actual=np.full((2,3),1773,np.uint16)
        context=self.lib.hncs_create_mode(0.,5500.,0,0)
        reproduction=self.lib.hncs_create_mode(0.,5500.,0,1)
        try:
            for ctx,gain in [(None,1.),(reproduction,1.),(context,.24),(context,32.01),
                              (context,float("inf")),(context,float("nan"))]:
                self.assertEqual(self.lib.hncs_render_x2d_hdr_color(ctx,gain,source.ctypes.data,actual.ctypes.data,2),-1)
                self.assertTrue(np.all(actual==1773))
            source[1,2]=np.nan
            self.assertEqual(self.lib.hncs_render_x2d_hdr_color(context,1.,source.ctypes.data,actual.ctypes.data,2),-1)
            self.assertTrue(np.all(actual==1773))
        finally:
            self.lib.hncs_destroy(context);self.lib.hncs_destroy(reproduction)


if __name__=="__main__":unittest.main()
