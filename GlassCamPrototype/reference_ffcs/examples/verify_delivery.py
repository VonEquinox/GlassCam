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
for directory in sorted((root / 'implementation/ffcs/data').iterdir()):
    if not (directory / 'manifest.json').is_file():
        continue
    family = directory.name
    original = json.loads((directory / 'manifest.json').read_text())
    entries = {item['file']: item for item in original['tables']}
    if set(entries) != {p.name for p in directory.glob('*.lutz')}:
        raise AssertionError(f'Asset manifest paths differ: {directory}')
    for path in sorted(directory.glob('*.lutz')):
        lut, matrix = load_packed_lut(path)
        entry = entries[path.name]
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256'] or path.stat().st_size != entry['size']:
            raise AssertionError(f'Original asset manifest mismatch: {path}')
        if lut.size != (64 if family == 'xa3' else 80) or len(matrix) != 9:
            raise AssertionError(f'Asset shape mismatch: {path}')
        count += 1
inventory = json.loads((root / 'validation/asset_inventory.json').read_text())
if count != inventory['lut_count']:
    raise AssertionError(f"Expected {inventory['lut_count']} LUTs, got {count}")
print(json.dumps({'status': 'pass', 'files_checked': len(manifest['files']), 'luts_checked': count}, indent=2))
