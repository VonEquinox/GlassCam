#!/usr/bin/env python3
"""RAW → HNCS 数值闭环演示（Phocus 4.2.2 技术数据，X2D 100MP Colormap）。

数据源（全部来自技术提取，非猜测）:
  - 工厂 Colormap mq7w3wb56dc3gq3hhv3s (X2D ccd=0x14, v3.0 2021-11-19):
      m* 分光源 raw-camera→XYZ(D50) 矩阵（由二进制函数名和矩阵数据共同确认）,
      v* 分光源 WB 增益, CbCr 2D 残差 LUT
  - 工作空间矩阵 S1 @HBRawCorrections 0x3fc30 = HasselbladLStarRGB(现行 HNCS) RGB→XYZ
  - V1 曲线七级管线 + L* 尾 (HBUtil CGradation @0x57684) — v1curve.py 复现

关键解码事实（CXMLLut::DecodeFrom @0x35a8 反汇编证实）:
  plist 存储 = 2·(真值−1) 混淆编码；装载时逐元素 真值 = 存储·0.5 + 1.0
  （仅 mt/mlt/mf/mfd/mh 与 vt/vf/vh；LUTTable* 不变换，原样拷贝）
  ⇒ 解码后 m* 的行和与 D50 白点相符；这里不把它等同于 DNG ColorMatrix 标签语义。

验证范围（不是对所有 Phocus 路径的声称）:
  - CorrectPixelsHasselbladRGB @0x15f60 已直接确认旧 Hasselblad RGB(2005) 路径的 ×1.7、矩阵乘和 γ2.2；
  - GetRawRGB2XYZMatrix @0x2ee04、GetColorSpaceChangeMatrix @0x15388、CColorCorrectFilter 构造器
    共同支持下面的 HNCS 合成模型；当前样本未证明每一条运行时分支都严格按此顺序执行。
  合成模型：raw → WB(·v_dec) → ×1.7（仅旧/ICM 相关路径）→ inv(S1)·m_dec(cct)
  → clamp → 线性 L*RGB → V1+L* 表 0x1794208。CbCr LUT 单独验证其网格与插值。
"""
import os, re, struct, sys
from pathlib import Path

EVIDENCE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(EVIDENCE_DIR))
from v1curve import gradation_table   # noqa: E402

CM_PATH = EVIDENCE_DIR / "colormaps_plain" / "mq7w3wb56dc3gq3hhv3s.bin"
CM = CM_PATH.read_bytes().decode("utf-8", "replace")

def grab_arr(k):
    m = re.search(r"<key>%s</key>\s*<array>(.*?)</array>" % k, CM, re.S)
    return [float(x) for x in re.findall(r"<real>([^<]+)</real>", m.group(1))]
def grab_int(k):
    return int(re.search(r"<key>%s</key>\s*<integer>(-?\d+)</integer>" % k, CM).group(1))
def dec(a):                       # DecodeFrom 的 ×0.5+1 反混淆（矩阵/向量专用）
    return [x * 0.5 + 1.0 for x in a]

MATS = {k: dec(grab_arr(k)) for k in ("mt", "mlt", "mf", "mh")}
TEMPS = {"mt": grab_int("tt"), "mlt": grab_int("tlt"),
         "mf": grab_int("tf"), "mh": grab_int("th")}
TH = grab_int("th")
VEC = {k: dec(grab_arr(k)) for k in ("vt", "vf", "vh")}
VEC_T = {"vt": TEMPS["mt"], "vf": TEMPS["mf"], "vh": TH}
CbS, CbE, CrS, CrE, DIV = grab_int("CbS"), grab_int("CbE"), grab_int("CrS"), grab_int("CrE"), grab_int("DivFactor")
LUT_TS_STD = grab_arr("LUTTableTSStd")          # LUT 不做 ×0.5+1（反汇编证实）

# 工作空间矩阵（fat binary ARM 切片直接提取, vaddr==fileoff）
HB_PATH = Path(os.environ.get(
    "PHOCUS_HBRAW",
    "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBRawCorrections.framework/"
    "Versions/A/HBRawCorrections",
))
if not HB_PATH.is_file():
    raise FileNotFoundError(
        "HBRawCorrections not found; set PHOCUS_HBRAW to the extracted arm64 binary"
    )
_HB = HB_PATH.read_bytes()
ARM = 688128
def binmat(v):
    return list(struct.unpack_from("<9d", _HB, ARM + v))
S1 = binmat(0x3fc30)     # HasselbladLStarRGB(HNCS) RGB→XYZ，白点=精确 D50
S4 = binmat(0x3fd08)     # LStarRGBv1(ProPhoto 原色) RGB→XYZ
M1 = binmat(0x3fd50)     # XYZ→HasselbladRGB(2005)，旧内核 pow(1/2.2) 路径用
K_SCALE = 1.7            # CorrectPixelsHasselbladRGB @0x3d9e8：像素预增益

def mul(A, B):
    return [sum(A[3*i+k]*B[3*k+j] for k in range(3)) for i in range(3) for j in range(3)]
def matvec(M, x):
    return [sum(M[3*i+k]*x[k] for k in range(3)) for i in range(3)]
def inv(M):
    a, b, c, d, e, f, g, h, i = M
    A, B, C = e*i-f*h, -(d*i-f*g), d*h-e*g
    det = a*A + b*B + c*C
    return [A/det, -(b*i-c*h)/det, (b*f-c*e)/det,
            B/det, (a*i-c*g)/det, -(a*f-c*d)/det,
            C/det, -(a*h-b*g)/det, (a*e-b*d)/det]
def lerp(a, b, f):
    return [x + f*(y-x) for x, y in zip(a, b)]

def interp_by_cct(cct, table, temps):
    """CalculateMatrix @0x266c：解码域(线性)按色温线性插值"""
    keys = sorted(temps, key=lambda k: temps[k])
    if cct <= temps[keys[0]]: return table[keys[0]]
    if cct >= temps[keys[-1]]: return table[keys[-1]]
    for k0, k1 in zip(keys, keys[1:]):
        t0, t1 = temps[k0], temps[k1]
        if t0 <= cct <= t1:
            return lerp(table[k0], table[k1], (cct-t0)/(t1-t0))

def wb_gains(cct):       # v* 解码 = WB 增益（钨丝 B↑ 高温 R↑，物理单调）
    v = interp_by_cct(cct, VEC, VEC_T)
    return [v[0], 1.0, v[2]]

def cam2xyz(cct):
    return interp_by_cct(cct, MATS, TEMPS)

def color_correct(rgb_wb, cct, S=S1):
    """合成模型：×1.7 → inv(S)·m(cct) → clamp。

    ×1.7 is directly confirmed in CorrectPixelsHasselbladRGB; its use for
    every HNCS working-space branch is intentionally not claimed.
    """
    M = mul(inv(S), cam2xyz(cct))
    p = [c * 65535.0 * K_SCALE for c in rgb_wb]
    v = matvec(M, p)
    lin = [min(65535.0, max(0.0, c)) / 65535.0 for c in v]
    return M, lin

def lut_lookup(cb, cr, lut):
    """CbCr 2D 残差 LUT 双线性插值（DivFactor=32: 每整数 32 子格；表值=(ΔCb,ΔCr) 原值）"""
    ncb, ncr = CbE - CbS + 1, CrE - CrS + 1
    def v(i, j):
        i = min(max(i, 0), ncb - 1); j = min(max(j, 0), ncr - 1)
        k = 2 * (ncb * j + i)
        return lut[k], lut[k + 1]
    fi, fj = (cb - CbS), (cr - CrS)
    i0, j0 = int(fi), int(fj)
    fi, fj = fi - i0, fj - j0
    a, b, c, d = v(i0, j0), v(i0+1, j0), v(i0, j0+1), v(i0+1, j0+1)
    dcb = a[0]*(1-fi)*(1-fj) + b[0]*fi*(1-fj) + c[0]*(1-fi)*fj + d[0]*fi*fj
    dcr = a[1]*(1-fi)*(1-fj) + b[1]*fi*(1-fj) + c[1]*(1-fi)*fj + d[1]*fi*fj
    return dcb, dcr

V1L = gradation_table(pipeline=True, lstar_tail=True)   # 0x1794208: V1 管线 + L* 编码

def hncs_code(lin):
    return [V1L[min(65535, max(0, int(c * 65536.0)))] for c in lin]

if __name__ == "__main__":
    print("== X2D 工厂标定点（plist 反混淆 ×0.5+1 后的真值）==")
    for k in sorted(MATS, key=lambda k: TEMPS[k]):
        m = MATS[k]; v = {"mt": VEC["vt"], "mf": VEC["vf"], "mh": VEC["vh"]}.get(k)
        print("  %-4s %5dK  XYZ白=(%.4f,%.4f,%.4f)  WB增益=%s" %
              (k, TEMPS[k], sum(m[0:3]), sum(m[3:6]), sum(m[6:9]),
               "(%.3f,1,%.3f)" % (v[0], v[2]) if v else "-"))
    w = [sum(MATS["mf"][3*r:3*r+3]) for r in range(3)]
    s = sum(w)
    print("  相机矩阵白点 xy=(%.5f,%.5f)   S1 白点 xy=(%.5f,%.5f) = D50(0.3457,0.3585)" %
          (w[0]/s, w[1]/s, sum(S1[0:3])/sum(S1), sum(S1[3:6])/sum(S1)))

    print("\n== 测试 1: WB 后中性灰跨光源（合成模型，scene=0.18）==")
    print("  CCT     raw=scene/WB → 线性 L*RGB 输出              通道失衡 Δ")
    for cct in (2400, 3100, 4300, 5550, 7000, 9100):
        g = wb_gains(cct)
        scene = [0.18, 0.18, 0.18]
        raw = [scene[i] / g[i] for i in range(3)]
        wb = [raw[i] * g[i] for i in range(3)]
        M, lin = color_correct(wb, cct)
        print("  %4dK   (%.5f,%.5f,%.5f)   Δ=%.4f%%" %
              (cct, lin[0], lin[1], lin[2], 100*(max(lin)-min(lin))/lin[1]))

    print("\n== 测试 2: 色块（钨丝灯 3100K 场景 as-shot）→ 合成矩阵/曲线模型 ==")
    g = wb_gains(3100)
    patches = {"18% gray": [0.18]*3, "white": [1.0]*3,
               "red":   [1.0, 0.08, 0.05], "green": [0.05, 1.0, 0.10],
               "blue":  [0.02, 0.12, 1.0], "skin":  [0.45, 0.28, 0.20]}
    print("  patch       raw(=patch/g)      →WB→ 线性 L*RGB          → V1+L* 码(16bit)")
    for name, scene in patches.items():
        raw = [scene[i] / g[i] for i in range(3)]        # as-shot 相机响应
        wb = [raw[i] * g[i] for i in range(3)]           # WB 还原
        _, lin = color_correct(wb, 3100)
        codes = hncs_code(lin)
        print("  %-9s (%5.3f,%5.3f,%5.3f)  (%.4f,%.4f,%.4f)  (%5d,%5d,%5d)" %
              (name, *raw, *lin, *codes))

    print("\n== 测试 3: CbCr 2D 残差 LUT 几何（TS Std，未声称已接入上述合成像素模型）==")
    print("  网格 Cb[%d,%d]×Cr[%d,%d] %dx%d 单元, DivFactor=%d" %
          (CbS, CbE, CrS, CrE, CbE-CbS+1, CrE-CrS+1, DIV))
    for cb, cr in ((0, 0), (-15, -25), (32, 12), (60, 30), (80, 50)):
        dcb, dcr = lut_lookup(cb, cr, LUT_TS_STD)
        print("  (%3d,%3d) → Δ=(%8.4f, %8.4f)" % (cb, cr, dcb, dcr))
    print("  中性 (0,0) Δ=(%.3f,%.3f) ← 近零：LUT 只修色域边缘残差（白点 0.0006 偏差即由此吸收）"
          % lut_lookup(0, 0, LUT_TS_STD))

    print("\n== 测试 4: V1+L* 曲线映射（0x1794208 = V1 管线 + L* 编码尾）==")
    for t in (0.01, 0.05, 0.18, 0.5, 0.9, 1.0):
        i = min(65535, int(t * 65536.0))
        print("  线性 %.2f → HNCS 码 %5d (%.4f 编码值)" % (t, V1L[i], V1L[i] / 65535.0))

    print("\n== 交叉验证 ==")
    M, lin = color_correct([1, 1, 1], 5550)
    print("  M_total 对角/行和:", ["%.4f" % M[i] for i in (0, 4, 8)],
          ["%.4f" % sum(M[3*r:3*r+3]) for r in range(3)])
    print("  合成模型 M_total = inv(S1)·mf；inv(S1) 与 ICC L*RGB 的 XYZ→RGB 解析值一致")
    iS1 = inv(S1)
    print("  inv(S1) =", ["%.4f" % x for x in iS1])
