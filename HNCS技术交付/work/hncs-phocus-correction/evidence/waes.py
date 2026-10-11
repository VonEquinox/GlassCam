#!/usr/bin/env python3
"""WAES (Hasselblad custom SPN, HBUtil) — faithful transcription from arm64 asm.

Source: HBUtil.framework arm64 slice
  _WAES_encrypt_real @0x2780, _WAES_decrypt_real @0x2874
  _shift_rows_inverse @0x22d8 (TBL idx @0x81130), _shift_rows @0x22f0 (TBL idx @0x81140)
  _shift_mix @0x2308 (A@0x81150, B@0x81250)      — encrypt permutation
  _mix_shift   @0x24f4 (T0@0x81350,T1@0x81650,T2@0x81550,T3@0x81450) — decrypt permutation
Round tables: encrypt @0xa8bc0, decrypt @0xb2bc0 — 10 rounds x 0x1000 (16 pos x 256B)
"""
import os
from pathlib import Path
import struct

HBUTIL = os.environ.get(
    "PHOCUS_HBUTIL",
    "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBUtil.framework/Versions/A/HBUtil",
)
ARM_SLICE = 61947904

if not Path(HBUTIL).is_file():
    raise FileNotFoundError("HBUtil not found; set PHOCUS_HBUTIL to the extracted arm64 binary")
_d = Path(HBUTIL).read_bytes()
def _rd(vaddr, n):
    off = ARM_SLICE + vaddr
    return _d[off:off+n]

class WAES:
    def __init__(self):
        b = lambda v: _rd(v, 256)
        self.A  = b(0x81150); self.B  = b(0x81250)              # _shift_mix
        self.T0 = b(0x81350); self.T1 = b(0x81650)              # _mix_shift
        self.T2 = b(0x81550); self.T3 = b(0x81450)
        self.tbl_dec = _rd(0x81130, 16)                          # _shift_rows_inverse
        self.tbl_enc = _rd(0x81140, 16)                          # _shift_rows
        self.enc_tables = _rd(0xa8bc0, 0xa000)                   # 10 x 0x1000
        self.dec_tables = _rd(0xb2bc0, 0xa000)

    # ---- byte-level transcriptions ----
    @staticmethod
    def _tbl(s, idx):            # tbl.16b v0, {v0}, v1  (indices >=16 yield 0)
        return bytes(s[i] if i < 16 else 0 for i in idx)

    def shift_mix(self, s):      # encrypt permutation (asm-verified groups)
        out = [0]*16
        for g in range(4):
            a, c, e, f = s[(4*g)%16], s[(4*g+5)%16], s[(4*g+10)%16], s[(4*g+15)%16]
            out[4*g+0] = self.A[a]^self.B[c]^e^f
            out[4*g+1] = self.A[c]^self.B[e]^a^f
            out[4*g+2] = self.A[e]^self.B[f]^a^c
            out[4*g+3] = self.A[f]^self.B[a]^c^e
        return bytes(out)

    def mix_shift(self, s):      # decrypt permutation (asm-verified)
        out = [0]*16
        for g in range(4):
            a, b, c, d = s[4*g:4*g+4]
            out[(4*g+ 0)%16] = self.T0[a]^self.T1[b]^self.T2[c]^self.T3[d]
            out[(4*g+ 5)%16] = self.T3[a]^self.T0[b]^self.T1[c]^self.T2[d]
            out[(4*g+10)%16] = self.T2[a]^self.T3[b]^self.T0[c]^self.T1[d]
            out[(4*g+15)%16] = self.T1[a]^self.T2[b]^self.T3[c]^self.T0[d]
        return bytes(out)

    @staticmethod
    def _subst(s, tbl):          # out[i] = tbl[i*0x100 + s[i]]
        return bytes(tbl[i*0x100 + s[i]] for i in range(16))

    def encrypt(self, blk):
        s = bytes(blk)
        for r in range(9):
            s = self._subst(s, self.enc_tables[r*0x1000:(r+1)*0x1000])
            s = self.shift_mix(s)
        s = self._subst(s, self.enc_tables[9*0x1000:10*0x1000])
        return self._tbl(s, self.tbl_enc)

    def decrypt(self, blk):
        s = self._tbl(bytes(blk), self.tbl_dec)
        s = self._subst(s, self.dec_tables[0:0x1000])
        for r in range(1, 10):
            s = self.mix_shift(s)
            s = self._subst(s, self.dec_tables[r*0x1000:(r+1)*0x1000])
        return s

def gf2_mul(a, b, poly=0x11b):
    r = 0
    for _ in range(8):
        if b & 1: r ^= a
        a <<= 1
        if a & 0x100: a ^= poly
        b >>= 1
    return r

if __name__ == "__main__":
    import os, random
    w = WAES()
    print("tbl_dec:", w.tbl_dec.hex())
    print("tbl_enc:", w.tbl_enc.hex())
    # characterize permutation tables: is this AES-family GF(2^8)?
    xt = bytes(gf2_mul(x, 2) for x in range(256))
    print("A == xtime(2)? ", w.A == xt)
    print("B == xtime(3)? ", bytes(gf2_mul(x,3) for x in range(256)) == w.B)
    for name, t in (("T0", w.T0), ("T1", w.T1), ("T2", w.T2), ("T3", w.T3)):
        for m in (9, 11, 13, 14):
            if t == bytes(gf2_mul(x, m) for x in range(256)):
                print(f"{name} == mul({m})")
    # roundtrip self-test (validates full transcription)
    random.seed(42)
    for trial in range(200):
        x = bytes(random.randrange(256) for _ in range(16))
        assert w.decrypt(w.encrypt(x)) == x, "roundtrip FAIL @%d" % trial
    print("roundtrip encrypt->decrypt x200: OK")
    for trial in range(200):
        x = bytes(random.randrange(256) for _ in range(16))
        assert w.encrypt(w.decrypt(x)) == x, "inverse roundtrip FAIL @%d" % trial
    print("roundtrip decrypt->encrypt x200: OK")
