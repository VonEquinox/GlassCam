"""Recreate original FFCS reference delivery and mobile assets from pinned ZIP.
No downloads, source execution or package installation. Source archive is already
tracked as an existing Git object from the original FFCS delivery branch.
"""
from pathlib import Path, PurePosixPath
import hashlib
import shutil
import subprocess
import zipfile
ROOT=Path(__file__).resolve().parents[1]
REFERENCE=ROOT/'reference_ffcs'
ARCHIVE=REFERENCE/'source.zip'
EXPECTED='bc8c9b4d7691f3ecef03a79e3b1a7ddd8364647e97877ee02ceefa8e50e2ea02'
PREFIX='FFCS_技术实现完整交付/'

def main():
    with ARCHIVE.open('rb') as stream:
        actual=hashlib.file_digest(stream,'sha256').hexdigest()
    if actual!=EXPECTED: raise ValueError('FFCS archive SHA256 mismatch')
    with zipfile.ZipFile(ARCHIVE) as source:
        for entry in source.infolist():
            if entry.is_dir():continue
            if not entry.filename.startswith(PREFIX):raise ValueError('Unexpected archive root')
            relative=PurePosixPath(entry.filename[len(PREFIX):])
            if relative.is_absolute() or '..' in relative.parts or not relative.parts:raise ValueError('Unsafe archive path')
            if ((entry.external_attr>>16)&0o170000)==0o120000:raise ValueError('Archive symlinks forbidden')
            destination=REFERENCE.joinpath(*relative.parts)
            destination.parent.mkdir(parents=True,exist_ok=True)
            with source.open(entry) as src,destination.open('wb') as dst:shutil.copyfileobj(src,dst)
    subprocess.run(['bash',str(ROOT/'tools/prepare_ffcs_resources.sh'),str(ARCHIVE),str(ROOT/'ios/GlassCam/Resources/FFCS/xh2s')],check=True)
    print('Original FFCS reference delivery and 19 mobile LUTs materialized.')

if __name__=='__main__':main()
