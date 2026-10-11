#!/usr/bin/env python3
"""Compare every FFCS strip to full-frame float output, including all boundaries.
Usage: python verify_ffcs_strips.py --library /path/libffcs.so --assets /path/xh2s
The shared library is built from core/ffcs.cpp with C++17, -lz, -pthread.
"""
import argparse, ctypes as c, json, random

def main():
    p=argparse.ArgumentParser();p.add_argument('--library',required=True);p.add_argument('--assets',required=True);a=p.parse_args()
    lib=c.CDLL(a.library);sz=c.c_size_t;fp=c.POINTER(c.c_float);bp=c.POINTER(c.c_uint8);sp=c.c_char_p;vp=c.c_void_p
    lib.ffcs_create.argtypes=[sp,sz,sp,sz];lib.ffcs_create.restype=vp
    lib.ffcs_destroy.argtypes=[vp];lib.ffcs_simulation_count.restype=sz
    full=lib.ffcs_process_linear_rgb_optimized
    full.argtypes=[vp,fp,sz,sz,sz,c.c_float,c.c_uint32,fp,sz,bp,sz,c.c_uint,sp,sz]
    strip=lib.ffcs_process_linear_rgb_strip
    strip.argtypes=[vp,fp,sz,sz,sz,sz,sz,sz,sz,c.c_float,c.c_uint32,fp,sz,c.c_uint,sp,sz]
    err=c.create_string_buffer(1024);calls=images=pixels=0
    sizes=[(1,1),(1,2),(1,13),(7,1),(11,3),(19,17),(131,19)]
    for index in range(lib.ffcs_simulation_count()):
        ctx=lib.ffcs_create(a.assets.encode(),index,err,len(err));assert ctx,err.value
        try:
            for w,h in sizes:
                for seed,ev in [(0,-2),(37,.7),(0xffffffff,2)]:
                    rng=random.Random(index*911+w*29+h+seed);n=w*h*3
                    data=(c.c_float*n)(*[rng.uniform(-.1,1.3) for _ in range(n)])
                    reference=(c.c_float*n)()
                    assert full(ctx,data,n,w,h,ev,seed,reference,n,None,0,1,err,len(err)),err.value
                    images+=1
                    # Single-row splits maximize halo boundaries. Random splits
                    # include extra input rows and every supported worker count.
                    for workers in range(1,5):
                        y=0
                        while y<h:
                            rows=1 if workers==1 else min(h-y,rng.randint(1,7))
                            first=max(0,y-1-rng.randint(0,2));last=min(h,y+rows+1+rng.randint(0,2))
                            ni=w*(last-first)*3;no=w*rows*3
                            inp=(c.c_float*ni).from_buffer_copy(bytes(data)[first*w*12:last*w*12])
                            out=(c.c_float*no)()
                            assert strip(ctx,inp,ni,w,h,first,last-first,y,rows,ev,seed,out,no,workers,err,len(err)),err.value
                            expected=bytes(reference)[y*w*12:(y+rows)*w*12]
                            assert bytes(out)==expected,(index,w,h,seed,ev,workers,y,rows)
                            calls+=1;pixels+=w*rows;y+=rows
        finally:lib.ffcs_destroy(ctx)
    ctx=lib.ffcs_create(a.assets.encode(),0,err,len(err));inp=(c.c_float*90)(*[.2]*90);out=(c.c_float*90)(*[.123]*90)
    valid=[ctx,inp,90,3,10,0,10,2,3,0,0,out,90,1,err,len(err)]
    invalid=[]
    def bad(k,v): q=valid.copy();q[k]=v;invalid.append(q)
    for k,v in [(0,None),(1,None),(2,89),(3,0),(4,0),(5,10),(6,0),(6,11),(7,10),(8,0),(8,9),(9,float('nan')),(9,33),(11,None),(12,26),(13,0),(13,5)]:bad(k,v)
    # Missing halo above / below and aliased output.
    q=valid.copy();q[5]=2;q[6]=8;invalid.append(q)
    q=valid.copy();q[6]=5;invalid.append(q)
    q=valid.copy();q[11]=inp;invalid.append(q)
    q=valid.copy();q[1]=(c.c_float*90)(*[float('inf')]*90);invalid.append(q)
    before=bytes(out)
    for q in invalid:
        assert strip(*q)==0,'invalid strip accepted'
        assert bytes(out)==before,'invalid call modified output'
        assert err.value,'missing error diagnostic'
    lib.ffcs_destroy(ctx)
    print(json.dumps({'status':'pass','looks':19,'full_frame_cases':images,'strip_calls':calls,'compared_pixels':pixels,'workers':[1,2,3,4],'invalid_calls':len(invalid),'max_float_error':0,'bit_exact':True},indent=2))
if __name__=='__main__': main()
