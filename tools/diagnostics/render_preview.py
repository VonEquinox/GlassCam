"""Render a real image through the supplied HNCS core using experimental RGB bridge.

Run --synthetic when no source photograph exists. It creates a diagnostic chart,
not a photograph and not a calibration target or evidence of an iPhone match.
"""
import argparse, json
from pathlib import Path
import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageOps
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/numeric"))
from support.reference_runtime import assets, effect

def decode(x): return np.where(x<=.04045,x/12.92,((x+.055)/1.055)**2.4)
def synthetic():
    h,w=480,960
    x=np.linspace(0,1,w)[None,:,None]
    y=np.linspace(0,1,h)[:,None,None]
    img=np.concatenate([np.broadcast_to(x,(h,w,1)),np.broadcast_to(y,(h,w,1)),np.broadcast_to(1-x,(h,w,1))],2)
    img[:80]=np.broadcast_to(x,(80,w,3))
    colors=np.array([[.72,.47,.34],[.91,.72,.58],[.13,.3,.18],[.2,.44,.73],[.9,.18,.1],[.9,.76,.25]])
    for i,color in enumerate(colors): img[340:440,i*160:(i+1)*160]=color
    return Image.fromarray(np.uint8(np.rint(img*255)))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path);p.add_argument('--synthetic',action='store_true')
    p.add_argument('--output',type=Path,default=Path.home() / 'Library/Developer/GlassCamDiagnostics/preview')
    p.add_argument('--cct',type=float,default=5500);p.add_argument('--ev',type=float,default=0)
    a=p.parse_args()
    if bool(a.input)==bool(a.synthetic): p.error('Choose exactly one of --input or --synthetic')
    if a.synthetic: im=synthetic()
    else:
        im=ImageOps.exif_transpose(Image.open(a.input))
        if im.info.get('icc_profile'):
            import io
            im=ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile'])),ImageCms.createProfile('sRGB'),outputMode='RGB')
        else: im=im.convert('RGB')
        im.thumbnail((2048,2048),Image.Resampling.LANCZOS)
    rgb=np.asarray(im,dtype=float)/255
    out=effect(decode(rgb),a.cct,assets(),a.ev)
    processed=Image.fromarray(np.uint8(np.rint(out*255)))
    a.output.mkdir(parents=True,exist_ok=True)
    profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    im.save(a.output/'before.png',icc_profile=profile)
    processed.save(a.output/'after.png',icc_profile=profile)
    canvas=Image.new('RGB',(im.width*2,im.height+64),'#101418')
    canvas.paste(im,(0,64));canvas.paste(processed,(im.width,64))
    d=ImageDraw.Draw(canvas)
    d.text((16,10),'BEFORE: '+('SYNTHETIC DIAGNOSTIC' if a.synthetic else 'sRGB import'),fill='white')
    d.text((im.width+16,10),'AFTER: existing HNCS / experimental RGB bridge',fill='white')
    d.text((16,34),'No chart fitting; not evidence of camera matching. CCT '+str(a.cct)+' K',fill='#aabbcc')
    canvas.save(a.output/'comparison.png',icc_profile=profile)
    (a.output/'metadata.json').write_text(json.dumps({'synthetic':a.synthetic,'cct':a.cct,'exposure_ev':a.ev,'adapter':'uncalibrated-linear-srgb-colorimetric-bridge','core':'original legacy/standard/v1_gamma','size':list(im.size),'max_abs_srgb_change':float(np.abs(out-rgb).max()),'mean_abs_srgb_change':float(np.abs(out-rgb).mean())},indent=2)+'\n')
    print(a.output/'comparison.png')
if __name__=='__main__': main()
