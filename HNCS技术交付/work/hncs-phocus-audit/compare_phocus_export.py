"""Measure the actual Phocus TIFF separately from native colour-kernel tests.

ColourChecker ROIs follow the input CFA coordinates, accounting for the TIFF's
documented DefaultCropOrigin. A fitted scalar exposure is a diagnostic only:
no colour matrix, white balance, or LUT is fitted to Phocus's output here.
"""
import json
import plistlib
import sys
from pathlib import Path

import numpy as np
import tifffile
from scipy.optimize import minimize_scalar
from PIL import ImageDraw
from PIL import Image, ImageFont

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
import hncs_pipeline as h


def patch_medians(image, polygons):
    result=[]
    for poly in polygons:
        x0,y0=np.floor(poly.min(axis=0)).astype(int)
        x1,y1=np.ceil(poly.max(axis=0)).astype(int)
        yy,xx=np.mgrid[y0:y1,x0:x1]
        points=np.stack([xx+.5,yy+.5],axis=-1)
        edges=np.roll(poly,-1,axis=0)-poly
        cross=edges[:,0,None,None]*(points[None,...,1]-poly[:,1,None,None])-edges[:,1,None,None]*(points[None,...,0]-poly[:,0,None,None])
        inside=np.all(cross>=0,axis=0)|np.all(cross<=0,axis=0)
        result.append(np.median(image[y0:y1,x0:x1][inside],axis=0))
    return np.array(result)


def main():
    assets=h.load_assets()
    profile=json.loads(h.PROFILE.read_text())
    folder=ROOT/'work/hncs-phocus-audit'
    exported=folder/'exports/x2dii_.tif'
    native=tifffile.memmap(exported,mode='r')
    with tifffile.TiffFile(exported) as tf:
        icc=tf.pages[0].tags[34675].value
        assert icc==assets['legacy_icc']
    with tifffile.TiffFile(h.TARGET) as tf:
        raw_page=tf.pages[0].pages[0]
        origin=np.array(raw_page.tags['DefaultCropOrigin'].value,dtype=float)
        crop=np.array(raw_page.tags['DefaultCropSize'].value,dtype=int)
    assert tuple(native.shape[:2])==tuple(crop[::-1])
    region=profile['chart_config']['hasselblad']
    polygons=h.patch_polygons(region['corners'],region['roi_fraction'])*np.array(profile['target']['visible_shape'][::-1])
    actual=patch_medians(native,polygons-origin)
    to_lab=lambda codes:h.xyz_to_lab((codes/65535)**float(assets['legacy_icc_gamma'][0])@assets['legacy_rgb_to_xyz'].T)
    actual_lab=to_lab(actual)
    calibrated=np.array([p['target_normalised'] for p in profile['patches']])
    predicted=h.hncs_codes(calibrated,profile['target_cct'],assets,working_space='legacy')
    pipeline_de=h.delta_e_2000(to_lab(predicted),actual_lab)
    saved_path=ROOT/'work/hncs-pipeline/output/x2dii_reference_hncs.tif'
    saved=tifffile.memmap(saved_path,mode='r')
    with tifffile.TiffFile(saved_path) as tf:
        assert tf.pages[0].tags[34675].value==icc
    assert saved.shape==tuple(profile['target']['visible_shape'])+(3,)
    saved_codes=patch_medians(saved,polygons)
    saved_de=h.delta_e_2000(to_lab(saved_codes),actual_lab)
    wb=np.array(profile['target']['camera_wb'][:3]);wb/=wb[1]
    cct,tint=h.estimate_cct(wb,assets)
    sensor=np.array([p['target_native'] for p in profile['patches']])*wb
    gray=np.arange(19,23)
    def diagnostic(ev):
        return h.hncs_codes(sensor*2**ev,cct,assets,working_space='legacy')
    def loss(ev):
        lab=to_lab(diagnostic(ev))
        return float(np.mean((lab[gray,0]-actual_lab[gray,0])**2))
    fit=minimize_scalar(loss,bounds=(-3,3),method='bounded',options={'xatol':1e-7})
    diagnostic_codes=diagnostic(fit.x)
    diagnostic_de=h.delta_e_2000(to_lab(diagnostic_codes),actual_lab)
    camera_wb_codes=diagnostic(0.)
    camera_wb_de=h.delta_e_2000(to_lab(camera_wb_codes),actual_lab)
    setting=plistlib.loads((folder/'evidence/actual_export.phos').read_bytes())
    correction=setting['ImageSettings'][setting['CurrentIx']]['ImageCorrection']
    selected={k:correction[k] for k in ('ExpToolVersion','FilmCurve','HDR','ColorModel','ColorWorkingSpace','ColorTemperature','Tint','EV','USMAmount','LensCorrection','VignetteAmount')}
    data={
        'phocus_tiff':str(exported),'phocus_tiff_sha256':h.digest(exported),
        'shape':list(native.shape),'icc_sha256':h.digest(folder/'evidence/actual_export.icc'),
        'actual_settings':selected,'default_crop_origin':origin.tolist(),
        'chart_reference_vs_actual_deltaE00':h.summary(pipeline_de),
        'saved_reference_tiff':str(saved_path),'saved_reference_sha256':h.digest(saved_path),
        'saved_reference_vs_actual_deltaE00':h.summary(saved_de),
        'diagnostic_camera_wb':wb.tolist(),'diagnostic_cct':cct,
        'diagnostic_internal_tint':tint,'diagnostic_fitted_ev':float(fit.x),
        'diagnostic_fitted_scale':float(2**fit.x),
        'diagnostic_camera_wb_without_exposure_fit_deltaE00':h.summary(camera_wb_de),
        'diagnostic_exposure_fitted_deltaE00':h.summary(diagnostic_de),
        'patches':[{'patch':i+1,'name':h.PATCH_NAMES[i],'phocus_codes':actual[i].tolist(),
                   'calibrated_pipeline_codes':predicted[i].tolist(),'pipeline_deltaE00':float(pipeline_de[i]),
                   'saved_reference_codes':saved_codes[i].tolist(),'saved_reference_deltaE00':float(saved_de[i]),
                   'diagnostic_codes':diagnostic_codes[i].tolist(),'diagnostic_deltaE00':float(diagnostic_de[i])} for i in range(24)],
        'scope':'Actual default non-HDR Phocus export, with its default sharpening/lens processing. ROIs use nominal crop registration, not a measured lens-warp map. Exposure diagnostic fits only four neutral lightness values and is not evidence of exact exposure-chain recovery. No per-pixel or full-pipeline equivalence claim.'}
    h.save_json(folder/'evidence/actual_export_comparison.json',data)
    preview=h.make_preview(native,assets,working_space='legacy')
    draw=ImageDraw.Draw(preview)
    scale=np.array(preview.size)/crop
    for i,poly in enumerate(polygons-origin):
        xy=[tuple(p*scale) for p in poly]
        draw.line(xy+[xy[0]],fill='yellow',width=1)
        draw.text(xy[0],str(i+1),fill='white')
    preview.save(folder/'exports/phocus_roi.preview.jpg',quality=95)
    # Compare the delivered image to Phocus using the documented common crop.
    # The saved reference keeps chart WB 7625 K; this is deliberately not an
    # exposure-fitted image or a same-WB per-pixel equivalence test.
    ox,oy=origin.astype(int);cw,ch=crop
    reference_preview=h.make_preview(saved[oy:oy+ch,ox:ox+cw],assets,working_space='legacy')
    original_preview=h.make_preview(native,assets,working_space='legacy')
    canvas=Image.new('RGB',(1800,760),'#f4f4f4')
    draw=ImageDraw.Draw(canvas);font=ImageFont.load_default(size=20)
    for i,(pic,title) in enumerate(((original_preview,'Phocus export | WB 7523 K | EV 0'),
                                  (reference_preview,'Python reference | chart WB 7625 K | EV 0'))):
        pic.thumbnail((880,700))
        draw.text((i*900+15,12),title,fill='black',font=font)
        canvas.paste(pic,(i*900+(900-pic.width)//2,50+(700-pic.height)//2))
    canvas.save(folder/'exports/phocus_vs_pipeline.jpg',quality=95)
    print(json.dumps({k:v for k,v in data.items() if k!='patches'},indent=2))


if __name__=='__main__':main()
