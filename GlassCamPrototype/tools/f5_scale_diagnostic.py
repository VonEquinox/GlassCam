"""Fixed Gaussian diagnostics for F5's data accumulation and prior units.

Independent dense matrices encode the documented Bayer/spline/Hessian model.
Metal probes reuse production operators with explicit Gaussian scores. This
does not certify the quantized Poisson-Gaussian solver or natural-image quality.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

import numpy as np
from scipy import linalg, optimize


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def operators(width,height):
    m=width*height;n=3*m
    def reflect(i,length):
        j=i%(2*length)
        return j if j<length else 2*length-j-1
    def one(length):
        b=np.zeros((length,length))
        for i in range(length):
            for d,v in [(-1,1/6),(0,2/3),(1,1/6)]:b[i,reflect(i+d,length)]+=v
        return b
    s0=np.kron(one(height),one(width));s=np.kron(np.eye(3),s0)
    h=np.zeros((m,3,m))
    for y in range(height):
        for x in range(width):
            row=y*width+x
            for dx,dy,value,component in [(-1,0,1,0),(0,0,-2,0),(1,0,1,0),(0,-1,1,2),(0,0,-2,2),(0,1,1,2),(-1,-1,1/np.sqrt(8),1),(1,-1,-1/np.sqrt(8),1),(-1,1,-1/np.sqrt(8),1),(1,1,1/np.sqrt(8),1)]:
                h[row,component,reflect(y+dy,height)*width+reflect(x+dx,width)]+=value
    h=h.reshape(m*3,m);t=np.array([[1,1,1],[1,0,-1],[1,-2,1]])/np.sqrt([[3],[2],[6]])
    p=np.kron(t,h)@s;py=p[:3*m].reshape(m,3,n)
    pc=p[3*m:].reshape(2,m,3,n).transpose(1,0,2,3).reshape(m,6,n)
    yy,xx=np.mgrid[:height,:width];color=np.array([2,1,1,0])[(yy%2)*2+xx%2]
    a=s[np.arange(m)+color.ravel()*m]
    return s,py,pc,a,color


def prior(x,py,pc,ly,lc,normalization,sigma,direction=None):
    n=x.size;value=0.;gradient=np.zeros(n);hessian=np.zeros((n,n));normal=np.zeros(n)
    for rows,lam in [(py,ly),(pc,lc)]:
        p=rows/sigma;z=p@x;r=np.sqrt(1+np.sum(z*z,axis=1));weight=normalization*lam/r
        value+=normalization*lam*np.sum(r-1);gradient+=np.einsum('pji,pj,p->i',p,z,weight)
        hessian+=np.einsum('pji,pjk,p->ik',p,p,weight)
        q=np.einsum('pji,pj->pi',p,z)
        hessian-=np.einsum('pi,pj,p->ij',q,q,weight/r**2)
        if direction is not None:normal+=np.einsum('pji,pj,p->i',p,p@direction,weight)
    return value,gradient,hessian,normal


def solve_exact(a,y,precision,py,pc,ly,lc,normalization,sigma,initial):
    h=a.T@(precision[:,None]*a);rhs=a.T@(precision*y)
    def value(x):
        p,g,_,_=prior(x,py,pc,ly,lc,normalization,sigma)
        residual=a@x-y
        return .5*np.dot(precision*residual,residual)+p,h@x-rhs+g
    def hessian(x):return h+prior(x,py,pc,ly,lc,normalization,sigma)[2]
    r=optimize.minimize(value,initial,jac=True,hess=hessian,method='trust-exact',options={'gtol':1e-9,'maxiter':1000})
    _,gradient=value(r.x)
    residual=float(np.max(abs(gradient))/max(1,np.max(abs(rhs))))
    if residual>1e-10:raise AssertionError(('Independent exact-prior solve not stationary',r.message,residual))
    return r.x,dict(iterations=int(r.nit),relative_stationarity=residual,minimum=float(r.x.min()))


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);rng=np.random.default_rng(6102708);w=h=8;m=w*h;n=3*m
    s,py,pc,a,color=operators(w,h);yy,xx=np.mgrid[:h,:w];wave=np.cos(np.pi*3*(xx+.5)/w)*np.cos(np.pi*(yy+.5)/h)
    detail=(.006*wave[...,None]*np.array([.65,1,.8])).transpose(2,0,1).ravel();truth=np.broadcast_to(np.array([.3,.32,.28]),(h,w,3)).transpose(2,0,1).copy().ravel()+detail
    xtrue=linalg.solve(s,truth);sigma=.02;frame_variances=sigma**2*np.array([1,.8,1.2,1.1])
    observations=(a@xtrue)[None,:]+rng.normal(size=(4,m))*np.sqrt(frame_variances[:,None]);weight=1/frame_variances[:,None]*np.ones((4,m))
    np.savez(args.output/'gaussian-inputs.npz',truth_native=truth,observations=observations,variances=frame_variances,spline=s,forward=a)
    # Exact sufficient statistics, with identical physical prior semantics.
    total=weight.sum(axis=0);mean=(weight*observations).sum(axis=0)/total;stacked=np.tile(a,(4,1));flat=observations.ravel();precision=weight.ravel()
    ly=.001;lc=.04;normalization=4.;pflat=py.reshape(-1,n);cflat=pc.reshape(-1,n)
    rmatrix=normalization*(ly*pflat.T@pflat+lc*cflat.T@cflat)/sigma**2
    direct=linalg.solve(stacked.T@(precision[:,None]*stacked)+rmatrix,stacked.T@(precision*flat),assume_a='pos')
    compressed=linalg.solve(a.T@(total[:,None]*a)+rmatrix,a.T@(total*mean),assume_a='pos')
    quadratic_difference=float(np.max(abs(direct-compressed)))
    exact,convergence=solve_exact(stacked,flat,precision,py,pc,ly,lc,normalization,sigma,direct)
    collapsed,compressed_convergence=solve_exact(a,mean,total,py,pc,ly,lc,normalization,sigma,direct)
    exact_difference=float(np.max(abs(exact-collapsed)))
    wrong,_=solve_exact(a,mean,total,py,pc,ly,lc,1.,sigma,direct)
    unit=255.;converted=linalg.solve((unit*stacked).T@((precision/unit**2)[:,None]*(unit*stacked))+rmatrix,(unit*stacked).T@(precision/unit**2*(unit*flat)),assume_a='pos')
    conversion_difference=float(np.max(abs(converted-direct)))
    if max(quadratic_difference,exact_difference,conversion_difference)>1e-9:raise AssertionError('Sufficient statistics or exact unit conversion changed the solution')
    # MC repetitions are noise repetitions of this one scene, not new scenes.
    trials=256;draws=rng.normal(size=(trials,4,m))*sigma;draws+=(a@xtrue)[None,None,:]
    scale_rows=[]
    for multiplier in [.25,1.,4.]:
        for rule in ['current_native','count_and_fused_noise','canonical_fixed_scene']:
            for k in [1,2,4]:
                q=k if rule!='canonical_fixed_scene' else 1.;sn=sigma/np.sqrt(k) if rule=='count_and_fused_noise' else sigma
                pr=q*(ly*multiplier*pflat.T@pflat+lc*multiplier*cflat.T@cflat)/sn**2
                data=k*a.T@a/sigma**2;factor=linalg.cho_factor(data+pr)
                expected=linalg.cho_solve(factor,k*a.T@(a@xtrue)/sigma**2);images=s@linalg.cho_solve(factor,k*a.T@draws[:,:k].mean(axis=1).T/sigma**2)
                expected_image=s@expected;noise=images-expected_image[:,None]
                amplitude=float(np.dot(expected_image-truth+detail,detail)/np.dot(detail,detail))
                data_gradient=k*a.T@(a@expected-a@xtrue)/sigma**2;prior_gradient=pr@expected
                scale_rows.append(dict(prior_rule=rule,lambda_multiplier=multiplier,frames=k,independent_noise_trials=trials,
                    prior_multiplier=q,prior_sigma=sn,detail_amplitude_gain=amplitude,output_noise_rms=float(np.sqrt(np.mean(noise**2))),
                    raw_mean_noise_rms=float(np.std(draws[:,:k].mean(axis=1)-a@xtrue)),expected_bias_rms=float(np.sqrt(np.mean((expected_image-truth)**2))),
                    data_gradient_norm=float(linalg.norm(data_gradient)),prior_gradient_norm=float(linalg.norm(prior_gradient)),
                    stationarity=float(linalg.norm(data_gradient+prior_gradient))))
    # Restrict to one known Bayer-visible mode to separate amplitude shrinkage
    # from the color/interpolation ambiguity of the full underdetermined image.
    mode_vector=linalg.solve(s,detail/.006);mode_y=a@mode_vector
    mode_py=py@mode_vector;mode_pc=pc@mode_vector;mode_rows=[]
    for rule in ['current_native','count_and_fused_noise','canonical_fixed_scene']:
        for k in [1,2,4]:
            q=k if rule!='canonical_fixed_scene' else 1.;sn=sigma/np.sqrt(k) if rule=='count_and_fused_noise' else sigma
            data_precision=k*np.dot(mode_y,mode_y)/sigma**2
            def derivative(amplitude):
                value=data_precision*(amplitude-.006)
                for p,lam in [(mode_py,ly),(mode_pc,lc)]:
                    energy=np.sum(p*p,axis=1)/sn**2
                    value+=q*lam*np.sum(amplitude*energy/np.sqrt(1+amplitude*amplitude*energy))
                return value
            amplitude=optimize.brentq(derivative,0,.006,xtol=1e-15)
            mode_rows.append(dict(prior_rule=rule,frames=k,expected_charbonnier_amplitude_gain=float(amplitude/.006)))
    # A changed observation mask must preserve the same semantic prior count
    # when the surviving observations are represented by sufficient statistics.
    mask=rng.random((4,m))>.25;mask[0]=True;masked_weight=weight*mask
    masked_total=masked_weight.sum(axis=0);masked_mean=(masked_weight*observations).sum(axis=0)/masked_total
    selected=mask.ravel();masked_a=stacked[selected];masked_y=flat[selected];masked_precision=precision[selected];masked_count=int(selected.sum())
    masked_r=rmatrix*(masked_count/(4*m))
    masked_direct=linalg.solve(masked_a.T@(masked_precision[:,None]*masked_a)+masked_r,masked_a.T@(masked_precision*masked_y),assume_a='pos')
    masked_compressed=linalg.solve(a.T@(masked_total[:,None]*a)+masked_r,a.T@(masked_total*masked_mean),assume_a='pos')
    masked_difference=float(np.max(abs(masked_direct-masked_compressed)))
    if masked_difference>1e-10:raise AssertionError('Masked sufficient statistics changed the solution')
    # Active physical-native constraints: solve in u=Sx, allowing signed x.
    invs=linalg.inv(s);forward=a@invs;reg=np.vstack([np.sqrt(normalization*ly)/sigma*pflat@invs,np.sqrt(normalization*lc)/sigma*cflat@invs])
    design=np.vstack([forward/sigma,reg]);target=np.concatenate([(.03*wave.ravel()-.005)/sigma,np.zeros(reg.shape[0])]);floor=1e-8
    bounded=optimize.lsq_linear(design,target,bounds=(floor,np.inf),method='bvls',tol=1e-12,max_iter=1000)
    g=design.T@(design@bounded.x-target);active=bounded.x-floor<1e-9;nu=np.where(active,np.maximum(g,0),0)
    kkt=dict(primal_violation=float(np.max(np.maximum(floor-bounded.x,0))),stationarity=float(np.max(abs(g-nu))),
        dual_violation=float(np.max(np.maximum(-nu,0))),complementarity=float(np.max(abs(nu*(bounded.x-floor)))),
        unconstrained_gradient_max=float(np.max(abs(g))),active_constraints=int(active.sum()),solver='scipy.optimize.lsq_linear BVLS')
    if max(kkt['primal_violation'],kkt['stationarity'],kkt['complementarity'])>1e-8:raise AssertionError('Bounded Gaussian reference failed KKT')
    # Production Metal adjoints, native sampling and exact Charbonnier rows.
    probe=xtrue+rng.normal(0,.001,n);direction=rng.normal(0,.001,n);gpu=[]
    for name,mat,yv,pv,semantic_count,sites in [('explicit',stacked,flat,precision,4*m,np.tile(np.arange(m),4)),
            ('compressed',a,mean,total,4*m,np.arange(m)),('converted',unit*stacked,unit*flat,precision/unit**2,4*m,np.tile(np.arange(m),4)),
            ('masked_explicit',masked_a,masked_y,masked_precision,masked_count,np.tile(np.arange(m),4)[selected]),
            ('masked_compressed',a,masked_mean,masked_total,masked_count,np.arange(m))]:
        records=[]
        for i in range(len(yv)):
            j=int(sites[i]);records.append(dict(x=float(j%w+.5),y=float(j//w+.5),mean=float(yv[i]),variance=float(1/pv[i]),gain=unit if name=='converted' else 1.,color=int(color.ravel()[j])))
        inputs=dict(width=w,height=h,normalizationCount=semantic_count,noise=sigma,lambdaY=ly,lambdaC=lc,coefficients=probe.tolist(),direction=direction.tolist(),observations=records)
        folder=args.output/name;folder.mkdir(exist_ok=True);path=folder/'input.json';path.write_text(json.dumps(inputs))
        with (folder/'run.log').open('w') as log:subprocess.run([str(args.metal.resolve()),str(path.resolve()),str(folder.resolve()),str(args.shader.resolve())],stdout=log,stderr=subprocess.STDOUT,check=True)
        result=json.loads((folder/'result.json').read_text());v,pg,_,pn=prior(probe,py,pc,ly,lc,semantic_count/m,sigma,direction)
        expected={'data_gradient':mat.T@(pv*(mat@probe-yv)),'data_normal':mat.T@(pv*(mat@direction)),
            'prior_gradient':pg,'prior_normal':pn}
        errors={key:float(linalg.norm(np.array(result[key])-value)/max(1e-12,linalg.norm(value))) for key,value in expected.items()}
        if max(errors.values())>1e-4:raise AssertionError(('Production Gaussian/prior operator disagreement',name,errors))
        gpu.append(dict(representation=name,input_sha256=sha(path),output_sha256=sha(folder/'result.json'),relative_errors=errors))
    result=dict(revision='f5-scale-diagnostic-v1',camera_used=False,qualification='CONTROLLED_SUBPROBLEM_NOT_IMAGE_QUALITY',seed=6102708,
        native_shape=[h,w],noise_repetitions=trials,independent_natural_scenes=0,source_code_sha256=sha(__file__),metal_executable_sha256=sha(args.metal),shader_sha256=sha(args.shader),
        sufficient_statistics=dict(quadratic_max_solution_difference=quadratic_difference,charbonnier_max_solution_difference=exact_difference,
            units_255_max_solution_difference=conversion_difference,masked_quadratic_max_solution_difference=masked_difference,
            wrong_compressed_count_native_difference=float(np.max(abs(s@(wrong-exact)))),
            explicit_convergence=convergence,compressed_convergence=compressed_convergence),scale_scan=scale_rows,known_mode_scan=mode_rows,constraint_kkt=kkt,metal_operator_checks=gpu,
        limitations=['Gaussian scores use continuous means and fixed variance. No exact PG sufficient-statistic compression claim.',
            'The frame-count scan uses the quadratic prior subproblem; exact Charbonnier is checked separately.',
            'Independent matrix and Metal operator agreement is not a convergence certificate for the production solver.',
            'The native read-noise rule and the hypothetical fused-noise rule are reported separately.',
            'No new production prior, texture gate, motion model or postfilter has been introduced.'])
    (args.output/'results.json').write_text(json.dumps(result,indent=2,allow_nan=False))
    print(json.dumps(result['sufficient_statistics'],indent=2));print(json.dumps(kkt,indent=2))
    for r in scale_rows:
        if r['lambda_multiplier']==1:print(r['prior_rule'],r['frames'],round(r['detail_amplitude_gain'],6),round(r['output_noise_rms'],6))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--metal',type=Path,required=True);p.add_argument('--shader',type=Path,required=True)
    run(p.parse_args())
