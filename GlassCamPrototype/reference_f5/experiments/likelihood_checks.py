#!/usr/bin/env python3
"""Small independent numerical checks for the F5 design, not a camera benchmark."""
import json, argparse, platform
from pathlib import Path
import numpy as np
from scipy.special import ndtr
from scipy.stats import poisson
from scipy.optimize import nnls

def pg(lam, y, sig=1.5, censored=False, threshold=20.0):
    # The test range is low enough to enumerate the distribution directly.
    n=np.arange(max(160, int(lam+16*np.sqrt(lam+1)+30)))
    p=poisson.pmf(n,lam)
    def q(m):
        return ndtr((m-threshold)/sig) if censored else ndtr((y+.5-m)/sig)-ndtr((y-.5-m)/sig)
    q0,q1,q2=q(n),q(n+1),q(n+2)
    val=np.dot(p,q0)
    d1=np.dot(p,q1-q0)
    d2=np.dot(p,q2-2*q1+q0)
    return val,d1,d2

def run():
    errors=[]
    for lam in (.01,.1,1.,5.,20.,50.):
        for y,censored in ((float(round(lam)),False),(0.,True)):
            h=max(lam*1e-4,1e-6)
            p,d1,d2=pg(lam,y,censored=censored)
            pm=pg(lam-h,y,censored=censored)[0]; pp=pg(lam+h,y,censored=censored)[0]
            fd=(pp-pm)/(2*h)
            # Scale by probability so tiny-tail derivatives do not look deceptively exact.
            err=abs(fd-d1)/max(abs(d1),p,1e-100)
            errors.append(err)
    n=64
    C=np.diag(np.full(n,2/3))+np.roll(np.eye(n),1,axis=1)/6+np.roll(np.eye(n),-1,axis=1)/6
    x=np.arange(n)
    target=.5+.45*np.cos(2*np.pi*24*x/n)
    signed=np.linalg.solve(C,target)
    positive,_=nnls(C,target)
    def H(f):return np.exp(-2*np.pi**2*.23**2*f*f)*np.sinc(f)
    ref=H(.75)
    scales=[1.,1.01,1.02,1.05]
    result={
      'status':'synthetic/algebraic checks; no phone data',
      'pg_quantized_and_censored_score_max_relative_fd_error':max(errors),
      'signed_spline_controls':{'minimum_true_output':float(target.min()),'minimum_exact_coefficient':float(signed.min()),'signed_fit_rmse':float(np.sqrt(np.mean((C@signed-target)**2))),'nonnegative_controls_fit_rmse':float(np.sqrt(np.mean((C@positive-target)**2)))},
      'warp_response_noncommutation':{'frequency_cycles_per_input_pixel':.75,'relative_magnifications':scales,'response_amplitude_relative_errors':[float(abs(H(.75*a)-ref)/abs(ref)) for a in scales]},
      'limitations':'The last test assumes Gaussian optics plus a box pixel. It is a counterexample to unrestricted effective-image warping, not an iPhone calibration.'
    }
    assert max(errors)<1e-5
    assert result['signed_spline_controls']['signed_fit_rmse']<1e-12
    assert result['signed_spline_controls']['minimum_exact_coefficient']<0
    return result
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--out',default='likelihood_results.json');args=ap.parse_args()
    result=run();Path(args.out).write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
