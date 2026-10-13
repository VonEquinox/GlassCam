"""Sample the two omitted native camera tables into reproducible FFCSLUT2 assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True, help="Expanded vendor .app directory")
parser.add_argument("--probe", type=Path, required=True, help="x86_64 native_probe executable")
parser.add_argument("--out", type=Path, default=ROOT / "ffcs/data")
args = parser.parse_args()
library = args.app / "Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
vendor = library.parent / "Resources/ColorModeData"
sources = {
    "gfx100s": ("nostalgic_neg", "CAM_GFX100S_NOSTALGIC_NEG_ISLRGB.s3d"),
    "gfx100ii": ("reala_ace", "CAM_GFX100_II_REALA_ACE_ISLRGB.s3d"),
}
for family, (look, filename) in sources.items():
    source = vendor / filename
    data = source.read_bytes()
    if not data.startswith(b"ISL_3DMAP_V2") or data[12] != 0:
        raise ValueError(f"Unexpected native format: {source}")
    n = struct.unpack_from("<H", data, 14)[0]
    gamma = struct.unpack_from("<i", data, 20)[0] / 1024
    grid = np.indices((n,n,n),dtype=np.float64)/(n-1)
    bgr = np.moveaxis(grid[::-1],0,-1)
    linear = np.rint(bgr**gamma*20000).astype("<u2")
    with tempfile.TemporaryDirectory(prefix="ffcs-lut-extract-") as directory:
        inp,out = Path(directory)/"input.bin",Path(directory)/"output.bin"
        inp.write_bytes(linear.tobytes())
        result = subprocess.run([str(args.probe),str(library),str(source),str(inp),str(out)],capture_output=True,text=True,timeout=60)
        if result.returncode: raise RuntimeError(result.stderr)
        values = np.frombuffer(out.read_bytes(),dtype="<u2").reshape(-1,3)
        if len(values)!=n**3: raise ValueError("Incomplete native sample output")
        encoded = np.clip(values[:,::-1]/20000,0,1)**(1/gamma)
        payload = np.rint(encoded*20000).astype("<u2").tobytes()
    compressed = zlib.compress(payload,9)
    matrix = (1.,0.,0.,0.,1.,0.,0.,0.,1.)
    packed = struct.pack("<8sHHf9fB3xI",b"FFCSLUT2",n,3,20000,*matrix,1,len(compressed))+compressed
    directory = args.out/family
    directory.mkdir(parents=True,exist_ok=True)
    path = directory/f"{look}.lutz"
    path.write_bytes(packed)
    manifest = {"camera":family.upper(),"format":"FFCSLUT2","nodes_per_axis":n,"tables":[{
        "file":path.name,"size":len(packed),"sha256":hashlib.sha256(packed).hexdigest(),
        "native_file":filename,"native_sha256":hashlib.sha256(data).hexdigest(),
        "native_library_sha256":hashlib.sha256(library.read_bytes()).hexdigest(),
        "header_gamma":gamma,"working_scale":20000,
        "method":"uniform encoded RGB grid, native TransFormTrilinear, explicit header Gamma",
    }]}
    (directory/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(json.dumps(manifest))
