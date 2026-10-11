"""Hash the current audit inputs, implementation, evidence and deliverables."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
AUDIT=ROOT/'work/hncs-phocus-audit'


def digest(path):
    hasher=hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''):
            hasher.update(block)
    return hasher.hexdigest()


def main():
    paths=[ROOT/name for name in ('README.md','hncs_pipeline.py','prepare_hncs_assets.py',
        'test_hncs_pipeline.py','requirements.txt','19990c35cf194481a0093de2b02ed818.arw',
        '7fbb1471e0cf4b22858cd9a161fb83a8.3fr')]
    paths.extend((ROOT/'work/hncs-pipeline/assets').glob('*'))
    paths.extend((ROOT/'work/hncs-pipeline/output').glob('*'))
    paths.extend(ROOT/'work/hncs-pipeline'/name for name in
        ('a7rv_to_x2dii.json','chart_regions.json','sony_chart_regions.jpg','x2dii_chart_regions.jpg','native_validation.py'))
    paths.extend(ROOT/'work/hncs-pipeline/evidence'/name for name in
        ('HBRawCorrections.arm64.asm','HBUtil.arm64.asm','Phocus.codesign.txt',
         'raw_normalisation.json','ciede2000testdata.txt','README.md'))
    paths.append(ROOT/'work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin')
    manifest=AUDIT/'evidence/artifact_hashes.json'
    paths.extend(p for p in AUDIT.rglob('*') if p.is_file()
                 and '__pycache__' not in p.parts and p!=manifest)
    fw=Path('/Volumes/Phocus/Phocus.app/Contents/Frameworks')
    paths.extend(fw/f'{name}.framework/Versions/A/{name}' for name in
        ('HBRawCorrections','HBUtil','HBImageProcessing','HBStorage'))
    records={}
    for path in sorted(set(paths)):
        if not path.is_file():
            raise FileNotFoundError(path)
        label=str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
        records[label]={'bytes':path.stat().st_size,'sha256':digest(path)}
    manifest.write_text(json.dumps({'schema':1,
        'scope':'Current audit snapshot; older injected-parameter validation files are historical and excluded. The manifest does not hash itself.',
        'files':records},indent=2,ensure_ascii=False)+'\n')
    print(f'Hashed {len(records)} files into {manifest}')


if __name__=='__main__':main()
