"""Run the existing HNCS renderer and CFA DNG/JPEG export for multiple photos."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from PIL import Image, ImageDraw, ImageCms

ROOT = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--illuminant-mode",choices=["adaptive","calibration","dual"],default="adaptive")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    for index, source in enumerate(args.inputs, 1):
        source = source.resolve()
        folder = output / source.stem
        folder.mkdir(parents=True, exist_ok=True)
        print(f"[{index}/{len(args.inputs)}] Processing {source.name}", flush=True)
        with (folder / "processing.log").open("w") as log:
            subprocess.run([sys.executable, str(ROOT / "hncs_pipeline.py"), "render",
                "--input", str(source), "--wb", "camera", "--illuminant-mode",args.illuminant_mode,"--output",
                str(folder / f"{source.stem}_hncs.tif")], cwd=ROOT, stdout=log, stderr=log, check=True)
            subprocess.run([sys.executable, str(ROOT / "export_photo_original.py"),
                "--input", str(source), "--output-dir", str(folder)],
                cwd=ROOT, stdout=log, stderr=log, check=True)
        report = json.loads((folder / "verification.json").read_text())
        reports.append({"source":str(source), "output":str(folder),
            "verification":report})
        (output / "batch_verification.json").write_text(json.dumps(reports, indent=2)+"\n")
        print(f"[{index}/{len(args.inputs)}] Done: {source.stem}; HNCS {report['hncs_parameters']['cct']} K; CFA identical; JPEG {report['jpeg_shape'][1]} x {report['jpeg_shape'][0]}", flush=True)
    tiles = []
    for entry in reports:
        stem = Path(entry["source"]).stem
        with Image.open(Path(entry["output"]) / f"{stem}_comparison.jpg") as image:
            tile = image.copy()
        tile.thumbnail((1000,620))
        tiles.append((stem,tile))
    row_heights = [max(tile.height for _,tile in tiles[i:i+2])+45 for i in range(0,len(tiles),2)]
    sheet = Image.new("RGB", (2000, sum(row_heights)), "#eeeeee")
    draw = ImageDraw.Draw(sheet)
    for i, (stem, tile) in enumerate(tiles):
        x,y = (i%2)*1000, sum(row_heights[:i//2])
        draw.text((x+15,y+10), stem+" | left: original, right: HNCS", fill="black")
        sheet.paste(tile, (x+(1000-tile.width)//2,y+35))
    sheet.save(output / "all_comparisons.jpg", quality=95,
               icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    mode_text = {"adaptive":"假设白平衡前 Sony→哈苏响应映射跨光源一致；逐张估计哈苏 WB，调整矩阵并选择 HNCS 工厂色温。",
                 "calibration":"沿用标定矩阵及标定工厂色温。",
                 "dual":"双光源实验模型：Sony A/D50、哈苏 A/D65 独立矩阵通过 XYZ 衔接，并用已有配对标定固定基准。各自范围外使用最近端点，没有虚构 Sony D65 标定。"}[args.illuminant_mode]
    lines = ["# 批量输出", "", "每张照片均使用拍摄白平衡；"+mode_text, "",
        "每个文件夹包含完整 HNCS JPG、原始 CFA DNG、从 DNG 常规显影的原色 JPG、16 位 TIFF、预览和核验 JSON。",
        "DNG 未迁移 Sony 私有 MakerNotes；原色 JPG 不等于 Sony 机内创意外观。HNCS 的跨光源准确性及完整 Phocus 等价性仍未验证。", "",
        "亮度差包含已有标定曝光尺度与 HNCS 曲线，并未额外对齐曝光。", "",
        "| 照片 | HNCS 色温 | HNCS JPG | 原色 JPG | DNG | 对比 |", "|---|---:|---|---|---|---|"]
    for entry in reports:
        stem = Path(entry["source"]).stem
        cct=entry["verification"]["hncs_parameters"]["cct"]
        lines.append(f"| {stem} | {cct} K | [HNCS]({stem}/{stem}_hncs.jpg) | [原色]({stem}/{stem}_original.jpg) | [DNG]({stem}/{stem}_original.dng) | [对比]({stem}/{stem}_comparison.jpg) |")
    (output / "README.md").write_text("\n".join(lines)+"\n")
    print(f"Complete: {output}", flush=True)

if __name__ == "__main__":
    main()
