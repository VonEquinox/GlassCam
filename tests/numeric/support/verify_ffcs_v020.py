#!/usr/bin/env python3
"""Independent FFCS 0.2.0 source goldens and native parity, no historical rewrite.

Reference stages execute the delivered Python implementation. Mobile switches
are represented by bypassing only the upstream grain/sharpen functions. Native
mobile input is exposure-clamped linear RGB encoded to the reference API.
"""
from __future__ import annotations
import ctypes as c, hashlib, importlib.metadata, json, math, os
from pathlib import Path
import random, struct, subprocess, sys, tempfile, zlib
from unittest.mock import patch
import numpy as np
from materialize_ffcs_reference import PREFIX, RESEARCH_FILES, verified_archive
ROOT=Path(__file__).resolve().parents[3]
SOURCE=ROOT/'vendor/ffcs'
FAMILIES=('XH2S','XA3','GFX100','GFX100S','GFX100II')
NAMES=('PROVIA','VELVIA','ASTIA','CLASSIC CHROME','CLASSIC NEG.','NOSTALGIC NEG.','ETERNA','ETERNA BLEACH BYPASS','ACROS','MONOCHROME','PRO NEG. HI','PRO NEG. STD','SEPIA','ACROS+G','ACROS+R','ACROS+Ye','MONOCHROME+G','MONOCHROME+R','MONOCHROME+Ye','REALA ACE')
V=ROOT/'tests/fixtures/ffcs'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def source_stamp(source):
    manifest=json.loads((source/'validation/delivery_manifest.json').read_text())
    with verified_archive(source/'source.zip') as archive:
        for entry in manifest['files']:
            path=entry['path']
            actual=(hashlib.sha256(archive.read(PREFIX+path)).hexdigest()
                    if path in RESEARCH_FILES else sha(source/path))
            assert actual==entry['sha256'],path
    return {'version':manifest['version'],'manifest_sha256':sha(source/'validation/delivery_manifest.json'),'verified_manifest_files':len(manifest['files']), 'implementation_sha256':{str(p.relative_to(source)):sha(p) for p in sorted((source/'implementation/ffcs').glob('*.py'))}}
def load(source=SOURCE):
    sys.path.insert(0,str(source/'implementation'))
    return source

def pixels(w=6,h=4):
    rng=random.Random(928)
    out=np.asarray([[[rng.uniform(-.2,1.2) for _ in range(3)] for _ in range(w)] for _ in range(h)],dtype=np.float64)
    boundary=[-.2,0,1e-8,.0031308,.04045-1e-10,.04045,.04045+1e-10,.18,.5,1-1e-8,1,1.2]
    for i,v in enumerate(boundary[:w*h]):out.reshape(-1,3)[i]=v
    return out

def reference(data,camera,name,overlay=False,radius=1.,grain=True,sharp=True,seed=0,linear=False):
    from PIL import Image
    from ffcs.pipeline import FFCS,PipelineConfig
    import ffcs.pipeline as pipeline
    original_grain,original_sharp=pipeline.apply_grain,pipeline.apply_sharpen_pixels
    with patch.object(pipeline,'apply_grain',side_effect=lambda p,s,seed=0:original_grain(p,s,seed) if grain else p),patch.object(pipeline,'apply_sharpen_pixels',side_effect=lambda p,a,radius=1:original_sharp(p,a,radius) if sharp else p):
        result=FFCS(PipelineConfig(camera=camera,simulation=name,seed=seed,input_is_linear=linear,apply_reference_adjustments=overlay,sharpen_radius=radius)).apply(Image.new('RGB',(len(data[0]),len(data))),input_pixels=data.tolist() if hasattr(data,'tolist') else data)
    assert result.metadata['approximation_metrics']['analytic_look']['status']=='not_used'
    return result

def configured(source):
    from ffcs.lutdata import load_reference_lut
    return [(camera,i,loaded[2]) for camera in FAMILIES for i,name in enumerate(NAMES) if (loaded:=load_reference_lut(camera,name)) is not None]



def build():
    output=ROOT/'build/libffcs_v020_verify.so';output.parent.mkdir(exist_ok=True)
    command=['g++','-std=c++17','-O3','-fno-fast-math','-ffp-contract=off','-shared','-fPIC','-pthread',str(ROOT/'core/ffcs.cpp'),'-lz','-o',str(output)]
    subprocess.run(command,check=True)
    lib=c.CDLL(str(output));sz=c.c_size_t;vp=c.c_void_p;cp=c.c_char_p;fp=c.POINTER(c.c_float);dp=c.POINTER(c.c_double);bp=c.POINTER(c.c_uint8)
    cb=c.CFUNCTYPE(None,cp,dp,sz,sz,vp)
    lib.ffcs_create_family_config.argtypes=[cp,cp,sz,c.c_int,c.c_int,c.c_int,c.c_double,cp,sz];lib.ffcs_create_family_config.restype=vp
    lib.ffcs_create_config.argtypes=[cp,sz,c.c_int,c.c_int,c.c_int,c.c_double,cp,sz];lib.ffcs_create_config.restype=vp
    lib.ffcs_destroy.argtypes=[vp]
    lib.ffcs_required_halo.argtypes=[vp];lib.ffcs_required_halo.restype=sz
    lib.ffcs_asset_family.argtypes=[vp];lib.ffcs_asset_family.restype=cp
    lib.ffcs_simulation_available.argtypes=[cp,cp,sz];lib.ffcs_simulation_available.restype=c.c_int
    lib.ffcs_simulation_count.restype=sz
    lib.ffcs_simulation_name.argtypes=[sz];lib.ffcs_simulation_name.restype=cp
    lib.ffcs_process_encoded_double.argtypes=[vp,dp,sz,sz,sz,c.c_uint32,dp,sz,cb,vp,cp,sz]
    base=[vp,fp,sz,sz,sz,c.c_float,c.c_uint32,fp,sz,bp,sz]
    lib.ffcs_process_linear_rgb.argtypes=base+[cp,sz]
    lib.ffcs_process_linear_rgb_optimized.argtypes=base+[c.c_uint,cp,sz]
    lib.ffcs_process_linear_rgb_strip.argtypes=[vp,fp,sz,sz,sz,sz,sz,sz,sz,c.c_float,c.c_uint32,fp,sz,c.c_uint,cp,sz]
    return lib,cb,command

def compare(source):
    from ffcs.color import srgb_decode,srgb_encode
    lib,callback,command=build();root=source/'implementation/ffcs/data';err=c.create_string_buffer(1024)
    fp=c.POINTER(c.c_float);dp=c.POINTER(c.c_double);bp=c.POINTER(c.c_uint8)
    golden=json.loads((V/'ffcs-v020-stage-goldens.json').read_text()); assert golden['source']==source_stamp(source)
    counts={'stage_comparisons':0,'encoded_cases':0,'linear_reference_cases':0,'optimized_bit_exact_cases':0,'strip_bit_exact_calls':0,'invalid_calls':0}; maximum=mobile_max=0.;checks=[]
    assert lib.ffcs_simulation_count()==20
    assert tuple(lib.ffcs_simulation_name(i).decode() for i in range(20))==NAMES
    available={(cam,i) for cam,i,_ in configured(source)}
    for cam in FAMILIES:
        for i in range(20):assert bool(lib.ffcs_simulation_available(str(root).encode(),cam.encode(),i))==((cam,i) in available),(cam,i,bool(lib.ffcs_simulation_available(str(root).encode(),cam.encode(),i)),(cam,i) in available)
    def create(cam,i,overlay,grain,sharp,radius):
        ctx=lib.ffcs_create_family_config(str(root).encode(),cam.encode(),i,grain,sharp,overlay,radius,err,len(err));assert ctx,err.value
        assert lib.ffcs_required_halo(ctx)==(math.ceil(3*max(.1,radius)) if overlay and sharp else 0)
        return ctx
    def encoded(ctx,data,expected,seed,label):
        nonlocal maximum
        out=np.empty_like(data);stages={}
        @callback
        def capture(name,p,w,h,user):stages[name.decode()]=np.ctypeslib.as_array(p,shape=(w*h*3,)).copy().reshape(h,w,3)
        assert lib.ffcs_process_encoded_double(ctx,data.ctypes.data_as(dp),data.size,data.shape[1],data.shape[0],seed,out.ctypes.data_as(dp),out.size,capture,None,err,len(err)),err.value
        assert set(stages)==set(expected)
        mx=0.
        for name,e in expected.items():
            error=float(np.max(np.abs(stages[name]-np.asarray(e))));maximum=max(maximum,error);mx=max(mx,error);counts['stage_comparisons']+=1
            assert error<1e-12,(label,name,error)
        np.testing.assert_array_equal(out,stages['output_icc']);counts['encoded_cases']+=1;checks.append({'case':label,'max_stage_error':mx})
    for record in golden['records']:
        ctx=create(record['camera'],record['index'],False,True,True,1)
        try:
            assert lib.ffcs_asset_family(ctx).decode()==record['asset'].split('/')[0]
            assert sha(root/record['asset'])==record['asset_sha256']
            encoded(ctx,np.asarray(golden['input']),record['stages'],0,record['camera']+'/'+record['look']+'/default')
        finally:lib.ffcs_destroy(ctx)
    # Representative families and chromatic/monochrome/sepia profiles. All four
    # independent switch states, default and explicit overlay, radii and edges.
    for case,(camera,i) in enumerate([('XH2S',0),('XA3',12),('GFX100',13),('GFX100S',5),('GFX100II',19),('GFX100II',3)]):
      for overlay in (False,True):
       for grain,sharp in ((0,0),(0,1),(1,0),(1,1)):
        radius=(.1,.5,1.,1.5,2.25,3.0)[case];ctx=create(camera,i,overlay,grain,sharp,radius)
        try:
            w,h=((1,9),(9,1),(7,13),(131,9),(11,17),(3,2))[case];data=pixels(w,h);seed=(0,37,0xffffffff)[case%3]
            expected=reference(data,camera,NAMES[i],overlay,radius,grain,sharp,seed)
            encoded(ctx,data,expected.stage_pixels,seed,f'{camera}/{NAMES[i]}/overlay={overlay}/flags={grain}{sharp}/radius={radius}')
            linear=np.asarray(data,dtype=np.float32); ev=c.c_float((-2,.7,2)[case%3]).value
            # Both reference input domains independently produce the same final
            # output after the mobile adapter's linear exposure/clamping.
            exposed=np.clip(linear.astype(np.float64)*2.**ev,0,1)
            encoded_input=np.vectorize(srgb_encode)(exposed)
            ref=reference(encoded_input,camera,NAMES[i],overlay,radius,grain,sharp,seed)
            direct=reference(exposed,camera,NAMES[i],overlay,radius,grain,sharp,seed,True)
            np.testing.assert_allclose(ref.pixels,direct.pixels,rtol=0,atol=1e-12)
            wanted=np.asarray([[[srgb_decode(v) for v in rgb] for rgb in row] for row in ref.pixels],dtype=np.float32)
            full=np.empty_like(linear);preview=np.empty((h,w,4),dtype=np.uint8)
            args=[ctx,linear.ctypes.data_as(fp),linear.size,w,h,ev,seed]
            assert lib.ffcs_process_linear_rgb(*args,full.ctypes.data_as(fp),full.size,preview.ctypes.data_as(bp),preview.size,err,len(err)),err.value
            error=float(np.max(np.abs(full-wanted)));mobile_max=max(mobile_max,error);assert error<=2e-7,(camera,i,error)
            expected_preview=np.rint(np.asarray(ref.pixels)*255).astype(np.int16)
            assert np.max(np.abs(preview[...,:3].astype(np.int16)-expected_preview))<=1 and np.all(preview[...,3]==255)
            counts['linear_reference_cases']+=1
            halo=lib.ffcs_required_halo(ctx);rng=random.Random(case+grain*100+sharp*1000)
            for workers in (1,2,3,4):
                opt=np.empty_like(full);rgba=np.empty_like(preview)
                for mode in ('both','float','preview'):
                    assert lib.ffcs_process_linear_rgb_optimized(*args,opt.ctypes.data_as(fp) if mode!='preview' else None,opt.size,rgba.ctypes.data_as(bp) if mode!='float' else None,rgba.size,workers,err,len(err)),err.value
                    if mode!='preview':assert opt.tobytes()==full.tobytes()
                    if mode!='float':assert rgba.tobytes()==preview.tobytes()
                    counts['optimized_bit_exact_cases']+=1
                y=0
                while y<h:
                    rows=min(h-y,1 if workers==1 else rng.randint(1,5));first=max(0,y-halo-rng.randint(0,2));last=min(h,y+rows+halo+rng.randint(0,2));inp=np.ascontiguousarray(linear[first:last]);out=np.full((rows,w,3),-7,dtype=np.float32)
                    assert lib.ffcs_process_linear_rgb_strip(ctx,inp.ctypes.data_as(fp),inp.size,w,h,first,last-first,y,rows,ev,seed,out.ctypes.data_as(fp),out.size,workers,err,len(err)),err.value
                    assert out.tobytes()==full[y:y+rows].tobytes(),(camera,i,overlay,grain,sharp,radius,workers,y)
                    counts['strip_bit_exact_calls']+=1;y+=rows
                # Missing required halo is an error only if a nonzero halo is
                # active. Border truncation is global, never strip-relative.
            if h>2 and halo:
                inp=np.ascontiguousarray(linear[1:2]);out=np.full_like(inp,-7);before=out.tobytes()
                assert not lib.ffcs_process_linear_rgb_strip(ctx,inp.ctypes.data_as(fp),inp.size,w,h,1,1,1,1,ev,seed,out.ctypes.data_as(fp),out.size,1,err,len(err))
                assert out.tobytes()==before and err.value;counts['invalid_calls']+=1
        finally:lib.ffcs_destroy(ctx)
    counts['invalid_calls']+=invalid_containers(lib,root)
    report={'status':'pass','source':source_stamp(source),'compile_command':command,'configured_family_cases':len(golden['records']),'unique_native_assets':50,**counts,'maximum_absolute_stage_error':maximum,'stage_tolerance':1e-12,'linear_mobile_max_error':mobile_max,'linear_mobile_tolerance':2e-7,'workers':[1,2,3,4],'checks':checks,'supersedes':['v0.1 default overlay bytes intentionally replaced by v0.2 neutral LUT defaults','v0.1 box blur intentionally replaced by reference Gaussian radius kernel','fixed one-row halo replaced by context-specific zero or ceil(3*max(.1,radius))'],'limitations':['Linux host numerical evidence only; no Apple build/runtime or real sensor/native renderer equivalence claim.','Only native bundled tables and documented same-look family fallback are implemented; analytic-only and custom cube remain outside mobile scope.']}
    return {k:v for k,v in report.items() if k!='checks'}

def invalid_containers(lib,root):
    original=(root/'xh2s/provia.lutz').read_bytes();header=60 if original[:8]==b'FFCSLUT2' else 56;length_offset=56 if header==60 else 52
    def compressed(blob):
        b=bytearray(original[:header]);struct.pack_into('<I',b,length_offset,len(blob));return bytes(b)+blob
    cases={'bad_magic':b'INVALID!'+original[8:],'truncated_header':original[:20],'truncated_file':original[:-1],'trailing_file':original+b'x','trailing_stream':compressed(original[header:]+b'x'),'concatenated_stream':compressed(original[header:]+zlib.compress(b'extra')),'incomplete_stream':compressed(original[header:-3]),'short_payload':compressed(zlib.compress(b'\0'*6))}
    for name,offset,fmt,value in [('bad_channels',10,'H',4),('zero_size',8,'H',0),('nan_scale',12,'f',float('nan')),('zero_scale',12,'f',0),('nan_matrix',16,'f',float('nan'))]:
        b=bytearray(original);struct.pack_into('<'+fmt,b,offset,value);cases[name]=bytes(b)
    if header==60:
        b=bytearray(original);b[52]=2;cases['unknown_flags']=bytes(b)
    err=c.create_string_buffer(1024)
    with tempfile.TemporaryDirectory(prefix='ffcs-v020-invalid-') as tmp:
        p=Path(tmp)/'provia.lutz'
        for name,blob in cases.items():
            p.write_bytes(blob);ctx=lib.ffcs_create_config(tmp.encode(),0,1,1,0,1,err,len(err));assert not ctx and err.value,(name,err.value)
        p.write_bytes(original)
        for radius in (0,-1,float('nan'),float('inf'),65):
            ctx=lib.ffcs_create_config(tmp.encode(),0,1,1,1,radius,err,len(err));assert not ctx and err.value
        for flags in ((2,1,1),(1,-1,1),(1,1,2)):
            ctx=lib.ffcs_create_config(tmp.encode(),0,*flags,1,err,len(err));assert not ctx and err.value
    return len(cases)+8
