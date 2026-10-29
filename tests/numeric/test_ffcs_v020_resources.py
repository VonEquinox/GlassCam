"""Pinned FFCS archive and materialized LUT identity."""
import hashlib
import zipfile

import pytest

from support.native import ROOT

ENTRIES = tuple(tuple(line.split()) for line in (ROOT / 'scripts/ffcs_native_SHA256SUMS').read_text().splitlines())


@pytest.mark.parametrize('digest,name', ENTRIES, ids=[name for _, name in ENTRIES])
def test_manifest_asset_matches_original_archive_and_bundle(digest, name):
    with zipfile.ZipFile(ROOT / 'vendor/ffcs/source.zip') as archive:
        raw = archive.read('FFCS_技术实现完整交付/implementation/ffcs/data/' + name)
    bundled = (ROOT / 'App/GlassCam/Resources/FFCS' / name).read_bytes()

    assert hashlib.sha256(raw).hexdigest() == digest
    assert hashlib.sha256(bundled).hexdigest() == digest


def test_manifest_assets_are_unique():
    names = [name for _, name in ENTRIES]
    assert len(names) == 50
    assert len(set(names)) == 50


@pytest.mark.parametrize('name,present', [('gfx100s/nostalgic_neg.lutz', True),
    ('gfx100ii/reala_ace.lutz', True), ('xh2s/reala_ace.lutz', False)])
def test_dedicated_tables_match_declared_family(name, present):
    assert (name in {name for _, name in ENTRIES}) == present


def test_archive_hash_is_pinned():
    expected = 'ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c'
    with (ROOT / 'vendor/ffcs/source.zip').open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    assert actual == expected
