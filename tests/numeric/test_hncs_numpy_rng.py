"""Production SeedSequence and normal streams agree bit-for-bit with NumPy."""
import ctypes as c
import os
import subprocess

import numpy as np
import pytest

from support.native import ROOT

BOUNDARY_SEEDS = (0, 1, 2, 42, 12345, 2**32 - 1, 2**32, 2**32 + 1, 2**63, 2**64 - 1, 0xdeadbeefcafebabe)
STREAM_SEEDS = BOUNDARY_SEEDS + tuple(np.random.default_rng(91302).integers(0, 2**64, size=21, dtype=np.uint64).tolist())
SEQUENCE_SEEDS = STREAM_SEEDS + tuple(np.random.default_rng(84639).integers(0, 2**64, size=10000, dtype=np.uint64).tolist())
STREAM_DRAW_COUNT = 1000003


@pytest.fixture(scope='module')
def rng_library(tmp_path_factory):
    output = tmp_path_factory.mktemp('rng') / 'rng.so'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-shared', '-fPIC', '-O3',
                    '-fno-fast-math', '-ffp-contract=off', '-Wall', '-Wextra', '-Werror',
                    str(ROOT / 'tests/native-legacy/hncs_numpy_rng_bridge.cpp'), '-o', str(output)], check=True)
    lib = c.CDLL(str(output))
    lib.hncs_rng_seed.argtypes = [c.c_uint64, c.c_void_p]
    lib.hncs_rng_normals.argtypes = [c.c_uint64, c.c_size_t, c.c_void_p]
    lib.hncs_rng_floats.argtypes = [c.c_uint64, c.c_size_t, c.c_void_p]
    return lib


@pytest.mark.parametrize('seed', SEQUENCE_SEEDS)
def test_seed_sequence_matches_numpy(rng_library, seed):
    output = np.empty(4, np.uint64)

    rng_library.hncs_rng_seed(seed, output.ctypes.data)

    np.testing.assert_array_equal(output, np.random.SeedSequence(seed).generate_state(4, dtype=np.uint64))


@pytest.mark.parametrize('seed', STREAM_SEEDS)
@pytest.mark.parametrize('dtype,function,bits', [(np.float64, 'hncs_rng_normals', np.uint64),
                                               (np.float32, 'hncs_rng_floats', np.uint32)])
def test_normal_stream_matches_numpy_bits(rng_library, seed, dtype, function, bits):
    output = np.empty(STREAM_DRAW_COUNT, dtype)
    expected = np.random.default_rng(seed).standard_normal(STREAM_DRAW_COUNT).astype(dtype)

    getattr(rng_library, function)(seed, STREAM_DRAW_COUNT, output.ctypes.data)

    np.testing.assert_array_equal(output.view(bits), expected.view(bits))
