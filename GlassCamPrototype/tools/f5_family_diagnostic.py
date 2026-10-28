"""Native four-frame information/denoiser controls with independent PG noise.

All geometry, v5 prior guides and masks are fixed. Calibration repetitions
estimate a separate output-noise PSD for each estimator. Evaluation repetitions
never select BM3D strength from truth. A stationary PSD remains an approximation
to spatially varying, signal-dependent reconstruction noise and is reported so.
"""
from pathlib import Path
from types import SimpleNamespace
import argparse
import contextlib
import hashlib
import json
import time

import numpy as np
from scipy import stats
import bm3d
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

from f5_diagnostic_truth import field,undo_known_bilinear
from f5_frozen_reference import run as solve_reference, FrozenObjective
from f5_quality_benchmark import baseline


T=np.array([[1,1,1],[1,0,-1],[1,-2,1]])/np.sqrt([[3],[2],[6]])


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def noise_profile(images):
    transformed=images@T.T;noise=transformed-transformed.mean(axis=0,keepdims=True);samples=len(images)
    psd=np.sum(abs(np.fft.fft2(noise,axes=(1,2)))**2,axis=0)/(samples-1)
    variance=np.sum(noise*noise,axis=0)/(samples-1);power=psd.sum(axis=(0,1))/(images.shape[1]*images.shape[2])**2
    if np.max(abs(power-variance.mean(axis=(0,1))))>1e-12:raise AssertionError('Noise PSD normalization failed Parseval')
    correlation=[]
    for axis in [1,2]:
        rolled=np.roll(noise,-1,axis=axis);correlation.append((np.mean(noise*rolled,axis=(0,1,2))/np.maximum(np.mean(noise*noise,axis=(0,1,2)),1e-20)).tolist())
    return psd,dict(repetitions=samples,opponent_noise_rms=np.sqrt(power).tolist(),nearest_neighbor_correlation_xy=correlation,
        variance_p90_to_p10=(np.quantile(variance,.9,axis=(0,1))/np.maximum(np.quantile(variance,.1,axis=(0,1)),1e-20)).tolist(),
        assumption='Global stationary PSD approximates the measured spatially varying output covariance; not an exact posterior covariance.')


def filtered(image,psd):
    # bm4d 4.2 still calls this removed NumPy alias in its PSD parameter fit.
    # NumPy's trapezoid is the same operation, confined to this offline process.
    if not hasattr(np,'trapz'):np.trapz=np.trapezoid
    profile=bm3d.BM3DProfile();profile.num_threads=2;opponent=image@T.T
    result=np.stack([bm3d.bm3d(opponent[...,c],np.maximum(psd[...,c],1e-20),profile=profile) for c in range(3)],axis=-1)
    return result@T


def run(args):
    rng=np.random.default_rng(args.seed);results=[];sources=[]
    args.output.mkdir(parents=True,exist_ok=True)
    for name in ['portrait','color_edge','chromatic_texture']:
        source_path=args.work/'family'/name/'input.json';source=json.loads(source_path.read_text());reference=source['reference']
        original=json.loads(Path(source['truth_parent_input']).read_text());parent=json.loads(Path(original['parent_input']).read_text())
        evaluate=field(parent);height=parent['height'];width=parent['width'];yy,xx=np.mgrid[:height,:width];rgb=evaluate(xx+.5,yy+.5)
        left,top=source['parent_crop_xy'];h=source['height'];w=source['width'];roi=np.s_[top:top+h,left:left+w]
        truth=rgb[roi];base=args.output/name;base.mkdir(exist_ok=True);np.save(base/'truth-native.npy',truth)
        report=args.work/'family'/name/(source['name']+'-metal-report.json')
        verifier=FrozenObjective(report)
        estimates={'single':[],'mean4':[],'f5':[]};observations=[];controls=[]
        total=args.calibration+args.evaluation
        for trial in range(total):
            target=base/f'trial-{trial:03d}';target.mkdir(exist_ok=True);phase='calibration' if trial<args.calibration else 'evaluation'
            codes=[];raws={}
            for f in source['frames']:
                if f['gain']['values']!=[1.0]:raise ValueError('This controlled family test requires uniform radiometry')
                cfa=np.array(f['cfa'])[(yy%2)*2+xx%2];channel=np.where(cfa==0,0,np.where(cfa==3,2,1));mu=np.take_along_axis(rgb,channel[...,None],axis=-1)[...,0]*f['exposureRatio']
                observed=f['kappa']*rng.poisson(mu/f['kappa'])+rng.normal(0,f['readSigma'],mu.shape)
                integer=np.rint((observed*f['whiteScale']+f['black'])*f['divisor']).astype(int)
                if np.any(integer<=0)|np.any(integer>=f['nativeWhite']):raise ValueError('Censoring entered this unsaturated control')
                codes.append(integer[roi].ravel().tolist())
                if f['used']:
                    if f['exposureRatio']!=1:raise ValueError('Expected four identical-exposure mains')
                    raws[f['index']]=(integer/f['divisor']-f['black'])/f['whiteScale']
            payload=target/'observations.json';payload.write_text(json.dumps(dict(seed=args.seed,trial=trial,phase=phase,codes=codes)))
            start=time.monotonic()
            reusable=False
            if (target/'result.json').exists():
                previous=json.loads((target/'result.json').read_text())
                if previous.get('reference_stationarity_passed') and previous.get('observation_override_sha256')==sha(payload) and previous.get('input_report_sha256')==sha(report):
                    verifier.replace_observations(codes);coefficients=np.load(target/'coefficients.npy');_,gradient,hessian,_=verifier.evaluate(coefficients,True)
                    metric=float(np.max(abs(gradient)/np.sqrt(np.maximum(abs(hessian.diagonal()),1e-12))))
                    reusable=metric<1e-6
            if not reusable:
                with (target/'reference.log').open('w') as log,contextlib.redirect_stdout(log):
                    solve_reference(SimpleNamespace(report=report,output=target,seconds=90,check_only=False,observations=payload))
            reference_result=json.loads((target/'result.json').read_text())
            if not reference_result['reference_stationarity_passed']:raise AssertionError(('Noise repetition not stationary',name,trial,reference_result['standardized_barrier_gradient']))
            single=demosaicing_CFA_Bayer_Malvar2004(raws[reference],'BGGR')[roi]
            mean4=demosaicing_CFA_Bayer_Malvar2004(np.mean(list(raws.values()),axis=0),'BGGR')[roi]
            f5=np.load(target/'native.npy')
            for key,image in [('single',single),('mean4',mean4),('f5',f5)]:estimates[key].append(image)
            np.savez(target/'estimators.npz',single=single,mean4=mean4,f5=f5)
            if phase=='evaluation':
                f=source['frames'][reference];strong,_=undo_known_bilinear(baseline(raws[reference],f['kappa'],f['readSigma']**2,1))
                controls.append(strong[roi])
            observations.append(dict(trial=trial,phase=phase,observations_sha256=sha(payload),reference_report_sha256=sha(target/'result.json'),
                standardized_gradient=reference_result['standardized_barrier_gradient'],seconds=time.monotonic()-start))
            (base/'progress.json').write_text(json.dumps(observations,indent=2));print(name,trial+1,'/',total,phase,flush=True)
        profiles={};psds={};evaluation={}
        for key,images in estimates.items():
            images=np.array(images);psds[key],profiles[key]=noise_profile(images[:args.calibration]);evaluation[key]=images[args.calibration:]
            evaluation[key+'_bm3d']=np.array([filtered(image,psds[key]) for image in evaluation[key]])
        evaluation['lucky_fixed_raw_bm3d_1']=np.array(controls);np.savez(base/'noise-psds.npz',**psds);np.savez(base/'evaluation.npz',**evaluation)
        # Common native interior, chosen before these repetitions were run.
        truth=truth[4:-4,4:-4];scores={}
        for key,images in evaluation.items():
            error=images[:,4:-4,4:-4]-truth;per_trial=np.mean(error**2,axis=(1,2,3));average=error.mean(axis=0)
            scores[key]=dict(mse=per_trial.tolist(),mean_mse=float(per_trial.mean()),root_mean_mse=float(np.sqrt(per_trial.mean())),
                mean_image_bias_rms=float(np.sqrt(np.mean(average**2))),noise_rms=float(np.sqrt(np.mean((error-average)**2))))
        paired={}
        for a,b in [('mean4','single'),('f5','mean4'),('mean4_bm3d','single_bm3d'),('f5_bm3d','mean4_bm3d'),('f5_bm3d','lucky_fixed_raw_bm3d_1')]:
            difference=np.array(scores[a]['mse'])-scores[b]['mse'];center=float(difference.mean());se=float(stats.sem(difference));radius=float(stats.t.ppf(.975,len(difference)-1)*se)
            paired[a+' minus '+b]=dict(mean_mse_difference=center,paired_95_percent_t_interval=[center-radius,center+radius])
        result=dict(name=name,calibration_repetitions=args.calibration,evaluation_repetitions=args.evaluation,noise_profiles=profiles,
            scores=scores,paired_comparisons=paired,observations=observations);results.append(result)
        (base/'comparison.json').write_text(json.dumps(result,indent=2))
        sources.append(dict(name=name,input_sha256=sha(source_path),truth_sha256=sha(base/'truth-native.npy'),frozen_report_sha256=sha(report)))
    report=dict(revision='f5-native-family-diagnostic-v1',camera_used=False,qualification='CONTROLLED_NATIVE_REPEATED_PHASE_DIAGNOSTIC',seed=args.seed,
        code_sha256=sha(__file__),sources=sources,results=results,denoiser='BM3D 4.0.3, fixed strength 1, independent opponent channels with separately measured PSDs',
        limitations=['Three 16x16 crops, with 8x8 native evaluation interiors; these are mechanism controls, not scene-generalization evidence.',
            'Four main frames, repeated sampling, no short exposure, no SR, no motion update and no DCT.',
            'The v5 guide/noise/prior remain frozen across independent noise repetitions of each scene.',
            'A global stationary PSD approximates nonstationary and nonlinear output noise; variance spread is reported.',
            'The fixed reference and BM3D strength never use evaluation truth. Best-of-six Lucky remains a separate oracle baseline.',
            'This offline reference and BM3D timing are not mobile implementation timings.'])
    (args.output/'results.json').write_text(json.dumps(report,indent=2,allow_nan=False))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--calibration',type=int,default=16);p.add_argument('--evaluation',type=int,default=16);p.add_argument('--seed',type=int,default=6102711);run(p.parse_args())
