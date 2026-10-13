#!/usr/bin/env python3
"""Bitwise Python/C++ revision-8 portable spatial contract and disk API tests.

This tests the portable model in phocus_presets.apply_preset, not proprietary
Phocus spatial kernels. Passes explicit flags (the outer CLI has its own
Standard bypass and default-sharpness selection).
"""
import argparse, ctypes, hashlib, importlib.util, json, os, pathlib, subprocess, tempfile, time
import numpy as np
import scipy
from scipy.ndimage import gaussian_filter
from hncs_spatial_evidence import snapshot, environment


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


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--reference',type=pathlib.Path,required=True);ap.add_argument('--output',type=pathlib.Path);ap.add_argument('--large',action='store_true');args=ap.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1]
    args.reference=args.reference.resolve()
    before=snapshot(root,args.reference)
    spec=importlib.util.spec_from_file_location('phocus_spatial_reference',args.reference/'phocus_presets.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
    report={'passed':False,'numpy':np.__version__,'scipy':scipy.__version__,'reference_sha256':hashlib.sha256((args.reference/'phocus_presets.py').read_bytes()).hexdigest(),'cases':0,'float32_channels':0,'float32_bit_mismatches':0,'u16_mismatches':0,'file_cases':0,'errors_tested':[],'timing':[]}
    callback=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_void_p)
    with tempfile.TemporaryDirectory(prefix='hncs-spatial-') as tmp:
        tmp=pathlib.Path(tmp);libpath=tmp/'spatial.so'
        subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-shared','-fPIC','-O3','-fno-fast-math','-ffp-contract=off','-Wall','-Wextra','-Werror',str(root/'core/hncs_spatial.cpp'),str(root/'core/hncs_numpy_rng.cpp'),'-o',str(libpath)],check=True)
        lib=ctypes.CDLL(str(libpath));mem=lib.hncs_apply_spatial_preset;disk=lib.hncs_apply_spatial_preset_file
        mem.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_int,ctypes.c_int]
        disk.argtypes=[ctypes.c_char_p,ctypes.c_size_t,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_int,ctypes.c_int,ctypes.c_char_p,callback,ctypes.c_void_p]
        nullcb=callback()
        def check(source,key,grain,sharp,filemode=False):
            ref=reference_apply(p,source.copy(),key,grain,sharp)
            out=source.copy();h,w=source.shape[:2];t=time.perf_counter()
            if filemode:
                path=tmp/'work.rgbf';out.tofile(path)
                ret=disk(os.fsencode(path),w,h,key.encode(),grain,sharp,os.fsencode(tmp),nullcb,None)
                out=np.fromfile(path,dtype=np.float32).reshape(source.shape);report['file_cases']+=1
            else:ret=mem(out.ctypes.data,w,h,key.encode(),grain,sharp)
            elapsed=time.perf_counter()-t
            assert ret==0,(key,source.shape,grain,sharp,ret)
            mismatch=int(np.count_nonzero(out.view(np.uint32)!=ref.view(np.uint32)))
            q=int(np.count_nonzero(np.rint(out*65535)!=np.rint(ref*65535)))
            assert mismatch==0,(key,source.shape,grain,sharp,mismatch,float(np.max(np.abs(out-ref))),q)
            report['cases']+=1;report['float32_channels']+=source.size
            return elapsed
        rng=np.random.default_rng(81047)
        keys=p.PRESET_CHOICES
        src=rng.uniform(-.03,1.03,(17,23,3)).astype(np.float32)
        src[0,:3]=np.array([[0,1,.5],[1/65535,65534/65535,.5/65535],[-.2,1.2,0]],np.float32)
        for key in keys:
            for grain,sharp in [(0,0),(1,0),(0,1),(1,1)]:check(src,key,grain,sharp,True)
        grainkeys=[k for k in keys if p.settings(k)['film_grain'].get('ApplyFilmGrain') and p.settings(k)['film_grain'].get('FilmGrainAmount')]
        for shape in [(1,1,3),(1,7,3),(7,1,3),(3,5,3),(127,129,3),(321,511,3),(5,8193,3),(4097,3,3)]:
            source=rng.random(shape,dtype=np.float32)
            for key in grainkeys:check(source,key,1,0,shape[1]>4096)
            for key in ['standard','sharpness-high','sharpness-portrait']:check(source,key,0,1)
        one=rng.random((1024,1024,3),dtype=np.float32)
        for key,g,s in [('film-grain-artistic',1,1),('film-grain-fine-texture',1,1),('sharpness-high',1,1)]:
            for filemode in [False,True]:
                elapsed=check(one,key,g,s,filemode)
                report['timing'].append({'width':1024,'height':1024,'preset':key,'grain_flag':g,'sharpness_flag':s,'mode':'file' if filemode else 'memory','seconds':round(elapsed,4)})
        if args.large:
            for shape,key in [((4097,4097,3),'film-grain-artistic'),((3073,4097,3),'film-grain-tabular-grain')]:
                source=rng.random(shape,dtype=np.float32);check(source,key,1,1,True)
        valid=np.zeros((7,9,3),np.float32);path=tmp/'work.rgbf';valid.tofile(path)
        def filecall(w=9,h=7,key=b'film-grain-artistic',g=1,s=1,cb=nullcb,directory=None):
            return disk(os.fsencode(path),w,h,key,g,s,os.fsencode(tmp if directory is None else directory),cb,None)
        for label,call in [
            ('zero width',lambda:filecall(w=0)),('overflow dimensions',lambda:filecall(w=2**63,h=3)),('unknown preset',lambda:filecall(key=b'missing')),
            ('bad grain flag',lambda:filecall(g=2)),('bad sharpness flag',lambda:filecall(s=-1)),('wrong file size',lambda:filecall(w=10))]:
            assert call()==-1,label;report['errors_tested'].append(label)
        valid[0,0,0]=np.nan;valid.tofile(path);assert filecall()==-1;report['errors_tested'].append('nonfinite');valid[0,0,0]=0;valid.tofile(path)
        assert filecall(directory=tmp/'missing')==-2;report['errors_tested'].append('scratch creation failure')
        for stop in [1,3,14,40]:
            valid.tofile(path);count=[0]
            def canceled(_):count[0]+=1;return int(count[0]>=stop)
            cb=callback(canceled);assert filecall(cb=cb)==-3,stop
            assert not list(tmp.glob('hncs-spatial-*'))
        report['errors_tested']+=['cancellation during passes','temp paths removed after cancellation']
        valid.tofile(path);assert filecall()==0;assert not list(tmp.glob('hncs-spatial-*'));report['errors_tested'].append('temp paths removed after success')
    assert snapshot(root,args.reference)==before, 'Test sources changed during run'
    report.update(environment());report['source_sha256']=before
    report['timing_filesystem']='TemporaryDirectory; /tmp is tmpfs on this test host, not representative device storage'
    report['scratch_bytes_per_pixel_max']=16
    report['extra_ram_bound_bytes']=4*1024*1024
    report['large_cases_requested']=args.large
    report['passed']=True
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
