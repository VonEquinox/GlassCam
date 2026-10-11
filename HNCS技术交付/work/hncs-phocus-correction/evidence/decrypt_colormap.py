#!/usr/bin/env python3
"""Decrypt a Phocus factory Colormap .dat (HBCryptoNameSpace CBC-WAES) and dump plaintext."""
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from waes import WAES

def decrypt_file(path, out_path):
    w = WAES()
    data = open(path, 'rb').read()
    assert len(data) >= 32 and len(data) % 16 == 0, "bad length"
    iv, ct = data[:16], data[16:]
    pt = bytearray()
    prev = iv
    for i in range(0, len(ct), 16):
        blk = ct[i:i+16]
        pt += bytes(a ^ b for a, b in zip(w.decrypt(blk), prev))
        prev = blk
    n = pt[-1]
    assert 1 <= n <= 16, "bad pad %d" % n
    pad = pt[-n:]
    assert pad == bytes([n])*n, "inconsistent pad"
    pt = pt[:-n]
    open(out_path, 'wb').write(pt)
    return pt

if __name__ == "__main__":
    src = os.environ.get(
        "PHOCUS_COLORMAPS",
        "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBRawCorrections.framework/Versions/A/Resources/Colormaps",
    )
    out_dir = Path(__file__).resolve().parent / "colormaps_plain"
    out_dir.mkdir(exist_ok=True)
    for f in sorted(os.listdir(src)):
        if not f.endswith('.dat'): continue
        try:
            pt = decrypt_file(os.path.join(src, f), str(out_dir / (f[:-4] + ".bin")))
            head = pt[:120]
            print("%s  %8dB -> OK  head=%r" % (f, len(pt), head[:80]))
        except Exception as e:
            print("%s  FAIL: %s" % (f, e))
