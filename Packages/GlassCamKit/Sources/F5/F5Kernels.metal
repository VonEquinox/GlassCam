#include <metal_stdlib>
using namespace metal;

// Integer Bayer decoding, curvature reconstruction and ordered lens operations.
struct F5Frame {
    uint4 shape, active, cfa;
    float4 scale, kappa, readSigma, low, high, gain, blackResidual;
    uint4 censorLow, censorHigh, black, tables, extras, extra2;
};
struct F5RawSample {
    float2 interval;
    float exposure, width;
    uint kind;
};
int f5mirror(int p,int n) { if(n<=1)return 0;int period=n*2;p%=period;if(p<0)p+=period;return p<n?p:period-p-1; }
float f5linear(float code,constant F5Frame &f,device const float *table) {
    if(f.tables.z==0)return code;float p=clamp(code,0.0f,float(f.tables.z-1));uint i=uint(p),j=min(i+1,f.tables.z-1);return mix(table[f.tables.y+i],table[f.tables.y+j],p-i);
}
F5RawSample f5decodeSample(uint2 p,device const ushort *raw,constant F5Frame &f,device const float *table) {
    uint2 absolute=p+f.active.xy;uint code=raw[absolute.y*f.shape.z+absolute.x];uint phase=f.cfa[(p.y&1)*2+(p.x&1)];
    float black=table[f.black.z+(p.y%f.black.x)*f.black.y+p.x%f.black.y]+f.blackResidual[phase];
    if(f.black.w!=0xffffffff)black+=table[f.black.w+p.x];if(f.tables.x!=0xffffffff)black+=table[f.tables.x+p.y];
    uint kind=code>=f.censorHigh[phase]?1:code<=f.censorLow[phase]?2:0;
    for(uint j=0;j<f.extras.z;++j)if(code/f.extra2.w==as_type<uint>(table[f.extras.y+j]))kind=3;
    uint sensorIndex=absolute.y*f.shape.x+absolute.x,lo=0,hi=f.extra2.x;
    while(lo<hi){uint mid=(lo+hi)/2;if(as_type<uint>(table[f.extras.w+mid])<sensorIndex)lo=mid+1;else hi=mid;}
    if(lo<f.extra2.x&&as_type<uint>(table[f.extras.w+lo])==sensorIndex)kind=3;
    for(uint j=0;j<f.extra2.z;++j){uint start=f.extra2.y+j*4;float4 a=float4(table[start],table[start+1],table[start+2],table[start+3]);if(absolute.y>=a.x&&absolute.x>=a.y&&absolute.y<a.z&&absolute.x<a.w)kind=3;}
    float eta=f.gain[phase];
    for(uint j=0;j<f.tables.w;++j){uint start=f.extras.x+j*16;int4 area=int4(table[start],table[start+1],table[start+2],table[start+3]);uint2 pitch=uint2(table[start+4],table[start+5]);
        if(p.x<uint(area.y)||p.y<uint(area.x)||p.x>=uint(area.w)||p.y>=uint(area.z)||(p.x-area.y)%pitch.y!=0||(p.y-area.x)%pitch.x!=0)continue;
        uint rows=uint(table[start+6]),columns=uint(table[start+7]),offset=as_type<uint>(table[start+12]);
        float2 pos=(float2(p)+0.5f)/float2(f.active.zw);pos=(pos-float2(table[start+8],table[start+9]))/float2(table[start+10],table[start+11]);pos=clamp(pos,float2(0),float2(columns-1,rows-1));uint2 q=uint2(pos);float2 a=pos-float2(q);
        uint x1=min(q.x+1,columns-1),y1=min(q.y+1,rows-1);eta/=mix(mix(table[offset+q.y*columns+q.x],table[offset+q.y*columns+x1],a.x),mix(table[offset+y1*columns+q.x],table[offset+y1*columns+x1],a.x),a.y);
    }
    if(float(code)<f.scale.z||float(code)>f.scale.w)kind=3;
    float loCode=f5linear((float(code)-0.5f)/float(f.extra2.w),f,table),hiCode=f5linear((float(code)+0.5f)/float(f.extra2.w),f,table);
    return {float2(kind==1?f.high[phase]:(loCode-black)/f.scale.y,kind==2?f.low[phase]:(hiCode-black)/f.scale.y),
        f.scale.x*eta,(hiCode-loCode)/f.scale.y,kind};
}

struct F5OutputMapping {float2 point;float gain;};
F5OutputMapping f5outputMapping(float2 point,uint channel,device const float4 *warps,uint count) {
    float gain=1;
    // Traverse the pullback in reverse list order. A gain preceding a warp is
    // evaluated at the warped position; a gain following it is evaluated here.
    // This decoder explicitly extends the linear operations to scene HDR,
    // without the unit-range clipping of a conventional DNG renderer.
    for(int i=int(count)-1;i>=0;--i){uint offset=uint(i)*8,kind=as_type<uint>(warps[offset+7].x);
      // SDK dng_filter_warp uses integer pixel positions and the image bounds
      // (r,b) for the normalized center. F5 positions include a half pixel.
      if(kind==1){float4 dimensions=warps[offset+6];float2 size=dimensions.zw,center=dimensions.xy*size;
        float radius=length(max(abs(center),abs(size-center)));float2 delta=(point-0.5f-center)/radius;float r2=dot(delta,delta);float4 kr=warps[offset+channel],kt=warps[offset+3+channel];float radial=kr.x+r2*(kr.y+r2*(kr.z+r2*kr.w));
        float2 tangential=float2(kt.x*2*delta.x*delta.y+kt.y*(r2+2*delta.x*delta.x),kt.y*2*delta.x*delta.y+kt.x*(r2+2*delta.y*delta.y));point=center+radius*(radial*delta+tangential)+0.5f;
      }else if(kind==9){float4 area=warps[offset],planes=warps[offset+1],shape=warps[offset+2],geometry=warps[offset+3];
        if(any(point<area.xy)||any(point>=area.zw)||channel<uint(planes.x)||channel>=uint(planes.x+planes.y))continue;
        uint rows=uint(planes.w),columns=uint(shape.x),nplanes=uint(planes.z),plane=min(channel,nplanes-1),start=as_type<uint>(warps[offset+4].x);
        float2 p=clamp((point/shape.yz-geometry.xy)/geometry.zw,float2(0),float2(columns-1,rows-1));uint2 q=uint2(p);float2 a=p-float2(q);
        uint x1=min(q.x+1,columns-1),y1=min(q.y+1,rows-1);device const float *values=reinterpret_cast<device const float *>(warps)+start;
        gain*=mix(mix(values[(q.y*columns+q.x)*nplanes+plane],values[(q.y*columns+x1)*nplanes+plane],a.x),
                  mix(values[(y1*columns+q.x)*nplanes+plane],values[(y1*columns+x1)*nplanes+plane],a.x),a.y);
      }else{gain=NAN;}
    }return {point,gain};
}
struct F5CurveParameters { uint4 shape; float4 policy; };
float2 f5curve_mul(float2 a,float2 b) {return float2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x);}
float2 f5curve_conj(float2 a) {return float2(a.x,-a.y);}
float2 f5curve_phase(float angle) {return float2(cos(angle),sin(angle));}
uint f5curve_reverse(uint value,uint bits) {uint r=0;for(uint i=0;i<bits;++i){r=(r<<1)|(value&1);value>>=1;}return r;}
constant float f5curve_cosine[17]={1,.995184726672f,.980785280403f,.956940335732f,.923879532511f,.881921264348f,.831469612303f,.773010453363f,
        .707106781187f,.634393284164f,.555570233020f,.471396736826f,.382683432365f,.290284677254f,.195090322016f,.098017140330f,0};
float2 f5curve_twiddle(uint k,bool inverse) {
    k%=64;uint quadrant=k/16,j=k%16;float a=f5curve_cosine[j],b=f5curve_cosine[16-j];float2 value;
    if(quadrant==0)value=float2(a,b);else if(quadrant==1)value=float2(-b,a);else if(quadrant==2)value=float2(-a,-b);else value=float2(b,-a);
    return inverse?value:float2(value.x,-value.y);
}
constant float f5curve_cosine128[33]={1,.998795456205f,.995184726672f,.989176509965f,.980785280403f,.970031253195f,.956940335732f,.941544065183f,
    .923879532511f,.903989293123f,.881921264348f,.857728610000f,.831469612303f,.803207531481f,.773010453363f,.740951125355f,
    .707106781187f,.671558954847f,.634393284164f,.595699304492f,.555570233020f,.514102744193f,.471396736826f,.427555093430f,
    .382683432365f,.336889853392f,.290284677254f,.242980179903f,.195090322016f,.146730474455f,.098017140330f,.049067674327f,0};
float2 f5curve_twiddle128(uint k) {
    k&=127;uint quadrant=k/32,j=k%32;float a=f5curve_cosine128[j],b=f5curve_cosine128[32-j];
    if(quadrant==0)return float2(a,-b);if(quadrant==1)return float2(-b,-a);
    if(quadrant==2)return float2(-a,b);return float2(b,a);
}
float2 f5curve_window(int k) {
    if(k==0)return float2(16,0);
    if(k==1)return -8.0f*f5curve_twiddle(1,true);
    if(k==-1)return -8.0f*f5curve_twiddle(1,false);
    return 0;
}
int2 f5curve_alias(uint mode,uint quadrant) {return int2(mode&1?(quadrant&1?1:-1):0,mode&2?(quadrant&2?1:-1):0);}

kernel void f5_curve_forward(device const float *samples [[buffer(0)]],device const float4 *rows [[buffer(1)]],
    device float2 *spectra [[buffer(2)]],device atomic_uint *failure [[buffer(3)]],constant F5CurveParameters &p [[buffer(4)]],uint pair [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint plane=pair*2;threadgroup float2 values[256];threadgroup float4 windows[16];
    if(tid<16){float2 a=rows[plane].xy,b=rows[plane+1].xy;float4 w=sin(M_PI_F*(2*tid+.5f+float4(a,b))/32);windows[tid]=w*w;}
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Two real CFA planes share one complex transform. Pairwise butterflies
    // compute each sum/difference once and keep the transform in shared memory.
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16;float a=samples[plane*256+i],b=samples[(plane+1)*256+i];
        if(!isfinite(a)||!isfinite(b)){atomic_fetch_or_explicit(failure,4u,memory_order_relaxed);a=isfinite(a)?a:0;b=isfinite(b)?b:0;}
        values[y*16+f5curve_reverse(x,4)]=float2(a*windows[x].x*windows[y].y,b*windows[x].z*windows[y].w);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=16;width*=2){uint span=width/2,y=tid/8,j=tid%8,x=j/span*width+j%span;
        float2 a=values[y*16+x],b=f5curve_mul(values[y*16+x+span],f5curve_twiddle((j%span)*64/width,false));
        values[y*16+x]=a+b;values[y*16+x+span]=a-b;threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16,other=f5curve_reverse(y,4);
        if(y<other){float2 value=values[i];values[i]=values[other*16+x];values[other*16+x]=value;}
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=16;width*=2){uint span=width/2,x=tid%16,j=tid/16,y=j/span*width+j%span;
        float2 a=values[y*16+x],b=f5curve_mul(values[(y+span)*16+x],f5curve_twiddle((j%span)*64/width,false));
        values[y*16+x]=a+b;values[(y+span)*16+x]=a-b;threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16;float2 a=values[i],b=f5curve_conj(values[((16-y)%16)*16+(16-x)%16]);
        spectra[plane*256+i]=(a+b)*.5f;float2 difference=a-b;
        spectra[(plane+1)*256+i]=float2(difference.y,-difference.x)*.5f;
    }
}
kernel void f5_curve_phases(device const float4 *rows [[buffer(0)]],device float2 *phases [[buffer(1)]],
    constant F5CurveParameters &p [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.shape.x*p.shape.y*48)return;uint j=i%48;float2 pos=rows[i/48].xy;float angle;
    if(j<32){uint index=j%16;int k=index<8?int(index):int(index)-16;angle=-2*M_PI_F*(j<16?pos.x:pos.y)*k/32;}
    else{uint quadrant=(j-32)/4,mode=(j-32)%4;angle=M_PI_F*dot(pos,float2(f5curve_alias(mode,quadrant)));}
    phases[i]=f5curve_phase(angle);
}
kernel void f5_curve_normals(device const float4 *rows [[buffer(0)]],device const uint *channels [[buffer(1)]],device const float2 *phases [[buffer(2)]],
    device float2 *normal [[buffer(3)]],constant F5CurveParameters &p [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.shape.x*4*48)return;uint batch=i/(4*48),quadrant=i/48%4,c=i%48/16,aa=i%16/4,bb=i%4;float2 total=0;
    for(uint r=0;r<p.shape.y;++r){uint row=batch*p.shape.y+r;if(channels[row]!=c)continue;
        float4 info=rows[row];float2 a=phases[row*48+32+quadrant*4+aa],b=phases[row*48+32+quadrant*4+bb];
        total+=f5curve_mul(f5curve_conj(a),b)*(info.w/(4*info.z));
    }normal[i]=total;
}

kernel void f5_curve_low_band(device const float2 *observations [[buffer(0)]],device const float4 *models [[buffer(1)]],
    device const uint *channels [[buffer(2)]],device const float2 *phases [[buffer(3)]],device float *low [[buffer(4)]],
    constant F5CurveParameters &p [[buffer(5)]],uint group [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint batch=group/3,channel=group%3;threadgroup float2 values[256];
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16;int kx=x<8?int(x):int(x)-16,ky=y<8?int(y):int(y)-16;
        float2 sum=0;float mass=0;
        for(uint r=0;r<p.shape.y;++r){uint row=batch*p.shape.y+r;if(channels[row]!=channel)continue;
            float weight=models[row].w;float2 correction=f5curve_mul(phases[row*48+x],phases[row*48+16+y]);
            sum+=f5curve_mul(observations[row*256+i],correction)*weight;mass+=weight;
        }
        float gaussian=exp(-2*M_PI_F*M_PI_F*.75f*.75f*float(kx*kx+ky*ky)/256);
        float2 centered=f5curve_mul(sum/max(mass,1e-20f),f5curve_twiddle(uint(kx+ky+64),true));
        values[y*16+f5curve_reverse(x,4)]=centered*gaussian;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=16;width*=2){uint span=width/2,y=tid/8,j=tid%8,x=j/span*width+j%span;
        float2 a=values[y*16+x],b=f5curve_mul(values[y*16+x+span],f5curve_twiddle((j%span)*64/width,true));
        values[y*16+x]=a+b;values[y*16+x+span]=a-b;threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16,other=f5curve_reverse(y,4);
        if(y<other){float2 value=values[i];values[i]=values[other*16+x];values[other*16+x]=value;}
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=16;width*=2){uint span=width/2,x=tid%16,j=tid/16,y=j/span*width+j%span;
        float2 a=values[y*16+x],b=f5curve_mul(values[(y+span)*16+x],f5curve_twiddle((j%span)*64/width,true));
        values[y*16+x]=a+b;values[(y+span)*16+x]=a-b;threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<256;i+=128){uint x=i%16,y=i/16;if(x<4||x>=12||y<4||y>=12)continue;
        float wx=f5curve_twiddle(2*x+1,true).y,wy=f5curve_twiddle(2*y+1,true).y;
        uint index=(batch*64+(y-4)*8+x-4)*4+channel;
        low[index]=values[i].x/(256*max(wx*wx*wy*wy,.05f));if(channel==0)low[index+3]=1;
    }
}

void f5curve_eigen(thread float *a,thread float *v) {
    for(uint i=0;i<9;++i)v[i]=i/3==i%3?1:0;
    for(uint iteration=0;iteration<24;++iteration){uint p=0,q=1;float largest=abs(a[1]);
        if(abs(a[2])>largest){p=0;q=2;largest=abs(a[2]);}if(abs(a[5])>largest){p=1;q=2;largest=abs(a[5]);}
        float scale=max(1e-30f,max(abs(a[0]),max(abs(a[4]),abs(a[8]))));if(largest<=scale*1e-7f)break;
        float off=a[p*3+q],tau=(a[q*3+q]-a[p*3+p])/(2*off);
        float t=abs(tau)>1e10f?.5f/tau:(tau>=0?1.0f:-1.0f)/(abs(tau)+precise::sqrt(1+tau*tau));
        float c=1/precise::sqrt(1+t*t),s=t*c;
        for(uint k=0;k<3;++k)if(k!=p&&k!=q){float ap=a[k*3+p],aq=a[k*3+q];
            a[k*3+p]=a[p*3+k]=c*ap-s*aq;a[k*3+q]=a[q*3+k]=s*ap+c*aq;
        }
        a[p*3+p]-=t*off;a[q*3+q]+=t*off;a[p*3+q]=a[q*3+p]=0;
        for(uint k=0;k<3;++k){float vp=v[k*3+p],vq=v[k*3+q];v[k*3+p]=c*vp-s*vq;v[k*3+q]=s*vp+c*vq;}
    }
}

kernel void f5_curve_color_prior(device const float4 *low [[buffer(0)]],device const float4 *statistics [[buffer(1)]],
    device const float4 *models [[buffer(2)]],device const uint *channels [[buffer(3)]],device float *precision [[buffer(4)]],
    device atomic_uint *failure [[buffer(5)]],constant F5CurveParameters &p [[buffer(6)]],uint batch [[thread_position_in_grid]]) {
    if(batch>=p.shape.x)return;float3 mean=0,mass=0,noise=0;float referenceNoise=0;
    for(uint i=0;i<64;++i)mean+=low[batch*64+i].xyz;mean/=64;
    float covariance[9]={0},vectors[9],projected[9];
    for(uint k=0;k<64;++k){float3 delta=low[batch*64+k].xyz-mean;
        for(uint i=0;i<3;++i)for(uint j=0;j<3;++j)covariance[i*3+j]+=delta[i]*delta[j]/64;
    }
    for(uint r=0;r<p.shape.y;++r){uint row=batch*p.shape.y+r,c=channels[row];float4 model=models[row];
        mass[c]+=model.w;noise[c]+=model.w*model.w*model.z;if(r<4)referenceNoise=max(referenceNoise,model.z);
    }
    // Mean squared magnitude of the fixed sigma=.75 Fourier low-pass on 16x16.
    float3 rawNoise=noise/max(mass*mass,float3(1e-20f))*.1411861476505366f;
    for(uint c=0;c<3;++c)covariance[c*3+c]-=rawNoise[c];
    f5curve_eigen(covariance,vectors);float3 eigen=float3(covariance[0],covariance[4],covariance[8]);
    float floor=max(1e-15f,max(rawNoise.x,max(rawNoise.y,rawNoise.z))*.01f);eigen=max(eigen,float3(floor));
    for(uint i=0;i<3;++i)for(uint j=0;j<=i;++j){float value=0;
        for(uint k=0;k<3;++k)value+=vectors[i*3+k]*eigen[k]*vectors[j*3+k];projected[i*3+j]=projected[j*3+i]=value;
    }
    float3 guideNoise=statistics[batch*2+1].xyz;
    float3 target=max(statistics[batch*2].xyz-guideNoise,guideNoise*.01f),amplitude;
    for(uint c=0;c<3;++c)amplitude[c]=precise::sqrt(target[c]/max(projected[c*3+c],1e-15f));
    for(uint i=0;i<3;++i)for(uint j=0;j<=i;++j){
        float value=.98f*projected[i*3+j]*amplitude[i]*amplitude[j]+(i==j?.02f*target[i]:0);
        covariance[i*3+j]=covariance[j*3+i]=value;
    }
    f5curve_eigen(covariance,vectors);eigen=float3(covariance[0],covariance[4],covariance[8]);
    floor=max(1e-15f,max(max(eigen.x,max(eigen.y,eigen.z))*1e-4f,referenceNoise*.01f));eigen=1/max(eigen,float3(floor));
    for(uint i=0;i<3;++i)for(uint j=0;j<=i;++j){float value=0;
        for(uint k=0;k<3;++k)value+=vectors[i*3+k]*eigen[k]*vectors[j*3+k];
        if(!isfinite(value))atomic_fetch_or_explicit(failure,2u,memory_order_relaxed);
        precision[batch*9+i*3+j]=precision[batch*9+j*3+i]=value;
    }
}
kernel void f5_curve_solve(device const float2 *observations [[buffer(0)]],device const float4 *rows [[buffer(1)]],device const uint *channels [[buffer(2)]],
    device const float2 *phases [[buffer(3)]],device const float2 *normal [[buffer(4)]],device const float4 *means [[buffer(5)]],device const float *color [[buffer(6)]],
    device float2 *spectrum [[buffer(7)]],device atomic_uint *failure [[buffer(8)]],constant F5CurveParameters &p [[buffer(9)]],uint system [[thread_position_in_grid]]) {
    if(system>=p.shape.x*256)return;uint batch=system/256,fx=system%16,fy=system/16%16;
    int kx=fx<8?int(fx):int(fx)-16,ky=fy<8?int(fy):int(fy)-16;uint quadrant=(kx<0?1:0)+(ky<0?2:0);
    bool bx=(fx==0),by=(fy==0),boundary=bx||by;
    float2 window0=f5curve_mul(f5curve_window(kx),f5curve_window(ky));float3 mean=means[batch].xyz;
    float2 right[12]={0},lower[78],work[12];float scaling[12],q[4];float2 sum[3]={float2(0),float2(0),float2(0)};float3 mass=0,noise=0;
    for(uint mode=0;mode<4;++mode){int2 kk=int2(kx,ky)+f5curve_alias(mode,quadrant)*16;
        float sx=f5curve_twiddle(uint((kk.x%64+64)%64),true).y,sy=f5curve_twiddle(uint((kk.y%64+64)%64),true).y;
        float lap=4*sx*sx+4*sy*sy;q[mode]=lap*lap+p.policy.y;
    }
    if(boundary){
        for(uint c=0;c<3;++c)for(uint a=0;a<4;++a){
            uint rowBase=(c*4+a)*(c*4+a+1)/2+c*4;
            for(uint b=0;b<=a;++b)lower[rowBase+b]=0;
        }
    }
    for(uint r=0;r<p.shape.y;++r){uint row=batch*p.shape.y+r,c=channels[row];float4 info=rows[row];
        float2 correction=f5curve_mul(phases[row*48+fx],phases[row*48+16+fy]);
        float2 measured=4*f5curve_mul(observations[row*256+fy*16+fx],correction),prediction=window0*mean[c];
        uint phaseBase=row*48+32+quadrant*4;
        float2 px=phases[phaseBase+1],py=phases[phaseBase+2];
        if(bx)px=float2(px.x,0);if(by)py=float2(py.x,0);
        float2 m[4]={float2(1,0),px,py,boundary?f5curve_mul(px,py):phases[phaseBase+3]};
        float2 residual=measured-prediction;sum[c]+=info.w*residual;mass[c]+=info.w;noise[c]+=info.w*info.w*info.z;
        float weight=info.w/(4*info.z);
        for(uint mode=0;mode<4;++mode)right[c*4+mode]+=f5curve_mul(f5curve_conj(m[mode]),residual)*weight;
        if(boundary){
            for(uint a=0;a<4;++a){
                uint rowBase=(c*4+a)*(c*4+a+1)/2+c*4;
                for(uint b=0;b<=a;++b)lower[rowBase+b]+=f5curve_mul(f5curve_conj(m[a]),m[b])*weight;
            }
        }
    }
    float power=0,variance=0;
    for(uint c=0;c<3;++c){float divisor=max(mass[c]*mass[c],1e-20f);power+=dot(sum[c],sum[c])/divisor;variance+=576*noise[c]/divisor;}
    float evidence=power/max(variance,1e-20f);q[0]*=max(p.policy.z,1/(1+max(evidence-p.policy.w,0.0f)/p.policy.w));
    for(uint i=0;i<12;++i){uint c=i/4,mode=i%4;
        float normDiag=boundary?lower[i*(i+1)/2+i].x:normal[((batch*4+quadrant)*3+c)*16+mode*4+mode].x;
        float diagonal=normDiag+p.policy.x*q[mode]*color[batch*9+c*3+c];scaling[i]=1/precise::sqrt(diagonal);
    }
    for(uint i=0;i<12;++i){for(uint j=0;j<=i;++j){float2 value=0;
        if(i/4==j/4)value=boundary?lower[i*(i+1)/2+j]:normal[((batch*4+quadrant)*3+i/4)*16+(i%4)*4+j%4];
        if(i%4==j%4)value.x+=p.policy.x*q[i%4]*color[batch*9+(i/4)*3+j/4];value*=scaling[i]*scaling[j];
        for(uint k=0;k<j;++k)value-=f5curve_mul(lower[i*(i+1)/2+k],f5curve_conj(lower[j*(j+1)/2+k]));
        if(i==j){if(!isfinite(value.x)||value.x<=0){atomic_fetch_or_explicit(failure,1u,memory_order_relaxed);return;}lower[i*(i+1)/2+j]=float2(precise::sqrt(value.x),0);}
        else lower[i*(i+1)/2+j]=value/lower[j*(j+1)/2+j].x;
    }}
    for(uint i=0;i<12;++i){float2 value=right[i]*scaling[i];for(uint j=0;j<i;++j)value-=f5curve_mul(lower[i*(i+1)/2+j],work[j]);work[i]=value/lower[i*(i+1)/2+i].x;}
    for(int i=11;i>=0;--i){float2 value=work[i];for(uint j=uint(i)+1;j<12;++j)value-=f5curve_mul(f5curve_conj(lower[j*(j+1)/2+uint(i)]),work[j]);work[i]=value/lower[uint(i)*(uint(i)+1)/2+uint(i)].x;
        int2 kk=int2(kx,ky)+f5curve_alias(uint(i)%4,quadrant)*16;uint x=uint((kk.x%32+32)%32),y=uint((kk.y%32+32)%32);
        float2 base=(uint(i)%4==0)?window0*mean[uint(i)/4]:float2(0);
        float2 result=base+work[i]*scaling[i];if(!all(isfinite(result)))atomic_fetch_or_explicit(failure,2u,memory_order_relaxed);
        spectrum[(batch*3+uint(i)/4)*1024+y*32+x]=result;
    }
}
float2 f5curve_extended(device const float2 *spectrum,uint plane,int kx,int ky,uint scale) {
    if(abs(kx)>16||abs(ky)>16)return 0;
    int x=(kx%32+32)%32,y=(ky%32+32)%32,nx=(32-x)%32,ny=(32-y)%32;
    float2 phase=scale==1?float2(1,0):f5curve_twiddle128(uint(kx+ky+128));
    float2 opposite=scale==1?float2(1,0):f5curve_twiddle128(uint(-kx-ky+128));
    float2 a=f5curve_mul(spectrum[plane*1024+y*32+x],phase);
    float2 b=f5curve_mul(spectrum[plane*1024+ny*32+nx],opposite);
    float weight=scale>1?(abs(kx)==16?.5f:1)*(abs(ky)==16?.5f:1):1;
    return (a+f5curve_conj(b))*(.5f*weight);
}
template<uint Side>
void f5curve_inverse_patch(device const float2 *spectrum,device float *output,device atomic_uint *failure,
    uint plane,uint tid,threadgroup float2 *values) {
    constexpr uint threads=Side*4,bits=Side==32?5:6,scale=Side/32;
    for(uint i=tid;i<Side*Side;i+=threads){uint x=i%Side,y=i/Side;
        int kx=x<Side/2?int(x):int(x)-int(Side),ky=y<Side/2?int(y):int(y)-int(Side);
        values[y*Side+f5curve_reverse(x,bits)]=f5curve_extended(spectrum,plane,kx,ky,scale);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=Side;width*=2){uint span=width/2;
        for(uint pair=tid;pair<Side*Side/2;pair+=threads){uint y=pair/(Side/2),j=pair%(Side/2),x=j/span*width+j%span;
            float2 a=values[y*Side+x],b=f5curve_mul(values[y*Side+x+span],f5curve_twiddle((j%span)*64/width,true));
            values[y*Side+x]=a+b;values[y*Side+x+span]=a-b;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<Side*Side;i+=threads){uint x=i%Side,y=i/Side,other=f5curve_reverse(y,bits);
        if(y<other){float2 value=values[i];values[i]=values[other*Side+x];values[other*Side+x]=value;}
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint width=2;width<=Side;width*=2){uint span=width/2;
        for(uint pair=tid;pair<Side*Side/2;pair+=threads){uint x=pair%Side,j=pair/Side,y=j/span*width+j%span;
            float2 a=values[y*Side+x],b=f5curve_mul(values[(y+span)*Side+x],f5curve_twiddle((j%span)*64/width,true));
            values[y*Side+x]=a+b;values[(y+span)*Side+x]=a-b;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=tid;i<Side*Side;i+=threads){float value=values[i].x/1024;uint index=((plane/3)*Side*Side+i)*4+plane%3;
        if(!isfinite(value))atomic_fetch_or_explicit(failure,2u,memory_order_relaxed);
        output[index]=value;if(plane%3==0)output[index+3]=1;
    }
}
kernel void f5_curve_inverse_patch_32(device const float2 *spectrum [[buffer(0)]],device float *output [[buffer(1)]],
    device atomic_uint *failure [[buffer(2)]],constant F5CurveParameters &p [[buffer(3)]],uint plane [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float2 values[1024];f5curve_inverse_patch<32>(spectrum,output,failure,plane,tid,values);
}
kernel void f5_curve_inverse_patch_64(device const float2 *spectrum [[buffer(0)]],device float *output [[buffer(1)]],
    device atomic_uint *failure [[buffer(2)]],constant F5CurveParameters &p [[buffer(3)]],uint plane [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float2 values[4096];f5curve_inverse_patch<64>(spectrum,output,failure,plane,tid,values);
}

kernel void f5_curve_accumulate(device const float4 *blocks [[buffer(0)]],device float4 *ring [[buffer(1)]],
    device atomic_uint *failure [[buffer(2)]],constant uint4 &shape [[buffer(3)]],constant int4 &placement [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint side=32*shape.z;if(i>=shape.x*side)return;int x=int(i%shape.x),localY=int(i/shape.x),y=placement.y*int(shape.z)+localY;
    if(y<0||y>=int(shape.y))return;float4 total=0;
    int stride=16*int(shape.z),base=placement.x*int(shape.z),last=(x-base)/stride;
    for(int j=max(0,last-1);j<=min(placement.z-1,last);++j){int localX=x-base-j*stride;if(localX<0||localX>=int(side))continue;
        float wx=sin(M_PI_F*(localX+.5f)/side),wy=sin(M_PI_F*(localY+.5f)/side),window=wx*wx*wy*wy;
        float3 value=blocks[(j*side+localY)*side+localX].xyz;
        total+=float4(value*window,window*window);
    }
    if(!all(isfinite(total)))atomic_fetch_or_explicit(failure,1u,memory_order_relaxed);
    ring[(uint(y)%shape.w)*shape.x+uint(x)]+=total;
}
kernel void f5_curve_normalize(device float4 *ring [[buffer(0)]],device float4 *output [[buffer(1)]],
    device atomic_uint *failure [[buffer(2)]],constant uint4 &shape [[buffer(3)]],constant uint2 &rows [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=shape.x*rows.y)return;uint index=((rows.x+i/shape.x)%shape.w)*shape.x+i%shape.x;
    float4 value=ring[index];float3 normalized=value.xyz/value.w;
    if(!(value.w>0)||!all(isfinite(normalized)))atomic_fetch_or_explicit(failure,1u,memory_order_relaxed);
    output[i]=float4(normalized,1);ring[index]=0;
}

// Bounded Bayer-to-observation preparation for the curvature estimator.
struct F5CurveSource {
    uint4 shape, grid, cfa;
    float4 alpha, beta;
    int4 rows;
};
int f5curve_reflect(int p, int n) {
    int period = 2 * n - 2; p %= period; if (p < 0) p += period; return min(p, period - p);
}
float f5curve_same_cfa(device const float *raw, int2 pixel, float2 flow, uint frame, constant F5CurveSource &p) {
    int2 phase = pixel & 1;
    float2 halfFlow = flow * 0.5f, baseFlow = floor(halfFlow), a = halfFlow - baseFlow;
    int2 q = pixel / 2 + int2(baseFlow), maximum = (int2(p.shape.xy) - 1 - phase) / 2;
    // Keep the fractional displacement separate from the large pixel index.
    if (q.x < 0) { q.x = 0; a.x = 0; } if (q.y < 0) { q.y = 0; a.y = 0; }
    if (q.x >= maximum.x) { q.x = maximum.x; a.x = 0; } if (q.y >= maximum.y) { q.y = maximum.y; a.y = 0; }
    int2 next = min(q + 1, maximum); uint base = frame * p.shape.x * p.shape.y;
    uint x0 = q.x * 2 + phase.x, x1 = next.x * 2 + phase.x, y0 = q.y * 2 + phase.y, y1 = next.y * 2 + phase.y;
    float lo = raw[base + y0 * p.shape.x + x0] * (1 - a.x) + raw[base + y0 * p.shape.x + x1] * a.x;
    float hi = raw[base + y1 * p.shape.x + x0] * (1 - a.x) + raw[base + y1 * p.shape.x + x1] * a.x;
    return lo * (1 - a.y) + hi * a.y;
}
kernel void f5_curve_temporal_rows(device const float *raw [[buffer(0)]], device const float2 *flow [[buffer(1)]],
    device const float *reliability [[buffer(2)]], device float *mosaic [[buffer(3)]], device atomic_uint *failure [[buffer(4)]],
    constant F5CurveSource &p [[buffer(5)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.shape.x * uint(p.rows.y)) return;
    int2 pixel = int2(i % p.shape.x, p.rows.x + i / p.shape.x); float total = 0, mass = 0;
    for (uint f = 0; f < p.shape.z; ++f) {
        uint tile = (f * p.grid.y + uint(pixel.y) / p.shape.w) * p.grid.x + uint(pixel.x) / p.shape.w;
        float2 shift = flow[tile]; float r = reliability[(f * (p.shape.y / 2) + pixel.y / 2) * (p.shape.x / 2) + pixel.x / 2];
        if (f == 0 && (any(shift != 0) || r != 1)) atomic_store_explicit(failure, 1, memory_order_relaxed);
        if (!all(isfinite(shift)) || any(abs(shift) > float2(p.shape.xy)) || !isfinite(r) || r < 0 || r > 1) {
            atomic_store_explicit(failure, 1, memory_order_relaxed); shift = 0; r = 0;
        }
        float value = f5curve_same_cfa(raw, pixel, shift, f, p);
        if (!isfinite(value)) { atomic_store_explicit(failure, 1, memory_order_relaxed); value = 0; }
        total += value * r; mass += r;
    }
    if (!(mass > 0)) atomic_store_explicit(failure, 1, memory_order_relaxed);
    mosaic[i] = total / max(mass, 1e-12f);
}
float f5curve_mosaic(device const float *mosaic, int2 q, constant F5CurveSource &p) {
    // Reflect around the edge sample: a two-pixel CFA period must keep its
    // colour phase when MHC reads outside the sensor rectangle.
    q = int2(f5curve_reflect(q.x, p.shape.x), f5curve_reflect(q.y, p.shape.y));
    return mosaic[(q.y - p.rows.x) * p.shape.x + q.x];
}
kernel void f5_curve_guide_rows(device const float *mosaic [[buffer(0)]], device float4 *guide [[buffer(1)]],
    constant F5CurveSource &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.shape.x * 40) return;
    int2 q = int2(i % p.shape.x, f5curve_reflect(p.rows.z - 4 + int(i / p.shape.x), p.shape.y));
    uint phase = (q.y & 1) * 2 + (q.x & 1), channel = p.cfa[phase];
    float center = f5curve_mosaic(mosaic, q, p);
    float h1 = f5curve_mosaic(mosaic, q + int2(-1,0), p) + f5curve_mosaic(mosaic, q + int2(1,0), p);
    float v1 = f5curve_mosaic(mosaic, q + int2(0,-1), p) + f5curve_mosaic(mosaic, q + int2(0,1), p);
    float h2 = f5curve_mosaic(mosaic, q + int2(-2,0), p) + f5curve_mosaic(mosaic, q + int2(2,0), p);
    float v2 = f5curve_mosaic(mosaic, q + int2(0,-2), p) + f5curve_mosaic(mosaic, q + int2(0,2), p);
    float diagonal = f5curve_mosaic(mosaic, q + int2(-1,-1), p) + f5curve_mosaic(mosaic, q + int2(1,-1), p)
                   + f5curve_mosaic(mosaic, q + int2(-1,1), p) + f5curve_mosaic(mosaic, q + int2(1,1), p);
    float3 value;
    if (channel == 1) {
        value.y = center;
        uint horizontal = p.cfa[phase ^ 1], vertical = p.cfa[phase ^ 2];
        value[horizontal] = (5 * center + 4 * h1 - h2 - diagonal + 0.5f * v2) * 0.125f;
        value[vertical] = (5 * center + 4 * v1 - v2 - diagonal + 0.5f * h2) * 0.125f;
    } else {
        value[channel] = center;
        value.y = (4 * center + 2 * (h1 + v1) - h2 - v2) * 0.125f;
        value[2 - channel] = (6 * center + 2 * diagonal - 1.5f * (h2 + v2)) * 0.125f;
    }
    guide[i] = float4(value, 0);
}
constant float f5curve_gaussian[9] = { .000133830624615f, .00443186162003f, .0539911274207f, .241971445657f,
    .398943469356f, .241971445657f, .0539911274207f, .00443186162003f, .000133830624615f };
kernel void f5_curve_gradient_horizontal(device const float4 *guide [[buffer(0)]], device float2 *horizontal [[buffer(1)]],
    constant F5CurveSource &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.shape.x * 40) return; int x = i % p.shape.x, row = i / p.shape.x; float2 value = 0;
    for (int dx = -4; dx <= 4; ++dx) {
        float3 rgb = guide[row * p.shape.x + f5curve_reflect(x + dx, p.shape.x)].xyz;
        float grey = (rgb.x + rgb.y + rgb.z) / 3;
        value += grey * f5curve_gaussian[dx + 4] * float2(1, dx);
    }
    horizontal[i] = value;
}
kernel void f5_curve_gradient_rows(device const float2 *horizontal [[buffer(0)]], device float *gradient [[buffer(1)]],
    constant F5CurveSource &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.shape.x * 32) return; int x = i % p.shape.x, row = i / p.shape.x + 4; float2 value = 0;
    for (int dy = -4; dy <= 4; ++dy) {
        float2 h = horizontal[(row + dy) * p.shape.x + x];
        value += float2(h.y, h.x * dy) * f5curve_gaussian[dy + 4];
    }
    gradient[i] = dot(value, value);
}
// Stationary MHC and grey-gradient response correlations at five CFA lags.
// Green inputs remain separate so phase-specific calibrated noise is retained.
constant float f5curve_guide_correlation[60] = {
    .5625f,.123046875f,.123046875f,.17578125f, .078125f,.3125f,.3125f,.078125f, .17578125f,.123046875f,.123046875f,.5625f,
    .09375f,-.03125f,.02734375f,-.0703125f, -.03125f,.015625f,.015625f,-.03125f, -.0703125f,.02734375f,-.03125f,.09375f,
    .09375f,.02734375f,-.03125f,-.0703125f, -.03125f,.015625f,.015625f,-.03125f, -.0703125f,-.03125f,.02734375f,.09375f,
    .015625f,0,0,.017578125f, .0078125f,0,0,.0078125f, .017578125f,0,0,.015625f,
    .015625f,0,0,.017578125f, .0078125f,0,0,.0078125f, .017578125f,0,0,.015625f };
constant float f5curve_gradient_correlation[20] = {
    .0313451340798f,.0142226881723f,.0142226881723f,.0313451340798f,
    .000658777244410f,-.000604127655538f,-.000604127655538f,.000658777244410f,
    .000658777244410f,-.000604127655538f,-.000604127655538f,.000658777244410f,
    -.00321508039558f,-.00239837636483f,-.00239837636483f,-.00321508039558f,
    -.00321508039558f,-.00239837636483f,-.00239837636483f,-.00321508039558f };
kernel void f5_curve_patch_statistics(device const float4 *guide [[buffer(0)]], device const float *gradient [[buffer(1)]],
    device const float2 *flow [[buffer(2)]], device const float *reliability [[buffer(3)]], device const int2 *origins [[buffer(4)]],
    device float4 *means [[buffer(5)]], device float4 *statistics [[buffer(6)]], device float4 *models [[buffer(7)]],
    device uint *channels [[buffer(8)]], device int2 *offsets [[buffer(9)]], device atomic_uint *failure [[buffer(10)]],
    constant F5CurveSource &p [[buffer(11)]], uint b [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    if (b >= p.grid.z) return; int2 origin = origins[b];
    threadgroup float4 scratch[128]; threadgroup float4 mean, variance;
    threadgroup float2 shifts[7]; threadgroup float3 robustness[7];
    float4 sum = 0;
    for (uint i = tid; i < 1024; i += 128) {
        int x = f5curve_reflect(origin.x + int(i % 32), p.shape.x), y = i / 32;
        sum += float4(guide[(y + 4) * p.shape.x + x].xyz, gradient[y * p.shape.x + x]);
    }
    scratch[tid] = sum; threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = 64; step; step >>= 1) { if (tid < step) scratch[tid] += scratch[tid + step]; threadgroup_barrier(mem_flags::mem_threadgroup); }
    if (tid == 0) mean = scratch[0] / 1024; threadgroup_barrier(mem_flags::mem_threadgroup);
    float3 centered = 0;
    for (uint i = tid; i < 1024; i += 128) {
        int x = f5curve_reflect(origin.x + int(i % 32), p.shape.x), y = i / 32;
        float3 d = guide[(y + 4) * p.shape.x + x].xyz - mean.xyz; centered += d * d;
    }
    scratch[tid] = float4(centered, 0); threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = 64; step; step >>= 1) { if (tid < step) scratch[tid] += scratch[tid + step]; threadgroup_barrier(mem_flags::mem_threadgroup); }
    if (tid == 0) { variance = scratch[0] / 1024; means[b] = float4(mean.xyz, 0); }
    for (uint f = 0; f < p.shape.z; ++f) {
        int2 lo = max(origin / 2, int2(0)), hi = min((origin + 32) / 2, int2(p.shape.xy) / 2), size = hi - lo;
        float mass = 0, minimum = 1;
        for (int i = tid; i < size.x * size.y; i += 128) {
            int2 q = lo + int2(i % size.x, i / size.x);
            float r = reliability[(f * (p.shape.y / 2) + q.y) * (p.shape.x / 2) + q.x];
            if (!isfinite(r) || r < 0 || r > 1) { atomic_store_explicit(failure, 1, memory_order_relaxed); r = 0; }
            mass += r; minimum = min(minimum, r);
        }
        scratch[tid] = float4(mass, minimum, 0, 0); threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint step = 64; step; step >>= 1) {
            if (tid < step) { scratch[tid].x += scratch[tid + step].x; scratch[tid].y = min(scratch[tid].y, scratch[tid + step].y); }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            int tile = p.shape.w;
            int2 start = max(int2(floor(float2(origin) / tile)), int2(0));
            int2 end = min(int2(floor(float2(origin + 32 + tile - 1) / tile)), int2(p.grid.xy));
            float2 average = 0; uint count = 0;
            for (int y = start.y; y < end.y; ++y) for (int x = start.x; x < end.x; ++x) {
                float2 v = flow[(f * p.grid.y + y) * p.grid.x + x];
                if (!all(isfinite(v)) || any(abs(v) > float2(p.shape.xy))) { atomic_store_explicit(failure, 1, memory_order_relaxed); v = 0; }
                average += v; ++count;
            }
            average /= max(count, 1u); float deviation = 0;
            for (int y = start.y; y < end.y; ++y) for (int x = start.x; x < end.x; ++x) {
                float2 d = flow[(f * p.grid.y + y) * p.grid.x + x] - average; deviation += dot(d, d);
            }
            shifts[f] = average;
            robustness[f] = float3(f == 0 ? 1.0f : scratch[0].x / max(size.x * size.y, 1), scratch[0].y, deviation / max(count, 1u));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        float4 noise; for (uint phase = 0; phase < 4; ++phase) noise[phase] = p.alpha[phase] * max(mean[p.cfa[phase]], 0.0f) + p.beta[phase];
        uint red = 0; for (uint phase = 0; phase < 4; ++phase) if (p.cfa[phase] == 0) red = phase;
        float4 canonicalNoise; for (uint phase = 0; phase < 4; ++phase) canonicalNoise[phase] = noise[phase ^ red];
        float total = 0; for (uint f = 0; f < p.shape.z; ++f) total += robustness[f].x;
        float3 guideNoise = 0; float gradientNoise = 0;
        for (uint f = 0; f < p.shape.z; ++f) {
            float2 fraction = fract(-shifts[f] * 0.5f), uv = fraction * (1 - fraction);
            float u = uv.x, v = uv.y, weights[5] = {(1-2*u)*(1-2*v),2*u*(1-2*v),2*v*(1-2*u),2*u*v,2*u*v};
            float factor = robustness[f].x * robustness[f].x / max(total * total, 1e-15f);
            for (uint lag = 0; lag < 5; ++lag) for (uint phase = 0; phase < 4; ++phase) {
                float weight = factor * weights[lag] * canonicalNoise[phase];
                for (uint c = 0; c < 3; ++c) guideNoise[c] += weight * f5curve_guide_correlation[lag * 12 + c * 4 + phase];
                gradientNoise += weight * f5curve_gradient_correlation[lag * 4 + phase];
            }
        }
        guideNoise = max(guideNoise, 1e-15f); gradientNoise = max(gradientNoise, 0.0f);
        statistics[b * 2] = float4(variance.xyz, 0); statistics[b * 2 + 1] = float4(guideNoise, 0);
        float signal = max(mean.w - gradientNoise, 0.0f), detail = signal / max(signal + gradientNoise, 1e-20f);
        float referenceNoise = (canonicalNoise.x + (canonicalNoise.y + canonicalNoise.z) * 0.5f + canonicalNoise.w) / 3;
        for (uint f = 0; f < p.shape.z; ++f) {
            float3 r = robustness[f]; float photometric = (1 - detail) * r.x + detail * r.y;
            float confidence = f == 0 ? 1.0f : photometric / (1 + r.z * signal / max(referenceNoise, 1e-15f));
            int2 offset = int2(floor(shifts[f] / 2)) * 2; float2 tau = float2(offset) - shifts[f];
            offsets[b * p.shape.z + f] = offset;
            for (uint phase = 0; phase < 4; ++phase) {
                uint row = (b * p.shape.z + f) * 4 + phase;
                models[row] = float4(tau + float2(phase & 1, phase / 2), noise[phase], confidence); channels[row] = p.cfa[phase];
            }
        }
    }
}
kernel void f5_curve_gather_planes(device const float *raw [[buffer(0)]], device const int2 *origins [[buffer(1)]],
    device const int2 *offsets [[buffer(2)]], device float *samples [[buffer(3)]], device atomic_uint *failure [[buffer(4)]],
    constant F5CurveSource &p [[buffer(5)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.grid.z * p.shape.z * 4 * 256) return;
    uint row = i / 256, index = i % 256, phase = row % 4, f = row / 4 % p.shape.z, b = row / (p.shape.z * 4);
    int2 source = origins[b] + offsets[b * p.shape.z + f] + int2((index % 16) * 2 + (phase & 1), (index / 16) * 2 + phase / 2);
    uint x = f5curve_reflect(source.x, p.shape.x), y = f5curve_reflect(source.y, p.shape.y);
    float value = raw[(f * p.shape.y + y) * p.shape.x + x];
    if (!isfinite(value)) { atomic_store_explicit(failure, 1, memory_order_relaxed); value = 0; }
    samples[i] = value;
}

kernel void f5_curve_decode_raw(device const ushort *raw [[buffer(0)]], device const float *table [[buffer(1)]],
    device float *values [[buffer(2)]], device uchar *kinds [[buffer(3)]], device atomic_uint *failure [[buffer(4)]],
    constant F5Frame &f [[buffer(5)]], constant uint &kindOffset [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    if (i >= f.active.z * f.active.w) return;
    F5RawSample event = f5decodeSample(uint2(i % f.active.z, i / f.active.z), raw, f, table);
    // Censored samples keep their delivered code center for registration and
    // guides. The separate kind byte retains the censor/repair quality flags.
    float center = event.kind == 1 ? event.interval.y - event.width * 0.5f :
                   event.kind == 2 ? event.interval.x + event.width * 0.5f : (event.interval.x + event.interval.y) * 0.5f;
    float value = center / event.exposure;
    if (!isfinite(value) || !(event.exposure > 0)) { atomic_store_explicit(failure, 1, memory_order_relaxed); value = 0; }
    values[i] = value; kinds[kindOffset + i] = uchar(event.kind);
}

struct F5CurveOutputParameters {
    uint4 shape, output, tile;
    float4 crop;
    int4 region;
    float4 color[3];
};
float3 f5curve_correct_highlight(float3 rgb, float green, float greenWhite) {
    float magenta = min(rgb.r, rgb.b) - rgb.g;
    if (greenWhite <= 0 || green <= 0.90f * greenWhite || rgb.g <= 0 || magenta <= 0) return rgb;
    float strength = smoothstep(0.90f * greenWhite, 0.98f * greenWhite, green);
    float3 recovered = rgb + float3(0, strength * magenta, 0);
    const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
    return recovered * (dot(rgb, luma) / dot(recovered, luma));
}
float2 f5curve_output_coordinate(float2 point, uint channel, device const float4 *operations,
    constant F5CurveOutputParameters &p, thread float &gain, device atomic_uint *failure) {
    F5OutputMapping mapping = f5outputMapping(point, channel, operations, p.shape.w); gain = mapping.gain;
    if (!all(isfinite(mapping.point)) || !isfinite(gain) || any(mapping.point < 0) || any(mapping.point > float2(p.shape.xy) / p.shape.z)) {
        atomic_store_explicit(failure, 1, memory_order_relaxed); return 0;
    }
    return clamp(mapping.point * p.shape.z - 0.5f, float2(0), float2(p.shape.xy - 1));
}
kernel void f5_curve_output_bounds(device const float4 *operations [[buffer(0)]], device atomic_int *bounds [[buffer(1)]],
    device atomic_uint *failure [[buffer(2)]], constant F5CurveOutputParameters &p [[buffer(3)]],
    uint i [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup int4 rectangles[128]; int2 lo = INT_MAX, hi = INT_MIN;
    if (i < p.tile.x * p.tile.y) {
        uint2 pixel = p.output.zw + uint2(i % p.tile.x, i / p.tile.x);
        float2 point = p.crop.xy + (float2(pixel) + 0.5f) / p.shape.z;
        for (uint c = 0; c < 3; ++c) {
            float gain; float2 coordinate = f5curve_output_coordinate(point, c, operations, p, gain, failure);
            int2 q = int2(floor(coordinate)); lo = min(lo, q); hi = max(hi, min(q + 1, int2(p.shape.xy) - 1));
        }
    }
    rectangles[tid] = int4(lo, hi); threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = 64; step; step >>= 1) {
        if (tid < step) { rectangles[tid].xy = min(rectangles[tid].xy, rectangles[tid + step].xy); rectangles[tid].zw = max(rectangles[tid].zw, rectangles[tid + step].zw); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        atomic_fetch_min_explicit(bounds, rectangles[0].x, memory_order_relaxed); atomic_fetch_min_explicit(bounds + 1, rectangles[0].y, memory_order_relaxed);
        atomic_fetch_max_explicit(bounds + 2, rectangles[0].z, memory_order_relaxed); atomic_fetch_max_explicit(bounds + 3, rectangles[0].w, memory_order_relaxed);
    }
}
kernel void f5_curve_output_tile(device const float4 *input [[buffer(0)]], device const float4 *operations [[buffer(1)]],
    device float4 *camera [[buffer(2)]], device float4 *linear [[buffer(3)]], device atomic_uint *failure [[buffer(4)]],
    constant F5CurveOutputParameters &p [[buffer(5)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.tile.x * p.tile.y) return;
    uint2 pixel = p.output.zw + uint2(i % p.tile.x, i / p.tile.x);
    float2 point = p.crop.xy + (float2(pixel) + 0.5f) / p.shape.z; float3 value;
    float sensorGreen = 0;
    for (uint c = 0; c < 3; ++c) {
        float gain; float2 coordinate = f5curve_output_coordinate(point, c, operations, p, gain, failure);
        int2 absolute = int2(floor(coordinate)), q = absolute - p.region.xy;
        int2 next = min(absolute + 1, int2(p.shape.xy) - 1) - p.region.xy; float2 a = coordinate - float2(absolute);
        if (any(q < 0) || any(next >= p.region.zw)) { atomic_store_explicit(failure, 1, memory_order_relaxed); value[c] = 0; continue; }
        float lo = input[q.y * p.region.z + q.x][c] * (1 - a.x) + input[q.y * p.region.z + next.x][c] * a.x;
        float hi = input[next.y * p.region.z + q.x][c] * (1 - a.x) + input[next.y * p.region.z + next.x][c] * a.x;
        float sample = lo * (1 - a.y) + hi * a.y;
        if (c == 1) sensorGreen = sample;
        value[c] = sample * gain;
    }
    float3 transformed = float3(dot(value, p.color[0].xyz), dot(value, p.color[1].xyz), dot(value, p.color[2].xyz));
    transformed = f5curve_correct_highlight(transformed, sensorGreen, p.crop.z);
    if (!all(isfinite(value)) || !all(isfinite(transformed))) atomic_store_explicit(failure, 1, memory_order_relaxed);
    uint index = (pixel.y - p.tile.z) * p.output.x + pixel.x;
    camera[index] = float4(value, 1); linear[index] = float4(transformed, 1);
}

// Registration adapted from Jamy Lafenetre (c) 2023, MIT; see vendor/handheld-sr.
// Current Bayer front end: global Fourier grayscale, coarse-to-fine local
// translation, inverse-compositional refinement and photometric reliability.
struct F5RegParameters { uint4 image, level, grid, previous; float4 control; };
struct F5RegFFT { uint4 shape, stage; };
kernel void f5_reg_fft_load(device const float *raw [[buffer(0)]], device float2 *output [[buffer(1)]],
    constant F5RegFFT &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    uint count=p.shape.x*p.shape.y; if(i<count)output[i]=float2(raw[p.shape.z*count+i],0);
}
kernel void f5_reg_fft_stage(device const float2 *input [[buffer(0)]], device float2 *output [[buffer(1)]],
    constant F5RegFFT &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if(i>=p.shape.x*p.shape.y)return;
    uint index=p.shape.z?i/p.shape.x:i%p.shape.x, line=p.shape.z?i%p.shape.x:i/p.shape.x;
    uint stride=p.shape.z?p.shape.x:1,base=p.shape.z?line:line*p.shape.x;
    uint n=p.stage.x,r=p.stage.y,k=p.stage.z,m=n/(r*k),offset=index%m,j=(index/m)%k,q=(index/m)/k;
    float angle=(p.shape.w?2.0f:-2.0f)*M_PI_F*float(j+q*k)/float(r*k);
    float2 factor=float2(cos(angle),sin(angle)),phase=float2(1,0),sum=0;
    for(uint t=0;t<r;++t) {
        float2 value=input[base+(offset+(r*j+t)*m)*stride];
        sum+=float2(value.x*phase.x-value.y*phase.y,value.x*phase.y+value.y*phase.x);
        phase=float2(phase.x*factor.x-phase.y*factor.y,phase.x*factor.y+phase.y*factor.x);
    }
    output[i]=sum;
}
kernel void f5_reg_fft_band(device float2 *data [[buffer(0)]],constant F5RegFFT &p [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.shape.x*p.shape.y)return;
    uint x=(i%p.shape.x+p.shape.x/2)%p.shape.x,y=(i/p.shape.x+p.shape.y/2)%p.shape.y;
    if(x<p.shape.x/4 || x>=p.shape.x-(p.shape.x+3)/4 || y<p.shape.y/4 || y>=p.shape.y-(p.shape.y+3)/4)data[i]=0;
}
kernel void f5_reg_gray_store(device const float2 *input [[buffer(0)]],device float *output [[buffer(1)]],
    constant F5RegParameters &p [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.level.x*p.level.y)return;uint x=i%p.level.x%p.image.x,y=i/p.level.x%p.image.y;
    output[i]=input[y*p.image.x+x].x/float(p.image.x*p.image.y);
}
kernel void f5_reg_gaussian_v(device const float *input [[buffer(0)]],device float *output [[buffer(1)]],
    constant F5RegParameters &p [[buffer(2)]],constant float *weights [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.level.z*(p.level.w-2*p.previous.y))return;uint x=i%p.level.z,y=i/p.level.z;float sum=0;
    for(uint j=0;j<=2*p.previous.y;++j)sum+=input[(y+j)*p.level.z+x]*weights[j];output[i]=sum;
}
kernel void f5_reg_gaussian_h(device const float *input [[buffer(0)]],device float *output [[buffer(1)]],
    constant F5RegParameters &p [[buffer(2)]],constant float *weights [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.level.x*p.level.y)return;uint x=i%p.level.x*p.previous.x,y=i/p.level.x*p.previous.x;float sum=0;
    for(uint j=0;j<=2*p.previous.y;++j)sum+=input[y*p.level.z+x+j]*weights[j];output[i]=sum;
}
float2 f5reg_bilinear_flow(device const float2 *input,float2 point,uint2 size) {
    point=clamp(point,float2(0),float2(size-1));uint2 q=uint2(point),next=min(q+1,size-1);float2 a=point-float2(q);
    return mix(mix(input[q.y*size.x+q.x],input[q.y*size.x+next.x],a.x),mix(input[next.y*size.x+q.x],input[next.y*size.x+next.x],a.x),a.y);
}
kernel void f5_reg_upscale(device const float2 *input [[buffer(0)]],device float2 *output [[buffer(1)]],
    constant F5RegParameters &p [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=p.grid.x*p.grid.y)return;uint2 q=uint2(i%p.grid.x,i/p.grid.x);
    output[i]=any(q>=p.previous.xy*p.previous.w)?float2(0):p.previous.z*f5reg_bilinear_flow(input,(float2(q)+0.5f)/p.previous.w-0.5f,p.previous.xy);
}
float f5reg_zero(device const float *input,int2 q,uint2 size) { return any(q<0)||any(q>=int2(size))?0:input[q.y*size.x+q.x]; }
kernel void f5_reg_block_match(device const float *reference [[buffer(0)]],device const float *moving [[buffer(1)]],
    device float2 *flow [[buffer(2)]],constant F5RegParameters &p [[buffer(3)]],uint block [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint tile=p.grid.z,radius=p.grid.w,side=tile+2*radius,localCandidates=(radius*2+1)*(radius*2+1);
    bool reconsiderZero=p.control.x==1;uint candidates=localCandidates*(reconsiderZero?2:1);
    int2 start=int2(block%p.grid.x,block/p.grid.x)*int(tile),initial=int2(rint(flow[block]));
    threadgroup float ref[256],mov[576],unshifted[576],costs[256];
    for(uint j=tid;j<tile*tile;j+=256)ref[j]=reference[(start.y+j/tile)*p.level.x+start.x+j%tile];
    for(uint j=tid;j<side*side;j+=256) {
        int2 q=start+initial+int2(j%side,j/side)-int(radius);
        if(p.control.x==1)mov[j]=f5reg_zero(moving,q,p.level.zw);
        else {q=clamp(q,int2(0),int2(p.level.zw)-1);mov[j]=moving[q.y*p.level.z+q.x];}
        if(reconsiderZero)unshifted[j]=f5reg_zero(moving,start+int2(j%side,j/side)-int(radius),p.level.zw);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float error=INFINITY;
    if(tid<candidates) {
        uint candidate=tid%localCandidates,dx=candidate%(radius*2+1),dy=candidate/(radius*2+1);error=0;
        for(uint j=0;j<tile*tile;++j){uint index=(j/tile+dy)*side+j%tile+dx;
            float d=ref[j]-(tid>=localCandidates?unshifted[index]:mov[index]);error+=p.control.x==1?abs(d):d*d;}
    }
    costs[tid]=error;threadgroup_barrier(mem_flags::mem_threadgroup);
    if(tid==0) {
        uint best=0;for(uint j=1;j<candidates;++j)if(costs[j]<costs[best])best=j;
        uint candidate=best%localCandidates;
        float2 offset=float2(int(candidate%(radius*2+1))-int(radius),int(candidate/(radius*2+1))-int(radius));
        flow[block]=(best>=localCandidates?float2(0):(p.control.x==1?float2(initial):flow[block]))+offset;
    }
}
kernel void f5_reg_ic(device const float *reference [[buffer(0)]],device const float *moving [[buffer(1)]],
    device float2 *flow [[buffer(2)]],constant F5RegParameters &p [[buffer(3)]],uint block [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint tile=p.grid.z;int2 q=int2(block%p.grid.x,block/p.grid.x)*int(tile)+int2(tid%tile,tid/tile);
    bool active=tid<tile*tile;float ref=active?reference[q.y*p.level.x+q.x]:0;float2 gradient=0;
    if(active)gradient=float2(f5reg_zero(reference,q+int2(1,0),p.level.xy)-f5reg_zero(reference,q-int2(1,0),p.level.xy),
                              f5reg_zero(reference,q+int2(0,1),p.level.xy)-f5reg_zero(reference,q-int2(0,1),p.level.xy));
    threadgroup float4 work[256];threadgroup float3 hessian;threadgroup float2 shift;threadgroup bool solvable[1];
    work[tid]=float4(gradient.x*gradient.x,gradient.x*gradient.y,gradient.y*gradient.y,0);threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint step=128;step;step>>=1){if(tid<step)work[tid]+=work[tid+step];threadgroup_barrier(mem_flags::mem_threadgroup);}
    if(tid==0){hessian=work[0].xyz;shift=flow[block];solvable[0]=abs(hessian.x*hessian.z-hessian.y*hessian.y)>=1e-10f;}
    threadgroup_barrier(mem_flags::mem_threadgroup);if(!solvable[0])return;
    for(uint iteration=0;iteration<3;++iteration) {
        float2 value=0;
        if(active) {
            float2 whole=floor(shift),a=shift-whole;int2 pos=q+int2(whole);
            float top=mix(f5reg_zero(moving,pos,p.level.zw),f5reg_zero(moving,pos+int2(1,0),p.level.zw),a.x);
            float bottom=mix(f5reg_zero(moving,pos+int2(0,1),p.level.zw),f5reg_zero(moving,pos+1,p.level.zw),a.x);
            value=-gradient*(mix(top,bottom,a.y)-ref);
        }
        work[tid]=float4(value,0,0);threadgroup_barrier(mem_flags::mem_threadgroup);
        for(uint step=128;step;step>>=1){if(tid<step)work[tid]+=work[tid+step];threadgroup_barrier(mem_flags::mem_threadgroup);}
        if(tid==0){float2 b=work[0].xy;float determinant=hessian.x*hessian.z-hessian.y*hessian.y;
            shift+=clamp(float2(hessian.z*b.x-hessian.y*b.y,hessian.x*b.y-hessian.y*b.x)/determinant,-float(p.grid.w),float(p.grid.w));}
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if(tid==0)flow[block]=all(isfinite(shift))?shift:float2(0);
}
float3 f5reg_quad(device const float *raw,int2 q,constant F5RegParameters &p) {
    q=clamp(q,int2(0),int2(p.image.xy/2)-1)*2;uint index=(p.image.z*p.image.y+q.y)*p.image.x+q.x;
    float3 sum=0;float3 count=0;
    for(uint phase=0;phase<4;++phase){uint c=p.previous[phase];sum[c]+=raw[index+(phase/2)*p.image.x+phase%2];count[c]+=1;}
    return sqrt(max(sum/count,float3(0)));
}
kernel void f5_reg_local_stats(device const float *raw [[buffer(0)]],device float4 *means [[buffer(1)]],device float4 *variances [[buffer(2)]],
    constant F5RegParameters &p [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint2 size=p.image.xy/2;if(i>=size.x*size.y)return;int2 q=int2(i%size.x,i/size.x);float3 mean=0,second=0;
    uint count=0;for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){float3 value=f5reg_quad(raw,q+int2(x,y),p);++count;
        float3 delta=value-mean;mean+=delta/count;second+=delta*(value-mean);}
    means[i]=float4(mean,0);if(p.control.w!=0)variances[i]=float4(max(second/9,float3(0)),0);
}
float f5reg_dogson(float x) { x=abs(x);return x<=.5f?1-2*x*x:x<=1.5f?x*x-2.5f*x+1.5f:0; }
kernel void f5_reg_robustness(device const float4 *referenceMean [[buffer(0)]],device const float4 *referenceVariance [[buffer(1)]],
    device const float4 *movingMean [[buffer(2)]],device const float2 *flows [[buffer(3)]],device const float4 *noise [[buffer(4)]],
    device float *output [[buffer(5)]],constant F5RegParameters &p [[buffer(6)]],uint i [[thread_position_in_grid]]) {
    uint2 size=p.image.xy/2;if(i>=size.x*size.y)return;uint2 pixel=uint2(i%size.x,i/size.x),tile=pixel/8;
    uint base=p.image.z*p.grid.x*p.grid.y;float2 shift=flows[base+tile.y*p.grid.x+tile.x];
    float2 point=float2(pixel)+shift*.5f;if(any(point<0)||any(point>=float2(size))){output[i]=0;return;}
    int2 center=int2(rint(point));float3 mean=0;float mass=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=clamp(center+int2(x,y),int2(0),int2(size)-1);
        float weight=f5reg_dogson(q.x-point.x)*f5reg_dogson(q.y-point.y);mean+=movingMean[q.y*size.x+q.x].xyz*weight;mass+=weight;}
    mean/=max(mass,1e-12f);float3 reference=referenceMean[i].xyz,d=reference-mean;
    float distance=dot(d,d),variance=dot(referenceVariance[i].xyz,float3(1));
    uint bin=uint(rint(clamp((reference.x+reference.y+reference.z)/3,0.0f,1.0f)*511));float2 floor=noise[bin].xy;
    variance=max(variance,max(floor.x,1e-15f));float shrink=distance/max(distance+floor.y,1e-20f);distance*=shrink*shrink;
    float2 low=INFINITY,high=-INFINITY;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=int2(tile)+int2(x,y);if(any(q<0)||any(q>=int2(p.grid.xy)))continue;
        float2 value=flows[base+q.y*p.grid.x+q.x];low=min(low,value);high=max(high,value);}
    float2 delta=high-low;float scale=dot(delta,delta)>.64f?2:12;
    float reliability=clamp(scale*exp(-distance/variance)-.12f,0.0f,1.0f);output[i]=isfinite(reliability)?reliability:0;
}
kernel void f5_reg_local_min(device const float *input [[buffer(0)]],device float *output [[buffer(1)]],
    constant F5RegParameters &p [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    uint2 size=p.image.xy/2;if(i>=size.x*size.y)return;int2 pixel=int2(i%size.x,i/size.x);float value=1;
    for(int y=-2;y<=2;++y)for(int x=-2;x<=2;++x){int2 q=clamp(pixel+int2(x,y),int2(0),int2(size)-1);value=min(value,input[q.y*size.x+q.x]);}
    output[p.image.z*size.x*size.y+i]=value;
}
kernel void f5_reg_identity(device float *reliability [[buffer(0)]],constant F5RegParameters &p [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    uint count=p.image.x*p.image.y/4;if(i<count*p.image.w)reliability[i]=i<count?1:0;
}
kernel void f5_reg_summary(device const float *reliability [[buffer(0)]],device const uchar *kinds [[buffer(1)]],
    device float4 *summaries [[buffer(2)]],constant F5RegParameters &p [[buffer(3)]],uint block [[threadgroup_position_in_grid]],uint tid [[thread_index_in_threadgroup]]) {
    uint tile=block%(p.grid.x*p.grid.y),f=block/(p.grid.x*p.grid.y);uint2 origin=uint2(tile%p.grid.x,tile/p.grid.x)*32;
    float4 value=0;float count=0;threadgroup float4 sums[256];threadgroup float counts[256];
    for(uint index=tid;index<1024;index+=256){uint2 q=origin+uint2(index%32,index/32);if(any(q>=p.image.xy))continue;
        uint kind=kinds[(f*p.image.y+q.y)*p.image.x+q.x];
        value+=float4(reliability[(f*(p.image.y/2)+q.y/2)*(p.image.x/2)+q.x/2],kind==1?1.0f:0.0f,kind==2?1.0f:0.0f,kind>=3?1.0f:0.0f);++count;}
    sums[tid]=value;counts[tid]=count;threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint step=128;step;step>>=1){if(tid<step){sums[tid]+=sums[tid+step];counts[tid]+=counts[tid+step];}threadgroup_barrier(mem_flags::mem_threadgroup);}
    if(tid==0)summaries[block]=sums[0]/max(counts[0],1.0f);
}

kernel void f5_curve_repair_raw(device const float *values [[buffer(0)]],device const uchar *kinds [[buffer(1)]],
    device float *output [[buffer(2)]],device atomic_uint *failure [[buffer(3)]],constant uint4 &shape [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint count=shape.x*shape.y;if(i>=count)return;uint base=shape.z*count;
    if(kinds[base+i]<3){output[i]=values[base+i];return;}
    int2 pixel=int2(i%shape.x,i/shape.x);float samples[8];uint n=0;
    for(int radius=2;radius<=8 && n==0;radius+=2) {
        for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x) {
            if(x==0 && y==0)continue;
            int2 q=pixel+int2(x,y)*radius;q=int2(f5curve_reflect(q.x,shape.x),f5curve_reflect(q.y,shape.y));
            uint source=base+q.y*shape.x+q.x;if(kinds[source]>=3)continue;samples[n++]=values[source];
        }
    }
    if(n==0){atomic_store_explicit(failure,1,memory_order_relaxed);output[i]=0;return;}
    for(uint j=1;j<n;++j){float value=samples[j];uint k=j;while(k>0 && samples[k-1]>value){samples[k]=samples[k-1];--k;}samples[k]=value;}
    output[i]=n%2?samples[n/2]:(samples[n/2-1]+samples[n/2])*.5f;
}
