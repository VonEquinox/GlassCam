"""Check explicit delivery file hashes and all packaged LUTs."""
from pathlib import Path
import hashlib
import json
from ffcs.lutdata import load_packed_lut

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'validation/delivery_manifest.json').read_text())
for entry in manifest['files']:
    path = root / entry['path']
    if not path.is_file() or path.stat().st_size != entry['bytes']:
        raise AssertionError(f'Missing or wrong size: {path}')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()
    if digest != entry['sha256']:
        raise AssertionError(f'Hash mismatch: {path}')
count = 0
for family in ('xh2s', 'gfx100', 'xa3'):
    directory = root / 'implementation/ffcs/data' / family
    original = json.loads((directory / 'manifest.json').read_text())
    entries = {item['file']: item for item in original['tables']}
    for path in sorted(directory.glob('*.lutz')):
        lut, matrix = load_packed_lut(path)
        entry = entries[path.name]
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256'] or path.stat().st_size != entry['size']:
            raise AssertionError(f'Original asset manifest mismatch: {path}')
        if lut.size != (64 if family == 'xa3' else 80) or len(matrix) != 9:
            raise AssertionError(f'Asset shape mismatch: {path}')
        count += 1
if count != 48:
    raise AssertionError(f'Expected 48 LUTs, got {count}')
print(json.dumps({'status': 'pass', 'files_checked': len(manifest['files']), 'luts_checked': count}, indent=2))
