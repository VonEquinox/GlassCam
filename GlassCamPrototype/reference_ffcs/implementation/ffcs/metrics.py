"""Reference comparison metrics for stage and end-to-end validation."""

from __future__ import annotations

import math
from pathlib import Path
from typing import Iterable, Sequence, Tuple

from .color import domain_to_lab, domain_to_xyz
from .validation import matching_shapes, pixel_shape


def load_stage_directory(directory: str | Path) -> dict:
    """Load stage TIFFs written by ``PipelineResult.save_stages``."""

    from .io import load_pixels
    directory = Path(directory)
    if not directory.is_dir():
        raise FileNotFoundError(f"Stage directory does not exist: {directory}")
    result = {}
    for path in sorted(directory.glob("*.tif")):
        result[path.stem] = load_pixels(path, colour_manage=False)
    if not result:
        raise ValueError(f"No stage TIFFs found in {directory}")
    return result


def load_stage_metadata(directory: str | Path) -> dict:
    path = Path(directory) / "pipeline.json"
    if not path.exists():
        return {}
    import json
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def compare_stage_directories(candidate: str | Path, reference: str | Path, stride: int = 1) -> dict:
    """Compare two exported stage directories with explicit residual status."""

    candidate_maps = load_stage_directory(candidate)
    reference_maps = load_stage_directory(reference)
    candidate_meta = load_stage_metadata(candidate)
    reference_meta = load_stage_metadata(reference)
    report = compare_stage_maps(reference_maps, candidate_maps, stride=stride,
                                reference_domains=reference_meta.get("stage_domains", {}),
                                candidate_domains=candidate_meta.get("stage_domains", {}))
    numeric = [v["delta_e2000_mean"] for v in report.values() if "delta_e2000_mean" in v]
    lut_metric = report.get("lut_3d", {})
    output_metric = report.get("output_icc", report.get("sharpen", {}))
    raw_metric = report.get("resize_lanczos", {}) if "resize_lanczos" in report else {}
    cgrain = candidate_meta.get("grain_statistics", {})
    rgrain = reference_meta.get("grain_statistics", {})
    grain_report = {"status": "unverified"}
    if cgrain and rgrain:
        cvar = cgrain.get("flat_region", {}).get("variance")
        rvar = rgrain.get("flat_region", {}).get("variance")
        cs = cgrain.get("radial_power_spectrum", [])
        rs = rgrain.get("radial_power_spectrum", [])
        compatible = (len(cs) == len(rs) and len(cs)>0 and
                      cgrain.get("method") == rgrain.get("method") and
                      cgrain.get("image_shape") == rgrain.get("image_shape"))
        n = len(cs) if compatible else 0
        spectrum_rmse = (sum((cs[i] - rs[i]) ** 2 for i in range(n)) / n) ** 0.5 if n else None
        variance_abs_error = abs(cvar - rvar) if cvar is not None and rvar is not None else None
        grain_report = {
            # Grain matching is a statistical equality gate.  Without a
            # declared tolerance, only an exact reproduction is a pass; the
            # raw errors remain visible for later fixture-specific analysis.
            "status": "fail" if not compatible else "pass" if variance_abs_error == 0.0 and spectrum_rmse == 0.0 else "fail" if variance_abs_error is not None and spectrum_rmse is not None else "unverified",
            "candidate_variance": cvar,
            "reference_variance": rvar,
            "variance_abs_error": variance_abs_error,
            "spectrum_rmse": spectrum_rmse,
            "spectrum_compatible": compatible,
        }
    def gate(metric: dict, target: float, key: str = "delta_e2000_mean", *, minimum: bool = False) -> dict:
        value = metric.get(key)
        if value is None or (isinstance(value, float) and math.isnan(value)):
            status = "unverified"
        else:
            status = "pass" if (value > target if minimum else value < target) else "fail"
        return {"value": value, "target": target, "comparison": ">" if minimum else "<", "status": status}
    problems = [k for k,v in report.items() if v.get("status") in {"missing", "shape_mismatch", "invalid"}]
    coverage = {}
    for side, meta, maps in (("candidate",candidate_meta,candidate_maps),("reference",reference_meta,reference_maps)):
        declared = meta.get("stage_coverage", {})
        required = set(declared.get("required_color", ())) | set(declared.get("required_raw", ()))
        missing = sorted(required-set(maps))
        coverage[side] = {**declared, "missing": missing, "status": "fail" if missing else "pass" if required else "unverified"}
    report["_summary"] = {
        "candidate": str(candidate), "reference": str(reference),
        "stages_compared": len(numeric),
        "max_delta_e2000_mean": max(numeric) if numeric else None,
        "unexplained_residual_stages": problems,
        "nonzero_residual_stages": [k for k,v in report.items() if v.get("delta_e2000_mean",0)>1e-8 or v.get("max_absolute_error",0)>1e-12],
        "stage_coverage": coverage,
        "acceptance": {
            "color_transform_delta_e2000_mean": gate(lut_metric, 1.0),
            "end_to_end_delta_e2000_mean": gate(output_metric, 2.0),
            "raw_psnr_db": gate(raw_metric, 35.0, "psnr_db", minimum=True),
            "grain_statistics": grain_report,
        },
    }
    acceptance = report["_summary"]["acceptance"]
    if "resize_lanczos" not in candidate_maps and "resize_lanczos" not in reference_maps:
        acceptance["raw_psnr_db"]["status"] = "not_applicable"
    elif any(meta.get("raw",{}).get("decoder")!="rawpy-sensor" for meta in (candidate_meta,reference_meta)):
        acceptance["raw_psnr_db"].update({"status":"unverified","reason":"Sensor RAW PSNR requires two sensor-domain results; embedded previews do not verify this gate"})
    statuses = [v["status"] for v in acceptance.values()]
    report["_summary"]["status"] = "fail" if problems or "fail" in statuses or any(v["status"]=="fail" for v in coverage.values()) else "unverified" if "unverified" in statuses or any(v["status"]=="unverified" for v in coverage.values()) else "pass"
    return report


def delta_e_76(lab1: Sequence[float], lab2: Sequence[float]) -> float:
    return math.sqrt(sum((float(a)-float(b))**2 for a, b in zip(lab1, lab2)))


def delta_e_2000(lab1: Sequence[float], lab2: Sequence[float]) -> float:
    """CIEDE2000, Sharma et al. 2005, with degree-safe trigonometry."""

    l1, a1, b1 = map(float, lab1); l2, a2, b2 = map(float, lab2)
    c1, c2 = math.hypot(a1, b1), math.hypot(a2, b2)
    cb = (c1+c2)/2.0
    g = 0.5*(1-math.sqrt(cb**7/(cb**7 + 25**7))) if cb else 0.5
    ap1, ap2 = (1+g)*a1, (1+g)*a2
    cp1, cp2 = math.hypot(ap1,b1), math.hypot(ap2,b2)
    hp1 = math.degrees(math.atan2(b1, ap1)) % 360 if cp1 else 0
    hp2 = math.degrees(math.atan2(b2, ap2)) % 360 if cp2 else 0
    dl = l2-l1; dc = cp2-cp1
    dh = hp2-hp1
    if cp1*cp2 == 0: dh = 0
    elif dh > 180: dh -= 360
    elif dh < -180: dh += 360
    dhp = 2*math.sqrt(cp1*cp2)*math.sin(math.radians(dh/2))
    lb = (l1+l2)/2; cbp = (cp1+cp2)/2
    if cp1*cp2 == 0: hp = hp1+hp2
    elif abs(hp1-hp2) <= 180: hp = (hp1+hp2)/2
    elif hp1+hp2 < 360: hp = (hp1+hp2+360)/2
    else: hp = (hp1+hp2-360)/2
    t = 1 - 0.17*math.cos(math.radians(hp-30)) + 0.24*math.cos(math.radians(2*hp)) + 0.32*math.cos(math.radians(3*hp+6)) - 0.20*math.cos(math.radians(4*hp-63))
    sl = 1 + 0.015*(lb-50)**2/math.sqrt(20+(lb-50)**2)
    sc = 1 + 0.045*cbp
    sh = 1 + 0.015*cbp*t
    rt = -2*math.sqrt(cbp**7/(cbp**7+25**7))*math.sin(math.radians(60*math.exp(-((hp-275)/25)**2)))
    return math.sqrt((dl/sl)**2 + (dc/sc)**2 + (dhp/sh)**2 + rt*(dc/sc)*(dhp/sh))


def mean_delta_e2000(
    pixels_a: Sequence[Sequence[Sequence[float]]],
    pixels_b: Sequence[Sequence[Sequence[float]]],
    stride: int = 1,
    domain: str = "encoded",
    *, reference_domain: str | None = None, candidate_domain: str | None = None,
) -> float:
    """Return mean CIEDE2000, converting linear working values for Lab."""

    h,w = matching_shapes(pixels_a, pixels_b)
    if stride<1: raise ValueError("stride must be positive")
    values = []
    for y in range(0, h, stride):
        for x in range(0, w, stride):
            values.append(delta_e_2000(domain_to_lab(pixels_a[y][x], reference_domain or domain), domain_to_lab(pixels_b[y][x], candidate_domain or domain)))
    return sum(values)/len(values)


def colorchecker24_delta_e2000(candidate: Sequence[Sequence[Sequence[float]]], reference: Sequence[Sequence[Sequence[float]]], boxes: Sequence[Tuple[int, int, int, int]], *, candidate_domain="encoded", reference_domain="encoded") -> dict:
    """Report mean/max CIEDE2000 for 24 ColorChecker swatch boxes.

    Boxes are supplied in image pixel coordinates, allowing charts with a
    border or perspective correction to be handled by the caller.
    """

    if len(boxes) != 24:
        raise ValueError(f"ColorChecker requires 24 boxes, got {len(boxes)}")
    h,w = matching_shapes(candidate, reference)
    seen = []
    for box in boxes:
        if len(box)!=4 or any(not isinstance(v,int) for v in box):
            raise ValueError("Each ColorChecker box must contain four integer coordinates")
        x0,y0,x1,y1 = box
        if not (0<=x0<x1<=w and 0<=y0<y1<=h):
            raise ValueError(f"Empty or out-of-bounds ColorChecker box: {box}")
        if any(max(x0,a)<min(x1,c) and max(y0,b)<min(y1,d) for a,b,c,d in seen):
            raise ValueError("ColorChecker swatches must be distinct and non-overlapping")
        seen.append(box)
    values = []
    for x0, y0, x1, y1 in boxes:
        samples = []
        for y in range(max(0, y0), min(len(candidate), y1)):
            for x in range(max(0, x0), min(len(candidate[y]), x1)):
                if y < len(reference) and x < len(reference[y]):
                    samples.append(delta_e_2000(domain_to_lab(candidate[y][x],candidate_domain), domain_to_lab(reference[y][x],reference_domain)))
        values.append(sum(samples) / len(samples))
    candidate_shape = (len(candidate), len(candidate[0]) if candidate else 0)
    reference_shape = (len(reference), len(reference[0]) if reference else 0)
    return {"mean": sum(values)/24, "max": max(values), "swatches": values, "valid_swatches": 24, "candidate_shape": candidate_shape, "reference_shape": reference_shape, "shape_mismatch": False}


def psnr(pixels_a: Sequence[Sequence[Sequence[float]]], pixels_b: Sequence[Sequence[Sequence[float]]], peak: float = 1.0) -> float:
    matching_shapes(pixels_a, pixels_b)
    if not math.isfinite(peak) or peak<=0: raise ValueError("PSNR peak must be finite and positive")
    values = []
    for row_a, row_b in zip(pixels_a, pixels_b):
        for a, b in zip(row_a, row_b):
            values.extend((float(a[i])-float(b[i]))**2 for i in range(3))
    mse = sum(values)/len(values) if values else 0.0
    return float("inf") if mse <= 1e-20 else 10.0 * math.log10(peak*peak/mse)


def flat_region_stats(pixels: Sequence[Sequence[Sequence[float]]], box: Tuple[int, int, int, int] | None = None) -> dict:
    h = len(pixels); w = len(pixels[0]) if h else 0
    x0, y0, x1, y1 = box or (0, 0, w, h)
    vals = [sum(row[x])/3 for row in pixels[max(0,y0):min(h,y1)] for x in range(max(0,x0), min(w,x1))]
    if not vals: return {"mean": 0.0, "variance": 0.0, "power": 0.0}
    mean = sum(vals)/len(vals); var = sum((v-mean)**2 for v in vals)/len(vals)
    return {"mean": mean, "variance": var, "power": sum(v*v for v in vals)/len(vals)}


def grain_spectrum(pixels: Sequence[Sequence[Sequence[float]]], bins: int = 8) -> list[float]:
    """Return a compact radial power spectrum for grain validation.

    NumPy FFT uses an evenly spaced grid (at most 32×32). Frequencies fold
    through fftfreq so positive and negative bins have the same radius.
    """

    import numpy as np
    if bins<1: raise ValueError("bins must be positive")
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    if not h or not w:
        return [0.0] * bins
    n = min(32, h, w)
    sample = [[sum(pixels[min(h-1, round(y*(h-1)/(n-1)))][min(w-1, round(x*(w-1)/(n-1)))])/3 for x in range(n)] for y in range(n)] if n > 1 else [[sum(pixels[0][0])/3]]
    mean = sum(v for row in sample for v in row) / (n*n)
    out = [0.0]*bins; counts = [0]*bins
    spectrum = np.abs(np.fft.fft2(np.asarray(sample)-mean))**2/(n*n)**2
    frequencies = np.fft.fftfreq(n)
    for ky,fy in enumerate(frequencies):
        for kx,fx in enumerate(frequencies):
            radius = math.hypot(float(fx),float(fy))/math.sqrt(0.5)
            idx = min(bins-1,int(radius*bins))
            out[idx] += float(spectrum[ky,kx]); counts[idx]+=1
    return [out[i]/counts[i] if counts[i] else 0.0 for i in range(bins)]


def compare_stage_maps(reference: dict, candidate: dict, stride: int = 1, stage_domains: dict | None = None, *, reference_domains: dict | None = None, candidate_domains: dict | None = None) -> dict:
    names = sorted(set(reference) | set(candidate))
    out = {}
    for name in names:
        if name not in reference or name not in candidate:
            out[name] = {"status": "missing"}
        else:
            try:
                ref_shape = pixel_shape(reference[name]); cand_shape = pixel_shape(candidate[name])
            except ValueError as exc:
                out[name] = {"status":"invalid","reason":str(exc)}
                continue
            if ref_shape != cand_shape:
                out[name] = {"status": "shape_mismatch", "reference_shape": ref_shape, "candidate_shape": cand_shape}
                continue
            rd = (reference_domains or stage_domains or {}).get(name,"encoded")
            cd = (candidate_domains or stage_domains or {}).get(name,"encoded")
            ra,ca = reference[name],candidate[name]
            metric = {"reference_domain":rd,"candidate_domain":cd}
            if rd in {"sensor-code","cfa-linear"} or cd in {"sensor-code","cfa-linear"}:
                if rd!=cd:
                    out[name] = {"status":"invalid","reason":"Sensor stage domains differ"}
                    continue
                metric["status"]="numeric_only"
            else:
                metric["delta_e2000_mean"] = mean_delta_e2000(ra,ca,stride,reference_domain=rd,candidate_domain=cd)
                if rd!=cd:
                    ra = [[domain_to_xyz(rgb,rd) for rgb in row] for row in ra]
                    ca = [[domain_to_xyz(rgb,cd) for rgb in row] for row in ca]
                    metric["psnr_domain"] = "XYZ"
            peak = max(1.0,max(v for row in ra for rgb in row for v in rgb)) if rd=="sensor-code" else 1.0
            metric["psnr_db"] = psnr(ra,ca,peak)
            metric["max_absolute_error"] = max(abs(a-b) for rowa,rowb in zip(ra,ca) for a_rgb,b_rgb in zip(rowa,rowb) for a,b in zip(a_rgb,b_rgb))
            out[name] = metric
    return out
