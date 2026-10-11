"""Read Sony's A/D65 characterization matrices from the pinned public DCP."""
import json
import struct
from pathlib import Path
import numpy as np
import hncs_pipeline as h
import hncs_dual_illuminant as d

CASE=h.ROOT/"work/hncs-finalization"
DCP=CASE/"sources/Sony ILCE-7RM5 Adobe Standard Linear.dcp"
MODEL=CASE/"sony_dcp_source_model.json"


def read_tags(path):
    data=Path(path).read_bytes()
    if len(data)<8 or data[:4]!=b"IIRC":raise ValueError("Expected little-endian DCP IFD header")
    offset=struct.unpack_from("<I",data,4)[0]
    if offset+2>len(data):raise ValueError("Invalid DCP IFD offset")
    count=struct.unpack_from("<H",data,offset)[0];tags={}
    selected={50708,50721,50722,50723,50724,50727,50778,50779,50936,50964,50965}
    sizes={2:1,3:2,10:8}
    for i in range(count):
        pos=offset+2+12*i
        if pos+12>len(data):raise ValueError("Truncated DCP directory")
        code,dtype,n=struct.unpack_from("<HHI",data,pos)
        if code not in selected:continue
        if dtype not in sizes:raise ValueError("Unexpected DCP characterization tag type")
        size=sizes[dtype]*n
        at=pos+8 if size<=4 else struct.unpack_from("<I",data,pos+8)[0]
        if at+size>len(data):raise ValueError("Truncated DCP characterization values")
        values=data[at:at+size]
        if dtype==2:value=values.rstrip(b"\0").decode("ascii")
        elif dtype==3:value=struct.unpack("<"+"H"*n,values);value=value[0] if n==1 else list(value)
        else:
            pairs=np.array(struct.unpack("<"+"i"*(n*2),values)).reshape(n,2)
            if np.any(pairs[:,1]==0):raise ValueError("Zero rational denominator")
            value=(pairs[:,0]/pairs[:,1]).tolist()
        tags[str(code)]={"dtype":dtype,"count":n,"value":value}
    return tags


def main():
    provenance=json.loads((CASE/"sources/sony-dcp-provenance.json").read_text())
    if h.digest(DCP)!=provenance["file_sha256"]:raise ValueError("Source DCP hash mismatch")
    tags=read_tags(DCP)
    if tags["50708"]["value"]!="Sony ILCE-7RM5":raise ValueError("Wrong DCP camera")
    if [tags[k]["value"] for k in ("50778","50779")]!=[17,21]:raise ValueError("Expected A/D65 calibration slots")
    matrices=[np.array(tags[k]["value"]).reshape(3,3) for k in ("50721","50722")]
    for matrix in matrices:
        if np.linalg.cond(matrix)>100:raise ValueError("Unstable Sony characterization")
    for k in ("50723","50724"):
        if k in tags and not np.allclose(np.array(tags[k]["value"]).reshape(3,3),np.eye(3)):
            raise ValueError("Nonidentity CameraCalibration requires an explicit reference-space conversion")
    if "50727" in tags and not np.allclose(tags["50727"]["value"],[1,1,1]):
        raise ValueError("Nonidentity AnalogBalance requires an explicit conversion")
    with h.rawpy.imread(str(h.SOURCE)) as raw:
        np.testing.assert_allclose(matrices[1],raw.rgb_xyz_matrix[:3],atol=5e-8,rtol=0)
    model={"schema":1,"status":"experimental",
        "sony":{"temperatures":[2856.,6504.],"xyz_to_native":[m.tolist() for m in matrices],
            "direction":"DCP ColorMatrix1/2: XYZ column to Sony ILCE-7RM5 native column"},
        "source_data":{"sony_source_dcp":provenance,"sony_d65_matches_libraw":True},
        "assumptions":["Characterization coefficients come from a public third-party mirror of an Adobe Standard Linear DCP. Camera identifier and A/D65 slots are verified; D65 matches the independent LibRaw and RawTherapee coefficients.",
            "Only ColorMatrix1/2 are used to estimate source-white chromaticity; no tone curve, hue tables, creative look or ForwardMatrix rendering is imported.",
            "CCT estimates are rendering coordinates, not measurements of the studio's illuminant spectrum. Two source matrices clamp outside A/D65."]}
    h.save_json(MODEL,model)
    h.save_json(CASE/"evidence/sony-dcp-characterization.json",{"source_sha256":h.digest(DCP),"tags":tags,"d65_matches_libraw":True})
    print("Prepared Sony A/D65 source profile",MODEL)


if __name__=="__main__":main()
