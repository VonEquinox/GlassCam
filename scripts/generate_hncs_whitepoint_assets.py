#!/usr/bin/env python3
"""Extract the original Robertson table; no new camera calibration is implied."""
import argparse
import hashlib
from pathlib import Path
import numpy as np


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path,
                        default=root / 'vendor/hncs/work/hncs-pipeline/assets/x2dii_phocus_422.npz')
    parser.add_argument('--output', type=Path, default=root / 'core/hncs_whitepoint_assets.inc')
    args = parser.parse_args()
    with np.load(args.source, allow_pickle=False) as source:
        table = source['robertson']
        assert table.shape == (31, 4) and np.isfinite(table).all()
        lines = ['// Robertson table from bundled x2dii_phocus_422.npz.',
                 '// Source SHA-256: ' + hashlib.sha256(args.source.read_bytes()).hexdigest(),
                 'namespace whitepoint_assets {',
                 'static constexpr double robertson[31][4] = {']
        lines.extend('    {' + ','.join(repr(float(v)) for v in row) + '},' for row in table)
        args.output.write_text('\n'.join(lines + ['};', '}']) + '\n')


if __name__ == '__main__':
    main()
