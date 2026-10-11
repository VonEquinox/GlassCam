"""Verify integrity and independently compare all stored reference vectors."""
from pathlib import Path
import sys,json,platform
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
import numpy as np
import scipy,rawpy,tifffile,PIL
import hncs_pipeline as h
import hncs_paired_illuminants as paired
from reference_color_core import render

def main():
 manifest_path=ROOT/'validation/delivery_manifest.json';manifest={'files':{}}
 if manifest_path.exists():
  manifest=json.loads(manifest_path.read_text())
  for name,record in manifest['files'].items():
   if h.digest(ROOT/name)!=record['sha256']:raise ValueError('Delivery hash mismatch: '+name)
 assets=h.load_assets();profile=json.loads(h.PROFILE.read_text());paired.load_model()
 parameters=paired.colour_parameters(profile,assets,profile['source_wb'],'calibration')
 checks=[];samples=0
 with np.load(ROOT/'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz',allow_pickle=False) as vectors:
  for key in vectors.files:
   if not key.endswith('_source'):continue
   space,intent,cct,_=key.split('_');source=vectors[key].astype(np.float64)/65535;reference=vectors[key.replace('_source','_output')]
   actual=render(source,int(cct),assets,space,intent);diff=int(np.abs(actual.astype(np.int32)-reference.astype(np.int32)).max())
   if diff:raise ValueError(f'Independent kernel differs: {key}: {diff}')
   np.testing.assert_array_equal(actual,h.hncs_codes(source,int(cct),assets,intent,working_space=space))
   samples+=len(source);checks.append({'key':key,'pixels':len(source),'max_uint16_difference':diff})
 env={'python':sys.version,'platform':platform.platform(),'numpy':np.__version__,'scipy':scipy.__version__,'rawpy':rawpy.__version__,'libraw':rawpy.libraw_version,'pillow':PIL.__version__,'tifffile':tifffile.__version__}
 report={'status':'passed','manifest_files_checked':len(manifest['files']),'environment':env,'vector_groups':len(checks),'pixels':samples,'max_uint16_difference':0,'checks':checks,'paired_profile_validated':True,'factory_cct':parameters['cct']}
 h.save_json(ROOT/'validation/delivery_verification.json',report)
 demo=np.array([[0,0,0],[.01,.01,.01],[.18,.18,.18],[1,0,0],[0,1,0],[0,0,1],[1,1,1],[-.1,.3,1.1]],dtype=np.float64);fixtures={'native_rgb':demo,'cct':np.array([2000,2716,5500,7625,10000])}
 for space in ('legacy','lstar'):
  for intent in ('standard','reproduction'):fixtures[space+'_'+intent]=np.stack([render(demo,k,assets,space,intent) for k in fixtures['cct']])
 if not (ROOT/'validation/color_core_vectors.npz').exists():np.savez_compressed(ROOT/'validation/color_core_vectors.npz',**fixtures)
 print(json.dumps({k:v for k,v in report.items() if k not in ('checks','environment')},indent=2))
if __name__=='__main__':main()
