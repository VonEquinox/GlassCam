"""Direct paired ColorChecker illuminant response interpolation."""
import json
import hashlib
from pathlib import Path
import numpy as np
import hncs_pipeline as h
import hncs_dual_illuminant as d

MODEL=h.ROOT/"work/hncs-finalization/paired_illuminants.json"


def profile_fingerprint(profile):
    values={k:profile[k] for k in ("matrix","source_wb","target_wb","source_scale","target_scale","target_cct")}
    values["source_sha256"]=profile["source"]["sha256"]
    values["target_sha256"]=profile["target"]["sha256"]
    values["assets"]=profile["assets_provenance"]["files"]
    return hashlib.sha256(json.dumps(values,sort_keys=True,separators=(",",":")).encode()).hexdigest()


def load_model(path=MODEL):
    model=json.loads(Path(path).read_text())
    if model.get("schema")!=1 or model.get("status")!="paired_chart_model":
        raise ValueError("Unsupported paired illuminant model")
    source_path=Path(model["source_model_path"])
    if not source_path.is_absolute():source_path=h.ROOT/source_path
    if h.digest(source_path)!=model["source_model_sha256"]:
        raise ValueError("Paired model source CCT profile changed; refit")
    endpoints=model["endpoints"]
    temperatures=np.array([e["source_estimated_cct"] for e in endpoints])
    if temperatures.shape!=(2,) or not np.isfinite(temperatures).all() or not 0<temperatures[0]<temperatures[1]:
        raise ValueError("Paired illuminant endpoints must be ascending")
    for endpoint in endpoints:
        swb=np.array(endpoint["source_wb"],dtype=float);twb=np.array(endpoint["target_wb"],dtype=float)
        matrix=np.array(endpoint["matrix"],dtype=float);response=np.array(endpoint["raw_response"],dtype=float)
        if swb.shape!=(3,) or twb.shape!=(3,) or not np.isfinite([swb,twb]).all() or np.any(swb<=0) or np.any(twb<=0):
            raise ValueError("Invalid paired calibration WB")
        if matrix.shape!=(3,3) or response.shape!=(3,3) or not np.isfinite([matrix,response]).all():
            raise ValueError("Invalid paired response matrix")
        if np.linalg.det(matrix)<=0 or np.linalg.cond(matrix)>20 or not np.allclose(matrix@np.ones(3),1,atol=1e-10,rtol=0):
            raise ValueError("Unstable or non-neutral paired matrix")
        if not np.allclose(response,matrix*swb[None,:]/twb[:,None],atol=1e-12,rtol=0):
            raise ValueError("Paired matrix and response convention disagree")
    return model


def colour_parameters(profile,assets,wb,wb_mode,cct_override=None,model_path=MODEL,
                      target_tint_multiplier=None):
    model=load_model(model_path)
    if model["base_calibration_fingerprint"]!=profile_fingerprint(profile):
        raise ValueError("Paired base calibration changed; refit")
    source_path=Path(model["source_model_path"])
    if not source_path.is_absolute():source_path=h.ROOT/source_path
    source_model=d.load_model(source_path)
    wb=np.asarray(wb,dtype=float)
    if wb.shape!=(3,) or not np.isfinite(wb).all() or np.any(wb<=0):raise ValueError("Invalid capture WB")
    wb=wb/wb[1]
    temperature,_,source_weight,xyz=d.source_illuminant(wb,source_model["sony"],assets)
    warm,day=model["endpoints"]
    low,high=warm["source_estimated_cct"],day["source_estimated_cct"]
    weight=float(np.clip((1/temperature-1/high)/(1/low-1/high),0,1))
    response=weight*np.array(warm["raw_response"])+(1-weight)*np.array(day["raw_response"])
    neutral=response@(1/wb)
    if not np.isfinite(neutral).all() or np.any(neutral<=0):raise ValueError("Invalid predicted X2D neutral")
    gain=float(neutral[1]);target_wb=gain/neutral
    matrix=response*target_wb[:,None]/wb[None,:]/gain
    for endpoint in (warm,day):
        if np.array_equal(wb,endpoint["source_wb"]):
            matrix=np.array(endpoint["matrix"]);target_wb=np.array(endpoint["target_wb"]);gain=1.
    if target_tint_multiplier is not None:
        override=np.asarray(target_tint_multiplier,dtype=float)
        if override.shape!=(3,) or not np.isfinite(override).all() or np.any(override<=0):
            raise ValueError("Invalid target white-balance preset gains")
        override=override/override[1]
        # The CCT is already selected by the factory matrix/LUT. Apply only
        # the native tint delta relative to the same-CCT zero-tint gain.
        target_wb=target_wb*override
        target_gain=float((neutral*target_wb)[1])
        matrix=response*target_wb[:,None]/wb[None,:]/target_gain
        gain=target_gain
    estimated,tint=h.estimate_cct(target_wb,assets)
    requested=estimated if cct_override is None else cct_override
    cct=int(np.clip(int(requested),2000,10000))
    return {"matrix":matrix.tolist(),"cct":cct,"cct_source":"manual" if cct_override is not None else "paired_illuminant_virtual_x2d_wb",
        "estimated_target_white_balance":target_wb.tolist(),"estimated_target_cct":estimated,"estimated_target_tint":tint,
        "factory_cct_clamped":int(requested)!=cct,"white_balance_bridge_enabled":True,"white_balance_bridge_neutral_gain":gain,
        "illuminant_mode":"paired","cross_illuminant_assumption":False,"paired_model_path":str(Path(model_path).resolve()),
        "paired_model_sha256":h.digest(model_path),"source_estimated_cct":temperature,"paired_warm_weight":weight,
        "paired_range_clamped":not low<=temperature<=high,"source_low_illuminant_weight":source_weight,
        "source_estimated_white_xy":(xyz[:2]/xyz.sum()).tolist(),
        "interpolation_assumption":"Two directly fitted nominal light responses interpolate in inverse estimated source CCT. Different physical light spectra with the same WB are not distinguished.",
        "calibration_input_assumption":model.get("input_acceptance"),
        "target_tint_multiplier":target_tint_multiplier}
