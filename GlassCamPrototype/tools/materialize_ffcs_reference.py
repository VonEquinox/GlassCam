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
EXPECTED='ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c'
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
    subprocess.run(['bash',str(ROOT/'tools/prepare_ffcs_resources.sh'),str(ARCHIVE),str(ROOT/'ios/GlassCam/Resources/FFCS')],check=True)
    print('Original FFCS reference delivery and 50 mobile LUTs materialized.')

if __name__=='__main__':main()
