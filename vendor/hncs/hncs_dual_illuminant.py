"""Experimental illuminant-dependent response mapping from public matrices.

Uses DXOMARK A7R V A/D50 data and pinned Hncs X2D II A/D65 chart fits.
These are separate characterizations, not paired Sony/Hasselblad measurements.
The existing paired calibration anchors the response at its own white balance.
"""
from pathlib import Path
import json
import numpy as np
import hncs_pipeline as hncs

CASE = hncs.ROOT / "work/hncs-dual-illuminant"
MODEL = CASE / "model.json"
BRADFORD = np.array([[.8951,.2664,-.1614],[-.7502,1.7135,.0367],[.0389,-.0685,1.0296]])
SRGB_XYZ = np.array([[.4124564,.3575761,.1804375],[.2126729,.7151522,.0721750],[.0193339,.1191920,.9503041]])


def xy_xyz(xy):
    x,y = np.asarray(xy,dtype=float)
    if not (np.isfinite([x,y]).all() and y>0 and x>0 and x+y<1):
        raise ValueError("Invalid illuminant chromaticity")
    return np.array([x/y,1,(1-x-y)/y])


def adaptation(source, target):
    return np.linalg.solve(BRADFORD,np.diag((BRADFORD@target)/(BRADFORD@source))@BRADFORD)


def xyz_cct(xyz, table):
    """Continuous Robertson CCT for iteration, using the recovered table."""
    xyz=np.asarray(xyz,dtype=float)
    if xyz.shape!=(3,) or not np.isfinite(xyz).all() or np.any(xyz<=0):
        raise ValueError("Nonphysical XYZ neutral")
    x,y=xyz[:2]/xyz.sum()
    denominator=1.5-x+6*y
    u,v=2*x/denominator,3*y/denominator
    previous=0.
    for i in range(1,len(table)):
        mired,ui,vi,slope=table[i]
        distance=((v-vi)-(u-ui)*slope)/np.sqrt(1+slope*slope)
        if distance<=0 or i==len(table)-1:
            if i==1:return 50000.
            distance=min(distance,0.)
            fraction=-distance/(previous-distance)
            return float(1e6/(table[i-1,0]*fraction+mired*(1-fraction)))
        previous=distance
    raise ValueError("CCT iteration failed")


def interpolate_cm(camera, temperature):
    """Interpolate stored XYZ->native matrices in inverse Kelvin, then invert."""
    temperatures=np.asarray(camera["temperatures"],dtype=float)
    if temperatures.shape!=(2,) or not 0<temperatures[0]<temperatures[1]:
        raise ValueError("Experimental profile needs two ascending illuminants")
    weight=float(np.clip((1/temperature-1/temperatures[1])/(1/temperatures[0]-1/temperatures[1]),0,1))
    matrices=np.asarray(camera["xyz_to_native"],dtype=float)
    if matrices.shape!=(2,3,3) or not np.isfinite(matrices).all():
        raise ValueError("Invalid experimental camera matrices")
    return weight*matrices[0]+(1-weight)*matrices[1],weight


def source_illuminant(source_wb, camera, assets):
    wb=np.asarray(source_wb,dtype=float)
    if wb.shape!=(3,) or not np.isfinite(wb).all() or np.any(wb<=0):
        raise ValueError("Invalid source capture WB")
    wb=wb/wb[1];neutral=1/wb
    temperature=5003.
    for iteration in range(80):
        matrix,weight=interpolate_cm(camera,temperature)
        xyz=np.linalg.solve(matrix,neutral)
        next_temperature=xyz_cct(xyz,assets["robertson"])
        if abs(1e6/next_temperature-1e6/temperature)<1e-8:
            temperature=next_temperature;break
        temperature=next_temperature
    else:raise ValueError("Experimental illuminant solution did not converge")
    matrix,weight=interpolate_cm(camera,temperature)
    xyz=np.linalg.solve(matrix,neutral)
    return temperature,matrix,weight,xyz


def public_response(source_wb, model, assets):
    temperature,source_cm,source_weight,xyz=source_illuminant(source_wb,model["sony"],assets)
    target_cm,target_weight=interpolate_cm(model["hasselblad"],temperature)
    response=target_cm@np.linalg.inv(source_cm)
    return response,{"source_estimated_cct":temperature,
        "source_estimated_white_xy":(xyz[:2]/xyz.sum()).tolist(),
        "source_low_illuminant_weight":source_weight,
        "target_low_illuminant_weight":target_weight,
        "source_profile_range_clamped":not model["sony"]["temperatures"][0]<=temperature<=model["sony"]["temperatures"][1],
        "target_profile_range_clamped":not model["hasselblad"]["temperatures"][0]<=temperature<=model["hasselblad"]["temperatures"][1]}


def load_model(path=MODEL):
    model=json.loads(Path(path).read_text())
    if model.get("schema")!=1 or model.get("status")!="experimental":
        raise ValueError("Unsupported dual-illuminant model")
    for camera in [model[name] for name in ("sony","hasselblad") if name in model]:
        for temp in camera["temperatures"]:
            matrix,_=interpolate_cm(camera,temp)
            if np.linalg.cond(matrix)>100:raise ValueError("Ill-conditioned experimental matrix")
    return model


def colour_parameters(profile,assets,wb,wb_mode,cct_override=None,model_path=MODEL,
                      target_tint_multiplier=None):
    model=load_model(model_path)
    source_cal=np.asarray(profile["source_wb"],dtype=float)
    target_cal=np.asarray(profile["target_wb"],dtype=float)
    calibrated=np.asarray(profile["matrix"],dtype=float)
    if not np.allclose(calibrated@np.ones(3),1,rtol=0,atol=1e-10):
        raise ValueError("Calibration matrix must preserve neutral")
    wb=np.asarray(wb,dtype=float);wb=wb/wb[1]
    raw_calibrated=calibrated*source_cal[None,:]/target_cal[:,None]
    anchor_response,anchor_info=public_response(source_cal,model,assets)
    anchor_correction=raw_calibrated@np.linalg.inv(anchor_response)
    raw_response,info=public_response(wb,model,assets)
    anchored_response=anchor_correction@raw_response
    target_neutral=anchored_response@(1/wb)
    if np.any(target_neutral<=0) or not np.isfinite(target_neutral).all():
        raise ValueError("Dual-illuminant model produced invalid target neutral")
    neutral_gain=float(target_neutral[1])
    target_wb=neutral_gain/target_neutral
    matrix=anchored_response*target_wb[:,None]/wb[None,:]/neutral_gain
    if np.array_equal(wb,source_cal):
        matrix=calibrated.copy();target_wb=target_cal.copy();neutral_gain=1.
    if target_tint_multiplier is not None:
        override=np.asarray(target_tint_multiplier,dtype=float)
        if override.shape!=(3,) or not np.isfinite(override).all() or np.any(override<=0):
            raise ValueError("Invalid target white-balance preset gains")
        override=override/override[1]
        target_wb=target_wb*override
        target_gain=float((target_neutral*target_wb)[1])
        matrix=anchored_response*target_wb[:,None]/wb[None,:]/target_gain
        neutral_gain=target_gain
    estimated,tint=hncs.estimate_cct(target_wb,assets)
    requested=cct_override if cct_override is not None else estimated
    cct=int(np.clip(int(requested),2000,10000))
    return {"matrix":matrix.tolist(),"cct":cct,
        "cct_source":"manual" if cct_override is not None else "dual_illuminant_virtual_x2d_wb",
        "estimated_target_white_balance":target_wb.tolist(),"estimated_target_cct":estimated,
        "estimated_target_tint":tint,"factory_cct_clamped":int(requested)!=cct,
        "white_balance_bridge_enabled":True,"white_balance_bridge_neutral_gain":neutral_gain,
        "illuminant_mode":"dual","cross_illuminant_assumption":False,
        "experimental_dual_illuminant":True,"dual_model_path":str(Path(model_path).resolve()),
        "dual_model_sha256":hncs.digest(model_path),"anchor_correction":anchor_correction.tolist(),
        "anchor_source_estimated_cct":anchor_info["source_estimated_cct"],
        "model_assumptions":model["assumptions"],"target_tint_multiplier":target_tint_multiplier,**info}


def build_model():
    sources=CASE/"sources"
    dxo=json.loads((sources/"sony-dxomark.json").read_text())
    hass=json.loads((sources/"dual_illuminant_report_v3_adobe_illuminant_order.json").read_text())
    source_matrices=[]
    for item in dxo["illuminants"]:
        matrix=np.asarray(item["white_balanced_native_to_linear_srgb"],dtype=float)
        # Public coefficients have only two decimals. Explicit row normalization
        # corrects the 0.99 blue neutral sum at D50; preserve originals as evidence.
        matrix=matrix/matrix.sum(axis=1)[:,None]
        white=xy_xyz(item["xy"])
        forward=adaptation(SRGB_XYZ@np.ones(3),white)@SRGB_XYZ@matrix@np.diag(item["wb"])
        source_matrices.append(np.linalg.inv(forward).tolist())
    target_matrices=[hass["dcp_color_matrix_1"],hass["dcp_color_matrix_2"]]
    for i in (1,2):
        row=np.asarray(hass[f"color_matrix_{i}"])
        cm=np.asarray(hass[f"dcp_color_matrix_{i}"])
        if not np.allclose(cm@row.T,np.eye(3),atol=1e-12,rtol=0):
            raise ValueError("External Hasselblad matrix direction mismatch")
    model={"schema":1,"status":"experimental",
        "sony":{"temperatures":[x["cct"] for x in dxo["illuminants"]],
            "xyz_to_native":source_matrices,"direction":"XYZ column -> unbalanced Sony native column"},
        "hasselblad":{"temperatures":[hass[f"slot_{i}"]["cct_k"] for i in (1,2)],
            "xyz_to_native":target_matrices,"direction":"XYZ column -> unbalanced X2D II native column"},
        "source_data":{"sony_url":dxo["url"],"repository_commit":json.loads((sources/"repository-commit.json").read_text())["commit"],
            "sony_data_sha256":hncs.digest(sources/"sony-dxomark.json"),
            "hasselblad_report_sha256":hncs.digest(sources/"dual_illuminant_report_v3_adobe_illuminant_order.json")},
        "assumptions":["DXOMARK displayed matrix is treated as WB-normalized native-column to linear-sRGB-column, followed by inverse Bradford adaptation to the reference illuminant. This convention is an interpretation checked for neutral consistency, not verified against DXOMARK's raw processing code.",
            "Sony A/D50 and Hasselblad A/D65 characterize different devices with independent fitted data; common XYZ is a model-mediated bridge, not a paired dual-light measurement.",
            "External Hasselblad chart targets were Bradford-adapted reference patches, not spectral reflectance integrals under measured DPReview illuminant SPDs.",
            "A constant left residual anchors the public response family to the existing paired calibration; its transfer across illuminants is assumed.",
            "Stored XYZ-to-camera matrices interpolate in inverse Kelvin; outside each camera's own endpoints they clamp. No Sony D65 measurement is fabricated.",
            "Neutral scalar normalization retains the existing calibration exposure. Full Phocus RAW equivalence and arbitrary LED accuracy are unverified."]}
    hncs.save_json(MODEL,model)
    print("Prepared",MODEL)


if __name__=="__main__":
    build_model()
