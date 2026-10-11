from pathlib import Path
import tempfile,shutil,subprocess,sys,json
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root))
import package_hncs_runtime as package,hncs_pipeline as h
import numpy as np
base=json.loads(h.PROFILE.read_text());pair=json.loads((root/'work/hncs-finalization/paired_illuminants.json').read_text())
with tempfile.TemporaryDirectory(prefix='hncs-delivery-refit-') as tmp:
 runtime=Path(tmp);names=package.FILES+['fit_paired_illuminants.py','prepare_sony_source_profile.py','work/hncs-pipeline/chart_regions.json','work/hncs-finalization/sources/Sony ILCE-7RM5 Adobe Standard Linear.dcp','work/hncs-finalization/sources/sony-dcp-provenance.json']
 for name in names:
  target=runtime/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
 for source in [root/'19990c35cf194481a0093de2b02ed818.arw',root/'7fbb1471e0cf4b22858cd9a161fb83a8.3fr',*(root/'work/hncs-finalization/raw').glob('*')]:
  target=runtime/source.relative_to(root);target.parent.mkdir(parents=True,exist_ok=True);target.symlink_to(source)
 with (root/'validation/refit_regression.log').open('w') as log:
  for args in [['hncs_pipeline.py','calibrate'],['prepare_sony_source_profile.py'],['fit_paired_illuminants.py']]:subprocess.run([sys.executable,*args],cwd=runtime,stdout=log,stderr=log,check=True)
 newbase=json.loads((runtime/'work/hncs-pipeline/a7rv_to_x2dii.json').read_text());newpair=json.loads((runtime/'work/hncs-finalization/paired_illuminants.json').read_text());diffs={}
 for key in ('matrix','source_wb','target_wb','source_scale','target_scale','target_cct'):
  diff=float(np.max(np.abs(np.array(newbase[key])-np.array(base[key]))));assert diff<1e-12,(key,diff);diffs[key]=diff
 for i in (0,1):
  for key in ('matrix','raw_response','source_wb','target_wb','source_estimated_cct','target_cct'):
   diff=float(np.max(np.abs(np.array(newpair['endpoints'][i][key])-np.array(pair['endpoints'][i][key]))));assert diff<1e-10,(i,key,diff);diffs[f'endpoint_{i}_{key}']=diff
 eval=json.loads((runtime/'work/hncs-finalization/evidence/paired_chart_evaluation.json').read_text())
 h.save_json(root/'validation/refit_regression.json',{'status':'passed','inputs':'delivered chart RAWs, ROI, DCP and source provenance','isolated_models':True,'maximum_absolute_differences':diffs,'evaluation':eval})
 print('Isolated refit numerical regression passed')
