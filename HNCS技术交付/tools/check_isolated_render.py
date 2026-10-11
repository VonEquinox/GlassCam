"""Re-render supplied DSC07247 in isolation and compare portable pixel hashes."""
from pathlib import Path
import tempfile,shutil,sys,subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
import hncs_pipeline as h,package_hncs_runtime as package
import tifffile

def main():
 baseline=json.loads((ROOT/'validation/photo_baseline.json').read_text())
 with tempfile.TemporaryDirectory(prefix='hncs-delivery-isolated-') as temp:
  runtime=Path(temp)/'runtime';output=Path(temp)/'output';runtime.mkdir()
  for name in package.FILES:
   target=runtime/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
  command=[sys.executable,str(runtime/'process_photo_batch.py'),'--output-dir',str(output),str(ROOT/'DSC07247.ARW')]
  with (ROOT/'validation/isolated_render.log').open('w') as log:subprocess.run(command,cwd=temp,stdout=log,stderr=log,check=True)
  folder=output/'DSC07247';records={}
  for name,expected in baseline.items():
   image=tifffile.memmap(folder/name,mode='r');digest=hashlib.sha256()
   for row in range(0,len(image),96):digest.update(image[row:row+96].tobytes())
   assert list(image.shape)==expected['shape'];assert digest.hexdigest()==expected['pixel_sha256'],name
   with tifffile.TiffFile(folder/name) as tf:
    page=tf.pages[0];orientation=int(page.tags[274].value) if 274 in page.tags else 1
    assert orientation==expected['orientation']
    if expected['master_icc_sha256']:assert hashlib.sha256(page.tags[34675].value).hexdigest()==expected['master_icc_sha256']
   records[name]={'shape':list(image.shape),'pixel_sha256':digest.hexdigest(),'pixels_identical_to_baseline':True,'orientation':orientation}
   del image
  verification=json.loads((folder/'verification.json').read_text());assert verification['dng_full_cfa_samples_identical']
  h.save_json(ROOT/'validation/isolated_render.json',{'status':'passed','runtime_source':'only delivered files in a temporary directory','no_external_runtime_assets':True,'input_sha256':h.digest(ROOT/'DSC07247.ARW'),'full_cfa_identical':True,'tiff_comparisons':records,'verification':verification})
  print('Isolated photo pixels, orientation, master ICC and full DNG CFA passed')
if __name__=='__main__':main()
