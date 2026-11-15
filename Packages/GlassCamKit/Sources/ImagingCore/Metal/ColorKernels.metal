#include <metal_stdlib>
#include "ColorTypes.h"
using namespace metal;

static float3 gc_matrix(constant float *m, float3 p) {
    return float3((m[0]*p.x+m[1]*p.y)+m[2]*p.z,
                  (m[3]*p.x+m[4]*p.y)+m[5]*p.z,
                  (m[6]*p.x+m[7]*p.y)+m[8]*p.z);
}
static float gc_decode(float x) { x=clamp(x,0.f,1.f);return x<=.04045f?x/12.92f:pow((x+.055f)/1.055f,2.4f); }
static float gc_encode(float x) { x=clamp(x,0.f,1.f);return x<=.0031308f?12.92f*x:1.055f*pow(x,1.f/2.4f)-.055f; }
static float3 gc_decode3(float3 v) { return float3(gc_decode(v.x),gc_decode(v.y),gc_decode(v.z)); }
static float3 gc_encode3(float3 v) { return float3(gc_encode(v.x),gc_encode(v.y),gc_encode(v.z)); }
static float gc_gain(float3 p) { return max(1.f,max(p.x,max(p.y,p.z))); }
static float3 gc_restore(float3 p,float gain) { return clamp(p*gain,0.f,10000.f/203.f); }
// FFCS evaluates the original native cube and optional analytic controls.
static float gc_labf(float t) {const float d=6.f/29.f;return t>d*d*d?pow(t,1.f/3.f):t/(3.f*d*d)+4.f/29.f;}
static float gc_labi(float t) {const float d=6.f/29.f;return t>d?pow(t,3.f):3.f*d*d*(t-4.f/29.f);}
static float3 gc_xyz(float3 v) {return float3((.4124564f*v.x+.3575761f*v.y)+.1804375f*v.z,(.2126729f*v.x+.7151522f*v.y)+.0721750f*v.z,(.0193339f*v.x+.1191920f*v.y)+.9503041f*v.z);}
static float3 gc_rgb(float3 v) {return float3((3.2404542f*v.x-1.5371385f*v.y)-.4985314f*v.z,(-.9692660f*v.x+1.8760108f*v.y)+.0415560f*v.z,(.0556434f*v.x-.2040259f*v.y)+1.0572252f*v.z);}
static float3 gc_perceptual(float3 v,constant GCFFCSColor &c) {
    if(c.saturation==1.f&&c.hue==0.f)return v;
    const float3 xyz=gc_xyz(gc_decode3(v));
    const float x=gc_labf(xyz.x/.95047f),y=gc_labf(xyz.y),z=gc_labf(xyz.z/1.08883f);
    const float l=clamp(116.f*y-16.f,0.f,100.f),a=500.f*(x-y),b=200.f*(y-z);
    const float chroma=length(float2(a,b))*c.saturation,hue=atan2(b,a)+c.hue*6.283185307179586f;
    const float fy=(l+16.f)/116.f;
    v=gc_encode3(gc_rgb(float3(gc_labi(fy+chroma*cos(hue)/500.f)*.95047f,gc_labi(fy),gc_labi(fy-chroma*sin(hue)/200.f)*1.08883f)));
    v=gc_decode3(v);
    float ll=(.4122214708f*v.x+.5363325363f*v.y)+.0514459929f*v.z;
    float mm=(.2119034982f*v.x+.6806995451f*v.y)+.1073969566f*v.z;
    float ss=(.0883024619f*v.x+.2817188376f*v.y)+.6299787005f*v.z;
    ll=copysign(pow(abs(ll),1.f/3.f),ll);mm=copysign(pow(abs(mm),1.f/3.f),mm);ss=copysign(pow(abs(ss),1.f/3.f),ss);
    const float L=(.2104542553f*ll+.7936177850f*mm)-.0040720468f*ss;
    const float aa=(1.9779984951f*ll-2.4285922050f*mm)+.4505937099f*ss;
    const float bb=(.0259040371f*ll+.7827717662f*mm)-.8086757660f*ss;
    const float cc=length(float2(aa,bb)),hh=atan2(bb,aa),A=cc*cos(hh),B=cc*sin(hh);
    ll=pow((L+.3963377774f*A)+.2158037573f*B,3.f);
    mm=pow((L-.1055613458f*A)-.0638541728f*B,3.f);
    ss=pow((L-.0894841775f*A)-1.2914855480f*B,3.f);
    return gc_encode3(float3((4.0767416621f*ll-3.3077115913f*mm)+.2309699292f*ss,
        (-1.2684380046f*ll+2.6097574011f*mm)-.3413193965f*ss,(-.0041960863f*ll-.7034186147f*mm)+1.7076147010f*ss));
}
static float3 gc_ffcs_fetch(uint3 p,constant GCFFCSColor &c,device const ushort *lut,device const float *codes) {
    const uint at=((p.z*c.size+p.y)*c.size+p.x)*3;
    return float3(codes[lut[at]],codes[lut[at+1]],codes[lut[at+2]]);
}
static float3 gc_ffcs_native(float3 encoded,constant GCFFCSColor &c,
    device const ushort *lut,device const float *codes,device const uint *gammaIn,
    device const ushort *gammaOut,device const int *gaussian,device const int *distances) {
    const uint3 input=min(uint3(floor(pow(clamp(encoded.bgr,0.f,1.f),c.mappingGamma)*float(c.workingMaximum)+.5f)),uint3(c.workingMaximum));
    const uint3 position=uint3(gammaIn[input.x],gammaIn[input.y],gammaIn[input.z]);
    const int3 lo=int3(position>>8),fraction=int3(position&255u);
    long3 sums=0;int3 weights=0;
    for(int r=-1;r<=2;++r)for(int g=-1;g<=2;++g)for(int b=-1;b<=2;++b) {
        if(int(r<0||r>1)+int(g<0||g>1)+int(b<0||b>1)>1)continue;
        const int3 offsets=int3(b,g,r);
        int3 coordinate=lo+offsets,sign=1;int squared=0;
        for(uint ch=0;ch<3;++ch) {
            squared+=distances[fraction[ch]*4+offsets[ch]+1];
            if(lo[ch]==0&&offsets[ch]==-1){coordinate[ch]=1;sign[ch]=-1;}
            else if(lo[ch]>=int(c.size)-(c.fixedMapping?2:3)&&offsets[ch]==2){coordinate[ch]=lo[ch];sign[ch]=-1;}
        }
        if(b==-1&&g==0&&r==1&&lo.x>0)coordinate.x=lo.x;
        if(squared>=0x60000)continue;
        const int weight=gaussian[squared>>8];
        const uint index=((uint(coordinate.z)*c.size+uint(coordinate.y))*c.size+uint(coordinate.x))*3;
        weights+=sign*weight;
        sums+=long3(lut[index],lut[index+1],lut[index+2])*long3(sign)*long(weight);
    }
    if(any(weights==0))return float3(NAN);
    const long3 value=clamp((sums+long3((weights+1)/2))/long3(weights),long3(0),long3(20000));
    return float3(codes[gammaOut[uint(value.z)]],codes[gammaOut[uint(value.y)]],codes[gammaOut[uint(value.x)]]);
}
static float gc_noise(uint x,uint y,uint seed) {uint n=x*374761393u+y*668265263u+seed*69069u;n=(n^(n>>13))*1274126177u;n^=n>>16;return (float(n)/4294967295.f)*2.f-1.f;}
static float gc_smooth(uint x,uint y,uint width,uint seed) {
    const float scale=max(1.f,float(width)*.008f),xx=float(x)/scale,yy=float(y)/scale;
    const uint gx=uint(xx),gy=uint(yy);const float fx=xx-float(gx),fy=yy-float(gy);
    const float a=gc_noise(gx,gy,seed)*(1.f-fx)+gc_noise(gx+1,gy,seed)*fx;
    const float b=gc_noise(gx,gy+1,seed)*(1.f-fx)+gc_noise(gx+1,gy+1,seed)*fx;
    return a*(1.f-fy)+b*fy;
}
static float4 gc_ffcs_pixel(float3 source,uint2 pixel,constant GCColorRegion &region,constant GCFFCSColor &c,device const ushort *lut,device const float *codes,device const uint *grainCoordinates,
    device const uint *gammaIn,device const ushort *gammaOut,device const int *gaussian,device const int *distances) {
    source*=region.preExposure;
    if(!all(isfinite(source)))return float4(float3(NAN),1.f);
    const float gain=gc_gain(source);
    float3 v=gc_encode3(gc_matrix(c.matrix,clamp((source/gain)*region.backendExposure,0.f,1.f)));
    if(c.nativeMapping) {
        v=gc_ffcs_native(v,c,lut,codes,gammaIn,gammaOut,gaussian,distances);
    } else {
    const float3 position=clamp(v.bgr,0.f,1.f)*float(c.size-1);
    const uint3 lo=uint3(floor(position)),hi=min(lo+1,uint3(c.size-1));const float3 f=position-float3(lo);
    const float3 a=gc_ffcs_fetch(lo,c,lut,codes)*(1.f-f.x)+gc_ffcs_fetch(uint3(hi.x,lo.y,lo.z),c,lut,codes)*f.x;
    const float3 b=gc_ffcs_fetch(uint3(lo.x,hi.y,lo.z),c,lut,codes)*(1.f-f.x)+gc_ffcs_fetch(uint3(hi.x,hi.y,lo.z),c,lut,codes)*f.x;
    const float3 d=gc_ffcs_fetch(uint3(lo.x,lo.y,hi.z),c,lut,codes)*(1.f-f.x)+gc_ffcs_fetch(uint3(hi.x,lo.y,hi.z),c,lut,codes)*f.x;
    const float3 e=gc_ffcs_fetch(uint3(lo.x,hi.y,hi.z),c,lut,codes)*(1.f-f.x)+gc_ffcs_fetch(hi,c,lut,codes)*f.x;
    v=clamp((a*(1.f-f.y)+b*f.y)*(1.f-f.z)+(d*(1.f-f.y)+e*f.y)*f.z,0.f,1.f);
    if(!c.rgbChannels)v=v.bgr;
    }
    v=gc_perceptual(v,c);
    if(c.contrast!=1.f||c.toe!=0.f||c.shoulder!=0.f) {
        v=.5f+(clamp(v,0.f,1.f)-.5f)*max(.05f,c.contrast);
        if(c.toe!=0.f)v+=c.toe*(1.f-v)*(.18f-.18f*v);
        if(c.shoulder!=0.f)v-=c.shoulder*v*v*.22f;
        v=clamp(v,0.f,1.f);
    }
    if(c.grainEnabled&&c.grain>0.f) {
        const float n=.72f*gc_noise(pixel.x,pixel.y,region.seed)+.28f*gc_smooth(grainCoordinates[1+pixel.x],grainCoordinates[1+region.fullWidth+pixel.y],grainCoordinates[0],region.seed+17u);
        const float lum=(.2126f*v.x+.7152f*v.y)+.0722f*v.z;
        const float delta=n*(c.grain*.035f)*(.35f+.9f*sqrt(max(0.f,lum*(1.f-.45f*lum))));
        if(c.acros||c.saturation==0.f)v=float3(clamp(clamp(lum,0.f,1.f)+delta,0.f,1.f));
        else {const float chroma=n*(c.grain*.035f)*c.chroma*.45f;v=clamp(v+delta+float3(chroma,0.f,-chroma),0.f,1.f);}
    }
    if(!all(isfinite(source)))v=float3(NAN);
    return float4(v,gain);
}
kernel void gc_ffcs_point(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
    constant GCColorRegion &region [[buffer(0)]],constant GCFFCSColor &c [[buffer(1)]],
    device const ushort *lut [[buffer(2)]],device const float *codes [[buffer(3)]],device const uint *grainCoordinates [[buffer(4)]],
    device const uint *gammaIn [[buffer(5)]],device const ushort *gammaOut [[buffer(6)]],
    device const int *gaussian [[buffer(7)]],device const int *distances [[buffer(8)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=region.outputWidth||p.y>=region.outputHeight)return;
    const uint2 source=uint2(int2(p)+int2(region.offsetX,region.offsetY));
    float4 v=gc_ffcs_pixel(input.read(source).rgb,uint2(int2(source)+int2(region.inputX,region.inputTop)),region,c,lut,codes,grainCoordinates,gammaIn,gammaOut,gaussian,distances);
    if(!all(isfinite(v))){output.write(float4(float3(NAN),1.f),p);return;}
    if(!c.reach)v=float4(gc_restore(gc_decode3(v.rgb),v.a),1.f);
    output.write(v,p);
}
kernel void gc_ffcs_horizontal(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
    constant GCColorRegion &region [[buffer(0)]],constant GCFFCSColor &c [[buffer(1)]],device const float *weights [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=region.outputWidth||p.y>=region.inputHeight)return;
    const int x=int(p.x)+region.offsetX,globalX=x+region.inputX;
    float3 sum=0.f;float total=0.f;
    for(int dx=-int(c.reach);dx<=int(c.reach);++dx) {
        const int sampleX=globalX+dx;
        if(sampleX<0||sampleX>=int(region.fullWidth))continue;
        const float weight=weights[uint(abs(dx))];
        total+=weight;sum+=input.read(uint2(uint(x+dx),p.y)).rgb*weight;
    }
    output.write(float4(sum/total,1.f),p);
}
kernel void gc_ffcs_finish(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::read> horizontal [[texture(1)]],
    texture2d<float,access::write> output [[texture(2)]],constant GCColorRegion &region [[buffer(0)]],
    constant GCFFCSColor &c [[buffer(1)]],device const float *weights [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=region.outputWidth||p.y>=region.outputHeight)return;
    const int2 at=int2(p)+int2(region.offsetX,region.offsetY);
    const int globalY=at.y+region.inputTop;
    const float4 original=input.read(uint2(at));float3 sum=0.f;float total=0.f;
    for(int dy=-int(c.reach);dy<=int(c.reach);++dy) {
        const int sampleY=globalY+dy;
        if(sampleY<0||sampleY>=int(region.fullHeight))continue;
        const float weight=weights[uint(abs(dy))];
        total+=weight;sum+=horizontal.read(uint2(p.x,uint(at.y+dy))).rgb*weight;
    }
    if(!all(isfinite(original))||!all(isfinite(sum))){output.write(float4(float3(NAN),1.f),p);return;}
    const float3 value=clamp(original.rgb+clamp(c.sharp,0.f,3.f)*.35f*(original.rgb-sum/total),0.f,1.f);
    output.write(float4(gc_restore(gc_decode3(value),original.a),1.f),p);
}

static float3 gc_bound_chroma(float3 rgb,bool soft) {
    const float y=clamp((rgb.x*.299f+rgb.y*.587f)+rgb.z*.114f,0.f,1.f);
    if(y<=0.f||y>=1.f)return float3(y);
    float radius=0.f;
    for(uint ch=0;ch<3;++ch){const float delta=rgb[ch]-y;radius=max(radius,delta>=0.f?delta/(1.f-y):-delta/y);}
    const float knee=soft?.95f:1.f;if(radius<=knee)return rgb;
    const float distance=radius-knee,bounded=soft?knee+distance/(1.f+distance/(1.f-knee)):1.f;
    return clamp(y+(rgb-y)*(bounded/radius),0.f,1.f);
}
static uint gc_quantize_unit(float value,uint scale) {
    if(value<=0.f)return 0;if(value>=1.f)return scale;
    const uint bits=as_type<uint>(value);const int shift=150-int((bits>>23)&255u);
    if(shift>63)return 0;
    const ulong product=ulong((bits&0x7fffffu)|0x800000u)*ulong(scale);
    return uint((product+(1ul<<(shift-1)))>>shift);
}
static float gc_curve(float value,constant float *x,constant float *y,uint count) {
    if(count<2)return value;
    uint i=0;while(i+2<count&&value>=x[i+1])++i;
    return y[i]+(y[i+1]-y[i])*(value-x[i])/(x[i+1]-x[i]);
}
static uint gc_truncated_code(float value) {
    if(!isfinite(value))return 0;
    const float narrowed=fmod(trunc(value),65536.f);
    return uint(narrowed<0.f?narrowed+65536.f:narrowed);
}
kernel void gc_lumix(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
    constant GCColorRegion &region [[buffer(0)]],constant GCLUMIXColor &c [[buffer(1)]],device const ushort *cube [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=region.outputWidth||p.y>=region.outputHeight)return;
    const float3 source=input.read(uint2(int2(p)+int2(region.offsetX,region.offsetY))).rgb*region.preExposure;
    if(!all(isfinite(source))){output.write(float4(float3(NAN),1.f),p);return;}
    const float gain=gc_gain(source);float3 rgb=gc_bound_chroma((source/gain)*region.backendExposure,false);
    uint3 coordinate;
    if(c.nativePipeline) {
        rgb=float3(gc_quantize_unit(rgb.x,16380),gc_quantize_unit(rgb.y,16380),gc_quantize_unit(rgb.z,16380));
        const float luma=(rgb.x*.299f+rgb.y*.587f)+rgb.z*.114f;
        const float ratio=luma==0.f?0.f:gc_curve(luma,c.preX,c.preY,c.preCount)/luma;
        coordinate=uint3(gc_truncated_code(rgb.x*ratio),gc_truncated_code(rgb.y*ratio),gc_truncated_code(rgb.z*ratio))>>2;
    } else {
        coordinate=uint3(gc_quantize_unit(rgb.x,4095),gc_quantize_unit(rgb.y,4095),gc_quantize_unit(rgb.z,4095));
    }
    const uint3 lo=min(coordinate/32,uint3(127)),f=coordinate%32;
    const uint r=f.x,g=f.y,b=f.z;
    const uint weights[8]={(32-b)*(32-g)*(32-r),b*(32-g)*(32-r),(32-b)*g*(32-r),(32-b)*(32-g)*r,b*g*(32-r),b*(32-g)*r,(32-b)*g*r,b*g*r};
    const uint offsets[8]={0,129*129,129,1,129*129+129,129*129+1,129+1,129*129+129+1};
    const uint base=(lo.z*129+lo.y)*129+lo.x;
    for(uint ch=0;ch<3;++ch) {
        uint sum=0;for(uint k=0;k<8;++k)sum+=uint(cube[(base+offsets[k])*3+ch])*weights[k];
        const uint mapped=(sum+16384u)>>15;
        rgb[ch]=c.nativePipeline?float((mapped*4u)&65535u):float(mapped)/4095.f;
    }
    const float y=(rgb.x*.299f+rgb.y*.587f)+rgb.z*.114f;
    if(y==0.f)rgb=0.f;
    else {
        const float monoScale=c.nativePipeline?16.f:4.f/4095.f;
        const float cb=c.monochrome?float(c.blueChroma)*monoScale:((rgb.x*-.1687f+rgb.y*-.3313f)+rgb.z*.5f)*float(c.saturation)*.0078125f;
        const float cr=c.monochrome?float(c.redChroma)*monoScale:((rgb.x*.5f+rgb.y*-.4187f)+rgb.z*-.0813f)*float(c.saturation)*.0078125f;
        const float tone=gc_curve(y,c.toneX,c.toneY,c.toneCount);
        const float ratio=tone/y;
        const float3 adjusted=float3(cr*1.402f+y,cr*-.71414f+(cb*-.34414f+y),cb*1.772f+y);
        if(c.nativePipeline) {
            const float3 scaled=floor(clamp(adjusted+.5f,0.f,65535.f))*ratio;
            rgb=clamp(float3(gc_truncated_code(scaled.x),gc_truncated_code(scaled.y),gc_truncated_code(scaled.z))/16380.f,0.f,1.f);
        } else {
            rgb=gc_bound_chroma(adjusted*ratio,true);
        }
    }
    rgb=gc_restore(gc_decode3(rgb),gain);if(!all(isfinite(source)))rgb=float3(NAN);
    output.write(float4(rgb,1.f),p);
}
