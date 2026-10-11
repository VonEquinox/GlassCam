"""Audit final deliverables against scope and freeze their SHA-256 manifest."""
import argparse
import json
from pathlib import Path
import re
import zipfile
import numpy as np
import rawpy
from PIL import Image
import hncs_pipeline as h
import hncs_paired_illuminants as paired

CASE=h.ROOT/"work/hncs-finalization"
PHOTOS={"DSC07247","DSC07426","DSC07294","DSC07372","DSC07240","DSC04637","DSC04945","DSC05218"}
SCRIPTS=["hncs_pipeline.py","hncs_dual_illuminant.py","hncs_paired_illuminants.py",
         "process_photo_batch.py","export_photo_original.py","fit_paired_illuminants.py",
         "prepare_sony_source_profile.py","verify_final_pipeline.py","package_hncs_runtime.py",
         "audit_hncs_finalization.py","test_hncs_pipeline.py","test_dual_illuminant.py",
         "test_paired_illuminants.py","requirements.txt","README.md"]


def read(relative):return json.loads((CASE/relative).read_text())


def audit():
    assets=h.load_assets();base=json.loads(h.PROFILE.read_text());model=paired.load_model()
    assert model["base_calibration_fingerprint"]==paired.profile_fingerprint(base)
    assert "User confirms" in base["calibration_input_assumption"]
    assert model["input_acceptance"]==base["calibration_input_assumption"]
    assert model["endpoints"][0]["fit_parameters"]=={"weight_power":.5,"ridge":.01}
    assert np.allclose(model["endpoints"][1]["matrix"],base["matrix"],atol=1e-14,rtol=0)
    clips=[]
    for path in (CASE/"evidence").glob("*.patches.json"):
        data=json.loads(path.read_text());assert len(data["values"])==24
        raw_path=CASE/"raw"/path.name.removesuffix(".patches.json")
        assert h.digest(raw_path)==data["metadata"]["sha256"]
        maximum=max(max(p["clipped_fraction"]) for p in data["quality"])
        assert maximum==0 and min(min(p["samples"]) for p in data["quality"])>100
        clips.append({"source":raw_path.name,"clipped_fraction_max":maximum,"sha256":h.digest(raw_path)})
    assert len(clips)==4
    evaluation=read("evidence/paired_chart_evaluation.json")["evaluation"]
    held=next(e for e in evaluation if e["dataset"]=="held_out_exposure_warm")
    assert "Not an independent scene" in held["metrics_scope"]
    means={mode:result["delta_e00"]["mean"] for mode,result in held["modes"].items()}
    assert min(means,key=means.get)=="paired" and abs(means["paired"]-.4320187628672792)<1e-12
    tests=(CASE/"evidence/tests.log").read_text()
    assert re.search(r"Ran 22 tests .*\n\nOK",tests)
    anchor=read("evidence/default_cli_regression.json")
    assert anchor["default_illuminant_mode"]=="paired" and anchor["full_master_file_identical_to_trusted_daylight_reference"]
    assert anchor["parameters"]["paired_model_sha256"]==h.digest(paired.MODEL)
    assert anchor["master_sha256"]==h.digest(h.WORK/"output/a7rv_hncs.tif")
    portability=read("evidence/runtime_portability.json")
    bundle=CASE/"hncs-runtime-r5.zip"
    assert portability["bundle_sha256"]==h.digest(bundle) and portability["isolated_runtime"]
    assert portability["full_cfa_identical"] and portability["hncs_master_file_sha256_identical"]
    with zipfile.ZipFile(bundle) as archive:
        manifest=json.loads(archive.read("runtime_manifest.json"))
        for name,expected in manifest["files"].items():
            if name!="README.md":assert h.digest(h.ROOT/name)==expected
            assert __import__("hashlib").sha256(archive.read(name)).hexdigest()==expected
    batch=read("output/batch_verification.json")
    assert {Path(row["source"]).stem for row in batch}==PHOTOS and len(batch)==8
    checked=[]
    for row in batch:
        source=Path(row["source"]);folder=Path(row["output"]);record=row["verification"]
        assert json.loads((folder/"verification.json").read_text())==record
        assert h.digest(source)==record["source_sha256"]
        assert record["hncs_parameters"]["illuminant_mode"]=="paired"
        assert record["hncs_parameters"]["paired_model_sha256"]==h.digest(paired.MODEL)
        for name,value in record["files"].items():
            assert (folder/name).stat().st_size==value["bytes"]
            assert h.digest(folder/name)==value["sha256"]
        with rawpy.imread(str(source)) as original,rawpy.imread(str(folder/f"{source.stem}_original.dng")) as dng:
            assert np.array_equal(original.raw_image,dng.raw_image)
            assert np.array_equal(original.raw_image_visible,dng.raw_image_visible)
            assert original.sizes.flip==dng.sizes.flip
        for suffix in ("hncs","hncs_srgb"):
            h.validate_output(folder/f"{source.stem}_{suffix}.tif",assets,"srgb" if suffix=="hncs_srgb" else "hasselblad")
        for suffix in ("hncs","original"):
            with Image.open(folder/f"{source.stem}_{suffix}.jpg") as image:
                assert image.size==tuple(record["jpeg_shape"][1::-1]) and image.info.get("icc_profile")
                image.verify()
        checked.append({"photo":source.stem,"full_and_visible_cfa_identical_now":True,
                        "source_and_output_hashes_verified_now":True,"cct":record["hncs_parameters"]["cct"]})
        print("Final audit",source.stem,"CFA and hashes confirmed",flush=True)
    final=read("evidence/final_output_verification.json")
    assert len(final["photos"])==8 and all(p["original_render_vs_previous_max_uint16_difference"]==0 for p in final["photos"])
    search=read("public-data-search.json")
    assert len(search["rounds"])==5 and len(search["final_rechecks"])==3
    for item in search["final_rechecks"]:
        evidence=read(item["evidence"])
        assert evidence["result"] and evidence["phase"]=="after_final_output_verification"
    repositories=read("evidence/final_repository_recheck.json")
    assert not repositories["songjiun10-collab/Hncs"]["changed_paths_vs_cached"]
    assert not repositories["haibogit2333/SSF-of-camera-data"]["truncated"]
    # Verify all local links in current delivery docs, not just the named report.
    documents=[h.ROOT/"README.md",CASE/"README.md",CASE/"output/README.md",
               CASE/"public-data-search.md",CASE/"2026-10-03_技术-HNCS-final-report.md"]
    future_files={CASE/"artifact_hashes.json",CASE/"completion_audit.json"}
    for document in documents:
        for target in re.findall(r"\]\(([^)]+)\)",document.read_text()):
            if target.startswith(("https://","http://","#")):continue
            path=(document.parent/target.split("#")[0]).resolve()
            assert path.exists() or path in future_files,(document,target)
    requirements=[
        {"id":1,"requirement":"接受用户原日光输入条件并写入当前模型与文档","status":"proven","evidence":["paired_illuminants.json","../../work/hncs-pipeline/a7rv_to_x2dii.json","../../README.md"],"scope":"基准输入假设，不由年份推断误差"},
        {"id":2,"requirement":"使用可取得的两机暖光 RAW 直接拟合并保留不同曝光验证","status":"proven","evidence":["sources/lowlight-candidates.json","evidence/warm-fit-selection.json","evidence/paired_chart_evaluation.json"],"scope":"24 块 CFA；同场景不同曝光；各组中性 WB/曝光归一化"},
        {"id":3,"requirement":"检查拟合、方向、光源插值、WB、曝光与边界，并按证据选默认","status":"proven","evidence":["evidence/tests.log","evidence/daylight-fit-study.json","evidence/fit-method-stability.json","evidence/sony-dcp-characterization.json","evidence/default_cli_regression.json"],"scope":"22 测试通过、两光源简单拟合、精确日光锚点；任意光谱与插值准确性边界明确"},
        {"id":4,"requirement":"完整 Python 默认流程、独立运行包、八张全尺寸 HNCS / DNG / JPG 与对比","status":"proven","evidence":["hncs-runtime-r5.zip","evidence/runtime_portability.json","output/batch_verification.json","evidence/final_output_verification.json","output/all_comparisons.jpg","output/previous_vs_final.jpg"],"scope":"完整 CFA 再读取核验、当前哈希、位深/ICC/方向/JPG 尺寸；Phocus 完整 RAW 等价性仍未声明"},
        {"id":5,"requirement":"完成多轮公开资料检索，采用合适数据后复查并按资料边界停止","status":"proven_with_bounded_search_scope","evidence":["public-data-search.json","public-data-search.md","evidence/search_round3_recheck.json","evidence/search_round4_recheck.json","evidence/search_round5_recheck.json","evidence/final_repository_recheck.json"],"scope":"五轮与交付前三轮复查；新增暖光 RAW 和 DCP 已采用；不是全网不存在证明"},
        {"id":6,"requirement":"保存来源、排除理由、搜索停止依据、测试、文件哈希和最终报告","status":"proven","evidence":["public-data-search.md","2026-10-03_技术-HNCS-final-report.md","artifact_hashes.json","evidence/timeline.json"],"scope":"本审计结束后写入 manifest 并独立重读校验；不改写历史证据"}]
    report={"goal_scope_source":"scope.md","status":"complete_with_explicit_accuracy_scope",
            "requirements":requirements,"raw_chart_checks":clips,"current_photo_checks":checked,
            "warm_validation_mean_delta_e00":means,"test_count":22,
            "runtime_bundle_sha256":h.digest(bundle),
            "accuracy_limits":["Not full Phocus RAW/spatial equivalence","No independent third-light or new-scene truth","WB cannot uniquely distinguish different physical spectra","Two-light interpolation remains assumed"],
            "browser_preference":"No further browser Computer Use after explicit user instruction"}
    h.save_json(CASE/"completion_audit.json",report)
    paths={h.ROOT/name for name in SCRIPTS}
    paths.update(p for p in CASE.rglob("*") if p.is_file() and "before" not in p.parts and "__pycache__" not in p.parts and p.name!="artifact_hashes.json")
    paths.update(p for p in h.ASSETS.iterdir() if p.is_file())
    paths.update([h.PROFILE,h.CHART,h.SOURCE,h.TARGET,
                  h.ROOT/"work/color-data-audit/sources/dpreview-widget.json",
                  h.ROOT/"work/hncs-dual-illuminant/model.json",
                  h.ROOT/"work/hncs-phocus-audit/2026-10-03_技术-Phocus-HNCS-audit-report.md"])
    paths.update(h.ROOT/f"{photo}.ARW" for photo in PHOTOS)
    paths.update(p for p in (h.ROOT/"work/hncs-phocus-audit/evidence").glob("*.json"))
    h.save_json(CASE/"artifact_hashes.json",{"algorithm":"sha256","base":"project root","excluded":"manifest itself; historical before snapshots and bytecode caches","files":{
        str(path.relative_to(h.ROOT)):{"bytes":path.stat().st_size,"sha256":h.digest(path)} for path in sorted(paths)}})
    verify_manifest()
    print("Six requirements audited; all final hashes verified",flush=True)


def verify_manifest():
    manifest=read("artifact_hashes.json")
    for name,record in manifest["files"].items():
        path=h.ROOT/name
        assert path.stat().st_size==record["bytes"] and h.digest(path)==record["sha256"],name
    print("Manifest verified:",len(manifest["files"]),"files",flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-manifest",action="store_true")
    args=parser.parse_args()
    if args.verify_manifest:verify_manifest()
    else:audit()
