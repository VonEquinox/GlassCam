#!/usr/bin/env python3
"""F5 design checks: mechanisms and numerical contracts, NOT device benchmarks.
Independent analytic generators and dense algebra are used where possible.
Run: python design_checks.py --out results.json
"""
from __future__ import annotations
import argparse, hashlib, json, platform, time
from pathlib import Path
import numpy as np
import scipy
from scipy import sparse
from scipy.special import log_ndtr
from scipy.optimize import minimize_scalar
from scipy.sparse.linalg import spsolve

SEED = 2026102603

def bspline3(x):
    x=np.asarray(x, dtype=float); a=np.abs(x)
    return np.where(a<1, 2/3-a*a+.5*a*a*a,
                    np.where(a<2,(2-a)**3/6,0.))

def dbspline3(x):
    x=np.asarray(x,dtype=float); a=np.abs(x)
    return np.sign(x)*np.where(a<1,-2*a+1.5*a*a,
                  np.where(a<2,-.5*(2-a)**2,0.))

def sampling_matrix(h,w,shifts,exposures,crop=(1,3),scale=2):
    """Camera RGB cubic B-spline coefficients, interleaved; cropped raw CFA.
    Input p is a center in ActiveArea coordinates: crop+(j,i)+0.5.
    Output coefficient lattice q has center (q+0.5)/scale in crop coords.
    Invalid supports are omitted, never renormalized.
    """
    hh,ww=scale*h,scale*w
    rows=[]; cols=[]; vals=[]; valid=[]; meta=[]
    for k,(dx,dy) in enumerate(shifts):
        for i in range(h):
            for j in range(w):
                c=[[0,1],[1,2]][(i+crop[0])%2][(j+crop[1])%2]
                tx=scale*(j+.5+dx)-.5; ty=scale*(i+.5+dy)-.5
                bx=int(np.floor(tx)); by=int(np.floor(ty))
                if bx-1<0 or bx+2>=ww or by-1<0 or by+2>=hh: continue
                row=len(valid);valid.append((k,i,j,c));meta.append((tx,ty))
                for v in range(by-1,by+3):
                    for u in range(bx-1,bx+3):
                        rows.append(row); cols.append(3*(v*ww+u)+c)
                        vals.append(exposures[k]*bspline3(tx-u)*bspline3(ty-v))
    A=sparse.csr_matrix((vals,(rows,cols)),shape=(len(valid),3*hh*ww))
    return A,np.array(valid,dtype=int)

def effective_image_equivalence(rng):
    # Two-dimensional sinusoidal radiance, independently integrated by Gauss-Legendre.
    # Gaussian optical blur is analytic, square pixel integration is numerical.
    f=np.array([[.17,.09],[.68,.13],[.11,.73]])
    amplitudes=np.array([.12,.14,.10]);phase=np.array([.2,1.1,-.8]);sigma=.23
    pts=rng.uniform(-10,10,(53,2))
    optical=np.exp(-2*np.pi**2*sigma**2*np.sum(f*f,axis=1))
    eamp=amplitudes*optical*np.sinc(f[:,0])*np.sinc(f[:,1])
    expected=.7+np.cos(2*np.pi*(pts@f.T)+phase)@eamp
    q,weights=np.polynomial.legendre.leggauss(24);q*=.5;weights*=.5
    integrated=np.zeros(len(pts))
    for i in range(len(q)):
        for j in range(len(q)):
            p=pts+np.array([q[i],q[j]])
            integrated+=weights[i]*weights[j]*(.7+np.cos(2*np.pi*(p@f.T)+phase)@(amplitudes*optical))
    extra=.7+np.cos(2*np.pi*(pts@f.T)+phase)@(eamp*np.sinc(f[:,0])*np.sinc(f[:,1]))
    err=float(np.max(np.abs(integrated-expected)))
    assert err<1e-12
    # Gaussian factors cannot be individually identified from their convolution.
    freq=np.linspace(0,1,101)
    h1=np.exp(-2*np.pi**2*freq**2*(.20**2+.30**2))
    h2=np.exp(-2*np.pi**2*freq**2*(.10**2+np.sqrt(.12)**2))
    assert np.max(abs(h1-h2))<1e-14
    return {'quadrature_vs_effective_field_max_error':err,
            'double_pixel_integration_rmse':float(np.sqrt(np.mean((extra-expected)**2))),
            'optics_pixel_factorization_nonidentifiability_max_error':float(np.max(abs(h1-h2))),
            'scope':'translation, fixed spatial response; no proof for arbitrary affine warps'}

def censored_bias(rng):
    n=400000;mu=.99;sd=.04;tau=1.
    z=rng.normal(mu,sd,n);sat=z>=tau;y=np.minimum(z,tau)
    yy=y[~sat];n_sat=int(sat.sum())
    def nll(m):
        return .5*np.sum(((yy-m)/sd)**2)-n_sat*log_ndtr((m-tau)/sd)
    fit=minimize_scalar(nll,bounds=(.85,1.12),method='bounded',options={'xatol':1e-13})
    assert fit.success and abs(fit.x-mu)<.0003
    return {'count':n,'true_mean':mu,'sigma':sd,'threshold':tau,
            'masked_mean':float(yy.mean()),'naive_clipped_mean':float(y.mean()),
            'censored_MLE':float(fit.x),'saturated_fraction':float(sat.mean()),
            'scope':'known Gaussian sigma; isolates selection bias, not a Poisson sensor validation'}

def noisy_weights(rng):
    mu=20.;n=400000;read=1.
    y=rng.poisson(mu,n).astype(float)+rng.normal(0,read,n)
    w=1/(np.maximum(y,0)+read**2)
    bad=float(w@y/w.sum());good=float(y.mean())
    assert bad<good-.7
    return {'true_mean_electrons':mu,'count':n,'inverse_observed_signal_weighted_mean':bad,
            'ordinary_sample_mean':good,'warning':'using fitted expected signal, not each noisy observation, prevents this particular weight bias'}

def nuisance_consistency(rng):
    m,n,r=90,21,4
    A=rng.normal(size=(m,n));G=rng.normal(size=(m,r))
    d=rng.uniform(.5,1.5,m);W=np.diag(1/d)
    Lx=np.eye(n)*.8;Lt=np.diag([2.,3.,5.,7.]);y=rng.normal(size=m)
    H=np.block([[A.T@W@A+Lx,A.T@W@G],[G.T@W@A,G.T@W@G+Lt]])
    rhs=np.r_[A.T@W@y,G.T@W@y]
    joint=np.linalg.solve(H,rhs)
    S=np.linalg.inv(Lt);C=np.diag(d)+G@S@G.T
    invC=W-W@G@np.linalg.solve(Lt+G.T@W@G,G.T@W)
    schur=np.linalg.solve(A.T@invC@A+Lx,A.T@invC@y)
    error=float(np.linalg.norm(joint[:n]-schur)/np.linalg.norm(schur))
    assert error<1e-12
    # Reusing a same-data estimate as independent prior halves claimed variance.
    noise=rng.normal(size=500000)
    coverage=float(np.mean(abs(noise)<=1.959963984540054/np.sqrt(2)))
    return {'joint_vs_schur_relative_error':error,
            'woodbury_relative_error':float(np.linalg.norm(invC-np.linalg.inv(C))/np.linalg.norm(invC)),
            'double_use_same_measurement_claimed_95_interval_actual_coverage':coverage,
            'scope':'independent nuisance prior in equivalence; same-data posterior must NOT become another prior'}

def operator_checks(rng):
    h,w=24,32;s=np.array([[0,0],[.43,.07],[.20,.58],[.67,.41],[-.18,.27]])
    t=np.array([1.,1.,.125,1.,1.]);A,idx=sampling_matrix(h,w,s,t)
    x=rng.normal(size=A.shape[1]);z=rng.normal(size=A.shape[0])
    a=float(z@(A@x));b=float(x@(A.T@z))
    adj=abs(a-b)/max(1,abs(a),abs(b))
    const=float(np.max(abs(A@np.ones(A.shape[1])-t[idx[:,0]])))
    eps=1e-6;sp=s.copy();sm=s.copy();sp[2,0]+=eps;sm[2,0]-=eps
    Ap,ip=sampling_matrix(h,w,sp,t);Am,im=sampling_matrix(h,w,sm,t)
    assert np.array_equal(ip,idx) and np.array_equal(im,idx)
    numeric=(Ap@x-Am@x)/(2*eps)
    analytic=np.zeros(len(idx));hh,ww=2*h,2*w
    for a0,(k,i,j,c) in enumerate(idx):
        if k!=2:continue
        tx=2*(j+.5+s[k,0])-.5;ty=2*(i+.5+s[k,1])-.5
        bx=int(np.floor(tx));by=int(np.floor(ty))
        for v in range(by-1,by+3):
            for u in range(bx-1,bx+3):
                analytic[a0]+=t[k]*2*dbspline3(tx-u)*bspline3(ty-v)*x[3*(v*ww+u)+c]
    jac=float(np.linalg.norm(numeric-analytic)/np.linalg.norm(analytic))
    assert adj<1e-12 and const<1e-12 and jac<1e-8
    d=rng.uniform(.5,1.5,A.shape[0]);F=A.T@sparse.diags(d)@A
    explicit=F@x;implicit=A.T@(d*(A@x))
    normal=float(np.linalg.norm(explicit-implicit)/np.linalg.norm(implicit))
    assert normal<1e-12
    return {'shape':list(A.shape),'nnz_A':int(A.nnz),'nnz_F':int(F.nnz),
            'adjoint_relative_error':adj,'constant_preservation_max_error':const,
            'motion_jacobian_relative_error':jac,'normal_equation_relative_error':normal,
            'csr_bytes_A':int(A.data.nbytes+A.indices.nbytes+A.indptr.nbytes),
            'csr_bytes_F':int(F.data.nbytes+F.indices.nbytes+F.indptr.nbytes),
            'matvec_nonzero_visits_AtWA':int(2*A.nnz),'matvec_nonzero_visits_F':int(F.nnz),
            'scope':'2D, CFA odd crop, 4+1 exposure, B-spline effective image; FP64 CPU only'}

def tile_consistency():
    n=160;lam=90.
    D=np.zeros((n-1,n))
    for i in range(n-1):D[i,i]=-1;D[i,i+1]=1
    Q=np.eye(n)+lam*D.T@D
    y=np.zeros(n);y[39:80]=1.;y[119:]=.6
    truth=np.linalg.solve(Q,y)
    independent=np.zeros(n);core=40;halo=6
    for a in range(0,n,core):
        b=min(a+core,n);lo=max(0,a-halo);hi=min(n,b+halo)
        local=np.linalg.solve(Q[lo:hi,lo:hi],y[lo:hi])
        independent[a:b]=local[a-lo:b-lo]
    x=np.zeros(n);errors=[];energies=[]
    for sweep in range(24):
        for color in [0,1]:
            for block,a in enumerate(range(0,n,core)):
                if block%2!=color:continue
                b=min(a+core,n);ii=np.arange(a,b)
                rhs=y[ii]-Q[ii,:]@x+Q[np.ix_(ii,ii)]@x[ii]
                x[ii]=np.linalg.solve(Q[np.ix_(ii,ii)],rhs)
        errors.append(float(np.max(abs(x-truth))))
        energies.append(float(.5*x@Q@x-y@x))
    assert all(np.diff(energies)<=1e-12)
    assert errors[-1]<np.max(abs(independent-truth))*.02
    # A coarse solve corrects slow global modes rather than hiding a failed fixed budget.
    knots=np.r_[np.arange(0,n,8),n-1];P=np.zeros((n,len(knots)))
    for col in range(len(knots)):
        v=np.zeros(len(knots));v[col]=1;P[:,col]=np.interp(np.arange(n),knots,v)
    Qc=P.T@Q@P;xc=np.zeros(n);coarse_errors=[]
    for sweep in range(8):
        for color in [0,1]:
            for block,a in enumerate(range(0,n,core)):
                if block%2!=color:continue
                b=min(a+core,n);ii=np.arange(a,b)
                rhs=y[ii]-Q[ii,:]@xc+Q[np.ix_(ii,ii)]@xc[ii]
                xc[ii]=np.linalg.solve(Q[np.ix_(ii,ii)],rhs)
        xc+=P@np.linalg.solve(Qc,P.T@(y-Q@xc))
        coarse_errors.append(float(np.max(abs(xc-truth))))
    assert coarse_errors[-1]<1e-7
    return {'independent_halo_max_error':float(np.max(abs(independent-truth))),
            'global_block_descent_errors_1_4_12_24':[errors[i] for i in [0,3,11,23]],
            'two_level_errors_1_4_8':[coarse_errors[i] for i in [0,3,7]],
            'initial_24_sweep_1_percent_relative_gate_failed': True,
            'monotonic_energy':True,'scope':'known convex quadratic; shows halo alone does not make independently converged tiles globally equivalent'}

def sampling_shift_value(rng):
    modes=np.array([[0,0],[1,0],[0,1],[1,1]])
    pos=np.array([[0,0],[.48,.02],[.02,.48],[.12,.18]])
    A=np.exp(-2j*np.pi*pos@modes.T)/2
    F=A.conj().T@A;outputs={}
    for tag,s in [('none',None),('repeat',[0,0]),('complement',[.5,.5])]:
        Fx=F.copy()
        if s is not None:
            a=np.exp(-2j*np.pi*np.array(s)@modes.T)/2
            Fx+=.125*np.outer(a.conj(),a)
        eig=np.linalg.eigvalsh(Fx);outputs[tag]={'lambda_min':float(eig[0]),'trace':float(eig.sum())}
    return outputs

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('results.json'));a=p.parse_args()
    rng=np.random.default_rng(SEED)
    out={'status':'executed synthetic and algebraic design checks, no iPhone measurements',
         'seed':SEED,'environment':{'python':platform.python_version(),'numpy':np.__version__,'scipy':scipy.__version__},
         'checks':{}}
    checks=[effective_image_equivalence,censored_bias,noisy_weights,nuisance_consistency,operator_checks,sampling_shift_value]
    for fn in checks:
        out['checks'][fn.__name__]=fn(rng)
    out['checks']['tile_consistency']=tile_consistency()
    out['script_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(out,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
