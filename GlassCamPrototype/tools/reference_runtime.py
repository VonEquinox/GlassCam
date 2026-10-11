"""Load unmodified source functions without unrelated RAW decoder dependencies.

The source is the pinned user-supplied HNCS delivery, not a replacement algorithm.
Only named function definitions are extracted; no arbitrary module top level runs.
"""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / 'reference'
if not REFERENCE.exists():
    REFERENCE = ROOT.parent / 'HNCS技术交付'
ASSETS = REFERENCE / 'work/hncs-pipeline/assets'

def assets():
    provenance = json.loads((ASSETS / 'provenance.json').read_text())
    for name, sha in provenance['files'].items():
        actual = hashlib.sha256((ASSETS / name).read_bytes()).hexdigest()
        if actual != sha:
            raise ValueError('Asset hash mismatch: ' + name)
    with np.load(ASSETS / 'x2dii_phocus_422.npz', allow_pickle=False) as file:
        return {k: file[k] for k in file.files}

def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

reference = load_module(REFERENCE / 'tools/reference_color_core.py', 'hncs_reference')
presets = load_module(REFERENCE / 'phocus_presets.py', 'hncs_presets')
source = (REFERENCE / 'hncs_pipeline.py').read_text()
wanted = {'lerp_table', 'expand_lut', 'lookup_chroma', 'kernel_matrices',
          'hncs_codes', 'lstar_decode', 'srgb_from_hncs'}
functions = [node for node in ast.parse(source).body
             if isinstance(node, ast.FunctionDef) and node.name in wanted]
if {node.name for node in functions} != wanted:
    raise ValueError('Pinned source functions missing')
namespace = {'np': np, 'resolve_film_curve': presets.resolve_film_curve}
exec(compile(ast.Module(body=functions, type_ignores=[]), 'pinned_hncs_functions', 'exec'), namespace)
hncs_codes = namespace['hncs_codes']
srgb_from_hncs = namespace['srgb_from_hncs']

SRGB_TO_XYZ = np.array([[.4124564,.3575761,.1804375],
                        [.2126729,.7151522,.0721750],
                        [.0193339,.1191920,.9503041]])
BRADFORD = np.array([[.8951,.2664,-.1614],[-.7502,1.7135,.0367],[.0389,-.0685,1.0296]])
D65 = np.array([.95047,1.,1.08883])

def experimental_adapter(linear_srgb, cct, a, exposure_ev=0.):
    """Colorimetric convenience bridge, NOT an iPhone sensor calibration.

    Input is already developed linear-sRGB; no extra camera WB is applied.
    The chosen factory CCT changes the reconstructed color core, not scene WB.
    Inversion maps colorimetric XYZ to virtual-native coordinates solely so
    the existing core can run. Negative and >1 values clip at its usual entry.
    """
    pixels = np.asarray(linear_srgb, dtype=np.float64)
    if pixels.shape[-1:] != (3,) or not np.isfinite(pixels).all():
        raise ValueError('Expected finite RGB triplets')
    if not np.isfinite(cct) or not np.isfinite(exposure_ev) or abs(exposure_ev)>2:
        raise ValueError('Invalid controls')
    cct = int(np.clip(int(cct),2000,10000))
    camera = reference.interpolate(cct, a['matrix_temperatures'], a['camera_to_xyz'])
    white = camera.sum(axis=1)
    adaptation = np.linalg.inv(BRADFORD) @ np.diag((BRADFORD@white)/(BRADFORD@D65)) @ BRADFORD
    bridge = np.linalg.inv(camera) @ adaptation @ SRGB_TO_XYZ
    return (pixels @ bridge.T) * (2.**exposure_ev)

def effect(linear_srgb, cct, a, exposure_ev=0.):
    native=experimental_adapter(linear_srgb,cct,a,exposure_ev)
    codes=hncs_codes(native,cct,a,working_space='legacy')
    return srgb_from_hncs(codes,a,'legacy')
