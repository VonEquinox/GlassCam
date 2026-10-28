"""Pinned FFCS archive and materialized LUT identity."""
import hashlib
from pathlib import Path
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[2]
class FFCS020Resources(unittest.TestCase):
    def test_all_fifty_manifest_assets_match_original_archive_and_bundle(self):
        entries=[line.split() for line in (ROOT/'tools/ffcs_native_SHA256SUMS').read_text().splitlines()]
        self.assertEqual(len(entries),50)
        self.assertEqual(len({name for _,name in entries}),50)
        with zipfile.ZipFile(ROOT/'reference_ffcs/source.zip') as archive:
            for digest,name in entries:
                with self.subTest(asset=name):
                    raw=archive.read('FFCS_技术实现完整交付/implementation/ffcs/data/'+name)
                    self.assertEqual(hashlib.sha256(raw).hexdigest(),digest)
                    self.assertEqual(hashlib.sha256((ROOT/'ios/GlassCam/Resources/FFCS'/name).read_bytes()).hexdigest(),digest)
    def test_new_dedicated_tables_are_present_without_fake_xh2s_reala(self):
        entries=(ROOT/'tools/ffcs_native_SHA256SUMS').read_text()
        self.assertIn('gfx100s/nostalgic_neg.lutz',entries)
        self.assertIn('gfx100ii/reala_ace.lutz',entries)
        self.assertNotIn('xh2s/reala_ace.lutz',entries)
    def test_archive_hash_is_pinned(self):
        expected='ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c'
        with (ROOT/'reference_ffcs/source.zip').open('rb') as stream:
            self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(),expected)
