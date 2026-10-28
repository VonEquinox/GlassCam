"""Native libraries and pinned resources shared by numerical behavior tests."""
from pathlib import Path
import ctypes as c
import hashlib
import json
import os
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))


@pytest.fixture(scope='session', autouse=True)
def ffcs_resources():
    from materialize_ffcs_reference import PREFIX, verified_archive
    reference = ROOT / 'vendor/ffcs'
    manifest = json.loads((reference / 'validation/delivery_manifest.json').read_text())
    with verified_archive(reference / 'source.zip') as archive:
        for entry in manifest['files']:
            path = Path(entry['path'])
            if path.parts[:3] != ('implementation', 'ffcs', 'data') or path.suffix not in ('.lutz', '.icc'):
                continue
            if '..' in path.parts:
                raise ValueError('Invalid reference asset path')
            destination = reference / path
            if destination.exists():
                continue
            data = archive.read(PREFIX + path.as_posix())
            if hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError('Reference asset hash mismatch: ' + path.as_posix())
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    subprocess.run(['bash', str(ROOT / 'scripts/prepare_ffcs_resources.sh'), str(reference / 'source.zip'),
                    str(ROOT / 'App/GlassCam/Resources/FFCS')], check=True)


@pytest.fixture(scope='session')
def native_library_path(tmp_path_factory):
    output = tmp_path_factory.mktemp('native') / 'libglasscam.so'
    sources = ['hncs.cpp', 'hncs_spatial.cpp', 'hncs_numpy_rng.cpp', 'ffcs.cpp', 'lumix.cpp']
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O3', '-fno-fast-math',
                    '-ffp-contract=off', '-shared', '-fPIC', '-pthread',
                    *(str(ROOT / 'core' / name) for name in sources), '-lz', '-o', str(output)], check=True)
    return output


@pytest.fixture(scope='session')
def native(native_library_path):
    from support.native import configure
    return configure(c.CDLL(str(native_library_path)))


@pytest.fixture(scope='session')
def reference_assets():
    from support import reference_runtime
    return reference_runtime.assets()


@pytest.fixture(scope='session')
def lumix_resources(tmp_path_factory):
    from prepare_lumix_resources import prepare
    output = tmp_path_factory.mktemp('lumix') / 'LUMIX'
    prepare(ROOT / 'vendor/lumix/source.zip', output)
    return output
