"""Independent inputs guarding the defects found in the October 2026 audit."""
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import json
import math
import sys

import numpy as np
import pytest
import tifffile
from PIL import Image, ImageCms

from ffcs.cli import main
from ffcs.color import apply_3d_lut, load_cube_lut, srgb_encode
from ffcs.effects import apply_sharpen_pixels
from ffcs.io import _icc_bytes, image_from_pixels, load_pixels, write_tiff16
from ffcs.lutdata import load_packed_lut
from ffcs.metrics import (colorchecker24_delta_e2000,compare_stage_directories,compare_stage_maps,
                          delta_e_2000,grain_spectrum,mean_delta_e2000,psnr)
from ffcs.models import FilmSimulation,get_simulation
from ffcs.pipeline import FFCS,PipelineConfig
from ffcs.raw import (RawSensor,_rawpy_decode,_sensor_bad_pixels,_sensor_band_preprocess,
                       _sensor_black_level,_sensor_white_balance,demosaic_cfa,develop_raf,extract_raf_preview)

BAYER = (("R","G"),("G","B"))
XTRANS = tuple(tuple(row) for row in ("GRGGBG","BGBRGR","GRGGBG","GBGGRG","RGRBGB","GBGGRG"))
NEUTRAL = FilmSimulation("TEST_NEUTRAL")


def test_sensor_domain_and_raw_codes_survive_pipeline_and_export(tmp_path):
    sensor = RawSensor([[500.]*4 for _ in range(4)],BAYER,(0,0,0),1000,(1,1,1))
    raf = tmp_path/"sensor.raf"; raf.write_bytes(b"FUJIFILMCCD-RAW")
    with patch("ffcs.raw.load_raf",return_value=(sensor,{"decoder":"rawpy-sensor"})):
        result = FFCS(PipelineConfig(simulation=NEUTRAL,use_reference_luts=False)).apply_path(raf)
    assert result.stage_pixels["gamma_pre"][1][1] == (0.5,)*3
    assert result.pixels[1][1] == pytest.approx((srgb_encode(0.5),)*3,abs=1e-12)
    assert result.metadata["stage_domains"]["input_normalized"] == "linear"
    result.save_stages(tmp_path/"stages")
    assert load_pixels(tmp_path/"stages/raw_input.tif",colour_manage=False)[1][1] == (500.,)*3
    with tifffile.TiffFile(tmp_path/"stages/gamma_pre.tif") as file:
        assert file.pages[0].dtype == np.dtype("float32")
        assert 34675 not in file.pages[0].tags


@pytest.mark.parametrize("pattern",[BAYER,XTRANS])
@pytest.mark.parametrize("colour",["R","G","B"])
@pytest.mark.parametrize("value",[0.8,1.0])
def test_cfa_processing_preserves_uniform_colour_fields(pattern,colour,value):
    ph,pw = len(pattern),len(pattern[0])
    plane = [[value if pattern[y%ph][x%pw]==colour else 0. for x in range(18)] for y in range(18)]
    repaired = _sensor_bad_pixels(plane,pattern)
    filtered = _sensor_band_preprocess(repaired,pattern)
    assert np.asarray(filtered) == pytest.approx(np.asarray(plane))
    rgb = demosaic_cfa(filtered,pattern)[9][9]
    assert rgb == pytest.approx(tuple(value if c==colour else 0 for c in "RGB"))


def test_demosaic_preserves_measured_center_channel():
    plane = [[0.2]*5 for _ in range(5)]; plane[2][2]=0.8
    assert demosaic_cfa(plane,BAYER)[2][2][0] == 0.8


def test_decoder_keeps_separate_green_black_and_wb(monkeypatch):
    class SensorFile:
        raw_image_visible = np.array([[110,120],[140,130]],dtype=np.uint16)
        raw_pattern = raw_colors_visible = np.array([[0,1],[3,2]],dtype=np.uint8)
        color_desc = b"RGBG"
        black_level_per_channel = [10,20,30,40]
        white_level = 1010
        camera_whitebalance = [2,1,3,1.2]
        def __enter__(self): return self
        def __exit__(self,*args): pass
    monkeypatch.setitem(sys.modules,"rawpy",SimpleNamespace(imread=lambda p:SensorFile()))
    from ffcs.models import get_camera
    sensor = _rawpy_decode("test.raf",get_camera("GENERIC"))
    assert sensor.black_pattern == ((10.,20.),(40.,30.))
    black = _sensor_black_level(sensor)
    assert black[1][0] == pytest.approx(100/970)
    balanced = _sensor_white_balance(black,sensor)
    assert balanced[1][0] == pytest.approx((100/970)*1.2/1.1)


def test_preview_uses_pixel_area_and_is_not_developed_twice(tmp_path):
    rng = np.random.default_rng(17)
    noisy = Image.fromarray(rng.integers(0,256,(64,64,3),dtype=np.uint8))
    larger = Image.new("RGB",(128,128),(80,100,120))
    a,b = BytesIO(),BytesIO()
    noisy.save(a,"JPEG",quality=100); larger.save(b,"JPEG",quality=95)
    assert len(a.getvalue())>len(b.getvalue())
    path = tmp_path/"preview.raf";path.write_bytes(b"FUJIFILMCCD-RAW"+a.getvalue()+b.getvalue())
    preview = extract_raf_preview(path)
    assert preview.size == (128,128)
    with patch("ffcs.raw._rawpy_decode",return_value=None):
        result = develop_raf(path,"XH2S")
    assert result.stage_pixels["raw_input"] == result.stage_pixels["resize_lanczos"]
    assert result.metadata["stage_status"]["white_balance"] == "not_applicable"


def test_partial_colorchecker_cannot_pass_cli(tmp_path,capsys):
    path = tmp_path/"image.png";Image.new("RGB",(1,1),(128,128,128)).save(path)
    boxes = tmp_path/"boxes.json";boxes.write_text(json.dumps([[0,0,1,1]]+[[2,2,3,3]]*23))
    assert main(["colorchecker",str(path),str(path),"--boxes",str(boxes)])==2
    assert "out-of-bounds" in capsys.readouterr().err


def test_colorchecker_requires_all_distinct_finite_swatches():
    pixels = [[(.2,.4,.6)]*6 for _ in range(4)]
    boxes = [(x,y,x+1,y+1) for y in range(4) for x in range(6)]
    assert colorchecker24_delta_e2000(pixels,pixels,boxes)["valid_swatches"]==24
    with pytest.raises(ValueError): colorchecker24_delta_e2000(pixels,pixels,[boxes[0]]*24)
    invalid = [[(float("nan"),0,0)]*6 for _ in range(4)]
    with pytest.raises(ValueError): colorchecker24_delta_e2000(invalid,pixels,boxes)


def test_adobergb_metric_does_not_clip_wide_gamut_difference():
    difference = mean_delta_e2000([[(0,.8,0)]],[[(.4,.8,0)]],domain="AdobeRGB")
    assert difference == pytest.approx(7.760737351551751,abs=1e-8)


def test_general_icc_colorchecker_matches_d65_lab(tmp_path):
    from ffcs.color import domain_to_lab
    from ffcs.io import load_lab_pixels
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    source = np.array([[[0,65535,0],[30000,10000,60000],[20000,20000,20000]]],dtype=np.uint16)
    path = tmp_path/"profile.tif"
    tifffile.imwrite(path,source,photometric="rgb",extratags=[(34675,"B",len(profile),profile,False)])
    measured = load_lab_pixels(path)
    for rgb,lab in zip(source[0],measured[0]):
        assert delta_e_2000(domain_to_lab(rgb/65535,"sRGB"),lab)<.02


def test_adobergb_colorchecker_files_cannot_hide_difference_in_srgb_clip(tmp_path,capsys):
    a,b=tmp_path/"a.tif",tmp_path/"b.tif"
    write_tiff16(a,[[(0,.8,0)]*6 for _ in range(4)],"AdobeRGB")
    write_tiff16(b,[[(.4,.8,0)]*6 for _ in range(4)],"AdobeRGB")
    boxes=tmp_path/"boxes.json";boxes.write_text(json.dumps([(x,y,x+1,y+1) for y in range(4) for x in range(6)]))
    assert main(["colorchecker",str(a),str(b),"--boxes",str(boxes)])==1
    assert json.loads(capsys.readouterr().out)["mean"]>7


def test_comparison_interprets_each_side_domain():
    linear = [[(.5,.5,.5)]]; encoded = [[(srgb_encode(.5),)*3]]
    result = compare_stage_maps({"s":linear},{"s":encoded},reference_domains={"s":"linear"},candidate_domains={"s":"sRGB"})["s"]
    assert result["delta_e2000_mean"]<1e-10
    assert result["psnr_domain"]=="XYZ"


@pytest.mark.parametrize("function",[mean_delta_e2000,psnr])
def test_numeric_metrics_reject_shape_mismatch(function):
    with pytest.raises(ValueError): function([[(0,0,0)]],[[(0,0,0),(0,0,0)]])


def test_result_compare_reports_output_shape_mismatch():
    renderer=FFCS(PipelineConfig(simulation=NEUTRAL,use_reference_luts=False))
    a=renderer.apply(Image.new("RGB",(1,1))); b=renderer.apply(Image.new("RGB",(2,1)))
    assert a.compare(b)["__output__"]["status"]=="shape_mismatch"


@pytest.mark.parametrize("orientation",range(1,9))
def test_tiff16_orientations_preserve_all_channel_bits(tmp_path,orientation):
    array = np.arange(18,dtype=np.uint16).reshape(3,2,3)*1000+17
    path = tmp_path/"image.tif"
    tifffile.imwrite(path,array,photometric="rgb",metadata=None,extratags=[(274,"H",1,orientation,False)])
    preview=Image.fromarray((array>>8).astype(np.uint8)); preview.getexif()[274]=orientation
    from PIL import ImageOps
    expected_preview = ImageOps.exif_transpose(preview)
    result = load_pixels(path)
    assert (len(result[0]),len(result))==expected_preview.size
    # Every original 16-bit tuple must survive rotation/flip exactly.
    assert sorted(tuple(round(v*65535) for v in rgb) for row in result for rgb in row)==sorted(map(tuple,array.reshape(-1,3)))
    expected = ImageOps.exif_transpose(preview)
    actual = np.asarray(result)*65535
    assert (actual.astype(np.uint16)>>8).tolist()==np.asarray(expected).tolist()


@pytest.mark.parametrize("compression",[None,"deflate","lzw"])
def test_planar_compressed_tiff16_is_not_reinterpreted_as_contiguous(tmp_path,compression):
    array = np.array([[[10000,40000]],[[20000,50000]],[[30000,60000]]],dtype=np.uint16)
    path=tmp_path/"planar.tif"
    tifffile.imwrite(path,array,photometric="rgb",planarconfig="separate",compression=compression,metadata=None)
    assert np.asarray(load_pixels(path))*65535 == pytest.approx(np.moveaxis(array,0,-1))


def test_tiff_photometric_validation(tmp_path):
    path = tmp_path/"cmyk.tif"
    tifffile.imwrite(path,np.zeros((2,2,4),dtype=np.uint16),photometric="separated",metadata=None)
    with pytest.raises(ValueError,match="photometric"): load_pixels(path)


def test_tagged_srgb_and_adobe_input_match_within_source_quantization(tmp_path):
    srgb=ImageCms.ImageCmsProfile(BytesIO(_icc_bytes("sRGB")))
    adobe=ImageCms.ImageCmsProfile(BytesIO(_icc_bytes("AdobeRGB")))
    source=Image.new("RGB",(1,1),(64,128,192))
    converted=ImageCms.profileToProfile(source,srgb,adobe,outputMode="RGB")
    p,q=tmp_path/"s.png",tmp_path/"a.png"
    source.save(p,icc_profile=srgb.tobytes()); converted.save(q,icc_profile=adobe.tobytes())
    assert mean_delta_e2000(load_pixels(p),load_pixels(q))<.15


def test_icc_conversion_keeps_more_than_eight_bits(tmp_path):
    values = [[(x/65535,)*3 for x in range(10000,10512)]]
    path = tmp_path/"adobe.tif";write_tiff16(path,values,"AdobeRGB")
    converted = load_pixels(path)
    assert len({rgb[0] for rgb in converted[0]})>256


def test_adobe_stage_export_uses_result_profile_and_save_converts_space(tmp_path):
    result=FFCS(PipelineConfig(simulation=NEUTRAL,use_reference_luts=False,output_space="AdobeRGB")).apply(Image.new("RGB",(1,1),(64,128,192)))
    result.save_stages(tmp_path/"stages")
    with Image.open(tmp_path/"stages/output_icc.tif") as image:
        assert image.info["icc_profile"]==_icc_bytes("AdobeRGB")
    result.save(tmp_path/"srgb.tif",output_space="sRGB")
    assert mean_delta_e2000(load_pixels(tmp_path/"srgb.tif"),[[(64/255,128/255,192/255)]])<.02
    with pytest.raises(ValueError): result.save_stages(tmp_path/"bad",output_space="sRGB")


def test_analytic_filters_act_before_colour_information_is_removed():
    image=Image.new("RGB",(2,1));image.putdata([(255,0,0),(0,255,0)])
    results={f:FFCS(PipelineConfig(simulation="MONOCHROME",filter_colour=f,use_reference_luts=False)).apply(image) for f in ("R","G")}
    assert results["R"].pixels[0][0][0]>results["G"].pixels[0][0][0]
    assert results["G"].pixels[0][1][0]>results["R"].pixels[0][1][0]


def test_reference_mapping_is_not_retuned_by_default():
    image=Image.new("RGB",(4,4),(64,128,192))
    result=FFCS(PipelineConfig(camera="XH2S",simulation="VELVIA")).apply(image)
    assert result.pixels==result.stage_pixels["lut_3d"]
    assert result.metadata["approximation_metrics"]["tone_curve"]["status"]=="not_used"
    adjusted=FFCS(PipelineConfig(camera="XH2S",simulation="VELVIA",apply_reference_adjustments=True)).apply(image)
    assert adjusted.pixels!=adjusted.stage_pixels["lut_3d"]
    assert adjusted.metadata["approximation_metrics"]["tone_curve"]["status"]=="unquantified"


def test_explicit_lut_is_not_overwritten_by_camera_lookup():
    lut=[(0.,0.,0.)]*8
    spec=FilmSimulation("PROVIA",lut=lut,lut_size=2,lut_domain="encoded")
    result=FFCS(PipelineConfig(camera="XH2S",simulation=spec)).apply(Image.new("RGB",(1,1),(128,128,128)))
    assert result.pixels[0][0]==(0,0,0)
    assert result.metadata["lut_source"]=="custom-lut"


@pytest.mark.parametrize("camera,look,suffix",[("GFX100S","NOSTALGIC NEG.","gfx100s/nostalgic_neg.lutz"),("GFX100 II","REALA ACE","gfx100ii/reala_ace.lutz")])
def test_omitted_native_camera_assets_are_selected(camera,look,suffix):
    result=FFCS(PipelineConfig(camera=camera,simulation=look)).apply(Image.new("RGB",(1,1),(128,128,128)))
    assert result.metadata["lut_source"].endswith(suffix)


def test_sharpen_radius_changes_a_float_image():
    pixels=[[(.4,)*3]*7 for _ in range(7)];pixels[3][3]=(.6,)*3
    a=apply_sharpen_pixels(pixels,1,.5);b=apply_sharpen_pixels(pixels,1,2)
    assert abs(a[3][3][0]-b[3][3][0])>.001


def test_radial_spectrum_folds_positive_and_negative_frequencies():
    pixels=[[((.5+.1*math.sin(2*math.pi*x/16)),)*3 for x in range(16)] for _ in range(16)]
    spectrum=grain_spectrum(pixels)
    assert spectrum[0]>0
    assert max(spectrum[1:])<1e-20


def test_grain_spectrum_length_mismatch_cannot_pass(tmp_path):
    directories=[tmp_path/"candidate",tmp_path/"reference"]
    for directory,spectrum in zip(directories,([1],[1,99])):
        directory.mkdir();write_tiff16(directory/"film_grain.tif",[[(.5,)*3]])
        (directory/"pipeline.json").write_text(json.dumps({"grain_statistics":{"flat_region":{"variance":.1},"radial_power_spectrum":spectrum}}))
    assert compare_stage_directories(*directories)["_summary"]["acceptance"]["grain_statistics"]["status"]=="fail"


def test_cli_comparison_serializes_perfect_psnr_as_strict_json(tmp_path,capsys):
    result=FFCS(PipelineConfig(simulation=NEUTRAL,use_reference_luts=False)).apply(Image.new("RGB",(2,2)))
    result.save_stages(tmp_path/"stages")
    assert main(["compare",str(tmp_path/"stages"),str(tmp_path/"stages")])==0
    output=capsys.readouterr().out
    report=json.loads(output,parse_constant=lambda value:pytest.fail(f"Non-standard JSON constant {value}"))
    assert report["output_icc"]["psnr_db"]=="Infinity"


def test_cube_domain_and_resolve_shaper_are_honored(tmp_path):
    nodes="\n".join(f"{r} {g} {b}" for b in (0,1) for g in (0,1) for r in (0,1))
    cube=tmp_path/"range.cube"
    cube.write_text("LUT_3D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n"+nodes)
    size,lut=load_cube_lut(cube)
    assert apply_3d_lut((0,0,0),FilmSimulation("N",lut=lut,lut_size=size))==(.5,)*3
    cube.write_text("LUT_1D_SIZE 3\nLUT_3D_SIZE 2\nLUT_1D_INPUT_RANGE 0 1\nLUT_3D_INPUT_RANGE 0 1\n0 0 0\n0.25 0.25 0.25\n1 1 1\n"+nodes)
    size,lut=load_cube_lut(cube)
    assert apply_3d_lut((.5,)*3,FilmSimulation("N",lut=lut,lut_size=size))==(.25,)*3


def test_lut_corruption_is_rejected(tmp_path):
    import ffcs
    source=Path(ffcs.__file__).parent/"data/xh2s/provia.lutz"
    target=tmp_path/"bad.lutz";target.write_bytes(source.read_bytes()+b"trailing")
    with pytest.raises(ValueError): load_packed_lut(target)
    target.write_bytes(b"FFCSLUT2")
    with pytest.raises(ValueError): load_packed_lut(target)


def test_ciede2000_matches_author_reference_pairs():
    source=Path(__file__).with_name("fixtures")/"ciede2000_reference.txt"
    for line in source.read_text().splitlines():
        if not line.strip(): continue
        row=list(map(float,line.split()))
        assert delta_e_2000(row[:3],row[3:6])==pytest.approx(row[6],abs=.00005)
