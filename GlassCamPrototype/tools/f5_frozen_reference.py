"""Independent sparse fixed-state F5 objective and standard constrained solver.

No production solver code is called. Frozen coordinates, guide, noise, masks,
and coefficients are read from the desktop state. Quantized PG probabilities
are summed in observation-centered intervals with a 12-read-sigma tail bound.
The robust mixture floor bounds the omitted likelihood mass contribution.
"""
from pathlib import Path
import argparse
import json
import time

import numpy as np
from scipy import sparse, special, optimize
from scipy.sparse.linalg import spsolve

from f5_residual_audit import read_state, response, motion, basis, mirror, sha


def stencil(width,height,x,y,channel):
    x=np.asarray(x).ravel()-.5;y=np.asarray(y).ravel()-.5;channel=np.broadcast_to(channel,np.shape(x)).ravel()
    left=np.floor(x).astype(int)-1;top=np.floor(y).astype(int)-1;rows=[];columns=[];values=[]
    for j in range(4):
        for i in range(4):
            px=left+i;py=top+j;rows.append(np.arange(len(x)));columns.append(channel*width*height+mirror(py,height)*width+mirror(px,width));values.append(basis(x-px)*basis(y-py))
    return sparse.coo_matrix((np.concatenate(values),(np.concatenate(rows),np.concatenate(columns))),shape=(len(x),width*height*3)).tocsr()


def hessian_rows(width,height):
    yy,xx=np.mgrid[:height,:width];m=width*height;rows=[];cols=[];values=[]
    for dx,dy,v,c in [(-1,0,1,0),(0,0,-2,0),(1,0,1,0),(0,-1,1,2),(0,0,-2,2),(0,1,1,2),(-1,-1,1/np.sqrt(8),1),(1,-1,-1/np.sqrt(8),1),(-1,1,-1/np.sqrt(8),1),(1,1,1/np.sqrt(8),1)]:
        rows.append(np.arange(m)*3+c);cols.append((mirror(yy+dy,height)*width+mirror(xx+dx,width)).ravel());values.append(np.full(m,v))
    return sparse.coo_matrix((np.concatenate(values),(np.concatenate(rows),np.concatenate(cols))),shape=(m*3,m)).tocsr()


def guide_at_native(state,arrays,width,height):
    m=width*height;shape=state.get('color_axis_shape',[0,0,0,0]);xx,yy=np.meshgrid(np.arange(width),np.arange(height))
    if shape[3]==0:
        t=np.array([[1,1,1],[1,0,-1],[1,-2,1]])/np.sqrt([[3],[2],[6]])
        return np.broadcast_to(t,(m,3,3)),np.ones(m),np.ones(m)
    table=arrays['color_axis'];u=np.clip(xx/shape[2],0,shape[0]-1);v=np.clip(yy/shape[2],0,shape[1]-1);i=u.astype(int);j=v.astype(int);a=u-i;b=v-j
    corners=[table[j,i],table[j,np.minimum(i+1,shape[0]-1)],table[np.minimum(j+1,shape[1]-1),i],table[np.minimum(j+1,shape[1]-1),np.minimum(i+1,shape[0]-1)]]
    weights=[(1-a)*(1-b),a*(1-b),(1-a)*b,a*b];value=sum(c*w[...,None,None] for c,w in zip(corners,weights))
    axis=np.maximum(value[...,0,:3],1e-6).reshape(m,3);axis/=np.linalg.norm(axis,axis=1)[:,None]
    tangent=np.stack([axis[:,1],-axis[:,0],np.zeros(m)],axis=1);tangent/=np.linalg.norm(tangent,axis=1)[:,None]
    t=np.stack([axis,tangent,np.cross(axis,tangent)],axis=1)
    confidence=np.clip(value[...,0,3],0,1).ravel() if shape[3]>=2 else np.ones(m)
    scale=value[...,1,0]
    if shape[3]==3:scale=1/sum(w/np.maximum(c[...,1,0],1e-6) for w,c in zip(weights,corners))
    return t,confidence,scale.ravel()


class FrozenObjective:
    def __init__(self,path):
        self.path=path;self.report,self.source,self.arrays=read_state(path);self.state=self.report['native_state']
        w=self.source['width'];h=self.source['height'];self.m=w*h;self.n=3*self.m
        if self.state['scale']!=1:raise ValueError('This reference audits native density only')
        if self.source.get('geometryMode')!='fixed_control':raise ValueError('A fixed-geometry render is required')
        yy,xx=np.mgrid[:h,:w];px=xx+.5;py=yy+.5
        self.s=sparse.vstack([stencil(w,h,px,py,c) for c in range(3)]).tocsr()
        observations=[];raw_constraints=[];gains=[];lower=[];upper=[];kappas=[];sigmas=[];self.observation_sites=[]
        for frame in self.source['frames']:
            if not frame['used']:continue
            phase=np.array(frame['cfa'])[(yy%2)*2+xx%2];channel=np.where(phase==0,0,np.where(phase==3,2,1))
            offsets=motion(self.arrays['motion_nodes'][frame['index']],px,py) if frame['index']!=self.source['reference'] else np.zeros((h,w,2))
            mx=px+offsets[...,0];my=py+offsets[...,1];codes=np.array(frame['codes']).reshape(h,w)
            inside=(mx>=0)&(mx<=w)&(my>=0)&(my<=h)
            if np.any(inside&((codes<=0)|(codes>=frame['nativeWhite']))):raise ValueError('Censored events need a separate reference likelihood')
            b=stencil(w,h,mx[inside],my[inside],channel[inside]);gain=response(frame,px,py,w,h)[inside]
            raw_constraints.append(b);observations.append(sparse.diags(gain)@b);gains.extend(gain)
            self.observation_sites.append((frame,np.flatnonzero(inside)))
            lower.extend(((codes[inside]-.5)/frame['divisor']-frame['black'])/frame['whiteScale']);upper.extend(((codes[inside]+.5)/frame['divisor']-frame['black'])/frame['whiteScale'])
            kappas.extend([frame['kappa']]*inside.sum());sigmas.extend([frame['readSigma']]*inside.sum())
        self.a=sparse.vstack(observations).tocsr();self.b=sparse.vstack([self.s,*raw_constraints]).tocsr();self.count=len(lower)
        self.lower=np.array(lower);self.upper=np.array(upper);self.kappa=np.array(kappas);self.read=np.array(sigmas)
        self.prepare_likelihood()
        t,confidence,luminance=guide_at_native(self.state,self.arrays,w,h);hrows=hessian_rows(w,h)
        rgbh=sparse.kron(sparse.eye(3),hrows,format='csr')@self.s;noise=self.arrays['noise'].ravel()
        prior_rows=[]
        for opponent in range(3):
            indices=np.arange(self.m*3);trans=sparse.coo_matrix((np.concatenate([np.repeat(t[:,opponent,c]/noise,3) for c in range(3)]),
                (np.tile(indices,3),np.concatenate([indices+c*self.m*3 for c in range(3)]))),shape=(self.m*3,self.m*9)).tocsr()
            prior_rows.append(trans@rgbh)
        self.py=prior_rows[0].tocsr();pc=sparse.vstack(prior_rows[1:]).tocsr()
        order=np.arange(self.m*6).reshape(2,self.m,3).transpose(1,0,2).ravel();self.pc=pc[order]
        policy=self.report['policy'];ly=policy['lambdaY'];lc=policy['lambdaC']
        self.ly=self.count/self.m*ly*luminance;self.lc=self.count/self.m*(ly+confidence*(lc-ly)*(1+(luminance-1)*confidence))
        self.pi=policy['outlierProbability'];self.mu=self.count*self.state.get('barrier_tau',1e-8)/(self.n+self.count)
        self.epsilon=1e-8;self.last=None

    def prepare_likelihood(self):
        # Every discarded Gaussian interval probability is below Phi(-12).
        lo=np.maximum(0,np.floor((self.lower-12*self.read)/self.kappa)).astype(int);hi=np.ceil((self.upper+12*self.read)/self.kappa).astype(int)
        self.electrons=lo[:,None]+np.arange(int(np.max(hi-lo))+1);valid=self.electrons<=hi[:,None]
        low=(self.lower[:,None]-self.electrons*self.kappa[:,None])/self.read[:,None];high=(self.upper[:,None]-self.electrons*self.kappa[:,None])/self.read[:,None]
        aa=np.where(low>0,-low,high);bb=np.where(low>0,-high,low);la=special.log_ndtr(aa);lb=special.log_ndtr(bb)
        with np.errstate(divide='ignore',invalid='ignore'):log_interval=la+np.log(-np.expm1(lb-la))
        n=self.electrons.astype(float)
        # Separate the observation-dependent constant from the Poisson
        # deviance. Subtracting n*log(lambda), lambda and log(n!) on each call
        # hides tiny objective improvements near a stationary point.
        constant=special.xlogy(n,n)-n-special.gammaln(n+1)
        self.fixed_log=np.where(valid,log_interval+constant,-np.inf)

    def replace_observations(self,frames):
        """Independent noise repetitions with every non-data quantity frozen."""
        if len(frames)!=5 or any(len(codes)!=self.m for codes in frames):raise ValueError('Invalid observation repetition')
        lower=[];upper=[]
        for frame,sites in self.observation_sites:
            codes=np.array(frames[frame['index']],float)[sites]
            if np.any(codes<=0)|np.any(codes>=frame['nativeWhite']):raise ValueError('Repetition introduced censoring')
            lower.extend(((codes-.5)/frame['divisor']-frame['black'])/frame['whiteScale'])
            upper.extend(((codes+.5)/frame['divisor']-frame['black'])/frame['whiteScale'])
        self.lower=np.array(lower);self.upper=np.array(upper);self.prepare_likelihood()

    def likelihood(self,mean):
        lam=mean/self.kappa
        n=self.electrons.astype(float);relative=(lam[:,None]-n)/np.maximum(n,1)
        with np.errstate(divide='ignore',invalid='ignore'):
            deviance=np.where(n>0,n*(np.log1p(relative)-relative),-lam[:,None])
        log_terms=self.fixed_log+deviance
        log_prob=special.logsumexp(log_terms,axis=1);posterior=np.exp(log_terms-log_prob[:,None]);expected=np.sum(posterior*self.electrons,axis=1)
        variance=np.sum(posterior*(self.electrons-expected[:,None])**2,axis=1)
        score=1/self.kappa-expected/mean;observed=(expected-variance)/mean**2
        inlier=np.log1p(-self.pi)+log_prob;mixture=np.logaddexp(inlier,np.log(self.pi/16384));gamma=np.exp(inlier-mixture)
        return -mixture,gamma*score,gamma*observed-gamma*(1-gamma)*score**2

    def evaluate(self,x,hessian=False):
        gap=self.b@x-self.epsilon
        if np.min(gap)<=0:raise ValueError('Reference solver left the physical feasible region')
        mean=self.a@x;nll,score,curvature=self.likelihood(mean)
        data=float(nll.sum());barrier=float(-self.mu*np.log(gap).sum());gradient=self.a.T@score-self.b.T@(self.mu/gap)
        matrix=self.a.T@sparse.diags(curvature)@self.a+self.b.T@sparse.diags(self.mu/gap**2)@self.b if hessian else None
        prior_value=0
        for p,lam,components in [(self.py,self.ly,3),(self.pc,self.lc,6)]:
            z=(p@x).reshape(self.m,components);r=np.sqrt(1+np.sum(z*z,axis=1));prior_value+=float(np.dot(lam,r-1));gradient+=p.T@(z*(lam/r)[:,None]).ravel()
            if hessian:
                group=sparse.coo_matrix((z.ravel(),(np.repeat(np.arange(self.m),components),np.arange(self.m*components))),shape=(self.m,self.m*components)).tocsr();q=group@p
                matrix+=p.T@sparse.diags(np.repeat(lam/r,components))@p-q.T@sparse.diags(lam/r**3)@q
        return data+prior_value+barrier,np.asarray(gradient).ravel(),matrix,dict(data=data,prior=prior_value,barrier=barrier,minimum_gap=float(gap.min()))


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);objective=FrozenObjective(args.report);x=objective.arrays['coefficients'].ravel()
    value,gradient,_,terms=objective.evaluate(x);gpu_gradient=objective.arrays['gradient'].ravel();gpu_value=objective.state['image_objective']
    relative_gradient=float(np.linalg.norm(gradient-gpu_gradient)/max(1e-15,np.linalg.norm(gradient)))
    standardized_error=float(np.max(abs(gradient-gpu_gradient)/np.sqrt(objective.arrays['diagonal'].ravel())))
    relative_objective=abs(value-gpu_value)/max(1,abs(value))
    checks=dict(relative_objective_error=relative_objective,relative_gradient_error=relative_gradient,standardized_gradient_error=standardized_error,
        reference_terms=terms,gpu_objective=gpu_value,reference_objective=value)
    (args.output/'agreement.json').write_text(json.dumps(checks,indent=2))
    if relative_objective>1e-5 or standardized_error>1e-3:raise AssertionError(('Independent objective disagrees with Metal',checks))
    if args.check_only:print(json.dumps(checks,indent=2));return
    override=None
    if args.observations:
        override=json.loads(args.observations.read_text());objective.replace_observations(override['codes'])
    initial_value=objective.evaluate(x)[0]
    started=time.monotonic();history=[];scale=objective.count
    def fun(x):
        value,g,_,_=objective.evaluate(x)
        return value/scale,g/scale
    def hess(x):return objective.evaluate(x,True)[2]/scale
    def callback(x,state):
        history.append(dict(iteration=int(state.nit),objective=float(state.fun*scale),optimality=float(state.optimality),constraint_violation=float(state.constr_violation),seconds=time.monotonic()-started))
        if state.nit%20==0:print(history[-1],flush=True)
        return time.monotonic()-started>args.seconds
    constraints=optimize.LinearConstraint(objective.b,objective.epsilon+1e-12,np.inf,keep_feasible=True)
    result=optimize.minimize(fun,x,jac=True,hess=hess,method='trust-constr',constraints=constraints,callback=callback,
        options={'gtol':1e-12,'xtol':1e-14,'barrier_tol':1e-18,'initial_barrier_parameter':1e-18,'initial_barrier_tolerance':1e-12,
            'maxiter':2000,'sparse_jacobian':True,'factorization_method':'AugmentedSystem'})
    # trust-constr can declare near-boundary KKT stationarity while the fixed
    # F5 barrier gradient still has a small residual. Independently solve the
    # exact sparse Newton systems to certify that same barrier subproblem.
    # This is an offline reference step, never a change to the Metal solver.
    solution=result.x.copy();polish=[]
    for iteration in range(8):
        f,g,hess_value,_=objective.evaluate(solution,True)
        metric=float(np.max(abs(g)/np.sqrt(np.maximum(abs(hess_value.diagonal()),1e-12))))
        if metric<1e-8:break
        delta=spsolve(hess_value,-g);gd=float(g@delta)
        if not np.all(np.isfinite(delta)) or gd>=0:break
        gaps=objective.b@solution-objective.epsilon;change=objective.b@delta;negative=change<0
        alpha=min(1.,float(np.min(-.9*gaps[negative]/change[negative]))) if np.any(negative) else 1.
        accepted=False
        for _ in range(20):
            trial=solution+alpha*delta;value,gg,hh,_=objective.evaluate(trial,True)
            next_metric=float(np.max(abs(gg)/np.sqrt(np.maximum(abs(hh.diagonal()),1e-12))))
            if value<=f+1e-10 and next_metric<metric:
                polish.append(dict(iteration=iteration,objective=value,standardized_gradient=next_metric,
                    maximum_coefficient_update=float(np.max(abs(alpha*delta))),step=alpha))
                solution=trial;accepted=True;break
            alpha*=.5
        if not accepted:break
    final,g,final_hessian,final_terms=objective.evaluate(solution,True);native=(objective.s@solution).reshape(3,objective.source['height'],objective.source['width']).transpose(1,2,0)
    standardized_gradient=float(np.max(abs(g)/np.sqrt(np.maximum(abs(final_hessian.diagonal()),1e-12))))
    stationary=bool(result.success and result.constr_violation<1e-10 and standardized_gradient<1e-6)
    np.save(args.output/'native.npy',native);np.save(args.output/'coefficients.npy',solution)
    report=dict(revision='f5-independent-frozen-reference-v1',camera_used=False,qualification='FIXED_STATE_STATIONARY_REFERENCE_NOT_GLOBAL_OPTIMUM' if stationary else 'REFERENCE_NOT_CONVERGED',
        input_report_sha256=sha(args.report),code_sha256=sha(__file__),agreement=checks,history=history,polish=polish,success=bool(result.success),reference_stationarity_passed=stationary,message=str(result.message),
        initial_objective=initial_value,final_objective=final,final_terms=final_terms,iterations=int(result.nit),optimality=float(result.optimality),
        constraint_violation=float(result.constr_violation),barrier_objective_gradient_max=float(np.max(abs(g))),
        standardized_barrier_gradient=standardized_gradient,solver_internal_barrier=float(result.barrier_parameter),
        barrier_objective_gradient_rms=float(np.sqrt(np.mean(g*g))),seconds=time.monotonic()-started,
        observation_override_sha256=sha(args.observations) if args.observations else None,
        limitations=['Same frozen v5 target, independently implemented; a stationary local solution, not a certified global minimum.',
            'The trust-constr interior parameter is separate from the fixed F5 barrier in the objective.',
            'Native pixels are compared before any magnification or postfilter.'])
    (args.output/'result.json').write_text(json.dumps(report,indent=2,allow_nan=False));print(json.dumps({k:v for k,v in report.items() if k not in ['history','agreement']},indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--seconds',type=float,default=300);p.add_argument('--check-only',action='store_true');p.add_argument('--observations',type=Path);run(p.parse_args())
