"""Compare saved native Phocus exports using their embedded ICC profiles.

Requires NumPy, Pillow, tifffile, Matplotlib and the existing HNCS reference checkout.
No exposure, white-balance, matrix, or curve is fitted to either photograph.
"""
import argparse
import hashlib
import io
import json
import plistlib
from pathlib import Path
import struct
import sys

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont
import tifffile
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


D50 = np.array([.9642, 1., .8249])
D65 = np.array([.95047, 1., 1.08883])
BRADFORD = np.array([[.8951, .2664, -.1614], [-.7502, 1.7135, .0367], [.0389, -.0685, 1.0296]])
ADAPT = np.linalg.inv(BRADFORD) @ np.diag((BRADFORD @ D65) / (BRADFORD @ D50)) @ BRADFORD
SRGB_TO_XYZ = np.array([[.4124564, .3575761, .1804375], [.2126729, .7151522, .0721750], [.0193339, .1191920, .9503041]])
SRGB_ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
SCENES = {"daylight": "日光样张", "lowlight": "低照度暖光样张"}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def matrix_profile(icc):
    """Read the matrix/gamma ICC profiles used by these exports; reject others."""
    if len(icc) < 132 or icc[16:24] != b"RGB XYZ ":
        raise ValueError("Expected an RGB matrix profile with XYZ PCS")
    tags = {}
    for index in range(struct.unpack_from(">I", icc, 128)[0]):
        signature, offset, size = struct.unpack_from(">4sII", icc, 132 + index * 12)
        if offset + size > len(icc):
            raise ValueError("Truncated ICC tag")
        tags[signature] = icc[offset:offset + size]
    primaries, gamma = [], []
    for channel in [b"r", b"g", b"b"]:
        xyz, curve = tags[channel + b"XYZ"], tags[channel + b"TRC"]
        if xyz[:4] != b"XYZ " or curve[:4] != b"curv" or struct.unpack_from(">I", curve, 8)[0] != 1:
            raise ValueError("This report supports matrix ICCs with single-gamma TRCs")
        primaries.append(np.array(struct.unpack_from(">iii", xyz, 8)) / 65536.)
        gamma.append(struct.unpack_from(">H", curve, 12)[0] / 256.)
    name = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(icc))).strip()
    return np.array(primaries).T, np.array(gamma), name


def xyz(codes, matrix, gamma):
    return (np.asarray(codes, dtype=np.float64) / 65535.) ** gamma @ matrix.T


def display(xyz_d50):
    rgb = xyz_d50 @ ADAPT.T @ np.linalg.inv(SRGB_TO_XYZ).T
    rgb = np.clip(rgb, 0, 1)
    rgb = np.where(rgb <= .0031308, 12.92 * rgb, 1.055 * rgb ** (1 / 2.4) - .055)
    return Image.fromarray(np.uint8(np.clip(rgb * 255 + .5, 0, 255)))


def patch_codes(codes, polygons):
    result = []
    for poly in polygons:
        x0, y0 = np.floor(poly.min(axis=0)).astype(int)
        x1, y1 = np.ceil(poly.max(axis=0)).astype(int)
        if x0 < 0 or y0 < 0 or x1 > codes.shape[1] or y1 > codes.shape[0]:
            raise ValueError("Chart ROI outside image")
        yy, xx = np.mgrid[y0:y1, x0:x1]
        points = np.stack([xx + .5, yy + .5], axis=-1)
        edges = np.roll(poly, -1, axis=0) - poly
        cross = (edges[:, 0, None, None] * (points[None, ..., 1] - poly[:, 1, None, None]) -
                 edges[:, 1, None, None] * (points[None, ..., 0] - poly[:, 0, None, None]))
        inside = np.all(cross >= 0, axis=0) | np.all(cross <= 0, axis=0)
        result.append(np.median(codes[y0:y1, x0:x1][inside], axis=0))
    return np.array(result)


def summary(values):
    return {"count": int(values.size), "mean": float(values.mean()), "median": float(np.median(values)),
            "p95": float(np.quantile(values, .95)), "maximum": float(values.max())}


def font(size):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Reference folder containing exports/ and evidence/")
    parser.add_argument("--reference-root", required=True, type=Path, help="Existing HNCS reference checkout")
    args = parser.parse_args()
    root, reference = args.root.resolve(), args.reference_root.resolve()
    sys.path.insert(0, str(reference))
    import hncs_pipeline as h
    import phocus_presets as presets

    manifest = sum([json.loads((root / "evidence" / f"{look}-exports.json").read_text())
                    for look in ["standard", "nature"]], [])
    entries = {(row["scene"], row["preset"]): row for row in manifest}
    chart = json.loads((reference / "work/hncs-pipeline/a7rv_to_x2dii.json").read_text())
    region = chart["chart_config"]["hasselblad"]
    # Nominal CFA-to-export crop registration from the source DNG/TIFF metadata.
    polygons = (h.patch_polygons(region["corners"], region["roi_fraction"]) *
                np.array(chart["target"]["visible_shape"][::-1]) - np.array([128, 96]))
    chart_box = tuple(np.r_[polygons.min(axis=(0, 1)), polygons.max(axis=(0, 1))].astype(int))
    images, samples, patches, settings, report = {}, {}, {}, {}, {"exports": [], "differences": {}}
    capture = {}
    for scene in SCENES:
        for look in ["standard", "nature"]:
            row = entries[(scene, look)]
            path = root / "exports" / row["file"]
            if digest(path) != row["sha256"]:
                raise ValueError(f"Export changed: {path}")
            with tifffile.TiffFile(path) as tif:
                page = tif.pages[0]
                if page.shape != (8742, 11656, 3) or page.dtype != np.uint16:
                    raise ValueError("Expected full-size 16-bit RGB reference")
                icc = page.tags[34675].value
                if hashlib.sha256(icc).hexdigest() != row["ICC_sha256"]:
                    raise ValueError("ICC does not match the recorded export")
                exif = page.tags["ExifTag"].value
                identity = {k: exif[k] for k in ["DateTimeOriginal", "ExposureTime", "ISOSpeedRatings", "FNumber"]}
            if scene in capture and capture[scene] != identity:
                raise ValueError("Standard and Nature do not show the same capture")
            capture[scene] = identity
            matrix, gamma, name = matrix_profile(icc)
            codes = tifffile.memmap(path, mode="r")
            sample = codes[::8, ::8]
            values = xyz(sample, matrix, gamma)
            samples[(scene, look)] = values
            patch_values = xyz(patch_codes(codes, polygons), matrix, gamma)
            patches[(scene, look)] = h.xyz_to_lab(patch_values)
            preview = display(values)
            images[(scene, look)] = preview
            preview.save(root / f"{scene}-{look}.jpg", quality=95, icc_profile=SRGB_ICC)
            x0, y0, x1, y1 = chart_box
            crop = display(xyz(codes[y0:y1:2, x0:x1:2], matrix, gamma))
            crop.save(root / f"{scene}-{look}-chart.jpg", quality=95, icc_profile=SRGB_ICC)
            sidecar = root / "evidence" / row["settings_file"]
            if digest(sidecar) != row["settings_sha256"]:
                raise ValueError("Settings snapshot changed")
            saved = plistlib.loads(sidecar.read_bytes())
            correction = saved["ImageSettings"][saved["CurrentIx"]]["ImageCorrection"]
            settings[(scene, look)] = correction
            if correction["HDR"] or correction["EV"] != 1:
                raise ValueError("Expected SDR and zero exposure adjustment")
            stock = presets.preset_payload(look)["ImageSetting"]["ImageCorrection"]
            check_keys = ["FilmCurve", "Gradations", "USMAmount", "USMRadius", "VignetteAmount", "LensCorrection"]
            if look == "nature":
                check_keys += ["ColorTemperature", "Tint"]
            # Phocus saves an additional identity curve beyond the seven in
            # the factory XML. Accept only exact identity extensions.
            curves, expected_curves = correction["Gradations"], stock["Gradations"]
            identity_curve = {"Points": [{"DY": 1, "X": 0, "Y": 0}, {"DY": 1, "X": 255, "Y": 255}]}
            curves_match = (curves[:len(expected_curves)] == expected_curves and
                            all(curve == identity_curve for curve in curves[len(expected_curves):]))
            if not curves_match or any(correction[k] != stock[k] for k in check_keys if k != "Gradations"):
                raise ValueError(f"Export differs from the factory preset: {scene} {look}")
            report["exports"].append({**row, "capture_metadata": identity,
                "ICC_matrix_to_XYZ_D50": matrix.tolist(), "ICC_channel_gammas": gamma.tolist(),
                "factory_fields_verified": check_keys, "sampling_stride": 8,
                "additional_identity_curves": len(curves) - len(expected_curves),
                "sampled_endpoint_channel_fraction": float(np.mean((sample == 0) | (sample == 65535))),
                "chart_patch_Lab_D50": patches[(scene, look)].tolist()})

    for scene in SCENES:
        standard, nature = [samples[(scene, look)] for look in ["standard", "nature"]]
        difference = h.delta_e_2000(h.xyz_to_lab(standard), h.xyz_to_lab(nature))
        chart_difference = h.delta_e_2000(patches[(scene, "standard")], patches[(scene, "nature")])
        report["differences"][scene] = {"sampled_image_deltaE00": summary(difference),
            "chart_patch_deltaE00": summary(chart_difference),
            "patches": [{"name": name, "deltaE00": float(delta)} for name, delta in zip(h.PATCH_NAMES, chart_difference)],
            "neutral_patches_19_to_24": {look: patches[(scene, look)][18:].tolist() for look in ["standard", "nature"]}}

    ramp = np.repeat(np.arange(65536, dtype=np.uint16)[None, :, None], 3, axis=2)
    nature_curve, provenance = presets.apply_post_curves(ramp, "nature")
    curve_codes = nature_curve[0, :, 0]
    fig, axis = plt.subplots(figsize=(8, 4.8), constrained_layout=True)
    axis.plot([0, 1], [0, 1], color="#aab2bc", linestyle="--", label="Identity")
    axis.plot(np.arange(65536) / 65535., curve_codes / 65535., color="#3269a8", label="Nature master curve")
    axis.set(xlim=(0, 1), ylim=(0, 1), xlabel="Encoded input after color core", ylabel="Encoded output",
             title="Phocus Nature: darker low tones, brighter high tones")
    axis.grid(alpha=.2); axis.legend()
    fig.savefig(root / "nature-curve.png", dpi=160); plt.close(fig)
    report["nature_curve"] = {"provenance": provenance,
        "control_points": settings[("daylight", "nature")]["Gradations"][0]["Points"],
        "samples": [{"input_code": i, "output_code": int(curve_codes[i])} for i in [0, 16384, 32768, 49152, 65535]]}

    canvas = Image.new("RGB", (1532, 1320), "#f3f5f7")
    draw = ImageDraw.Draw(canvas)
    draw.text((24, 12), "原版 Phocus 4.2.2：Standard 与 Nature", font=font(28), fill="#172638")
    for r, scene in enumerate(SCENES):
        y = 62 + r * 605
        draw.text((24, y), SCENES[scene], font=font(23), fill="#25394d")
        for c, look in enumerate(["standard", "nature"]):
            x = 24 + c * 758
            picture = images[(scene, look)].copy()
            picture.thumbnail((734, 550), Image.Resampling.LANCZOS)
            canvas.paste(picture, (x, y + 34))
            kelvin = settings[(scene, look)]["ColorTemperature"]
            draw.text((x, y + 581), f"{look.title()} · {kelvin} K · 0 EV · HDR 关闭", font=font(19), fill="#25394d")
    draw.text((24, 1290), "四张均为原尺寸 16 位 TIFF；按内嵌 ICC 统一显示；没有逐图曝光或白平衡匹配", font=font(18), fill="#455260")
    canvas.save(root / "four-way-phocus.jpg", quality=95, icc_profile=SRGB_ICC)
    report["display"] = "Embedded matrix/gamma ICC → XYZ D50 → Bradford D65 → sRGB. Display gamut clipping only; metrics use XYZ/Lab before that clipping. No exposure or white-balance fit."
    report["limits"] = ["Delta E measures Standard/Nature differences, not color accuracy or iPhone/Hasselblad matching.",
        "Image metrics use a stride-8 grid, not every full-resolution output pixel.",
        "Chart interiors use nominal CFA-to-export crop registration, also reused for the lowlight scene; not a measured lens-warp registration or calibrated target truth.",
        "Printed skin photographs in the studio scene are reference image content, not measurements of real skin under these lights."]
    (root / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Phocus 原版参考</title><style>body{font:16px/1.7 -apple-system,sans-serif;margin:0;background:#f4f6f8;color:#1e2b3b}main{max-width:1150px;margin:auto;padding:24px}h1{font-size:27px}select{font:inherit;padding:5px}figure{margin:22px 0}figure img{width:100%;height:auto}.compare{position:relative;aspect-ratio:4/3;background:#111;overflow:hidden}.compare img{position:absolute;width:100%;height:100%;object-fit:contain}input{width:100%}.labels{display:flex;justify-content:space-between}a{color:#185d9d}.note{color:#526478;font-size:14px}</style>
<main><h1>原版 Phocus：Standard／Nature 参考</h1><p>同一 RAW 的两个原厂预设，原尺寸 16 位 TIFF、Adobe RGB (1998)、0 EV、HDR 关闭。按各文件内嵌 ICC 统一到 sRGB 查看，没有另外匹配亮度或白平衡。</p>
<p><b>Nature 会固定使用 5500K，并增加 S 曲线和锐化。</b>Standard 分别使用日光 7523K、低照度 2993K。这里展示的预设差异，不是 iPhone 与哈苏的匹配结论。</p>
<label>场景 <select id="scene"><option value="daylight">日光</option><option value="lowlight">低照度暖光</option></select></label>
<div class="compare"><img id="back"><img id="front"></div><input id="slider" aria-label="左右比较位置" type="range" min="0" max="100" value="50"><div class="labels"><a id="left">Standard 原始 TIFF</a><a id="right">Nature 原始 TIFF</a></div>
<figure><img src="four-way-phocus.jpg" alt="四路 Phocus 原版参考"></figure><figure><img src="nature-curve.png" alt="Nature 主曲线"></figure>
<p class="note">曲线图使用已恢复并经原生探针验证的 Phocus 后置曲线表。数值报告中的 ΔE 只描述两个预设的差异；不代表哪一个更准确。参考片包含原厂镜头与锐化处理。</p><p><a href="analysis.json">参数与数值报告</a> · <a href="../raw-input-study/comparison.html">iPhone RAW 六路对照</a></p></main>
<script>const scene=document.getElementById('scene'),slider=document.getElementById('slider');function update(){const s=scene.value;document.getElementById('front').src=s+'-standard.jpg';document.getElementById('back').src=s+'-nature.jpg';document.getElementById('front').style.clipPath='inset(0 '+(100-slider.value)+'% 0 0)';document.getElementById('left').href='exports/'+s+'-standard.tif';document.getElementById('right').href='exports/'+s+'-nature.tif';}scene.addEventListener('input',update);slider.addEventListener('input',update);update();</script></html>'''
    (root / "comparison.html").write_text(page)
    print(root / "comparison.html")
    print(json.dumps(report["differences"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
