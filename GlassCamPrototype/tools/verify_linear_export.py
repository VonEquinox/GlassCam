"""Verify float display-linear export before any 8-bit encoder (no Apple SDK needed)."""
import ctypes as c
import json
import numpy as np
import verify_cpp as v
r=v.r

def decode_srgb(encoded):
    return np.where(encoded<=.04045,encoded/12.92,((encoded+.055)/1.055)**2.4)

def main():
    lib=v.library()
    f=lib.hncs_process_linear_rgba
    f.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.POINTER(c.c_float),c.c_size_t]
    f.restype=c.c_int
    a=r.assets();rng=np.random.default_rng(1717)
    x=rng.uniform(-.1,1.2,(8192,3)).astype(np.float32)
    maxima=[];compared=0
    for space in ('legacy','lstar'):
        for intent in ('standard','reproduction'):
            for kelvin in (2000,5500,10000):
                for ev in (-2,0,2):
                    ctx=lib.hncs_create_mode(ev,kelvin,int(space=='lstar'),int(intent=='reproduction'))
                    assert ctx
                    out=np.empty((len(x),4),np.float32)
                    assert f(ctx,x.ctypes.data_as(c.POINTER(c.c_float)),out.ctypes.data_as(c.POINTER(c.c_float)),len(x))==0
                    native=r.experimental_adapter(x,kelvin,a,ev)
                    codes=r.hncs_codes(native,kelvin,a,intent,working_space=space)
                    # Invert the reference display OETF in double precision. This
                    # recovers its clipped display-linear RGB, not a byte image.
                    expected=decode_srgb(r.srgb_from_hncs(codes,a,space))
                    error=float(np.max(np.abs(out[:,:3].astype(np.float64)-expected)))
                    assert error<=1e-7,(space,intent,kelvin,ev,error)
                    assert np.isfinite(out).all() and np.all((out>=0)&(out<=1))
                    assert np.all(out[:,3]==1)
                    maxima.append(error);compared+=expected.size
                    # Reentrant tiled execution is identical to full-buffer output.
                    tiled=np.empty_like(out)
                    for begin in range(0,len(x),1000):
                        end=min(len(x),begin+1000)
                        assert f(ctx,x[begin:end].ctypes.data_as(c.POINTER(c.c_float)),tiled[begin:end].ctypes.data_as(c.POINTER(c.c_float)),end-begin)==0
                    np.testing.assert_array_equal(tiled,out)
                    lib.hncs_destroy(ctx)
    ramp=np.repeat(np.linspace(0,1,4096,dtype=np.float32)[:,None],3,axis=1)
    output=np.empty((len(ramp),4),np.float32);ctx=lib.hncs_create_mode(0,5500,0,0)
    assert f(ctx,ramp.ctypes.data_as(c.POINTER(c.c_float)),output.ctypes.data_as(c.POINTER(c.c_float)),len(ramp))==0
    unique=[int(len(np.unique(output[:,i]))) for i in range(3)]
    assert min(unique)>1024,unique
    non_byte_levels=int(np.count_nonzero(np.abs(output[:,:3]*255-np.rint(output[:,:3]*255))>1e-4))
    assert non_byte_levels>0
    assert f(None,None,None,0)==-1
    assert f(ctx,None,None,0)==0
    assert f(ctx,None,None,1)==-1
    assert f(ctx,ramp.ctypes.data_as(c.POINTER(c.c_float)),output.ctypes.data_as(c.POINTER(c.c_float)),c.c_size_t(-1).value)==-1
    bad=np.array([[np.nan,0,0]],np.float32)
    assert f(ctx,bad.ctypes.data_as(c.POINTER(c.c_float)),output.ctypes.data_as(c.POINTER(c.c_float)),1)==-1
    lib.hncs_destroy(ctx)
    original=v.verify(lib)
    report={'status':'passed','float_display_linear_channel_comparisons':compared,'max_absolute_error_vs_double_reference':max(maxima),'tolerance':1e-7,'gray_ramp_unique_values_per_channel':unique,'gray_ramp_non_byte_levels':non_byte_levels,'tiled_output':'bit-exact','alpha':'one','invalid_arguments':'passed','original_hncs_core':{k:v for k,v in original.items() if k!='golden_checks'},'apple_heif_encoder_executed':False,'actual_heif_bitstream_checked':False,'wechat_delivery_checked':False,'notes':'Float export is independent of the eight-bit preview encoder; dedicated Apple HEIF10 writer requires Apple-platform testing.'}
    (r.ROOT/'validation/linear-export.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
