"""Verify every packed asset against the explicit native trilinear entry."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from ffcs.color import apply_3d_lut,rgb_to_lab
from ffcs.lutdata import load_packed_lut
from ffcs.metrics import delta_e_2000
from ffcs.models import FilmSimulation

parser=argparse.ArgumentParser()
parser.add_argument("--app",type=Path,required=True)
parser.add_argument("--probe",type=Path,required=True)
parser.add_argument("--out",type=Path,default=ROOT/"ffcs/data/reference_validation.json")
args=parser.parse_args()
library=args.app/"Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
vendor=library.parent/"Resources/ColorModeData"
prefixes={"xh2s":"CAM_FUJI_XH2S_","xa3":"CAM_FUJI_XA3_","gfx100":"CAM_GFX_100_",
          "gfx100s":"CAM_GFX100S_","gfx100ii":"CAM_GFX100_II_"}
rng=random.Random(20261013)
samples=[tuple(rng.random() for _ in range(3)) for _ in range(2000)]
report={"version":"0.2.0","date":"2026-10-13","seed":20261013,"samples_per_table":2000,
        "method":"ReadMappingData + TransFormTrilinear; explicit native header Gamma decode/encode; BGR uint16; scale 20000",
        "metric_domain":"display-coded samples interpreted as sRGB for Lab/CIEDE2000",
        "native_library_sha256":hashlib.sha256(library.read_bytes()).hexdigest(),
        "scope":"LUT mapping only; sigma=1; no GUI/RAW/end-to-end equivalence claim","tables":{}}
with tempfile.TemporaryDirectory(prefix="ffcs-native-verify-") as directory:
    inp,out=Path(directory)/"input.bin",Path(directory)/"output.bin"
    for path in sorted((ROOT/"ffcs/data").glob("*/*.lutz")):
        source=vendor/(prefixes[path.parent.name]+path.stem.upper()+"_ISLRGB.s3d")
        data=source.read_bytes()
        gamma=struct.unpack_from("<i",data,20)[0]/1024 if data.startswith(b"ISL_3DMAP_V2") else struct.unpack_from("<H",data,16)[0]/100
        inp.write_bytes(b"".join(struct.pack("<3H",*(round(v**gamma*20000) for v in reversed(rgb))) for rgb in samples))
        completed=subprocess.run([str(args.probe),str(library),str(source),str(inp),str(out)],capture_output=True,text=True,timeout=30)
        if completed.returncode: raise RuntimeError(completed.stderr)
        triples=list(struct.iter_unpack("<3H",out.read_bytes()))
        if len(triples)!=len(samples): raise ValueError("Incomplete native output")
        lut,_=load_packed_lut(path);spec=FilmSimulation("VERIFY",lut=lut,lut_size=lut.size)
        channel,de=[],[]
        for rgb,bgr in zip(samples,triples):
            native=tuple(min(1.,v/20000)**(1/gamma) for v in reversed(bgr))
            portable=apply_3d_lut(rgb,spec)
            channel.append(max(abs(a-b) for a,b in zip(native,portable)))
            de.append(delta_e_2000(rgb_to_lab(native),rgb_to_lab(portable)))
        row={"samples":len(samples),"seed":20261013,"header_gamma":gamma,"nodes":lut.size,
             "native_file":source.name,"native_sha256":hashlib.sha256(data).hexdigest(),
             "packed_sha256":hashlib.sha256(path.read_bytes()).hexdigest(),
             "mean_max_channel_error":sum(channel)/len(channel),"max_channel_error":max(channel),
             "p95_channel_error":sorted(channel)[math.ceil(.95*len(channel))-1],
             "delta_e2000_mean":sum(de)/len(de),"delta_e2000_max":max(de),
             "delta_e2000_p95":sorted(de)[math.ceil(.95*len(de))-1],
             "mean_gate":"pass" if sum(de)/len(de)<1 else "fail"}
        report["tables"][str(path.relative_to(ROOT/"ffcs/data"))]=row
report["total_samples"]=len(samples)*len(report["tables"])
args.out.parent.mkdir(parents=True,exist_ok=True)
args.out.write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps({"tables":len(report["tables"]),"samples":report["total_samples"],
                  "max_table_mean_delta_e2000":max(row["delta_e2000_mean"] for row in report["tables"].values()),
                  "failed_tables":[key for key,row in report["tables"].items() if row["mean_gate"]!="pass"]},indent=2))
