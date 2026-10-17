"""Build reproducible SDR comparison images and a local viewer from RAW studies."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import shutil

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


NAMES = {"current": "当前 Apple 显影", "scene": "去默认显影／原始曝光尺度",
         "scene-baseline": "去默认显影＋元数据曝光补偿", "scene-hdr-baseline": "去默认显影＋保留 EDR＋曝光补偿",
         "scene-hdr-aligned": "去默认显影＋EDR＋中间调曝光对齐"}
LOOKS = {"none": "无 HNCS", "standard": "Standard", "nature": "Nature"}
LUMA = np.array([.2126, .7152, .0722])
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def read_rgba(path, width, height):
    expected = width * height * 16
    if path.stat().st_size != expected: raise ValueError(f"Wrong raster size: {path}")
    return np.memmap(path, dtype="<f4", mode="r", shape=(height, width, 4))[..., :3]


def sdr(rgb):
    # One fixed diagnostic display transform for every image, independent of its
    # histogram or headroom: max-channel Reinhard followed by the sRGB OETF.
    rgb = np.maximum(np.asarray(rgb), 0)
    rgb = rgb / (1 + rgb.max(axis=-1, keepdims=True))
    encoded = np.where(rgb <= .0031308, rgb * 12.92, 1.055 * rgb ** (1 / 2.4) - .055)
    return Image.fromarray(np.uint8(np.clip(encoded * 255 + .5, 0, 255)))


def font(size):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", size)


def sheet(images, variants, output, title):
    cell_w, cell_h, gutter = 352, 470, 16
    canvas = Image.new("RGB", (3 * cell_w + 4 * gutter, len(variants) * (cell_h + 62) + 96), "#181b20")
    draw = ImageDraw.Draw(canvas)
    draw.text((gutter, 12), title, font=font(24), fill="white")
    for row, variant in enumerate(variants):
        y = 54 + row * (cell_h + 62)
        draw.text((gutter, y), NAMES[variant], font=font(21), fill="#dbe7f7")
        for column, look in enumerate(LOOKS):
            x = gutter + column * (cell_w + gutter)
            image = images[(variant, look)].copy()
            image.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
            canvas.paste(image, (x + (cell_w - image.width) // 2, y + 33))
            draw.text((x, y + 36 + cell_h), LOOKS[look], font=font(18), fill="white")
    draw.text((gutter, canvas.height - 29), "同一 RAW · 完整源处理后输出 24MP · HEIF 回读 · 统一 SDR 诊断映射", font=font(16), fill="#bbc2cc")
    canvas.save(output, quality=94, icc_profile=ICC)


def profile_figure(profile_dir, output):
    profile = json.loads((profile_dir / "embedded-profile.json").read_text())
    curve = np.array(next(iter(profile["tone_curves"].values()))["points"])
    info = next(iter(profile["gain_tables"].values()))
    gains = np.fromfile(profile_dir / info["float32_little_endian_file"], dtype="<f4").reshape(info["shape_v_h_n"])
    fig, axes = plt.subplots(1, 3, figsize=(14, 4.1), constrained_layout=True)
    axes[0].plot(curve[:, 0], curve[:, 1], label="Embedded ProfileToneCurve", color="#2b6cb0")
    axes[0].plot([0, 1], [0, 1], "--", label="Identity", color="#999999")
    axes[0].set(xlabel="Profile input", ylabel="Profile output", title=f"Global curve ({len(curve)} points)")
    axes[0].legend(fontsize=8); axes[0].grid(alpha=.2)
    for ax, value in zip(axes[1:], [.01, .18]):
        position = min(gains.shape[2] - 1, value * gains.shape[2])
        lo, hi = int(position), min(gains.shape[2] - 1, int(position) + 1)
        fraction = position - lo
        image = ax.imshow((1 - fraction) * gains[..., lo] + fraction * gains[..., hi], cmap="viridis")
        ax.set(title=f"Spatial gain at table input {value}\nRAW-coordinate grid", xlabel="Horizontal map cell", ylabel="Vertical map cell")
        fig.colorbar(image, ax=ax, label="Gain")
    fig.savefig(output, dpi=150); plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("studies", type=Path, nargs="+", help="Completed study directories containing report.json")
    parser.add_argument("--profile-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    sources, outputs, configurations, inputs = {}, {}, {}, []
    first = None
    for directory in args.studies:
        report = json.loads((directory / "report.json").read_text())
        if report["status"] != "complete": raise ValueError("Study is incomplete")
        if first is None: first = report
        if any(report[key] != first[key] for key in ["source_sha256", "exposure_ev", "working_space", "os", "gpu"]):
            raise ValueError("Different source, exposure, working space, or platform across studies")
        for name, configuration in report["configurations"].items():
            reference = next(iter(first["configurations"].values()))["configured"]
            if any(configuration["configured"][key] != reference[key] for key in ["decoder_version", "white_xy"]):
                raise ValueError("Different decoder or captured white point across studies")
            if name in configurations and configurations[name] != configuration:
                raise ValueError(f"Conflicting configuration for {name}")
        for name, sample in report["source_samples"].items(): sources[name] = (directory, sample)
        for sample in report["outputs"]:
            key = (sample["variant"], sample["look"])
            if key in outputs and outputs[key][1]["encoded_sha256"] != sample["encoded_sha256"]:
                raise ValueError(f"Conflicting output for {key}")
            outputs[key] = (directory, sample)
        configurations.update(report["configurations"])
        inputs.append({"report": str((directory / "report.json").resolve()), "os": report["os"], "gpu": report["gpu"],
                       "decoder_exposure_probes": report["decoder_exposure_probes"],
                       "exposure_alignment": report.get("exposure_alignment"),
                       "edr_probe": report.get("neutral_edr_probe"), "edr_max_difference": report["neutral_edr0_vs_edr1_max_absolute_error"]})
    profile = json.loads((args.profile_dir / "embedded-profile.json").read_text())
    if profile["source_sha256"] != first["source_sha256"]:
        raise ValueError("Embedded profile does not belong to the study RAW")
    images, analysis, files = {}, [], {}
    for (variant, look), (directory, sample) in outputs.items():
        with (directory / sample["file"]).open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != sample["encoded_sha256"]:
                raise ValueError(f"HEIF does not match the device report: {sample['file']}")
        rgb = read_rgba(directory / sample["review_rgba_file"], sample["review_width"], sample["review_height"])
        preview = sdr(rgb); images[(variant, look)] = preview
        filename = variant + "-" + look + ".jpg"
        preview.save(out / filename, quality=95, icc_profile=ICC)
        shutil.copy2(directory / sample["file"], out / sample["file"])
        files[variant + ":" + look] = {"preview": filename, "heif": sample["file"]}
        entry = {"variant": variant, "look": look, "statistics": sample["statistics"],
                 "encoded_sha256": sample["encoded_sha256"], "preview_export_identical": sample["preview_export_identical"]}
        if look != "none":
            src_dir, src = sources[variant]
            pixels = read_rgba(src_dir / src["rgba_file"], src["width"], src["height"])
            # Reproduce the Float32 highlight normalization before the Double bridge.
            normalized = (pixels / np.maximum(np.float32(1), pixels.max(axis=-1, keepdims=True))).astype(np.float64)
            normalized *= 2 ** sample["bridge"]["exposure_ev"]
            matrix = np.array(sample["bridge"]["source_to_native_row_major"]).reshape(3, 3)
            native = np.stack([normalized[..., 0] * row[0] + normalized[..., 1] * row[1] + normalized[..., 2] * row[2]
                               for row in matrix], axis=-1)
            entry["native_bridge_preview_range"] = {"minimum": float(native.min()), "maximum": float(native.max()),
                "pixels_with_negative_channel_percent": float(100 * np.mean(np.any(native < 0, axis=-1))),
                "pixels_above_one_percent": float(100 * np.mean(np.any(native > 1, axis=-1))),
                "scope": "Input preview samples before the reference native-domain UInt16 clamp; not full-resolution clipping or color accuracy"}
        analysis.append(entry)
    sheets = []
    for variant, filename, title in [
        ("scene", "six-way-original.jpg", "六路对照：保留各自的原始曝光尺度"),
        ("scene-baseline", "six-way-baseline.jpg", "六路对照：去默认显影＋RAW 元数据曝光补偿"),
        ("scene-hdr-baseline", "six-way-hdr.jpg", "六路对照：两侧均保留 EDR，候选额外补偿 RAW 曝光"),
        ("scene-hdr-aligned", "six-way-aligned.jpg", "六路对照：以同一曝光系数对齐中间调，再分别应用 HNCS")]:
        if all((v, look) in images for v in ["current", variant] for look in LOOKS):
            sheet(images, ["current", variant], out / filename, title)
            sheets.append((filename, title))
    profile_figure(args.profile_dir, out / "embedded-profile.png")
    shutil.copy2(args.profile_dir / "embedded-profile.json", out / "embedded-profile.json")
    profile = json.loads((args.profile_dir / "embedded-profile.json").read_text())
    for table in profile["gain_tables"].values():
        filename = table["float32_little_endian_file"]
        shutil.copy2(args.profile_dir / filename, out / filename)
    summary = {"source_sha256": first["source_sha256"], "source_bytes": first["source_bytes"],
        "display_transform": "Fixed max-channel Reinhard followed by sRGB OETF; no per-image exposure, histogram or white-balance matching",
        "baseline_compensation_ev": first["baseline_compensation_ev"], "configurations": configurations,
        "statistics_scope": "Final HEIFs decoded to 2048-edge linear-sRGB review images; not statistics over every full-resolution output pixel.",
        "studies": inputs, "outputs": analysis,
        "limits": ["One indoor RAW; no measured color target or same-scene Hasselblad reference.",
                   "Metadata exposure compensation is not calibrated middle-gray matching.",
                   "Comparison images are SDR diagnostic views of finalized 24MP HDR HEIFs, not HDR screen captures."]}
    (out / "analysis.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    available = [key for key in NAMES if all((key, look) in images for look in LOOKS)]
    if not available: raise ValueError("No complete three-look variant to display")
    options = "".join(f'<option value="{key}">{html.escape(NAMES[key])}</option>' for key in available)
    overview = (f'<figure><img src="{sheets[-1][0]}" alt="六路对照"><figcaption>{html.escape(sheets[-1][1])}</figcaption></figure>'
                if sheets else "")
    links = " · ".join(f'<a href="{name}">{html.escape(title)}</a>' for name, title in sheets)
    alignment = next((study["exposure_alignment"] for study in inputs if study["exposure_alignment"]), None)
    alignment_note = (f'中间调对齐候选在元数据曝光补偿后再加 {alignment["extra_ev_after_baseline"]:+.4f} EV。'
                      '此系数从无 HNCS 输入的非饱和中间调计算，并固定用于三种效果；不逐图拟合颜色或曲线。' if alignment else "")
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>GlassCam RAW 输入对照</title><style>
body{font:16px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;background:#f4f5f7;color:#1e2630;margin:0}main{max-width:1120px;margin:auto;padding:28px}
h1{font-size:27px;margin:0 0 10px}p{max-width:920px}.controls{display:flex;gap:16px;flex-wrap:wrap;margin:20px 0}label{display:flex;flex-direction:column;gap:5px}select{padding:8px;border:1px solid #bcc4ce;border-radius:7px;background:white;font:inherit}
.compare{position:relative;background:#101216;max-width:700px;aspect-ratio:3/4;overflow:hidden;margin:auto}.compare img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}.line{position:absolute;top:0;bottom:0;border-left:2px solid white;left:50%;pointer-events:none}
input[type=range]{width:100%;margin:12px 0}.labels{display:flex;justify-content:space-between;gap:20px;font-size:14px}.note{color:#536274;font-size:14px}a{color:#1f5e98}figure{margin:25px 0}figure img{width:100%;height:auto}footer{border-top:1px solid #ccd2da;margin-top:25px;padding-top:18px}
</style><main><h1>GlassCam：RAW 输入与 HNCS 成片对照</h1>
<p>同一张 iPhone ProRAW，固定捕获白点、解码器版本和 HNCS 配方。每张图均从完整源处理后输出 24MP，再回读最终 HEIF；以下使用同一 SDR 诊断映射。</p>
<p class="note">元数据曝光补偿为 +BASELINE EV。ALIGNMENT_NOTE 这不是色卡标定或“已匹配哈苏”的证明。滑块左侧显示左选项，右侧显示右选项。</p>
<div class="controls"><label>左侧解码<select id="left">OPTIONS</select></label><label>右侧解码<select id="right">OPTIONS</select></label><label>效果<select id="look"><option value="none">无 HNCS</option><option value="standard" selected>Standard</option><option value="nature">Nature</option></select></label></div>
<div class="compare"><img id="back"><img id="front"><div class="line" id="line"></div></div><input id="slider" type="range" min="0" max="100" value="50" aria-label="左右对照位置"><div class="labels"><a id="leftFile">左侧原始 HDR HEIF</a><a id="rightFile">右侧原始 HDR HEIF</a></div>
OVERVIEW
<p>SHEET_LINKS · <a href="analysis.json">数值与参数报告</a></p>
<figure><img src="embedded-profile.png" alt="RAW 内嵌曲线和局部增益表"><figcaption>源文件的全局色调曲线与局部增益表。局部表作用于 DNG 指定的 RIMM 域，不能当作 sRGB 纠色 LUT。</figcaption></figure>
<footer class="note">这轮评估输入标准化、曝光和显示行为。灰阶、肤色及哈苏风格的普遍准确性还需要更多独立场景验证。</footer></main>
<script>const files=FILES;const left=document.getElementById('left'),right=document.getElementById('right'),look=document.getElementById('look'),slider=document.getElementById('slider');
right.value=DEFAULT_RIGHT;function update(){let a=files[left.value+':'+look.value],b=files[right.value+':'+look.value];document.getElementById('front').src=a.preview;document.getElementById('back').src=b.preview;document.getElementById('leftFile').href=a.heif;document.getElementById('rightFile').href=b.heif;document.getElementById('front').style.clipPath='inset(0 '+(100-slider.value)+'% 0 0)';document.getElementById('line').style.left=slider.value+'%';}for(const c of [left,right,look,slider])c.addEventListener('input',update);update();</script></html>'''
    page = (page.replace("OPTIONS", options).replace("BASELINE", f"{first['baseline_compensation_ev']:.4f}")
            .replace("ALIGNMENT_NOTE", alignment_note).replace("OVERVIEW", overview).replace("SHEET_LINKS", links)
            .replace("DEFAULT_RIGHT", json.dumps(available[-1])).replace("FILES", json.dumps(files)))
    (out / "comparison.html").write_text(page)
    print(out / "comparison.html")
    for row in analysis:
        print(row["variant"], row["look"], row.get("native_bridge_preview_range", {}))


if __name__ == "__main__": main()
