"""Bundle the saved rendering pipeline and verify it outside the workspace."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
import numpy as np
import tifffile
import hncs_pipeline as h

CASE=h.ROOT/"work/hncs-finalization"
BUNDLE=CASE/"hncs-runtime-r6.zip"
FILES=["hncs_pipeline.py","phocus_presets.py","work/hncs-pipeline/phocus_presets.json",
       "hncs_dual_illuminant.py","hncs_paired_illuminants.py",
       "process_photo_batch.py","export_photo_original.py","requirements.txt",
       "work/hncs-pipeline/a7rv_to_x2dii.json",
       "work/hncs-pipeline/assets/x2dii_phocus_422.npz",
       "work/hncs-pipeline/assets/HasselbladRGB.icc",
       "work/hncs-pipeline/assets/HasselbladLStarRGB.icc",
       "work/hncs-pipeline/assets/provenance.json",
       "work/hncs-dual-illuminant/model.json",
       "work/hncs-dual-illuminant/sources/LICENSE",
       "work/hncs-finalization/paired_illuminants.json",
       "work/hncs-finalization/sony_dcp_source_model.json"]
README="""# HNCS rendering runtime — revision 6

本包用已保存的日光/暖光直接配对模型，将 Sony A7R V RAW 映射到虚拟
X2D II，再执行恢复的 Phocus 4.2.2 非 HDR 工厂颜色核心。

在解压目录运行，Python 3.12 与 uv：

```bash
uv run --python 3.12 --with-requirements requirements.txt \\
  python process_photo_batch.py --output-dir output /absolute/path/photo.ARW
```

将 `/absolute/path/photo.ARW` 换成你的 A7R V RAW 路径，可连续列出多个文件。
有依赖缓存后可给 uv 添加 `--offline`；不需要 Phocus 或原色卡 RAW。
每张生成 HNCS JPG/16 位 TIFF、正常 CFA DNG、实际从 DNG 常规显影的
原色 JPG/16 位 sRGB TIFF，以及预览、实际参数和 SHA-256。

默认 paired；保留 --illuminant-mode adaptive/calibration/dual 历史模式。
支持 Phocus 的六个 Film Curve 名称（`as-shot`、`standard`、`low-contrast`、
`high-contrast`、`old-standard`、`linear`）以及 `Settings/Standard` 中提取的
全部 43 个 XML 设置：照片、白平衡、灰度、锐化、胶片颗粒、曝光、颜色校正、
曲线和其他工具预设。`--preset` 的可选值从随包的 `phocus_presets.json` 生成。
带 USM 参数的预设默认启用便携式近似锐化，`--no-sharpness` 可关闭；原生
Phocus 的镜头/除尘/专有空间锐化仍保留在参数记录中，不冒充颜色核心复现。
白平衡预设使用随包 JSON 中由 Phocus 原生 `TempAndTintToGain` probe 得到的
同 CCT Tint 相对增益；Film Grain 按 XML 五个控制量生成稳定便携式颗粒。
完整路径与内容校验只需标准库：

```bash
python3 -c 'import hashlib,json,pathlib; p=pathlib.Path("."); m=json.loads((p/"runtime_manifest.json").read_text()); assert all(hashlib.sha256((p/k).read_bytes()).hexdigest()==v for k,v in m["files"].items()); print("Runtime hashes OK")'
```

暖光不同曝光色卡平均 ΔE00 0.432，原 adaptive 为 0.551。
这个验证对齐各组中性块的 WB/曝光，参考本实现的哈苏颜色核心，覆盖同一
摄影棚场景。两端之间靠逆估计色温插值；范围外固定最近端点并记录。
相同 WB 的不同光谱和完整 Phocus RAW/空间处理等价性没有得到证明。
原色 JPG 是 LibRaw 常规显影，Sony 私有 MakerNotes 未迁移。

本包只含渲染运行文件，未包含原始照片、第三方 DCP 或重新拟合数据。
源码工作区保留完整拟合脚本、输入、五轮检索记录与验收证据。
工厂资产来自已分析的 Phocus 4.2.2；外部实验资料许可见
work/hncs-dual-illuminant/sources/LICENSE。Sony 矩阵来源及固定 commit
记录在 work/hncs-finalization/sony_dcp_source_model.json 中。
"""


def bundle():
    contents={name:(h.ROOT/name).read_bytes() for name in FILES}
    contents["README.md"]=README.encode()
    manifest={"render_path_revision":h.RENDER_PATH_REVISION,
              "files":{name:hashlib.sha256(data).hexdigest() for name,data in contents.items()}}
    contents["runtime_manifest.json"]=(json.dumps(manifest,indent=2)+"\n").encode()
    with zipfile.ZipFile(BUNDLE,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,data in contents.items():
            info=zipfile.ZipInfo(name,date_time=(2026,10,3,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644<<16
            archive.writestr(info,data)
    print("Bundled",BUNDLE,flush=True)


def verify():
    with tempfile.TemporaryDirectory(prefix="hncs-runtime-r6-") as temporary:
        runtime=Path(temporary)/"runtime";output=Path(temporary)/"output"
        with zipfile.ZipFile(BUNDLE) as archive:archive.extractall(runtime)
        manifest=json.loads((runtime/"runtime_manifest.json").read_text())
        assert all(h.digest(runtime/name)==value for name,value in manifest["files"].items())
        log_path=CASE/"evidence/runtime_portability.log"
        command=[sys.executable,str(runtime/"process_photo_batch.py"),"--output-dir",str(output),str(h.ROOT/"DSC07247.ARW")]
        with log_path.open("w") as log:
            subprocess.run(command,cwd="/tmp",stdout=log,stderr=log,check=True)
        records={};stem="DSC07247"
        for suffix in ("hncs.tif","hncs_srgb.tif","original_srgb.tif"):
            name=f"{stem}_{suffix}"
            a=tifffile.memmap(output/stem/name,mode="r")
            b=tifffile.memmap(CASE/"output"/stem/name,mode="r")
            assert a.shape==b.shape
            maximum=0
            for start in range(0,len(a),96):
                maximum=max(maximum,int(np.abs(a[start:start+96].astype(np.int32)-b[start:start+96].astype(np.int32)).max()))
            assert maximum==0
            with tifffile.TiffFile(output/stem/name) as tif:
                first=tif.pages[0];orientation=int(first.tags[274].value) if 274 in first.tags else 1
                description=first.tags[34675].value
            with tifffile.TiffFile(CASE/"output"/stem/name) as tif:
                second=tif.pages[0];expected=int(second.tags[274].value) if 274 in second.tags else 1
                assert orientation==expected
                if suffix=="hncs.tif":assert description==second.tags[34675].value
            records[name]={"max_uint16_difference":maximum,"orientation":orientation,
                           "shape":list(a.shape),"file_sha256":h.digest(output/stem/name)}
            del a,b
        assert records[f"{stem}_hncs.tif"]["file_sha256"]==h.digest(CASE/"output"/stem/f"{stem}_hncs.tif")
        report=json.loads((output/stem/"verification.json").read_text())
        assert report["dng_full_cfa_samples_identical"]
        h.save_json(CASE/"evidence/runtime_portability.json",{
            "bundle_sha256":h.digest(BUNDLE),"manifest_files_checked":len(manifest["files"]),
            "working_directory":"/tmp","isolated_runtime":True,
            "raw_dependency":"Only the supplied DSC07247.ARW; no original chart RAW, DCP file or Phocus process",
            "default_illuminant_mode":report["hncs_parameters"]["illuminant_mode"],
            "full_cfa_identical":True,"hncs_master_file_sha256_identical":True,
            "tiff_comparisons":records,"batch_verification":report})
    print("Isolated runtime and full batch verified",flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify",action="store_true")
    args=parser.parse_args();bundle()
    if args.verify:verify()
