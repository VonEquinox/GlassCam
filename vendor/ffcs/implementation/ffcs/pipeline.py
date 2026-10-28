"""Complete FFCS colour and RAW-to-render pipeline."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Dict, List, Mapping, Sequence, Tuple

from PIL import Image

from .color import adobe_rgb_to_srgb, adjust_lab, adjust_ucs, apply_3d_lut, apply_matrix, clamp, grayscale, load_cube_lut, srgb_decode, srgb_encode, srgb_to_adobe_rgb, tone_curve
from .effects import apply_grain, apply_sharpen_pixels
from .io import _icc_bytes, image_from_pixels, load_pixels, pixels_from_image, save_image, write_float_tiff
from .lutdata import load_reference_lut, reference_validation
from .metrics import compare_stage_maps, flat_region_stats, grain_spectrum, mean_delta_e2000, psnr
from .models import CameraProfile, FilmSimulation, get_camera, get_simulation
from .raw import RawDevelopment, develop_raf, is_raf
from .validation import canonical_space, json_safe, matching_shapes, pixel_shape

RGB = Tuple[float, float, float]

REQUIRED_COLOR_STAGES = ("input_normalized", "gamma_pre", "matrix_3x3", "lut_3d", "lab_ucs", "tone_curve", "film_grain", "sharpen", "output_icc")
REQUIRED_RAW_STAGES = ("raw_input", "black_level", "bad_pixel_repair", "lens_shading", "band_preprocess", "white_balance", "demosaic", "shadow_cleanup", "resize_lanczos")


@dataclass
class PipelineConfig:
    simulation: str | FilmSimulation = "PROVIA"
    camera: str | CameraProfile = "GENERIC"
    output_space: str = "sRGB"
    output_bits: int = 16
    seed: int = 0
    filter_colour: str | None = None
    stage_dir: str | Path | None = None
    sharpen_radius: float = 1.0
    input_is_linear: bool = False
    lut_path: str | Path | None = None
    lut_domain: str | None = None
    sigma: float | None = None
    use_reference_luts: bool = True
    apply_reference_adjustments: bool = False

    def __post_init__(self):
        self.output_space = canonical_space(self.output_space)
        if self.output_bits not in {8,16}: raise ValueError("output_bits must be 8 or 16")
        if not math.isfinite(self.sharpen_radius) or self.sharpen_radius<=0:
            raise ValueError("sharpen_radius must be finite and positive")
        if self.sigma is not None and (not math.isfinite(self.sigma) or not 0.05<=self.sigma<=8):
            raise ValueError("sigma must be finite and in [0.05,8]")

    def resolved_simulation(self) -> FilmSimulation:
        if isinstance(self.simulation, FilmSimulation):
            return self.simulation
        return get_simulation(self.simulation, self.filter_colour)

    def resolved_camera(self) -> CameraProfile:
        if isinstance(self.camera, CameraProfile):
            return self.camera
        return get_camera(self.camera)


@dataclass
class PipelineResult:
    image: Image.Image
    pixels: List[List[RGB]]
    stages: Dict[str, Image.Image]
    stage_pixels: Dict[str, List[List[RGB]]]
    metadata: Dict[str, object] = field(default_factory=dict)

    def save(self, path: str | Path, bits: int | None = None, output_space: str | None = None) -> None:
        resolved_bits = bits if bits is not None else int(self.metadata.get("output_bits", 16))
        resolved_space = output_space or str(self.metadata.get("output_space", "sRGB"))
        resolved_space = canonical_space(resolved_space)
        original = canonical_space(self.metadata.get("output_space","sRGB"))
        pixels = self.pixels
        image = self.image
        if resolved_space!=original:
            convert = srgb_to_adobe_rgb if resolved_space=="AdobeRGB" else adobe_rgb_to_srgb
            pixels = [[convert(rgb) for rgb in row] for row in pixels]
            image = image_from_pixels(pixels)
        save_image(path, image, pixels, bits=resolved_bits, colour_space=resolved_space)
        with Image.open(path) as file:
            embedded = bool(file.info.get("icc_profile"))
        self.metadata.setdefault("output_files",[]).append({"path":str(path),"space":resolved_space,"icc_embedded":embedded})

    def save_stages(self, directory: str | Path, bits: int | None = None, output_space: str | None = None) -> None:
        bits = int(self.metadata.get("output_bits",16)) if bits is None else bits
        space = canonical_space(self.metadata.get("output_space","sRGB"))
        if output_space and canonical_space(output_space)!=space:
            raise ValueError("Stage output space must match the rendered result")
        files = {}
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        for name, image in self.stages.items():
            safe = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in name)
            pixels = self.stage_pixels.get(name)
            domain = self.metadata.get("stage_domains",{}).get(name,"encoded")
            path = directory / f"{safe}.tif"
            if domain in {"linear","sensor-code","cfa-linear"}:
                write_float_tiff(path,pixels)
                files[name] = {"bits":32,"sample_format":"float","icc_embedded":False,"domain":domain}
            else:
                stage_space = space if name=="output_icc" else "sRGB"
                save_image(path,image,pixels,bits=bits,colour_space=stage_space)
                with Image.open(path) as saved:
                    embedded = bool(saved.info.get("icc_profile"))
                files[name] = {"bits":bits,"sample_format":"uint","space":stage_space,"icc_embedded":embedded,"domain":domain}
        self.metadata["stage_files"] = files
        (directory / "pipeline.json").write_text(json.dumps(json_safe(self.metadata), indent=2, allow_nan=False, default=str), encoding="utf-8")

    def compare(self, reference: "PipelineResult", stride: int = 1) -> dict:
        """Compare this result with a reference stage by stage.

        Missing stages are reported explicitly, and the output includes the
        end-to-end ΔE2000 and PSNR so unexplained residuals remain visible.
        """

        rd,cd = reference.metadata.get("stage_domains",{}),self.metadata.get("stage_domains",{})
        stage_metrics = compare_stage_maps(reference.stage_pixels,self.stage_pixels,stride,reference_domains=rd,candidate_domains=cd)
        stage_metrics["__output__"] = compare_stage_maps({"output":reference.pixels},{"output":self.pixels},stride,
            reference_domains={"output":reference.metadata.get("output_space","sRGB")},
            candidate_domains={"output":self.metadata.get("output_space","sRGB")})["output"]
        return stage_metrics

    def validate_contract(self, raw: bool = False) -> dict:
        required = set(REQUIRED_COLOR_STAGES)
        if raw:
            required.update(REQUIRED_RAW_STAGES)
        present = set(self.stages)
        return {"required": sorted(required), "present": sorted(present), "missing": sorted(required - present), "status": "pass" if required <= present else "fail", "scope":"stage names only; not reference equivalence"}


def _linear_to_encoded(pixels: Sequence[Sequence[RGB]]) -> List[List[RGB]]:
    return [[tuple(srgb_encode(clamp(v)) for v in rgb) for rgb in row] for row in pixels]


def _encoded_to_linear(pixels: Sequence[Sequence[RGB]]) -> List[List[RGB]]:
    return [[tuple(srgb_decode(clamp(v)) for v in rgb) for rgb in row] for row in pixels]


def _mono_weights(sim: FilmSimulation) -> Tuple[float, float, float]:
    n = sim.name.upper()
    if "+G" in n: return (0.20, 0.68, 0.12)
    if "+R" in n: return (0.62, 0.26, 0.12)
    if "+YE" in n: return (0.42, 0.48, 0.10)
    return (0.2126, 0.7152, 0.0722)


def _apply_monochrome(pixels: Sequence[Sequence[RGB]], sim: FilmSimulation) -> List[List[RGB]]:
    weights = _mono_weights(sim)
    out: List[List[RGB]] = []
    for row in pixels:
        nrow = []
        for rgb in row:
            y = grayscale(rgb, weights)
            if sim.sepia:
                # Slightly lifted highlights reproduce a restrained sepia tone.
                nrow.append((clamp(y * 1.04), clamp(y * 0.88), clamp(y * 0.68)))
            else:
                nrow.append((y, y, y))
        out.append(nrow)
    return out


def _stage_image(pixels: Sequence[Sequence[RGB]]) -> Image.Image:
    return image_from_pixels(pixels, bits=8)


class FFCS:
    """Renderer implementing the colour stages and stage-level observability."""

    def __init__(self, config: PipelineConfig | None = None):
        self.config = config or PipelineConfig()

    def apply(
        self,
        image: Image.Image,
        *,
        input_pixels: Sequence[Sequence[RGB]] | None = None,
        raw_stages: Mapping[str, Image.Image] | None = None,
        raw_stage_pixels: Mapping[str, Sequence[Sequence[RGB]]] | None = None,
        raw_metadata: Mapping[str, object] | None = None,
        input_is_linear: bool | None = None,
    ) -> PipelineResult:
        cfg = self.config
        sim = cfg.resolved_simulation()
        camera = cfg.resolved_camera()
        reference_lut_path = None
        supplied_lut = sim.lut is not None
        if cfg.lut_path:
            size, lut = load_cube_lut(cfg.lut_path)
            requested_domain = (cfg.lut_domain or sim.lut_domain).strip().lower()
            if requested_domain not in {"linear", "encoded"}:
                raise ValueError("lut_domain must be 'linear' or 'encoded'")
            sim = replace(sim, lut=lut, lut_size=size, lut_domain=requested_domain, lut_source=str(cfg.lut_path))
        elif cfg.use_reference_luts and not supplied_lut:
            loaded = load_reference_lut(camera.name, sim.name)
            if loaded is not None:
                lut, matrix, reference_lut_path = loaded
                sim = replace(
                    sim, lut=lut, lut_size=lut.size, matrix=tuple(tuple(matrix[r*3+c] for c in range(3)) for r in range(3)),
                    lut_domain="encoded", lut_scale=lut.scale, lut_source=str(reference_lut_path),
                )
        if sim.lut is not None and not cfg.apply_reference_adjustments and not isinstance(cfg.simulation,FilmSimulation):
            sim = replace(sim,contrast=1,saturation=1,hue_shift=0,highlight_rolloff=0,shadow_lift=0,grain_strength=0,sharpness=0)
        if cfg.sigma is not None:
            sim = replace(sim, sigma=float(cfg.sigma))
        if not math.isfinite(sim.sigma) or not 0.05<=sim.sigma<=8:
            raise ValueError("Simulation sigma must be finite and in [0.05,8]")
        linear_input = input_is_linear if input_is_linear is not None else bool((raw_metadata or {}).get("decoder")=="rawpy-sensor" or cfg.input_is_linear)
        stages: Dict[str, Image.Image] = {}
        stage_pixels: Dict[str, List[List[RGB]]] = {}
        metadata: Dict[str, object] = {
            "simulation": sim.name, "camera": camera.name, "output_space": cfg.output_space,
            "output_bits": cfg.output_bits, "seed": cfg.seed, "sigma": sim.sigma,
            "version":"0.2.0", "input_domain":"linear" if linear_input else "encoded",
            "lut_source": sim.lut_source or ("custom-lut" if sim.lut is not None else "analytic"),
            "lut_domain": sim.lut_domain,
            "matrix_fused_into_lut": bool(reference_lut_path),
            "approximations": [
                "Built-in looks use analytic profiles when no measured/reference LUT is available.",
                "RAF decoding uses rawpy when installed, otherwise the largest embedded JPEG preview.",
                "Camera-specific RAW calibration and demosaic coefficients require a reference RAF fixture for quantitative validation.",
                "Non-default sigma is an explicit portable tanh adjustment, not native normal-distribution mode.",
            ],
            "approximation_metrics": {
                "analytic_look": {"status": "unquantified", "reason": "no bundled native table for the requested camera/look"},
                "raw_calibration": {"status": "unquantified", "reason": "no matching RAF reference stages supplied"},
                "sigma_override": {"status":"not_used" if sim.sigma==1 else "unquantified","reason":"portable adjustment has no matching native reference"},
                "lab_ucs":{"status":"not_used" if sim.saturation==1 and sim.hue_shift==0 else "unquantified"},
                "tone_curve":{"status":"not_used" if sim.contrast==1 and sim.highlight_rolloff==0 and sim.shadow_lift==0 else "unquantified"},
                "film_grain":{"status":"not_used" if sim.grain_strength<=0 else "unquantified"},
                "sharpen":{"status":"not_used" if sim.sharpness<=0 else "unquantified"},
            },
            "stage_contract": [
                {"name": "input_normalized", "domain": "sRGB-normalized [0,1]"},
                {"name": "gamma_pre", "domain": "linear-light RGB"},
                {"name": "matrix_3x3", "domain": "linear camera/work RGB"},
                {"name": "lut_3d", "domain": "camera/work RGB with trilinear interpolation (linear or encoded per LUT)"},
                {"name": "lab_ucs", "domain": "CIELAB then OKLab UCS"},
                {"name": "tone_curve", "domain": "display RGB"},
                {"name": "film_grain", "domain": "display RGB with seeded noise"},
                {"name": "sharpen", "domain": "display RGB"},
                {"name": "output_icc", "domain": cfg.output_space},
            ],
            "stage_aliases": {
                "input_normalization": "input_normalized",
                "3d_color_mapping": "lut_3d",
                "output_color_management": "output_icc",
            },
        }
        if raw_metadata:
            metadata["raw"] = dict(raw_metadata)
        elif not raw_stages:
            metadata["approximation_metrics"]["raw_calibration"] = {"status": "not_applicable"}
        if sim.lut is not None:
            metadata["approximation_metrics"]["analytic_look"] = {"status": "not_used"}
        if reference_lut_path:
            metadata["reference_camera_asset"] = reference_lut_path.parent.name.upper()
            requested = "".join(c for c in camera.name.lower() if c.isalnum())
            substitute = requested!=reference_lut_path.parent.name
            metadata["approximation_metrics"]["camera_asset_substitution"] = {
                "status":"unquantified" if substitute else "not_used",
                "requested_camera":camera.name,"asset_family":reference_lut_path.parent.name}
            metadata["approximation_metrics"]["analytic_look"] = {"status": "not_used"}
            if abs(float(sim.sigma) - 1.0) < 1e-7:
                metadata["approximation_metrics"]["sigma_override"] = {"status": "not_used"}
            metadata["reference_lut_validation"] = reference_validation(reference_lut_path)
            metadata["reference_lut_validation"]["applies_to_current_lut_stage"] = sim.sigma==1
        metadata["resolved_simulation"] = {key:value for key,value in sim.__dict__.items() if key!="lut"}
        metadata["resolved_camera"] = dict(camera.__dict__)
        metadata["reference_adjustments_enabled"] = cfg.apply_reference_adjustments or isinstance(cfg.simulation,FilmSimulation)
        metadata["end_to_end_reference_validation"] = {"status":"unverified","reason":"No paired real RAF/GUI/ColorChecker reference fixture is bundled"}
        if raw_stages:
            for key, val in raw_stages.items():
                stages[key] = val.copy()
                if raw_stage_pixels and key in raw_stage_pixels:
                    stage_pixels[key] = [list(map(tuple, row)) for row in raw_stage_pixels[key]]
                else:
                    stage_pixels[key] = pixels_from_image(val)

        pixels = [list(map(tuple, row)) for row in input_pixels] if input_pixels is not None else pixels_from_image(image)
        pixel_shape(pixels)
        def put(name: str, p: Sequence[Sequence[RGB]]) -> None:
            q = [list(map(tuple, row)) for row in p]
            stage_pixels[name] = q
            stages[name] = _stage_image(q)

        put("input_normalized", pixels)
        if linear_input:
            linear = pixels
        else:
            linear = _encoded_to_linear(pixels)
        # Keep stage pixels in their actual working domain.  The preview Image
        # is still an 8-bit rendering, while ``stage_pixels`` retains the
        # normalized linear values used by the next stage.
        put("gamma_pre", linear)

        if sim.lut_domain == "encoded":
            matrix_pixels = [[apply_matrix(rgb, sim.matrix) for rgb in row] for row in linear]
        else:
            matrix_pixels = [[apply_matrix(apply_matrix(rgb, camera.matrix), sim.matrix) for rgb in row] for row in linear]
        put("matrix_3x3", matrix_pixels)

        if sim.lut_domain == "encoded":
            encoded = [[apply_3d_lut(rgb, sim) for rgb in row] for row in _linear_to_encoded(matrix_pixels)]
            put("lut_3d", encoded)
        else:
            lut_pixels = [[apply_3d_lut(rgb, sim) for rgb in row] for row in matrix_pixels]
            put("lut_3d", lut_pixels)
            encoded = _linear_to_encoded(lut_pixels)
        # LAB/UCS fine tuning is kept separate from the tone curve so residuals
        # can be attributed to one stage during reference comparisons.
        if sim.lut_domain != "encoded" and (sim.acros or sim.saturation == 0 or sim.sepia):
            # Filter the coloured values before any desaturation removes them.
            lab_pixels = _apply_monochrome(encoded,sim)
        elif sim.saturation==1 and sim.hue_shift==0:
            lab_pixels = encoded
        else:
            lab_pixels = [[adjust_ucs(adjust_lab(rgb,contrast=1,saturation=sim.saturation,hue_shift=sim.hue_shift)) for rgb in row] for row in encoded]
        put("lab_ucs", lab_pixels)

        tone_pixels = [[tone_curve(rgb, contrast=sim.contrast, shoulder=sim.highlight_rolloff, toe=sim.shadow_lift) for rgb in row] for row in lab_pixels]
        put("tone_curve", tone_pixels)

        grain_pixels = apply_grain(tone_pixels, sim, seed=cfg.seed)
        put("film_grain", grain_pixels)
        grain_noise = [[tuple(a-b for a,b in zip(g,t)) for g,t in zip(grow,trow)] for grow,trow in zip(grain_pixels,tone_pixels)]
        metadata["grain_statistics"] = {
            "method":"grain-residual-fft-v1","image_shape":[len(pixels),len(pixels[0])],
            "flat_region": flat_region_stats(grain_noise),
            "radial_power_spectrum": grain_spectrum(grain_noise),
        }

        sharpen_pixels = apply_sharpen_pixels(grain_pixels, sim.sharpness, cfg.sharpen_radius)
        put("sharpen", sharpen_pixels)

        # Pillow embeds ICC where available; pixel values remain in the chosen
        # display encoding and are explicitly tagged in metadata.
        output_pixels = sharpen_pixels if cfg.output_space.lower() == "srgb" else [[srgb_to_adobe_rgb(rgb) for rgb in row] for row in sharpen_pixels]
        output = _stage_image(output_pixels)
        put("output_icc", output_pixels)
        present_stages = list(stages)
        missing_color = [name for name in REQUIRED_COLOR_STAGES if name not in stages]
        # A RAW result carries the pre-colour stage map into this method.  Keep
        # its required-stage list in the saved manifest so an exported run can
        # be validated without reconstructing whether the source was RAF.
        has_raw_stages = any(name in stages for name in REQUIRED_RAW_STAGES)
        missing_raw = [name for name in REQUIRED_RAW_STAGES if name not in stages] if has_raw_stages else []
        metadata["stage_order"] = present_stages
        metadata["stage_coverage"] = {
            "scope": "stage names only; not reference equivalence",
            "required_color": list(REQUIRED_COLOR_STAGES),
            "required_raw": list(REQUIRED_RAW_STAGES) if has_raw_stages else [],
            "present": present_stages,
            "missing": missing_color + missing_raw,
            "status": "pass" if not (missing_color or missing_raw) else "fail",
        }
        stage_domains = {
            "input_normalized": "linear" if linear_input else "encoded",
            "gamma_pre": "linear",
            "matrix_3x3": "linear",
            "lut_3d": "encoded" if sim.lut_domain == "encoded" else "linear",
            "lab_ucs": "encoded",
            "tone_curve": "encoded",
            "film_grain": "encoded",
            "sharpen": "encoded",
            "output_icc": cfg.output_space,
        }
        if raw_stages:
            raw_domain = "linear" if str((raw_metadata or {}).get("decoder", "")).lower() == "rawpy-sensor" else "encoded"
            stage_domains.update({name: raw_domain for name in raw_stages})
            if raw_domain=="linear":
                stage_domains["raw_input"]="sensor-code"
                for name in ("black_level","bad_pixel_repair","lens_shading","band_preprocess","white_balance"):
                    if name in raw_stages: stage_domains[name]="cfa-linear"
        metadata["stage_domains"] = stage_domains
        metadata["stage_contract"][0]["domain"] = stage_domains["input_normalized"]
        metadata["colour_management"] = {"profile": cfg.output_space, "profile_available": bool(_icc_bytes(cfg.output_space))}
        result = PipelineResult(output, output_pixels, stages, stage_pixels, metadata)
        if cfg.stage_dir:
            result.save_stages(cfg.stage_dir, bits=cfg.output_bits, output_space=cfg.output_space)
        return result

    def apply_path(self, path: str | Path) -> PipelineResult:
        if is_raf(path):
            developed = develop_raf(path, self.config.camera)
            return self.apply(
                developed.image,
                input_pixels=developed.stage_pixels.get("resize_lanczos"),
                raw_stages=developed.stages,
                raw_stage_pixels=developed.stage_pixels,
                raw_metadata=developed.metadata,
                input_is_linear=developed.metadata.get("decoder")=="rawpy-sensor",
            )
        pixels = load_pixels(path,colour_manage=not self.config.input_is_linear)
        return self.apply(image_from_pixels(pixels),input_pixels=pixels)


def apply_image(path: str | Path, output: str | Path, config: PipelineConfig | None = None) -> PipelineResult:
    renderer = FFCS(config)
    result = renderer.apply_path(path)
    cfg = renderer.config
    result.save(output, bits=cfg.output_bits, output_space=cfg.output_space)
    return result
