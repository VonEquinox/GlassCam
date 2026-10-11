#!/usr/bin/env python3
"""Phocus V1 gradation curves — full reproduction from HBUtil arm64 disassembly.

Recovered functions:
  CGradationManager::SetFilmCurveOriginal(x=0.76, y=4.1, strength=48) @0x258c0
  CGradation::CGradation(bool, x[], y[], n, bLstar, bPipeline)      @0x57684
  CGradation::GetCurveGain(t)    @0x57b58  (UGradation table lerp, pow 1.8)
  CGradation::GetPointCurveGain(t) @0x57bf8 (natural cubic spline / t)
  CCubicSpline::init → spline(yp1=ypn=9.9e31 → NATURAL) @0x1fd10/@0x1fa44

Tables produced by InitGradationCurves @0x2556c:
  0x1714208  film curve original (float[65536], direct)
  0x1754208  V1 standard  = gain pipeline + pow(1/2.2)          (GetStandardGradationCurve)
  0x1794208  V1 + L* OETF tail
  0x17d4208  pure gamma table  (t^0.4547)
  0x1814208  pure L* OETF table
"""
import os, struct, math
from pathlib import Path

HBUTIL = os.environ.get(
    "PHOCUS_HBUTIL",
    "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBUtil.framework/Versions/A/HBUtil",
)
ARM = 61947904
if not Path(HBUTIL).is_file():
    raise FileNotFoundError("HBUtil not found; set PHOCUS_HBUTIL to the extracted arm64 binary")
_d = Path(HBUTIL).read_bytes()
def _dbl(v): return struct.unpack_from("<d", _d, ARM + v)[0]

UG = struct.unpack_from("<1025d", _d, ARM + 0x89220)          # UGradation static table
CONST = dict(knee=_dbl(0x891f8), s100=903.2962962963, m116=1.16, b116=-0.16,
             third=_dbl(0x85810), g22=_dbl(0x891e8), g2199=_dbl(0x891f0))

# ---- gain stage polynomials (each == const at t=0.25, == 1 at t=1) ----
GAINS = [
    (1.2201699047005,    -0.39141316391199, 1.4158764866565, -0.024463322744499),
    (math.sqrt(2.0),     -0.73637966644106, 1.7824033955936, -0.046023729152566),
    (0.81955799446263,    0.32078578762198, 0.65916510065164, 0.020049111726374),
]
def gain(t, const, a, b, c):
    return const if t <= 0.25 else (a * t * t + b * t + c) / t

# ---- default contrast point curve (manager arrays @+0x28/+0x78) ----
PX = [0.0, 0.125, 0.25, 0.5, 0.75, 1.0]
PY = [0.0, 0.0859375, 0.21875, 0.5, 0.76171875, 1.0]
ANCHOR = 0.45852946567989455                                   # [0x89188]

def pinch(v):  # SetPointCurve in-place domain transform
    return 2*ANCHOR*v if v < ANCHOR else (2*(1-ANCHOR)*v + (2*ANCHOR-1))

def knot_arrays(px, py):
    x = [px[0]] + [pinch(v) for v in px[1:]]
    y = [py[0]] + [pinch(px[k]) * py[k] / px[k] for k in range(1, len(px))]
    return x, y

# ---- Numerical Recipes natural cubic spline ----
def spline(x, y, n):
    u, y2 = [0.0]*n, [0.0]*n
    for i in range(1, n-1):
        sig = (x[i]-x[i-1])/(x[i+1]-x[i-1])
        p = sig*y2[i-1] + 2.0
        y2[i] = (sig-1.0)/p
        u[i] = (y[i+1]-y[i])/(x[i+1]-x[i]) - (y[i]-y[i-1])/(x[i]-x[i-1])
        u[i] = (6.0*u[i]/(x[i+1]-x[i-1]) - sig*u[i-1])/p
    for k in range(n-2, -1, -1):
        y2[k] = y2[k]*y2[k+1] + u[k]
    return y2

def splint(x, y, y2, n, t):
    klo, khi = 0, n-1
    while khi-klo > 1:                       # bisection
        k = (klo+khi)//2
        if x[k] > t: khi = k
        else: klo = k
    h = x[khi]-x[klo]
    a, b = (x[khi]-t)/h, (t-x[klo])/h
    return a*y[klo] + b*y[khi] + ((a**3-a)*y2[klo] + (b**3-b)*y2[khi])*h*h/6.0

# ---- CGradation gain lookups ----
def curve_gain(t):                           # GetCurveGain @0x57b58
    if t <= 1e-7: return 0.0
    pos = 1024.0 * t
    idx = min(1023, int(pos))
    f = pos - idx
    v = (1.0-f)*UG[idx] + f*UG[idx+1]
    v = v ** 1.8                             # [0x85920]
    return (0.25*v + 0.75*t) / t

class PointCurve:
    def __init__(self, px=None, py=None):
        if px and py and len(px) > 2:
            self.x, self.y = knot_arrays(px, py)
            self.n = len(px)
        else:                                 # default 2-point identity
            self.x, self.y, self.n = [0.0, 1.0], [0.0, 1.0], 2
        self.y2 = spline(self.x, self.y, self.n)
    def gain(self, t):                        # GetPointCurveGain @0x57bf8
        if t <= 1e-7: return 0.0
        return splint(self.x, self.y, self.y2, self.n, t) / t

PC = PointCurve(PX, PY)

def lstar(v):  # CIE L* OETF (encode): knee [0x891f8], 903.3/100 & 1.16·cbrt−0.16
    if v <= CONST['knee']: return v * CONST['s100'] / 100.0
    return CONST['m116'] * v ** CONST['third'] + CONST['b116']

def film_curve_original(x=0.76, y=4.1, strength=48.0):   # @0x258c0
    s = strength / 50.0
    out = []
    for i in range(65536):
        t = i / 65536.0
        v = 65536.0 * t ** (1.0/y)
        if v < 32768.0:
            d = s * (v*v/32768.0 - v)                     # toe
        else:
            u = 65536.0 - v
            d = s * u * (1.0 - u/32768.0)                 # shoulder
        out.append(float(int(min(65535.0, max(0.0, 65536.0 * ((v+d)/65536.0) ** (1.0/x))))))
    return out

def gradation_table(pipeline=True, lstar_tail=True, pc=PC):  # @0x57684
    out = []
    for i in range(65536):
        t = i / 65536.0
        if pipeline:                                       # long path (w26=0)
            for const, a, b, c in GAINS[:2]:
                t *= gain(t, const, a, b, c)
            t *= curve_gain(t)
            t *= gain(t, *GAINS[2])
            t = t ** CONST['g22']                          # w22=true → apply
            t *= pc.gain(t)
            if lstar_tail:                                 # w20=1 tail: L*(t^2.199)
                t = lstar(t ** CONST['g2199'])
        else:                                              # short path (w26=1)
            t = lstar(t) if lstar_tail else t ** CONST['g22']
        out.append(min(65535, max(0, int(t * 65536.0))))
    return out

if __name__ == "__main__":
    print("== SetFilmCurveOriginal(0.76, 4.1, 48) ==")
    fc = film_curve_original()
    print("[0]=%d [1000]=%d [8192]=%d [32768]=%d [65535]=%d" %
          (fc[0], fc[1000], fc[8192], fc[32768], fc[65535]))
    mono = all(fc[i+1] >= fc[i] for i in range(65535))
    print("monotone:", mono, "| local gamma @0.5: %.4f" %
          (math.log(fc[33000]/fc[32000]) / math.log(33000/32000)))

    print("\n== V1 standard (pipeline, no L*) — 0x1754208 ==")
    v1 = gradation_table(pipeline=True, lstar_tail=False)
    print("[0]=%d [1000]=%d [8192]=%d [32768]=%d [65535]=%d" %
          (v1[0], v1[1000], v1[8192], v1[32768], v1[65535]))
    print("monotone:", all(v1[i+1] >= v1[i] for i in range(65535)))
    for t in (0.01, 0.05, 0.18, 0.5, 0.9):
        i = int(t*65535.99)
        print("  V1(%.2f) = %.5f" % (t, v1[i]/65535.0))

    print("\n== V1 + L* (pipeline, L* tail) — 0x1794208 ==")
    v1l = gradation_table(pipeline=True, lstar_tail=True)
    print("[0]=%d [8192]=%d [32768]=%d [65535]=%d  monotone: %s" %
          (v1l[0], v1l[8192], v1l[32768], v1l[65535],
           all(v1l[i+1] >= v1l[i] for i in range(65535))))

    print("\n== pure tables ==")
    pg = gradation_table(pipeline=False, lstar_tail=False)
    pl = gradation_table(pipeline=False, lstar_tail=True)
    print("gamma:  [32768]=%d [65535]=%d  (t^0.4547: 32768→%.1f)" %
          (pg[32768], pg[65535], 0.5**0.45470692717584*65536))
    print("L*:     [32768]=%d [65535]=%d  (L*(0.5)=%.5f)" %
          (pl[32768], pl[65535], lstar(0.5)))

    # dump CSV for inspection
    csv_path = Path(__file__).resolve().parent / "v1_curves.csv"
    with csv_path.open("w") as f:
        f.write("i,t,film_original,v1_standard,v1_lstar,pure_gamma,pure_lstar\n")
        for i in range(0, 65536, 64):
            t = i/65536.0
            f.write("%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n" %
                    (i, t, fc[i]/65535.0, v1[i]/65535.0, v1l[i]/65535.0,
                     pg[i]/65535.0, pl[i]/65535.0))
    print("\nwrote %s (1024 samples)" % csv_path)
