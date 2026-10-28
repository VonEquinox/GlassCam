#!/usr/bin/env python3
"""Temporary layer check for App/GlassCam Swift files (T06–T08 only)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'App/GlassCam'
ALLOWED = {
    'ImagingCore/Model': set(),
    'ImagingCore/Engines': {'ImagingCore/Model'},
    'ImagingCore/Processing': {'ImagingCore/Model', 'ImagingCore/Engines'},
    'Capture': {'ImagingCore/Model', 'ImagingCore/Engines', 'ImagingCore/Processing'},
    'F5': {'ImagingCore/Model', 'ImagingCore/Engines', 'ImagingCore/Processing', 'Capture'},
    'Peripheral': {'ImagingCore/Model'},
}
APP_LAYERS = ('Camera', 'UI', 'Bench')
DECLARATION = re.compile(
    r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|final|nonisolated)\s+)*'
    r'(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)', re.M)


def layer(path):
    relative = path.relative_to(ROOT).as_posix()
    for name in (*ALLOWED, *APP_LAYERS):
        if relative.startswith(name + '/'):
            return name
    return None


files = sorted(ROOT.rglob('*.swift'))
owner = {}
for path in files:
    for name in DECLARATION.findall(path.read_text()):
        owner.setdefault(name, path)

violations = 0
for path in files:
    source = layer(path)
    if source not in ALLOWED:
        continue
    text = re.sub(r'//[^\n]*', '', path.read_text())
    for name in sorted(set(re.findall(r'\b[A-Z]\w*\b', text))):
        target_path = owner.get(name)
        if target_path is None or target_path == path:
            continue
        target = layer(target_path)
        if target != source and target not in ALLOWED[source]:
            violations += 1
            print(f'{path.relative_to(ROOT)} -> {name} ({target})')
sys.exit(1 if violations else 0)
