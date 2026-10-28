"""All FFCS switch combinations retain exact independent stage semantics."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FFCSEffectSwitchesTests(unittest.TestCase):
    def test_all_looks_and_combinations(self):
        with tempfile.TemporaryDirectory(prefix='ffcs-effect-switches-') as temp:
            binary = str(Path(temp) / 'ffcs_effect_switches_test')
            subprocess.run([
                'g++', '-std=c++17', '-O3', '-fno-fast-math', '-ffp-contract=off',
                '-pthread', '-Wall', '-Wextra', '-Wpedantic',
                str(ROOT / 'tests/native-legacy/ffcs_effect_switches_test.cpp'), '-lz', '-o', binary,
            ], check=True, cwd=ROOT)
            completed = subprocess.run([
                binary, str(ROOT / 'vendor/ffcs/implementation/ffcs/data/xh2s'),
            ], check=True, cwd=ROOT, capture_output=True, text=True)
            report = json.loads(completed.stdout)
            self.assertEqual(report['looks'], 19)
            self.assertEqual(report['flag_combinations'], 4)
            self.assertEqual(report['max_float_error'], 0)
            self.assertTrue(report['zero_coefficients_remain_inactive'])
            self.assertTrue(report['bit_exact'])


if __name__ == '__main__':
    unittest.main()
