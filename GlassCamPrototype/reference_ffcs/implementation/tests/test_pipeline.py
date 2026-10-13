from io import BytesIO

from PIL import Image

from ffcs.color import adjust_lab, lab_to_rgb, rgb_to_lab
from ffcs.metrics import compare_stage_directories
from ffcs.models import get_simulation
from ffcs.pipeline import FFCS, PipelineConfig, REQUIRED_RAW_STAGES


def test_lab_round_trip_is_neutral():
    rgb = (0.72, 0.46, 0.33)
    assert max(abs(a - b) for a, b in zip(rgb, lab_to_rgb(rgb_to_lab(rgb)))) < 1e-5
    assert max(abs(a - b) for a, b in zip(rgb, adjust_lab(rgb, saturation=1.0))) < 1e-5


def test_stage_domains_match_saved_intermediate_values():
    result = FFCS(PipelineConfig(use_reference_luts=False)).apply(Image.new("RGB", (1, 1), (128, 128, 128)))
    assert result.metadata["stage_domains"]["gamma_pre"] == "linear"
    assert abs(result.stage_pixels["gamma_pre"][0][0][0] - 0.2158605) < 1e-6


def test_fujifilm_nc_cc_aliases():
    assert get_simulation("NC").name == "CLASSIC NEG."
    assert get_simulation("CC").name == "CLASSIC CHROME"


def test_custom_encoded_cube_declares_input_domain(tmp_path):
    cube = tmp_path / "identity.cube"
    cube.write_text("LUT_3D_SIZE 2\n" + "\n".join(f"{r} {g} {b}" for b in (0.0, 1.0) for g in (0.0, 1.0) for r in (0.0, 1.0)), encoding="utf-8")
    result = FFCS(PipelineConfig(lut_path=cube, lut_domain="encoded", camera="XH2S")).apply(Image.new("RGB", (1, 1), (128, 96, 64)))
    assert result.metadata["lut_domain"] == "encoded"
    assert result.metadata["matrix_fused_into_lut"] is False


def test_xh2s_reference_lut_and_stage_export(tmp_path):
    result = FFCS(PipelineConfig(simulation="PROVIA", camera="XH2S", stage_dir=tmp_path)).apply(Image.new("RGB", (4, 4), (128, 96, 64)))
    assert result.metadata["lut_source"].endswith("provia.lutz")
    assert result.metadata["stage_order"][-1] == "output_icc"
    assert (tmp_path / "lut_3d.tif").exists()
    assert (tmp_path / "pipeline.json").exists()


def test_additional_camera_reference_assets_are_selected():
    image = Image.new("RGB", (2, 2), (128, 96, 64))
    xa3 = FFCS(PipelineConfig(simulation="PROVIA", camera="XA3")).apply(image)
    gfx = FFCS(PipelineConfig(simulation="PROVIA", camera="GFX100S")).apply(image)
    assert xa3.metadata["lut_source"].endswith("xa3/provia.lutz")
    assert gfx.metadata["lut_source"].endswith("gfx100/provia.lutz")


def test_stage_contract_records_raw_and_colour_coverage():
    stage = Image.new("RGB", (2, 2), (0, 0, 0))
    raw_stages = {name: stage for name in REQUIRED_RAW_STAGES}
    raw_stage_pixels = {name: [[(0.123456, 0.234567, 0.345678)] * 2 for _ in range(2)] for name in REQUIRED_RAW_STAGES}
    result = FFCS(PipelineConfig(use_reference_luts=False)).apply(stage, raw_stages=raw_stages, raw_stage_pixels=raw_stage_pixels)
    assert result.validate_contract(raw=True)["status"] == "pass"
    coverage = result.metadata["stage_coverage"]
    assert coverage["required_raw"] == list(REQUIRED_RAW_STAGES)
    assert coverage["missing"] == []
    assert result.stage_pixels["raw_input"][0][0] == raw_stage_pixels["raw_input"][0][0]


def test_preview_backed_raf_keeps_raw_stage_contract(tmp_path):
    payload = BytesIO()
    Image.new("RGB", (4, 3), (80, 100, 120)).save(payload, format="JPEG", quality=100)
    path = tmp_path / "fixture.raf"
    path.write_bytes(b"FUJIFILMCCD-RAW" + payload.getvalue())
    result = FFCS(PipelineConfig(simulation="PROVIA", use_reference_luts=False)).apply_path(path)
    assert result.metadata["raw"]["decoder"] == "embedded-jpeg-preview"
    assert result.validate_contract(raw=True)["status"] == "pass"
    assert result.stage_pixels["resize_lanczos"][0][0][0] != 0.0


def test_raw_psnr_gate_uses_resize_stage_and_minimum_threshold(tmp_path):
    stage = Image.new("RGB", (2, 2), (64, 80, 96))
    raw_stages = {name: stage for name in REQUIRED_RAW_STAGES}
    result = FFCS(PipelineConfig(use_reference_luts=False)).apply(stage, raw_stages=raw_stages,raw_metadata={"decoder":"rawpy-sensor"})
    directory = tmp_path / "stages"
    result.save_stages(directory)
    report = compare_stage_directories(directory, directory)
    assert report["_summary"]["acceptance"]["raw_psnr_db"]["status"] == "pass"
