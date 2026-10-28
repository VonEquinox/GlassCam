"""Genuine FFCS pointwise C ABI parity, safety and full-photo isolation."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FFCSColorOnlyTests(unittest.TestCase):
    def test_pointwise_api_all_looks(self):
        with tempfile.TemporaryDirectory(prefix='ffcs-color-only-') as temp:
            binary = str(Path(temp) / 'ffcs_color_only_test')
            subprocess.run([
                'g++', '-std=c++17', '-O3', '-fno-fast-math', '-ffp-contract=off',
                '-pthread', '-Wall', '-Wextra', '-Wpedantic',
                str(ROOT / 'tests/native-legacy/ffcs_color_only_test.cpp'), '-lz', '-o', binary,
            ], check=True, cwd=ROOT)
            completed = subprocess.run([
                binary, str(ROOT / 'vendor/ffcs/implementation/ffcs/data/xh2s'),
            ], check=True, cwd=ROOT, capture_output=True, text=True)
            self.assertIn('19 looks', completed.stdout)
            self.assertIn('unchanged full-photo output', completed.stdout)


if __name__ == '__main__':
    unittest.main()
