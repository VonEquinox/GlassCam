"""Build integrity manifest for immutable delivered files."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
MUTABLE={'validation/delivery_manifest.json','validation/delivery_verification.json','validation/isolated_render.json','validation/refit_regression.json'}

def main():
 files={}
 for path in sorted(ROOT.rglob('*')):
  if not path.is_file() or '__pycache__' in path.parts or path.name=='.DS_Store':continue
  name=str(path.relative_to(ROOT))
  if name in MUTABLE or (name.startswith('validation/') and path.suffix=='.log'):continue
  with path.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
  files[name]={'bytes':path.stat().st_size,'sha256':digest}
 record={'schema':1,'scope':'immutable delivery files; excludes caches, manifest itself and regenerated validation reports/logs','files':files}
 (ROOT/'validation/delivery_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
 print('Manifest:',len(files),'files;',sum(v['bytes'] for v in files.values()),'bytes')
if __name__=='__main__':main()
