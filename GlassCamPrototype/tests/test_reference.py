import json
import sys
import unittest
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import reference_runtime as r

class ReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.a=r.assets()

    def test_all_original_native_golden_vectors(self):
        count=0
        with np.load(r.REFERENCE/'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz',allow_pickle=False) as v:
            for key in v.files:
                if not key.endswith('_source'): continue
                space,intent,cct,_=key.split('_')
                src=v[key].astype(np.float64)/65535
                expected=v[key.replace('_source','_output')]
                with self.subTest(key=key):
                    np.testing.assert_array_equal(r.reference.render(src,int(cct),self.a,space,intent),expected)
                    np.testing.assert_array_equal(r.hncs_codes(src,int(cct),self.a,intent,working_space=space),expected)
                count+=1
        self.assertEqual(count,52)

    def test_adapter_controls_and_nonfinite(self):
        for bad in (np.nan,np.inf):
            with self.assertRaises(ValueError): r.experimental_adapter([[bad,0,0]],5500,self.a)
            with self.assertRaises(ValueError): r.experimental_adapter([[0,0,0]],bad,self.a)
        with self.assertRaises(ValueError): r.experimental_adapter([[0,0,0]],5500,self.a,3)
        base=r.experimental_adapter([[.18,.18,.18]],5500,self.a)
        np.testing.assert_allclose(r.experimental_adapter([[.18,.18,.18]],5500,self.a,1),base*2)

    def test_original_bounds_and_tile_invariance(self):
        src=np.random.default_rng(7).uniform(-.2,1.2,(65,33,3))
        full=r.hncs_codes(src,5500,self.a,working_space='legacy')
        tiled=np.concatenate([r.hncs_codes(t,5500,self.a,working_space='legacy') for t in np.array_split(src,7)])
        np.testing.assert_array_equal(full,tiled)
        self.assertEqual(full.dtype,np.uint16)
        with self.assertRaises(ValueError): r.hncs_codes([[np.nan,0,0]],5500,self.a)

    def test_effect_returns_finite_display_rgb(self):
        x=np.random.default_rng(99).uniform(0,1,(32,32,3))
        for cct in (2000,5500,10000):
            out=r.effect(x,cct,self.a)
            self.assertTrue(np.isfinite(out).all())
            self.assertTrue(np.all((out>=0)&(out<=1)))

if __name__=='__main__': unittest.main(verbosity=2)
