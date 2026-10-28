"""Pinned preset grain and SciPy spatial numerical reference."""
import numpy as np
from scipy.ndimage import gaussian_filter

def reference_apply(p,work,key,grain,sharp):
    cfg=p.settings(key)
    if grain:work,_=p._apply_film_grain(work,cfg['film_grain'],p.preset_key(key))
    sh=cfg['sharpness']
    if sharp and sh.get('amount'):
        amount=float(sh['amount'])/100
        radius=max(float(sh.get('radius',10))/10,.1)
        blurred=gaussian_filter(work,sigma=(radius,radius,0.),mode='nearest')
        detail=work-blurred
        threshold=float(sh.get('noise_limit') or 0.)/65535
        if threshold:detail=np.where(np.abs(detail)>=threshold,detail,0.)
        work=np.clip(work+amount*detail,0,1)
    return work
