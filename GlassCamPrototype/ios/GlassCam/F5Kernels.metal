#include <metal_stdlib>
using namespace metal;

// F5: unrotated input-pixel coordinates, planar signed spline coefficients.
// Only integer atomics build bins. Sorted bin indices make every floating-point
// gather deterministic; no float atomic scatter approximates an adjoint.
struct F5Frame {
    uint4 shape, active, cfa;
    float4 scale, kappa, readSigma, low, high, gain, blackResidual;
    uint4 censorLow, censorHigh, black, tables, extras, extra2;
};
struct F5Grid {
    uint4 shape; // input width,height,scale,reference frame
    uint4 core; // output coefficient x,y,width,height
    int4 field; // sampled-field origin x,y,width,height, clipped to global grid
    uint4 counts; // events, bins width,bins height, bin capacity
    int4 bin; // bin origin x,y; mesh columns,rows
    float4 objective; // N, N/M, barrier N*tau/Nz, outlier probability
    float4 regularizer; // lambdaY,lambdaC,lambdaMotion,damping
    float4 step; // alpha, mode (0=gradient,1=Q,2=candidate), direction (0=local,1=coarse), motion alpha
    uint4 options; // objective scope (0=local,1=core), coarse columns,rows, frame
};
struct F5Event {
    float4 at; // warped input x,y,exposure*eta, independent interval width
    float4 interval; // lower,upper,kappa,readSigma
    float4 score; // NLL,score,positive curvature,responsibility
    uint4 info; // RGB channel,CFA phase,frame,event kind; kind >=3 is invalid
    float4 source; // uniform code probability, original input x,y,baseline valid
    float4 frozenScore; // base-point row; candidate trials never overwrite it
};
struct F5Prior { float4 y,c1,c2,weight; };
struct F5LUT {
    uint4 layout; // lambda knots,z knots,phase stride,enabled
    float4 domain; // log1p(lambda) minimum,step,z minimum,step
    float4 width; // quantization width in normalized units by CFA phase
    float4 limits; // exact max lambda, certified Gaussian min (0 disabled), unused
};
constant float f5epsilon=1e-8f;
constant float f5log2pi=1.83787706640934548f;
// Metal omits these C special functions. Keep the cancellation-sensitive
// branches explicit and validate them against the FP64 event implementation.
float log1p(float x) {if(abs(x)<0.01f)return x*(1+x*(-0.5f+x*(1.0f/3+x*(-0.25f+x*(0.2f-x/6)))));return log(1+x);}
float expm1(float x) {if(abs(x)<0.01f)return x*(1+x*(0.5f+x*(1.0f/6+x*(1.0f/24+x*(1.0f/120+x/720)))));return exp(x)-1;}
float lgamma(float x) {float correction=0;while(x<10){correction-=log(x);x+=1;}float inv=1/x,sq=inv*inv;return correction+(x-0.5f)*log(x)-x+0.918938533204673f+inv*(1.0f/12+sq*(-1.0f/360+sq*(1.0f/1260-sq/1680)));}
int f5mirror(int p,int n) { if(n<=1)return 0;int period=n*2;p%=period;if(p<0)p+=period;return p<n?p:period-p-1; }
float f5b(float t) {t=abs(t);if(t>=2)return 0;if(t>=1){float v=2-t;return v*v*v/6;}return (4-6*t*t+3*t*t*t)/6;}
float f5db(float t) {float a=abs(t);if(a>=2||a==0)return 0;return sign(t)*(a>=1?-(2-a)*(2-a)/2:(-12*a+9*a*a)/6);}
uint f5index(int2 p,uint channel,constant F5Grid &g) {uint w=g.shape.x*g.shape.z,h=g.shape.y*g.shape.z;return (channel*h+f5mirror(p.y,h))*w+f5mirror(p.x,w);}
bool f5inCore(int2 p,constant F5Grid &g) {return all(p>=int2(g.core.xy))&&all(p<int2(g.core.xy+g.core.zw));}
uint f5localIndex(int2 p,uint c,constant F5Grid &g) {return (c*g.core.w+uint(p.y-int(g.core.y)))*g.core.z+uint(p.x-int(g.core.x));}
float f5prolong(device const float *coarse,int2 p,uint c,constant F5Grid &g) {
    uint2 q=uint2(p)/8;float2 f=float2(uint2(p)%8)/8;uint w=g.options.y,h=g.options.z;uint x=min(q.x,w-1),y=min(q.y,h-1),x1=min(x+1,w-1),y1=min(y+1,h-1);uint base=c*w*h;
    return mix(mix(coarse[base+y*w+x],coarse[base+y*w+x1],f.x),mix(coarse[base+y1*w+x],coarse[base+y1*w+x1],f.x),f.y);
}
float f5delta(device const float *direction,int2 p,uint c,constant F5Grid &g) {
    int w=g.shape.x*g.shape.z,h=g.shape.y*g.shape.z;p=int2(f5mirror(p.x,w),f5mirror(p.y,h));
    if(g.step.z==1)return f5prolong(direction,p,c,g);
    return f5inCore(p,g)?direction[f5localIndex(p,c,g)]:0;
}
float4 f5sample(device const float *x,device const float *direction,float2 point,uint c,constant F5Grid &g,bool sampleDelta=true) {
    float2 uv=point*float(g.shape.z)-0.5f;int2 first=int2(floor(uv))-1;float value=0,dx=0,dy=0,d=0;
    for(int y=0;y<4;++y)for(int xx=0;xx<4;++xx){int2 p=first+int2(xx,y);float2 t=uv-float2(p);float bx=f5b(t.x),by=f5b(t.y),coefficient=x[f5index(p,c,g)];
        if(g.step.y==2)coefficient=fma(g.step.x,f5delta(direction,p,c,g),coefficient);
        value+=coefficient*bx*by;dx+=coefficient*f5db(t.x)*by*g.shape.z;dy+=coefficient*bx*f5db(t.y)*g.shape.z;
        if(sampleDelta&&(g.step.y!=0||g.step.x!=0))d+=f5delta(direction,p,c,g)*bx*by;
    }return float4(value,dx,dy,d);
}
float f5weight(int2 coefficient,float2 point,constant F5Grid &g) {
    float2 uv=point*float(g.shape.z)-0.5f;int2 first=int2(floor(uv))-1;float2 weights=0;int2 n=int2(g.shape.xy*g.shape.z);
    for(int j=0;j<4;++j){int2 p=first+j;if(f5mirror(p.x,n.x)==coefficient.x)weights.x+=f5b(uv.x-p.x);if(f5mirror(p.y,n.y)==coefficient.y)weights.y+=f5b(uv.y-p.y);}
    return weights.x*weights.y;
}
float2 f5motion(device const float2 *nodes,device const float2 *delta,float2 p,uint frame,constant F5Grid &g,bool candidate) {
    if(frame==g.shape.w)return 0;float2 uv=clamp(p/32.0f,float2(0),float2(g.bin.zw-1));int2 q=min(int2(uv),g.bin.zw-2);float2 f=uv-float2(q);uint base=frame*g.bin.z*g.bin.w;
    uint4 i=uint4(q.y*g.bin.z+q.x,q.y*g.bin.z+q.x+1,(q.y+1)*g.bin.z+q.x,(q.y+1)*g.bin.z+q.x+1)+base;
    float4 w=float4((1-f.x)*(1-f.y),f.x*(1-f.y),(1-f.x)*f.y,f.x*f.y);float2 value=0;
    for(uint j=0;j<4;++j)value+=(candidate?fma(float2(g.step.w),delta[i[j]],nodes[i[j]]):nodes[i[j]])*w[j];return value;
}
float f5logadd(float a,float b) {if(!isfinite(a))return b;if(!isfinite(b))return a;return max(a,b)+log1p(exp(-abs(a-b)));}
float f5logcdf(float z) {
    if(z<-8){float inv=1/(z*z),sum=1,term=1;for(int k=1;k<16;++k){term*=-(2*k-1)*inv;sum+=term;}return -z*z/2-f5log2pi/2-log(-z)+log(sum);}
    float x=abs(z)*M_SQRT1_2_F,logTail;
    if(x<1){float a=x*x;float p=((((9.60497373987f*a+90.0260197204f)*a+2232.00534595f)*a+7003.32514113f)*a+55592.301301f);float q=(((((a+33.5617141648f)*a+521.35794978f)*a+4594.32382971f)*a+22629.0000614f)*a+49267.3942609f);float erf=x*p/q;return log(0.5f+(z<0?-0.5f:0.5f)*erf);}
    float p=2.46196981474e-10f;p=p*x+0.564189564831f;p=p*x+7.46321056442f;p=p*x+48.6371970986f;p=p*x+196.520832956f;p=p*x+526.445194995f;p=p*x+934.528527172f;p=p*x+1027.5518869f;p=p*x+557.535335369f;
    float q=x+13.2281951155f;q=q*x+86.7072140886f;q=q*x+354.937778888f;q=q*x+975.708501743f;q=q*x+1823.90916688f;q=q*x+2246.33760819f;q=q*x+1656.66309194f;q=q*x+557.535340818f;
    logTail=-x*x+log(0.5f*p/q);return z<0?logTail:log1p(-exp(logTail));
}
float f5logdiff(float a,float b) {return b>=a?-INFINITY:a+log(-expm1(b-a));}
float f5loginterval(float lo,float hi) {
    if(!(hi>lo))return -INFINITY;
    if(hi-lo<0.1f/max(1.0f,max(abs(hi),abs(lo)))){float z=(lo+hi)/2,width=hi-lo,w2=width*width,z2=z*z;return log(width)-z2/2-f5log2pi/2+log1p((z2-1)*w2/24+(z2*z2-6*z2+3)*w2*w2/1920);}
    return lo>0?f5logdiff(f5logcdf(-lo),f5logcdf(-hi)):f5logdiff(f5logcdf(hi),f5logcdf(lo));
}
float f5width(F5Event e) {return e.at.w>0?e.at.w:e.interval.y-e.interval.x;}
float f5logintervalCentered(float z,float width) {
    if(!(width>0))return -INFINITY;
    if(width<0.1f/max(1.0f,abs(z)+width/2)){float w2=width*width,z2=z*z;return log(width)-z2/2-f5log2pi/2+log1p((z2-1)*w2/24+(z2*z2-6*z2+3)*w2*w2/1920);}
    return f5loginterval(z-width/2,z+width/2);
}
float f5logq(F5Event e,float n) {float mu=e.interval.z*n,sigma=e.interval.w;if(e.info.w==1)return f5logcdf((mu-e.interval.x)/sigma);if(e.info.w==2)return f5logcdf((e.interval.y-mu)/sigma);return f5logintervalCentered(fma(-e.interval.z,n,(e.interval.x+e.interval.y)/2)/sigma,f5width(e)/sigma);}
float f5mills(float z) {float inv=1/(z*z),sum=1,term=1,previous=1;for(int k=1;k<24;++k){term*=-(2*k-1)*inv;if(abs(term)>=previous)break;sum+=term;previous=abs(term);}return sum;}
float f5logqRatio(F5Event e,float n) {
    float z=e.info.w==1?(e.interval.z*n-e.interval.x)/e.interval.w:(e.interval.y-e.interval.z*n)/e.interval.w;
    float delta=(e.info.w==1?1.0f:-1.0f)*e.interval.z/e.interval.w;
    if(z<-6&&z+delta<-6)return -z*delta-delta*delta/2-log1p(delta/z)+log(f5mills(z+delta)/f5mills(z));
    return f5logq(e,n+1)-f5logq(e,n);
}
float f5accurateLog1p(float t) {
    if(abs(t)>=0.25f)return log1p(t);
    float z=t/(2+t),power=z,sum=z;
    for(uint j=3;j<=15;j+=2){power*=z*z;sum+=power/float(j);}return 2*sum;
}
float f5logPoisson(float n,float mu,float k) {
    float lambda=mu/k;
    if(n<10)return -lambda+n*log(lambda)-lgamma(n+1);
    float t=fma(-k,n,mu)/(k*n),deviance;
    if(abs(t)<0.25f){float power=t*t,sum=-power/2;
        for(uint j=3;j<=16;++j){power*=t;sum+=(j%2?1.0f:-1.0f)*power/float(j);}deviance=n*sum;
    }else deviance=n*log(lambda/n)+(n-lambda);
    float inv=1/n,sq=inv*inv;
    return deviance-0.5f*log(2*M_PI_F*n)-inv*(1.0f/12+sq*(-1.0f/360+sq*(1.0f/1260-sq/1680)));
}
float f5intervalPosteriorRatio(F5Event e,uint n,float mu) {
    float t=fma(-e.interval.z,float(n+1),mu)/(e.interval.z*float(n+1));
    return f5accurateLog1p(t)+f5logq(e,float(n+1))-f5logq(e,float(n));
}
float4 f5pgInterval(F5Event e,float mu) {
    float k=e.interval.z,s=e.interval.w,lambda=mu/k;
    float radius=sqrt(72*(lambda+1))+72;
    uint high=uint(ceil(max(lambda+radius,(e.interval.y+12*s)/k)));
    if(high>200000)return float4(NAN);
    // Poisson mass times a Gaussian interval probability is log-concave.
    // Locate its posterior mode, then sum relative masses around that mode.
    // Bright RAW events therefore need tens of terms rather than scanning the
    // entire prior Poisson support and the gap to the observed code.
    uint left=0,right=high;
    while(left<right){uint mid=left+(right-left)/2;
        if(f5intervalPosteriorRatio(e,mid,mu)>0)left=mid+1;else right=mid;}
    uint mode=left;float peak=f5logPoisson(float(mode),mu,k)+f5logq(e,float(mode));
    if(!isfinite(peak))return float4(NAN);
    float total=1,m1=0,m2=0,weight=1;
    for(uint n=mode;n<high;++n){
        float ratio=exp(f5intervalPosteriorRatio(e,n,mu));weight*=ratio;
        float d=float(n+1)-float(mode);total+=weight;m1+=weight*d;m2+=weight*d*d;
        if(ratio<1 && weight*ratio/max(1e-20f,1-ratio)<1e-10f*total)break;
    }
    weight=1;
    for(int n=int(mode)-1;n>=0;--n){
        float ratio=exp(-f5intervalPosteriorRatio(e,uint(n),mu));weight*=ratio;
        float d=float(n)-float(mode);total+=weight;m1+=weight*d;m2+=weight*d*d;
        if(ratio<1 && weight*ratio/max(1e-20f,1-ratio)<1e-10f*total)break;
    }
    float offset=m1/total,mean=float(mode)+offset,variance=max(0.0f,m2/total-offset*offset);
    float score=(fma(-k,float(mode),mu)/k-offset)/mu,observed=(mean-variance)/(mu*mu);
    float logp=min(0.0f,peak+log(total)),fisher=1/(k*mu+s*s);
    return float4(-logp,score,max(1e-12f,max(fisher,observed)),exp(logp));
}
float4 f5pg(F5Event e,float mu,constant F5LUT &lut,device const float4 *table) {
    float k=e.interval.z,s=e.interval.w,lambda=mu/k,v=k*mu+s*s,standard=sqrt(v);
    float center=e.info.w==1?e.interval.x:e.info.w==2?e.interval.y:(e.interval.x+e.interval.y)/2;
    float2 uv=float2((log1p(lambda)-lut.domain.x)/lut.domain.y,((center-mu)/standard-lut.domain.z)/lut.domain.w);
    if(lut.layout.w!=0&&all(uv>=0)&&uv.x<float(lut.layout.x-1)&&uv.y<float(lut.layout.y-1)&&
       (e.info.w!=0||abs(f5width(e)-lut.width[e.info.y])<lut.width[e.info.y]*1e-4f)) {
        uint2 p=uint2(uv);float2 f=uv-float2(p);uint base=e.info.y*lut.layout.z+e.info.w*lut.layout.x*lut.layout.y;
        return mix(mix(table[base+p.x*lut.layout.y+p.y],table[base+(p.x+1)*lut.layout.y+p.y],f.x),
                   mix(table[base+p.x*lut.layout.y+p.y+1],table[base+(p.x+1)*lut.layout.y+p.y+1],f.x),f.y);
    }
    if(lut.limits.y>0&&lambda>=lut.limits.y) {
        float zl=(e.interval.x-mu)/standard,zu=(e.interval.y-mu)/standard;
        float dl=-1/standard-zl*k/(2*v),du=-1/standard-zu*k/(2*v),lp,derivative;
        if(e.info.w==1){lp=f5logcdf(-zl);derivative=-exp(-zl*zl/2-f5log2pi/2-lp)*dl;}
        else if(e.info.w==2){lp=f5logcdf(zu);derivative=exp(-zu*zu/2-f5log2pi/2-lp)*du;}
        else{float z=(center-mu)/standard,width=f5width(e)/standard;lp=f5logintervalCentered(z,width);
            if(width<0.01f/max(1.0f,abs(z))){float dz=-1/standard-z*k/(2*v),dw=-width*k/(2*v),z2=z*z,w2=width*width;
                float correction=(z2-1)*w2/24+(z2*z2-6*z2+3)*w2*w2/1920;
                float dc=(2*z*dz*w2+2*(z2-1)*width*dw)/24+((4*z*z2-12*z)*dz*w2*w2+4*(z2*z2-6*z2+3)*w2*width*dw)/1920;
                derivative=-k/(2*v)-z*dz+dc/(1+correction);
            }else{zl=z-width/2;zu=z+width/2;dl=-1/standard-zl*k/(2*v);du=-1/standard-zu*k/(2*v);derivative=exp(-zu*zu/2-f5log2pi/2-lp)*du-exp(-zl*zl/2-f5log2pi/2-lp)*dl;}}
        float complement=-expm1(min(0.0f,lp)),curvature=e.info.w==0?1/v+k*k/(2*v*v):(complement>1e-7?derivative*derivative*exp(lp)/complement:1e-12f);
        return float4(-lp,-derivative,max(1e-12f,curvature),exp(lp));
    }
    if(lambda>lut.limits.x)return float4(INFINITY,0,0,0);
    if(e.info.w==0 && lambda>1e-5f){float4 value=f5pgInterval(e,mu);if(all(isfinite(value)))return value;}
    float radius=sqrt(72*(lambda+1))+72,low=max(0.0f,floor(lambda-radius)),high=ceil(lambda+radius);
    float elo=e.info.w==2?0:e.interval.x,ehi=e.info.w==1?e.interval.x:e.interval.y;
    low=max(0.0f,min(low,floor((elo-12*s)/k)));high=max(high,ceil((ehi+12*s)/k));
    if(lambda==0){low=0;high=0;}if(high>200000)return float4(INFINITY,0,0,0);
    float lp=lambda==0?0:-lambda+low*log(lambda)-lgamma(low+1);float3 sums=-INFINITY;float peak=-INFINITY;uint peakN=uint(low);
    for(uint n=uint(low);n<=uint(high);++n){for(uint j=0;j<3;++j){float term=lp+f5logq(e,float(n+j));sums[j]=f5logadd(sums[j],term);if(j==0&&term>peak){peak=term;peakN=n;}}if(lambda>0)lp+=log(lambda)-log(float(n+1));}
    float r1=exp(sums.y-sums.x),r2=exp(sums.z-sums.x),score=(1-r1)/k,observed=(r1*r1-r2)/(k*k),positive=1/v;
    float logp=min(0.0f,sums.x),complement=-expm1(logp);
    // Ratios of nearly equal large negative log-CDF sums lose rare-tail score
    // precision in FP32. Centered posterior count moments avoid that subtraction.
    if(lambda>1e-5f&&e.info.w!=0){float total=1,m1=0,m2=0,weight=1;
        for(uint n=peakN;n<uint(high);++n){weight*=lambda/float(n+1)*exp(f5logqRatio(e,float(n)));float d=float(n+1)-float(peakN);total+=weight;m1+=weight*d;m2+=weight*d*d;if(weight<1e-16f)break;}
        weight=1;for(int n=int(peakN)-1;n>=int(low);--n){weight*=float(n+1)/lambda*exp(-f5logqRatio(e,float(n)));float d=float(n)-float(peakN);total+=weight;m1+=weight*d;m2+=weight*d*d;if(weight<1e-16f)break;}
        float offset=m1/total,mean=float(peakN)+offset,variance=m2/total-offset*offset;score=(lambda-mean)/mu;observed=(mean-variance)/(mu*mu);
        logp=min(0.0f,peak+log(total));complement=-expm1(logp);
    }
    if(e.info.w!=0)positive=complement>1e-7?score*score*exp(logp)/complement:0;
    return float4(-logp,score,max(1e-12f,max(positive,observed)),exp(logp));
}
float f5linear(float code,constant F5Frame &f,device const float *table) {
    if(f.tables.z==0)return code;float p=clamp(code,0.0f,float(f.tables.z-1));uint i=uint(p),j=min(i+1,f.tables.z-1);return mix(table[f.tables.y+i],table[f.tables.y+j],p-i);
}
F5Event f5canonical(uint2 p,uint frame,device const ushort *raw,constant F5Frame &f,device const float *table) {
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
    float count=f.scale.w-f.scale.z+1,uniform=kind==1?(f.scale.w-f.censorHigh[phase]+1)/count:kind==2?(float(f.censorLow[phase])-f.scale.z+1)/count:1/count;
    float loCode=f5linear((float(code)-0.5f)/float(f.extra2.w),f,table),hiCode=f5linear((float(code)+0.5f)/float(f.extra2.w),f,table);
    F5Event e;e.at=float4(float2(p)+0.5f,f.scale.x*eta,(hiCode-loCode)/f.scale.y);e.interval=float4(kind==1?f.high[phase]:(loCode-black)/f.scale.y,kind==2?f.low[phase]:(hiCode-black)/f.scale.y,f.kappa[phase],f.readSigma[phase]);e.info=uint4(phase==0?0:phase==3?2:1,phase,frame,kind);e.score=0;e.source=float4(uniform,float2(p)+0.5f,1);e.frozenScore=0;return e;
}

kernel void f5_clear(device float *values [[buffer(0)]],constant uint &count [[buffer(1)]],uint i [[thread_position_in_grid]]) {if(i<count)values[i]=0;}
kernel void f5_load_events(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device F5Event *events [[buffer(2)]],device const float2 *motion [[buffer(3)]],device const float2 *motionDelta [[buffer(4)]],device const uint *eligibility [[buffer(5)]],constant F5Frame &f [[buffer(6)]],constant F5Grid &g [[buffer(7)]],constant uint4 &rect [[buffer(8)]],constant uint &offset [[buffer(9)]],uint i [[thread_position_in_grid]]) {
    if(i>=rect.z*rect.w)return;uint2 p=rect.xy+uint2(i%rect.z,i/rect.z);F5Event e=f5canonical(p,g.options.w,raw,f,table);
    uint inputIndex=p.y*f.active.z+p.x;if((eligibility[inputIndex/32]&(1u<<(inputIndex%32)))==0)e.info.w=3;
    float2 before=e.at.xy+f5motion(motion,motionDelta,e.at.xy,g.options.w,g,false);
    float2 after=e.at.xy+f5motion(motion,motionDelta,e.at.xy,g.options.w,g,true);
    bool validBefore=all(before>=0)&&all(before<=float2(g.shape.xy)),validAfter=all(after>=0)&&all(after<=float2(g.shape.xy));
    e.at.xy=after;e.source.w=validBefore==validAfter?1:-1;if(!validAfter)e.info.w=5;
    int2 cell=int2(floor(after*float(g.shape.z)-0.5f));if(any(cell<g.bin.xy)||any(cell>=g.bin.xy+int2(g.counts.yz)))e.info.w=5;
    events[offset+i]=e;
}

kernel void f5_build_bins(device const F5Event *events [[buffer(0)]],device atomic_uint *counts [[buffer(1)]],device uint *entries [[buffer(2)]],device atomic_uint *failure [[buffer(3)]],constant F5Grid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.counts.x||events[i].info.w>=3)return;int2 cell=int2(floor(events[i].at.xy*float(g.shape.z)-0.5f))-g.bin.xy;uint bin=cell.y*g.counts.y+cell.x;uint slot=atomic_fetch_add_explicit(&counts[bin],1,memory_order_relaxed);if(slot>=g.counts.w){atomic_store_explicit(failure,1,memory_order_relaxed);return;}entries[bin*g.counts.w+slot]=i;
}
kernel void f5_sort_bins(device const uint *counts [[buffer(0)]],device uint *entries [[buffer(1)]],constant F5Grid &g [[buffer(2)]],uint bin [[thread_position_in_grid]]) {
    if(bin>=g.counts.y*g.counts.z)return;uint n=min(counts[bin],g.counts.w);for(uint i=1;i<n;++i){uint value=entries[bin*g.counts.w+i],j=i;while(j>0&&entries[bin*g.counts.w+j-1]>value){entries[bin*g.counts.w+j]=entries[bin*g.counts.w+j-1];--j;}entries[bin*g.counts.w+j]=value;}
}
kernel void f5_event_scores(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device F5Event *events [[buffer(2)]],constant F5Grid &g [[buffer(3)]],constant F5LUT &lut [[buffer(4)]],device const float4 *lookup [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.counts.x)return;F5Event e=events[i];if(e.source.w<0){e.score=float4(INFINITY,0,0,0);events[i]=e;return;}if(e.info.w>=3){e.score=0;events[i]=e;return;}
    float4 field=f5sample(coefficients,direction,e.at.xy,e.info.x,g);float signal=field.x;
    if(!(signal>f5epsilon)){e.score=float4(INFINITY,0,0,0);events[i]=e;return;}
    if(g.step.y==1){
        // PCG applies the already frozen positive normal operator. Re-running
        // the PG series for every direction is both unnecessary and expensive.
        if(!(e.frozenScore.z>0)||!all(isfinite(e.frozenScore))){e.score=float4(INFINITY,0,0,0);events[i]=e;return;}
        e.score=float4(e.frozenScore.x,e.frozenScore.z*field.w*e.at.z,e.frozenScore.z,e.frozenScore.w);events[i]=e;return;
    }
    float4 l=f5pg(e,signal*e.at.z,lut,lookup);if(!all(isfinite(l.xyz))){e.score=float4(INFINITY,0,0,0);events[i]=e;return;}float logIn=log1p(-g.objective.w)-l.x,logMix=f5logadd(logIn,log(g.objective.w)+log(e.source.x)),gamma=exp(logIn-logMix),gap=signal-f5epsilon;
    e.score=float4(-logMix-g.objective.z*log(gap),gamma*l.y-g.objective.z/(gap*e.at.z),max(1e-12f,gamma*l.z+g.objective.z/(gap*gap*e.at.z*e.at.z)),gamma);
    if(g.step.y==0)e.frozenScore=e.score;events[i]=e;
}

float3 f5opponent(float3 rgb) {return float3((rgb.r+rgb.g+rgb.b)*0.57735026919f,(rgb.r-rgb.b)*0.70710678119f,(rgb.r-2*rgb.g+rgb.b)*0.40824829046f);}
float3 f5rgb(float3 v) {return float3(v.x*0.57735026919f+v.y*0.70710678119f+v.z*0.40824829046f,v.x*0.57735026919f-2*v.z*0.40824829046f,v.x*0.57735026919f-v.y*0.70710678119f+v.z*0.40824829046f);}
float4 f5colorGuide(device const float4 *guide,float2 p,constant uint4 &shape,thread float &luminanceScale) {
    luminanceScale=1;if(shape.w==0)return float4(0,0,0,1);
    float2 q=clamp(p/float(shape.z),float2(0),float2(shape.xy-1));uint2 a=min(uint2(q),shape.xy-1),b=min(a+1,shape.xy-1);float2 t=q-float2(a);
    uint4 i=2*uint4(a.y*shape.x+a.x,a.y*shape.x+b.x,b.y*shape.x+a.x,b.y*shape.x+b.x);
    float4 v=mix(mix(guide[i.x],guide[i.y],t.x),mix(guide[i.z],guide[i.w],t.x),t.y);
    luminanceScale=mix(mix(guide[i.x+1].x,guide[i.y+1].x,t.x),mix(guide[i.z+1].x,guide[i.w+1].x,t.x),t.y);
    if(shape.w==3){
        float4 scale=float4(guide[i.x+1].x,guide[i.y+1].x,guide[i.z+1].x,guide[i.w+1].x);
        float4 weight=float4((1-t.x)*(1-t.y),t.x*(1-t.y),(1-t.x)*t.y,t.x*t.y);
        luminanceScale=1/dot(weight,1/max(scale,float4(1e-6f)));
    }
    return float4(normalize(max(v.xyz,float3(1e-6f))),shape.w>=2?clamp(v.w,0.0f,1.0f):1);
}
float3 f5colorTransform(float3 rgb,float3 axis) {
    if(axis.y==0)return f5opponent(rgb);
    float3 tangent=normalize(float3(axis.y,-axis.x,0)),other=cross(axis,tangent);
    return float3(dot(axis,rgb),dot(tangent,rgb),dot(other,rgb));
}
float3 f5colorTranspose(float3 v,float3 axis) {
    if(axis.y==0)return f5rgb(v);
    float3 tangent=normalize(float3(axis.y,-axis.x,0));return axis*v.x+tangent*v.y+cross(axis,tangent)*v.z;
}
kernel void f5_initialize_color_axis(device const float *coefficients [[buffer(0)]],device float4 *guide [[buffer(1)]],constant F5Grid &g [[buffer(2)]],constant uint4 &shape [[buffer(3)]],device const ushort *raw [[buffer(4)]],device const float *table [[buffer(5)]],constant F5Frame &frame [[buffer(6)]],constant float &flatPriorBoost [[buffer(7)]],constant uint &protectFineDetail [[buffer(8)]],uint i [[thread_position_in_grid]]) {
    if(i>=shape.x*shape.y)return;int2 center=int2(i%shape.x,i/shape.x)*int(shape.z);float3 value=0;
    float3 second=0,crossMoment=0,noise=0;
    // The native initializer is a known weighted linear guide before its
    // positivity clamp. Propagate the same per-CFA weights to estimate guide
    // variance, instead of comparing a smoothed guide with raw-pixel noise.
    int step=shape.w>=2?2:1;float samples=0;
    for(int y=-4;y<4;y+=step)for(int x=-4;x<4;x+=step){float3 v;samples+=1;
        for(uint c=0;c<3;++c)v[c]=max(0.0f,coefficients[f5index(center+int2(x,y),c,g)]);
        value+=v;second+=v*v;crossMoment+=v.xxy*v.yzz;
        if(shape.w>=2){float3 variance=0,mass=0;int2 p=center+int2(x,y);p=int2(f5mirror(p.x,g.shape.x),f5mirror(p.y,g.shape.y));
            for(int dy=-2;dy<=2;++dy)for(int dx=-2;dx<=2;++dx){
                uint2 q=uint2(f5mirror(p.x+dx,g.shape.x),f5mirror(p.y+dy,g.shape.y));F5Event e=f5canonical(q,0,raw,frame,table);if(e.info.w>=3)continue;
                float mu=max(0.0f,(e.interval.x+e.interval.y)/2),weight=1/(1.0f+dx*dx+dy*dy);
                variance[e.info.x]+=weight*weight*(e.interval.z*mu+e.interval.w*e.interval.w)/(e.at.z*e.at.z);mass[e.info.x]+=weight;
            }
            noise+=variance/max(mass*mass,float3(1e-20f));
        }
    }
    float3 axis=normalize(max(value,float3(1e-6f)));
    float perpendicular=max(0.0f,dot(second,float3(1))-dot(second,axis*axis)-2*dot(crossMoment,axis.xxy*axis.yzz));
    float noiseEnergy=dot(noise,1-axis*axis);
    float confidence=min(1.0f,noiseEnergy/max(1e-12f,perpendicular));confidence*=confidence;
    float luminanceEnergy=max(0.0f,dot(second,axis*axis)+2*dot(crossMoment,axis.xxy*axis.yzz)-pow(dot(value,axis),2.0f)/samples);
    float luminanceNoise=dot(noise,axis*axis),flatness=shape.w>=2?min(1.0f,luminanceNoise/max(1e-12f,luminanceEnergy)):0;
    if(protectFineDetail!=0&&shape.w>=2){
        // A smoothed guide can hide fine green texture. Check original green
        // samples before boosting flat-region regularization. Boundaries use
        // unique sensor sites so reflected copies are not independent evidence.
        float count=0,sum=0,squared=0,variance=0;
        for(int y=-4;y<4;++y)for(int x=-4;x<4;++x){
            int2 p=center+int2(x,y);if(any(p<0)||any(p>=int2(g.shape.xy)))continue;
            F5Event e=f5canonical(uint2(p),0,raw,frame,table);if(e.info.w!=0||e.info.x!=1)continue;
            float mu=(e.interval.x+e.interval.y)/2,v=mu/e.at.z;
            count+=1;sum+=v;squared+=v*v;variance+=(e.interval.z*max(0.0f,mu)+e.interval.w*e.interval.w)/(e.at.z*e.at.z);
        }
        if(count>=8){
            float energy=max(0.0f,squared-sum*sum/count),expected=variance*(1-1/count);
            float evidence=max(0.0f,energy-expected*(1+3*sqrt(2/(count-1))));
            float ratio=expected/max(1e-20f,expected+evidence);flatness=min(flatness,ratio*ratio);
        }
    }
    guide[i*2]=float4(axis,shape.w>=2?confidence:1);
    guide[i*2+1]=float4(1+(flatPriorBoost-1)*flatness,0,0,0);
}
uint f5fieldIndex(int2 p,constant F5Grid &g) {int2 n=int2(g.shape.xy*g.shape.z);p=int2(f5mirror(p.x,n.x),f5mirror(p.y,n.y));p=clamp(p,g.field.xy,g.field.xy+g.field.zw-1);return (p.y-g.field.y)*g.field.z+p.x-g.field.x;}
float3 f5fieldAt(device const float4 *field,int2 p,constant F5Grid &g) {return field[f5fieldIndex(p,g)].xyz;}
float3 f5hessian(device const float4 *field,int2 p,uint component,constant F5Grid &g) {
    float scale=float(g.shape.z*g.shape.z);
    if(component==0)return scale*(f5fieldAt(field,p+int2(-1,0),g)-2*f5fieldAt(field,p,g)+f5fieldAt(field,p+int2(1,0),g));
    if(component==2)return scale*(f5fieldAt(field,p+int2(0,-1),g)-2*f5fieldAt(field,p,g)+f5fieldAt(field,p+int2(0,1),g));
    return scale*0.35355339059f*(f5fieldAt(field,p+int2(-1,-1),g)-f5fieldAt(field,p+int2(1,-1),g)-f5fieldAt(field,p+int2(-1,1),g)+f5fieldAt(field,p+int2(1,1),g));
}
kernel void f5_sample_field(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device const float *noise [[buffer(2)]],device float4 *field [[buffer(3)]],device float4 *deltaField [[buffer(4)]],constant F5Grid &g [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(g.field.z*g.field.w))return;int2 p=g.field.xy+int2(i%g.field.z,i/g.field.z);float3 value=0,d=0;
    for(uint c=0;c<3;++c){float4 s=f5sample(coefficients,direction,(float2(p)+0.5f)/float(g.shape.z),c,g);value[c]=s.x;d[c]=s.w;}
    uint2 np=min(uint2(p)/g.shape.z,g.shape.xy-1);float sigma=max(1e-12f,noise[np.y*g.shape.x+np.x]);field[i]=float4(value,sigma);deltaField[i]=float4(d,0);
}
kernel void f5_prior_rows(device const float4 *field [[buffer(0)]],device const float4 *delta [[buffer(1)]],device F5Prior *prior [[buffer(2)]],device float *objective [[buffer(3)]],constant F5Grid &g [[buffer(4)]],device const float4 *colorGuide [[buffer(5)]],constant uint4 &colorShape [[buffer(6)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(g.field.z*g.field.w))return;int2 p=g.field.xy+int2(i%g.field.z,i/g.field.z);float sigma=field[i].w;float3 y=0,c1=0,c2=0,dy=0,dc1=0,dc2=0;
    float luminanceScale;float4 guide=f5colorGuide(colorGuide,(float2(p)+0.5f)/float(g.shape.z)-0.5f,colorShape,luminanceScale);float3 axis=guide.xyz;
    float lambdaY=g.regularizer.x*luminanceScale;
    float lambdaC=g.regularizer.x+guide.w*(g.regularizer.y-g.regularizer.x)*(1+(luminanceScale-1)*guide.w);
    for(uint j=0;j<3;++j){float3 h=f5colorTransform(f5hessian(field,p,j,g),axis);y[j]=h.x;c1[j]=h.y;c2[j]=h.z;if(g.step.y==1){float3 hd=f5colorTransform(f5hessian(delta,p,j,g),axis);dy[j]=hd.x;dc1[j]=hd.y;dc2[j]=hd.z;}}
    float ry=sqrt(1+dot(y,y)/(sigma*sigma)),rc=sqrt(1+(dot(c1,c1)+dot(c2,c2))/(sigma*sigma));
    float wy=g.objective.y*lambdaY/(sigma*sigma*ry),wc=g.objective.y*lambdaC/(sigma*sigma*rc);
    F5Prior value;value.y=float4(wy*(g.step.y==1?dy:y),axis.x);value.c1=float4(wc*(g.step.y==1?dc1:c1),axis.y);value.c2=float4(wc*(g.step.y==1?dc2:c2),axis.z);value.weight=float4(wy,wc,0,0);prior[i]=value;
    float3 gap=field[i].xyz-f5epsilon;float total=all(gap>0)?g.objective.y*(lambdaY*(ry-1)+lambdaC*(rc-1))-g.objective.z*(log(gap.x)+log(gap.y)+log(gap.z)):INFINITY;
    // Two field pixels suffice for H*B support. The third row is sampling halo,
    // so its incomplete H row must not enter a local or global objective.
    bool affected=all(p>=int2(g.core.xy)-2)&&all(p<int2(g.core.xy+g.core.zw)+2);
    objective[i]=(g.options.x==1?!f5inCore(p,g):!affected)?0:total;
}
float3 f5hweight(int2 row,int2 column,constant F5Grid &g) {
    float3 result=0;int2 n=int2(g.shape.xy*g.shape.z);
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 p=row+int2(x,y);p=int2(f5mirror(p.x,n.x),f5mirror(p.y,n.y));if(any(p!=column))continue;
        if(y==0)result.x+=x==0?-2:1;if(x==0)result.z+=y==0?-2:1;if(x!=0&&y!=0)result.y+=float(x*y)*0.35355339059f;
    }return result*float(g.shape.z*g.shape.z);
}
kernel void f5_prior_transpose(device const F5Prior *prior [[buffer(0)]],device const float4 *field [[buffer(1)]],device const float4 *delta [[buffer(2)]],device float4 *gradient [[buffer(3)]],constant F5Grid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(g.field.z*g.field.w))return;int2 p=g.field.xy+int2(i%g.field.z,i/g.field.z),n=int2(g.shape.xy*g.shape.z);float3 sum=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=p+int2(x,y);if(any(q<0)||any(q>=n)||any(q<g.field.xy)||any(q>=g.field.xy+g.field.zw))continue;float3 weights=f5hweight(q,p,g);F5Prior row=prior[f5fieldIndex(q,g)];sum+=f5colorTranspose(float3(dot(weights,row.y.xyz),dot(weights,row.c1.xyz),dot(weights,row.c2.xyz)),float3(row.y.w,row.c1.w,row.c2.w));}
    float3 gap=field[i].xyz-f5epsilon;sum+=g.step.y==1?g.objective.z*delta[i].xyz/(gap*gap):-g.objective.z/gap;gradient[i]=float4(sum,0);
}
float f5hbweight(int2 row,int2 column,uint component,constant F5Grid &g) {
    float result=0;int2 n=int2(g.shape.xy*g.shape.z);
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 sample=row+int2(x,y);sample=int2(f5mirror(sample.x,n.x),f5mirror(sample.y,n.y));float coefficient=0;
        if(component==0&&y==0)coefficient=x==0?-2:1;if(component==2&&x==0)coefficient=y==0?-2:1;if(component==1&&x!=0&&y!=0)coefficient=float(x*y)*0.35355339059f;
        if(coefficient!=0)result+=coefficient*f5weight(column,(float2(sample)+0.5f)/float(g.shape.z),g);
    }return result*float(g.shape.z*g.shape.z);
}
kernel void f5_prior_gather(device const float4 *fieldGradient [[buffer(0)]],device const F5Prior *prior [[buffer(1)]],device const float4 *field [[buffer(2)]],device const float *direction [[buffer(3)]],device float *gradient [[buffer(4)]],device float *diagonal [[buffer(5)]],constant F5Grid &g [[buffer(6)]],uint i [[thread_position_in_grid]]) {
    uint pixels=g.core.z*g.core.w;if(i>=pixels*3)return;uint c=i/pixels;int2 p=int2(g.core.xy)+int2(i%g.core.z,(i%pixels)/g.core.z),n=int2(g.shape.xy*g.shape.z);float sum=0,diag=0;
    if(g.step.y==1){
        // The Jacobi diagonal was frozen with the gradient. Q*d only needs
        // B^T times the field response; the 25 Hessian-diagonal rows are not
        // recomputed for every conjugate-gradient direction.
        for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=p+int2(x,y);if(any(q<0)||any(q>=n))continue;
            float b=f5weight(p,(float2(q)+0.5f)/float(g.shape.z),g);sum+=b*fieldGradient[f5fieldIndex(q,g)][c];}
        gradient[i]+=sum+g.regularizer.w*f5delta(direction,p,c,g);return;
    }
    for(int y=-2;y<=2;++y)for(int x=-2;x<=2;++x){int2 q=p+int2(x,y);if(any(q<0)||any(q>=n))continue;uint index=f5fieldIndex(q,g);float b=f5weight(p,(float2(q)+0.5f)/float(g.shape.z),g);
        if(b!=0){sum+=b*fieldGradient[index][c];float gap=field[index][c]-f5epsilon;diag+=b*b*g.objective.z/(gap*gap);}
        F5Prior row=prior[index];float norm=0;for(uint j=0;j<3;++j){float hb=f5hbweight(q,p,j,g);norm+=hb*hb;}
        float3 axis=float3(row.y.w,row.c1.w,row.c2.w);float luminance=axis.y==0?1.0f/3:axis[c]*axis[c];
        diag+=norm*(row.weight.x*luminance+row.weight.y*(1-luminance));
    }
    gradient[i]+=sum+(g.step.y==1?g.regularizer.w*f5delta(direction,p,c,g):0);diagonal[i]+=diag+g.regularizer.w;
}

kernel void f5_vector_init(device const float *gradient [[buffer(0)]],device const float *diag [[buffer(1)]],device float *solution [[buffer(2)]],device float *residual [[buffer(3)]],device float *z [[buffer(4)]],device float *p [[buffer(5)]],constant uint &n [[buffer(6)]],uint i [[thread_position_in_grid]]) {
    if(i>=n)return;solution[i]=0;residual[i]=-gradient[i];z[i]=residual[i]/max(1e-12f,diag[i]);p[i]=z[i];
}
kernel void f5_spline_inverse(device const float *input [[buffer(0)]],device float *output [[buffer(1)]],device float *recurrence [[buffer(2)]],constant uint4 &core [[buffer(3)]],constant uint4 &shape [[buffer(4)]],constant uint &axis [[buffer(5)]],uint line [[thread_position_in_grid]]) {
    uint length=axis==0?core.z:core.w,lines=axis==0?core.w:core.z;if(line>=lines*3)return;
    uint c=line/lines,coordinate=line%lines,stride=axis==0?1:core.z;
    uint start=c*core.z*core.w+(axis==0?coordinate*core.z:coordinate);
    bool firstBoundary=(axis==0?core.x:core.y)==0;
    bool lastBoundary=(axis==0?core.x+core.z:core.y+core.w)==(axis==0?shape.x:shape.y)*shape.z;
    float previous=0,last=0;
    for(uint j=0;j<length;++j){uint index=start+j*stride;
        float diagonal=4+(j==0&&firstBoundary?1:0)+(j==length-1&&lastBoundary?1:0);
        float inv=1/(diagonal-previous),next=(6*input[index]-last)*inv;
        previous=j+1<length?inv:0;recurrence[index]=previous;output[index]=next;last=next;
    }
    for(int j=int(length)-2;j>=0;--j){uint index=start+uint(j)*stride;output[index]-=recurrence[index]*output[index+stride];}
}
kernel void f5_vector_update(device float *solution [[buffer(0)]],device float *residual [[buffer(1)]],device float *z [[buffer(2)]],device const float *p [[buffer(3)]],device const float *q [[buffer(4)]],device const float *diag [[buffer(5)]],constant float &alpha [[buffer(6)]],constant uint &n [[buffer(7)]],uint i [[thread_position_in_grid]]) {
    if(i>=n)return;solution[i]+=alpha*p[i];residual[i]-=alpha*q[i];z[i]=residual[i]/max(1e-12f,diag[i]);
}
kernel void f5_vector_direction(device float *p [[buffer(0)]],device const float *z [[buffer(1)]],constant float &beta [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]]) {if(i<n)p[i]=z[i]+beta*p[i];}
kernel void f5_diagonal_direction(device const float *gradient [[buffer(0)]],device const float *diagonal [[buffer(1)]],device float *direction [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i<n)direction[i]=-gradient[i]/max(1e-12f,diagonal[i]);
}
kernel void f5_dot(device const float *a [[buffer(0)]],device const float *b [[buffer(1)]],device float *sums [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]],uint tid [[thread_index_in_threadgroup]],uint group [[threadgroup_position_in_grid]]) {
    threadgroup float scratch[256];scratch[tid]=i<n?a[i]*b[i]:0;threadgroup_barrier(mem_flags::mem_threadgroup);for(uint stride=128;stride>0;stride/=2){if(tid<stride)scratch[tid]+=scratch[tid+stride];threadgroup_barrier(mem_flags::mem_threadgroup);}if(tid==0)sums[group]=scratch[0];
}
kernel void f5_event_objective(device const F5Event *events [[buffer(0)]],device float *values [[buffer(1)]],constant F5Grid &g [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.counts.x)return;F5Event e=events[i];
    // A candidate cannot improve NLL by moving an observation outside the
    // field. Boundary samples at exactly width/height belong to the last tile.
    if(e.source.w<0){values[i]=INFINITY;return;}
    int2 p=clamp(int2(floor(e.at.xy*float(g.shape.z))),int2(0),int2(g.shape.xy*g.shape.z)-1);
    values[i]=g.options.x==1&&!f5inCore(p,g)?0:e.score.x;
}
kernel void f5_sum(device const float *a [[buffer(0)]],device float *sums [[buffer(1)]],constant uint &n [[buffer(2)]],uint i [[thread_position_in_grid]],uint tid [[thread_index_in_threadgroup]],uint group [[threadgroup_position_in_grid]]) {
    threadgroup float scratch[256];scratch[tid]=i<n?a[i]:0;threadgroup_barrier(mem_flags::mem_threadgroup);for(uint stride=128;stride>0;stride/=2){if(tid<stride)scratch[tid]+=scratch[tid+stride];threadgroup_barrier(mem_flags::mem_threadgroup);}if(tid==0)sums[group]=scratch[0];
}
kernel void f5_commit(device float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],constant F5Grid &g [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    uint pixels=g.core.z*g.core.w;if(i>=pixels*3)return;uint c=i/pixels;int2 p=int2(g.core.xy)+int2(i%g.core.z,(i%pixels)/g.core.z);uint index=f5index(p,c,g);coefficients[index]=fma(g.step.x,f5delta(direction,p,c,g),coefficients[index]);
}
kernel void f5_coarse_transpose(device const float *fine [[buffer(0)]],device float *coarse [[buffer(1)]],constant F5Grid &g [[buffer(2)]],constant uint &diagonalMode [[buffer(3)]],constant uint4 &rect [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint cw=g.options.y,ch=g.options.z,pixels=rect.z*rect.w;if(i>=pixels*3)return;uint c=i/pixels;uint2 cell=rect.xy+uint2(i%rect.z,(i%pixels)/rect.z);int2 p=int2(cell)*8;float sum=0;
    int2 lo=max(p-7,int2(g.core.xy)),hi=min(p+8,int2(g.core.xy+g.core.zw));
    for(int y=lo.y;y<hi.y;++y)for(int x=lo.x;x<hi.x;++x){float weight=(1-abs(float(x-p.x))/8)*(1-abs(float(y-p.y))/8);if(diagonalMode)weight*=weight;sum+=weight*fine[f5localIndex(int2(x,y),c,g)];}coarse[(c*ch+cell.y)*cw+cell.x]+=sum;
}
kernel void f5_event_count(device const F5Event *events [[buffer(0)]],device float *values [[buffer(1)]],constant F5Grid &g [[buffer(2)]],uint i [[thread_position_in_grid]]) {if(i<g.counts.x){int2 owner=clamp(int2(floor(events[i].at.xy*float(g.shape.z))),int2(0),int2(g.shape.xy*g.shape.z)-1);values[i]=events[i].info.w<3&&f5inCore(owner,g)?1:0;}}

kernel void f5_guide(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device float4 *guide [[buffer(2)]],constant F5Frame &frame [[buffer(3)]],constant uint4 &shape [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=shape.x*shape.y)return;uint2 start=uint2(i%shape.x,i/shape.x)*shape.z;float sum=0,variance=0,valid=0,total=0;
    for(uint y=start.y;y<min(start.y+shape.z,frame.active.w);++y)for(uint x=start.x;x<min(start.x+shape.z,frame.active.z);++x){F5Event e=f5canonical(uint2(x,y),0,raw,frame,table);total+=1;if(e.info.w!=0)continue;float signal=(e.interval.x+e.interval.y)/2,v=e.interval.z*max(0.0f,signal)+e.interval.w*e.interval.w;if(signal<3*sqrt(v)||signal>frame.high[e.info.y]-3*sqrt(v))continue;sum+=signal/e.at.z;variance+=v/(e.at.z*e.at.z);valid+=1;}
    guide[i]=float4(valid>0?sum/valid:0,valid>0?variance/(valid*valid):0,total>0?valid/total:0,total);
}
kernel void f5_initialize_native(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device float *coefficients [[buffer(2)]],device float *noise [[buffer(3)]],constant F5Frame &frame [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint w=frame.active.z,h=frame.active.w,pixels=w*h;if(i>=pixels)return;int2 p=int2(i%w,i/w);float3 sum=0,weight=0;float variance=0;
    for(int y=-2;y<=2;++y)for(int x=-2;x<=2;++x){uint2 q=uint2(f5mirror(p.x+x,w),f5mirror(p.y+y,h));F5Event e=f5canonical(q,0,raw,frame,table);if(e.info.w>=3)continue;float value=e.info.w==1?e.interval.x:e.info.w==2?0:(e.interval.x+e.interval.y)/2;float k=1/(1.0f+x*x+y*y);sum[e.info.x]+=k*max(1e-6f,value/e.at.z);weight[e.info.x]+=k;variance=max(variance,e.interval.w/e.at.z);}
    for(uint c=0;c<3;++c)coefficients[c*pixels+i]=weight[c]>0?max(1e-6f,sum[c]/weight[c]):0.18f;noise[i]=max(1e-6f,variance);
}
kernel void f5_initialize_cardinal_samples(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device float *samples [[buffer(2)]],constant F5Frame &frame [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint w=frame.active.z,h=frame.active.w,pixels=w*h;if(i>=pixels)return;int2 p=int2(i%w,i/w);float3 total=0,mass=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
        uint2 q=uint2(f5mirror(p.x+x,w),f5mirror(p.y+y,h));F5Event e=f5canonical(q,0,raw,frame,table);if(e.info.w>=3)continue;
        float value=e.info.w==1?e.interval.x:e.info.w==2?0:(e.interval.x+e.interval.y)/2;
        float weight=float((x==0?2:1)*(y==0?2:1));total[e.info.x]+=weight*value/e.at.z;mass[e.info.x]+=weight;
    }
    F5Event observed=f5canonical(uint2(p),0,raw,frame,table);
    for(uint c=0;c<3;++c){
        float sample=mass[c]>0?max(1e-6f,total[c]/mass[c]):0.18f;
        // The two green sublattices have same-color diagonal neighbors. They
        // must not average away an observed green site during initialization.
        if(observed.info.w<3&&observed.info.x==c){float v=observed.info.w==1?observed.interval.x:observed.info.w==2?0:(observed.interval.x+observed.interval.y)/2;sample=max(1e-6f,v/observed.at.z);}
        samples[c*pixels+i]=sample;
    }
}
kernel void f5_initializer_direction(device float *candidate [[buffer(0)]],device const float *coefficients [[buffer(1)]],constant uint &n [[buffer(2)]],uint i [[thread_position_in_grid]]) {if(i<n)candidate[i]-=coefficients[i];}
// Optional 5x5 gradient-corrected linear initializer (Malvar, He, Cutler 2004).
// This changes an initial RGB estimate only, never the retained RAW events.
kernel void f5_initialize_detail_samples(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device float *samples [[buffer(2)]],constant F5Frame &frame [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint w=frame.active.z,h=frame.active.w,pixels=w*h;if(i>=pixels)return;int2 p=int2(i%w,i/w);float v[25];
    for(int y=-2;y<=2;++y)for(int x=-2;x<=2;++x){
        uint2 q=uint2(f5mirror(p.x+x,w),f5mirror(p.y+y,h));F5Event e=f5canonical(q,0,raw,frame,table);
        if(e.info.w!=0)return;v[(y+2)*5+x+2]=(e.interval.x+e.interval.y)/(2*e.at.z);
    }
    float center=v[12],horizontal=v[11]+v[13],vertical=v[7]+v[17],horizontal2=v[10]+v[14],vertical2=v[2]+v[22],diagonal=v[6]+v[8]+v[16]+v[18];
    uint phase=frame.cfa[(p.y&1)*2+(p.x&1)],observed=phase==0?0:phase==3?2:1;
    float3 result=0;result[observed]=center;
    if(observed!=1){
        result[1]=(4*center+2*(horizontal+vertical)-horizontal2-vertical2)/8;
        result[2-observed]=(6*center+2*diagonal-1.5f*(horizontal2+vertical2))/8;
    }else{
        uint horizontalPhase=frame.cfa[(p.y&1)*2+((p.x+1)&1)],horizontalColor=horizontalPhase==0?0:2;
        result[horizontalColor]=(5*center+4*horizontal-horizontal2-diagonal+0.5f*vertical2)/8;
        result[2-horizontalColor]=(5*center+4*vertical-vertical2-diagonal+0.5f*horizontal2)/8;
    }
    for(uint c=0;c<3;++c)samples[c*pixels+i]=max(1e-6f,result[c]);
}
kernel void f5_initialize_high(device const float *native [[buffer(0)]],device float *high [[buffer(1)]],device const float *dummy [[buffer(2)]],constant F5Grid &grid [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint pixels=grid.shape.x*grid.shape.y*4;if(i>=pixels*3)return;uint c=i/pixels,w=grid.shape.x*2;float2 p=float2(i%w,(i%pixels)/w)*0.5f+0.25f;
    high[i]=max(1e-6f,f5sample(native,dummy,p,c,grid).x);
}
kernel void f5_positive_limits(device const float4 *field [[buffer(0)]],device const float4 *delta [[buffer(1)]],device float *limits [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=n)return;float value=1;for(uint c=0;c<3;++c)if(delta[i][c]<0)value=min(value,0.99f*(field[i][c]-f5epsilon)/(-delta[i][c]));limits[i]=max(0.0f,value);
}
kernel void f5_event_limits(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device const F5Event *events [[buffer(2)]],device float *limits [[buffer(3)]],constant F5Grid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.counts.x)return;F5Event e=events[i];if(e.info.w>=3){limits[i]=1;return;}float4 field=f5sample(coefficients,direction,e.at.xy,e.info.x,g);limits[i]=field.w<0?max(0.0f,min(1.0f,0.99f*(field.x-f5epsilon)/(-field.w))):1;
}
float f5constraintMetric(float2 point,uint c,device const float *diagonal,constant F5Grid &g) {
    int2 first=int2(floor(point*float(g.shape.z)-0.5f))-1,n=int2(g.shape.xy*g.shape.z);float metric=0;
    for(int y=0;y<4;++y)for(int x=0;x<4;++x){
        int2 p=first+int2(x,y);p=int2(f5mirror(p.x,n.x),f5mirror(p.y,n.y));
        if(!f5inCore(p,g))continue;bool duplicate=false;
        for(int yy=0;yy<=y;++yy)for(int xx=0;xx<4;++xx){if(yy==y&&xx>=x)break;
            int2 q=first+int2(xx,yy);q=int2(f5mirror(q.x,n.x),f5mirror(q.y,n.y));if(all(q==p))duplicate=true;}
        if(duplicate)continue;float b=f5weight(p,point,g);metric+=b*b/max(1e-30f,diagonal[f5localIndex(p,c,g)]);
    }return metric;
}
kernel void f5_step_limit_initialize(device uint *limits [[buffer(0)]],constant uint &count [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i<count)limits[i]=as_type<uint>(1.0f);
}
kernel void f5_step_limit_physical(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device const F5Event *events [[buffer(2)]],device atomic_uint *limits [[buffer(3)]],constant F5Grid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint fields=uint(g.field.z*g.field.w);if(i>=fields*3+g.counts.x)return;float2 point;uint channel;
    if(i<fields*3){uint index=i%fields;channel=i/fields;point=(float2(g.field.xy+int2(index%g.field.z,index/g.field.z))+0.5f)/float(g.shape.z);}
    else {F5Event e=events[i-fields*3];if(e.info.w>=3)return;point=e.at.xy;channel=e.info.x;}
    int2 first=int2(floor(point*float(g.shape.z)-0.5f))-1;float2 uv=point*float(g.shape.z)-0.5f;
    float current=0,positive=0,negative=0;
    for(int y=0;y<4;++y)for(int x=0;x<4;++x){int2 p=first+int2(x,y);float2 t=uv-float2(p);float b=f5b(t.x)*f5b(t.y),d=b*f5delta(direction,p,channel,g);
        current+=b*coefficients[f5index(p,channel,g)];if(d>=0)positive+=d;else negative-=d;
    }
    float gap=current-f5epsilon;if(!(gap>0)||negative<=positive+0.9f*gap)return;
    uint factor=as_type<uint>(clamp((positive+0.9f*gap)/negative,0.0f,1.0f));int2 n=int2(g.shape.xy*g.shape.z);
    for(int y=0;y<4;++y)for(int x=0;x<4;++x){int2 p=first+int2(x,y);float2 t=uv-float2(p);float b=f5b(t.x)*f5b(t.y);
        p=int2(f5mirror(p.x,n.x),f5mirror(p.y,n.y));if(!f5inCore(p,g)||b<=0)continue;uint index=f5localIndex(p,channel,g);
        if(direction[index]<0)atomic_fetch_min_explicit(&limits[index],factor,memory_order_relaxed);
    }
}
kernel void f5_step_limit_apply(device float *direction [[buffer(0)]],device const uint *limits [[buffer(1)]],constant uint &count [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i<count&&direction[i]<0)direction[i]*=as_type<float>(limits[i]);
}
kernel void f5_update_field_guard(device const float4 *field [[buffer(0)]],device const float4 *delta [[buffer(1)]],device const float *diagonal [[buffer(2)]],device float4 *guard [[buffer(3)]],constant F5Grid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(g.field.z*g.field.w))return;int2 p=g.field.xy+int2(i%g.field.z,i/g.field.z);float4 added=0;
    for(uint c=0;c<3;++c){float gap=field[i][c]-f5epsilon,d=delta[i][c];if(!(gap>0&&d < -0.5f*gap))continue;
        float metric=f5constraintMetric((float2(p)+0.5f)/float(g.shape.z),c,diagonal,g);
        if(metric>0)added[c]=min(1e12f,(-2*d/gap-1)/metric);
    }guard[i]+=added;
}
kernel void f5_update_event_guard(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device const F5Event *events [[buffer(2)]],device const float *diagonal [[buffer(3)]],device float *guard [[buffer(4)]],constant F5Grid &g [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.counts.x)return;F5Event e=events[i];if(e.info.w>=3)return;float4 f=f5sample(coefficients,direction,e.at.xy,e.info.x,g);float gap=f.x-f5epsilon;
    if(!(gap>0&&f.w < -0.5f*gap))return;float metric=f5constraintMetric(e.at.xy,e.info.x,diagonal,g);
    if(metric>0)guard[i]+=min(1e12f,(-2*f.w/gap-1)/metric);
}
kernel void f5_guard_gather(device const F5Event *events [[buffer(0)]],device const uint *counts [[buffer(1)]],device const uint *entries [[buffer(2)]],device const float4 *field [[buffer(3)]],device const float4 *delta [[buffer(4)]],device const float4 *fieldGuard [[buffer(5)]],device const float *eventGuard [[buffer(6)]],device float *normal [[buffer(7)]],device float *diagonal [[buffer(8)]],constant F5Grid &g [[buffer(9)]],uint i [[thread_position_in_grid]]) {
    uint pixels=g.core.z*g.core.w;if(i>=pixels*3)return;uint c=i/pixels;int2 p=int2(g.core.xy)+int2(i%g.core.z,(i%pixels)/g.core.z),n=int2(g.shape.xy*g.shape.z);float sum=0,diag=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=p+int2(x,y);if(any(q<0)||any(q>=n))continue;
        uint index=f5fieldIndex(q,g);float b=f5weight(p,(float2(q)+0.5f)/float(g.shape.z),g),weight=fieldGuard[index][c];
        diag+=b*b*weight;if(g.step.y==1)sum+=b*weight*delta[index][c];
    }
    for(int y=-2;y<=1;++y)for(int x=-2;x<=1;++x){int2 cell=p+int2(x,y)-g.bin.xy;if(any(cell<0)||any(cell>=int2(g.counts.yz)))continue;uint bin=cell.y*g.counts.y+cell.x;
        for(uint j=0;j<min(counts[bin],g.counts.w);++j){uint index=entries[bin*g.counts.w+j];F5Event e=events[index];if(e.info.x!=c)continue;
            float b=f5weight(p,e.at.xy,g),weight=eventGuard[index];diag+=b*b*weight;
            if(g.step.y==1&&weight>0)sum+=b*weight*e.score.y/(e.frozenScore.z*e.at.z);
        }
    }
    if(g.step.y==1)normal[i]+=sum;else diagonal[i]+=diag;
}
kernel void f5_extreme(device const float *values [[buffer(0)]],device float *sums [[buffer(1)]],constant uint &n [[buffer(2)]],constant uint &takeMaximum [[buffer(3)]],uint i [[thread_position_in_grid]],uint tid [[thread_index_in_threadgroup]],uint group [[threadgroup_position_in_grid]]) {
    threadgroup float scratch[256];scratch[tid]=i<n?values[i]:(takeMaximum?0:1);threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint stride=128;stride>0;stride/=2){if(tid<stride)scratch[tid]=takeMaximum?max(scratch[tid],scratch[tid+stride]):min(scratch[tid],scratch[tid+stride]);threadgroup_barrier(mem_flags::mem_threadgroup);}if(tid==0)sums[group]=scratch[0];
}
kernel void f5_gradient_metric(device const float *gradient [[buffer(0)]],device const float *diagonal [[buffer(1)]],device float *metric [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]]) {if(i<n)metric[i]=isfinite(gradient[i])?abs(gradient[i])/sqrt(max(1e-12f,diagonal[i])):INFINITY;}
kernel void f5_noise_from_events(device const F5Event *events [[buffer(0)]],device const uint *counts [[buffer(1)]],device const uint *entries [[buffer(2)]],device const float *coefficients [[buffer(3)]],device const float *dummy [[buffer(4)]],device float *noise [[buffer(5)]],constant F5Grid &g [[buffer(6)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.core.z*g.core.w)return;int2 p=int2(g.core.xy)+int2(i%g.core.z,i/g.core.z);float information=0,floorNoise=INFINITY;
    for(int y=-2;y<=1;++y)for(int x=-2;x<=1;++x){int2 cell=p+int2(x,y)-g.bin.xy;if(any(cell<0)||any(cell>=int2(g.counts.yz)))continue;uint bin=cell.y*g.counts.y+cell.x;
        for(uint j=0;j<min(counts[bin],g.counts.w);++j){F5Event e=events[entries[bin*g.counts.w+j]];float mu=f5sample(coefficients,dummy,e.at.xy,e.info.x,g).x*e.at.z;information+=f5weight(p,e.at.xy,g)*e.at.z*e.at.z/(e.interval.z*mu+e.interval.w*e.interval.w);floorNoise=min(floorNoise,e.interval.w/e.at.z);}
    }noise[p.y*g.shape.x+p.x]=max(isfinite(floorNoise)?floorNoise:1e-4f,information>0?sqrt(3/information):1.0f);
}

// CPU/GPU golden tests use the same production routines, with a bounded list
// of independently chosen positions. They never read back a full photo.
kernel void f5_probe_operator(device const float *coefficients [[buffer(0)]],device const float4 *positions [[buffer(1)]],device float4 *output [[buffer(2)]],device const float *dummy [[buffer(3)]],constant F5Grid &g [[buffer(4)]],constant uint &n [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i<n)output[i]=f5sample(coefficients,dummy,positions[i].xy,uint(positions[i].z),g);
}
kernel void f5_probe_likelihood(device const F5Event *events [[buffer(0)]],device const float *means [[buffer(1)]],device float4 *output [[buffer(2)]],constant F5LUT &lut [[buffer(3)]],device const float4 *lookup [[buffer(4)]],constant uint &n [[buffer(5)]],uint i [[thread_position_in_grid]]) {if(i<n)output[i]=f5pg(events[i],means[i],lut,lookup);}

float2 f5node(device const float2 *nodes,int2 p,uint frame,constant F5Grid &g) {return nodes[(frame*g.bin.w+f5mirror(p.y,g.bin.w))*g.bin.z+f5mirror(p.x,g.bin.z)];}
float2 f5nodeH(device const float2 *nodes,int2 p,uint frame,uint component,constant F5Grid &g) {
    if(component==0)return f5node(nodes,p+int2(-1,0),frame,g)-2*f5node(nodes,p,frame,g)+f5node(nodes,p+int2(1,0),frame,g);
    if(component==2)return f5node(nodes,p+int2(0,-1),frame,g)-2*f5node(nodes,p,frame,g)+f5node(nodes,p+int2(0,1),frame,g);
    return 0.35355339059f*(f5node(nodes,p+int2(-1,-1),frame,g)-f5node(nodes,p+int2(1,-1),frame,g)-f5node(nodes,p+int2(-1,1),frame,g)+f5node(nodes,p+int2(1,1),frame,g));
}
float3 f5nodeWeight(int2 row,int2 column,constant F5Grid &g) {
    float3 result=0;for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 p=row+int2(x,y);p=int2(f5mirror(p.x,g.bin.z),f5mirror(p.y,g.bin.w));if(any(p!=column))continue;if(y==0)result.x+=x==0?-2:1;if(x==0)result.z+=y==0?-2:1;if(x!=0&&y!=0)result.y+=float(x*y)*0.35355339059f;}return result;
}
kernel void f5_motion_normal(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device const float *coefficients [[buffer(2)]],device const float2 *nodes [[buffer(3)]],device const float2 *direction [[buffer(4)]],device const float *edgeWeights [[buffer(5)]],device const uint *eligibility [[buffer(6)]],device float2 *gradient [[buffer(7)]],device float2 *diagonal [[buffer(8)]],constant F5Frame &frame [[buffer(9)]],constant F5Grid &g [[buffer(10)]],constant F5LUT &lut [[buffer(11)]],device const float4 *lookup [[buffer(12)]],device const float *zero [[buffer(13)]],device float4 *dataNormal [[buffer(14)]],uint i [[thread_position_in_grid]]) {
    uint count=g.bin.z*g.bin.w;if(i>=count)return;uint f=g.options.w,index=f*count+i;if(f==g.shape.w){gradient[index]=0;diagonal[index]=1;return;}
    int2 node=int2(i%g.bin.z,i/g.bin.z);float2 sum=0,diag=0;int2 lo=max(int2(0),node*32-32),hi=min(int2(g.shape.xy),node*32+32);
    // Mode 3 is the direct matrix-free normal product retained as a numerical
    // oracle. Production PCG uses mode 1 and the same frozen 3x3 block stencil.
    bool normal=g.step.y==1||g.step.y==3;float4 blocks[9];for(uint j=0;j<9;++j)blocks[j]=0;
    if(g.step.y==1){
        for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 q=node+int2(x,y);if(any(q<0)||any(q>=g.bin.zw))continue;
            float4 block=dataNormal[index*9+(y+1)*3+x+1];float2 d=direction[(f*g.bin.w+q.y)*g.bin.z+q.x];
            sum+=float2(dot(block.xy,d),dot(block.zw,d));if(x==0&&y==0)diag+=block.xw;
        }
    }else for(int y=lo.y;y<hi.y;++y)for(int x=lo.x;x<hi.x;++x){uint rawIndex=y*frame.active.z+x;if((eligibility[rawIndex/32]&(1u<<(rawIndex%32)))==0)continue;
        F5Event e=f5canonical(uint2(x,y),f,raw,frame,table);if(e.info.w>=3)continue;float2 source=e.at.xy,position=source+f5motion(nodes,direction,source,f,g,false);if(any(position<0)||any(position>float2(g.shape.xy)))continue;
        float4 sampled=f5sample(coefficients,zero,position,e.info.x,g,false);if(!(sampled.x>f5epsilon)){sum=INFINITY;continue;}float4 l=f5pg(e,sampled.x*e.at.z,lut,lookup);if(!all(isfinite(l.xyz))){sum=INFINITY;continue;}
        float logIn=log1p(-g.objective.w)-l.x,logMix=f5logadd(logIn,log(g.objective.w)+log(e.source.x)),gamma=exp(logIn-logMix),gap=sampled.x-f5epsilon;
        float score=gamma*l.y-g.objective.z/(gap*e.at.z),curvature=max(1e-12f,gamma*l.z+g.objective.z/(gap*gap*e.at.z*e.at.z));
        float2 distance=abs(source/32-float2(node));float weight=max(0.0f,1-distance.x)*max(0.0f,1-distance.y);float2 j=sampled.yz*e.at.z;
        if(normal)score=curvature*dot(j,f5motion(direction,nodes,source,f,g,false));
        sum+=weight*j*score;diag+=weight*weight*j*j*curvature;
        if(!normal){float4 outer=curvature*weight*float4(j.x*j.x,j.x*j.y,j.y*j.x,j.y*j.y);
            for(int yy=-1;yy<=1;++yy)for(int xx=-1;xx<=1;++xx){int2 q=node+int2(xx,yy);if(any(q<0)||any(q>=g.bin.zw))continue;
                float2 distance=abs(source/32-float2(q));float other=max(0.0f,1-distance.x)*max(0.0f,1-distance.y);
                blocks[(yy+1)*3+xx+1]+=outer*other;
            }
        }
    }
    if(!normal)for(uint j=0;j<9;++j)dataNormal[index*9+j]=blocks[j];
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 row=node+int2(x,y);if(any(row<0)||any(row>=g.bin.zw))continue;float norm=0;for(uint j=0;j<3;++j){float2 h=f5nodeH(nodes,row,f,j,g);norm+=dot(h,h);}
        float weight=g.objective.x*g.regularizer.z/(4*count)*edgeWeights[(f*g.bin.w+row.y)*g.bin.z+row.x]/sqrt(1+norm);float3 h=f5nodeWeight(row,node,g);
        for(uint j=0;j<3;++j){sum+=weight*h[j]*f5nodeH(normal?direction:nodes,row,f,j,g);diag+=weight*h[j]*h[j];}
    }
    if(normal)sum+=g.regularizer.w*direction[index];gradient[index]=sum;diagonal[index]=max(float2(1e-12f),diag+g.regularizer.w);
}
kernel void f5_clip_motion(device const float2 *solution [[buffer(0)]],device float2 *step [[buffer(1)]],constant uint &n [[buffer(2)]],uint i [[thread_position_in_grid]]) {if(i<n)step[i]=solution[i]*min(1.0f,0.25f/max(1e-20f,length(solution[i])));}
// Parallel observation terms, with the original node integration order.
// The caller retains at most 64 native rows in this cache.
kernel void f5_motion_terms(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device const float *coefficients [[buffer(2)]],device const float2 *nodes [[buffer(3)]],device const uint *eligibility [[buffer(4)]],device float4 *terms [[buffer(5)]],constant F5Frame &frame [[buffer(6)]],constant F5Grid &g [[buffer(7)]],constant F5LUT &lut [[buffer(8)]],device const float4 *lookup [[buffer(9)]],device const float *zero [[buffer(10)]],constant uint4 &region [[buffer(11)]],uint i [[thread_position_in_grid]]) {
    if(i>=region.z*region.w)return;terms[i]=0;uint2 p=region.xy+uint2(i%region.z,i/region.z);uint index=p.y*frame.active.z+p.x;
    if((eligibility[index/32]&(1u<<(index%32)))==0)return;
    F5Event e=f5canonical(p,g.options.w,raw,frame,table);if(e.info.w>=3)return;
    float2 position=e.at.xy+f5motion(nodes,nodes,e.at.xy,g.options.w,g,false);if(any(position<0)||any(position>float2(g.shape.xy)))return;
    float4 sampled=f5sample(coefficients,zero,position,e.info.x,g,false);if(!(sampled.x>f5epsilon)){terms[i]=INFINITY;return;}
    float4 l=f5pg(e,sampled.x*e.at.z,lut,lookup);if(!all(isfinite(l.xyz))){terms[i]=INFINITY;return;}
    float logIn=log1p(-g.objective.w)-l.x,logMix=f5logadd(logIn,log(g.objective.w)+log(e.source.x)),gamma=exp(logIn-logMix),gap=sampled.x-f5epsilon;
    float score=gamma*l.y-g.objective.z/(gap*e.at.z),curvature=max(1e-12f,gamma*l.z+g.objective.z/(gap*gap*e.at.z*e.at.z));
    terms[i]=float4(sampled.yz*e.at.z,score,curvature);
}
kernel void f5_motion_gather_terms(device const float4 *terms [[buffer(0)]],device const float2 *nodes [[buffer(1)]],device const float *edgeWeights [[buffer(2)]],device float2 *gradient [[buffer(3)]],device float2 *diagonal [[buffer(4)]],device float4 *dataNormal [[buffer(5)]],constant F5Grid &g [[buffer(6)]],constant uint4 &region [[buffer(7)]],constant uint &nodeRow [[buffer(8)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(g.bin.z))return;uint count=g.bin.z*g.bin.w,f=g.options.w,index=f*count+nodeRow*g.bin.z+i;
    if(f==g.shape.w){gradient[index]=0;diagonal[index]=1;return;}
    int2 node=int2(i,nodeRow),lo=max(int2(0),node*32-32),hi=min(int2(g.shape.xy),node*32+32);float2 sum=0,diag=0;
    float4 blocks[9];for(uint j=0;j<9;++j)blocks[j]=0;
    for(int y=lo.y;y<hi.y;++y)for(int x=lo.x;x<hi.x;++x){float4 t=terms[(uint(y)-region.y)*region.z+uint(x)-region.x];
        if(!all(isfinite(t))){sum=INFINITY;continue;}if(t.w<=0)continue;float2 source=float2(x,y)+0.5f,j=t.xy;
        float2 distance=abs(source/32-float2(node));float weight=max(0.0f,1-distance.x)*max(0.0f,1-distance.y);
        sum+=weight*j*t.z;diag+=weight*weight*j*j*t.w;
        float4 outer=t.w*weight*float4(j.x*j.x,j.x*j.y,j.y*j.x,j.y*j.y);
        for(int yy=-1;yy<=1;++yy)for(int xx=-1;xx<=1;++xx){int2 q=node+int2(xx,yy);if(any(q<0)||any(q>=g.bin.zw))continue;
            float2 distance=abs(source/32-float2(q));float other=max(0.0f,1-distance.x)*max(0.0f,1-distance.y);blocks[(yy+1)*3+xx+1]+=outer*other;
        }
    }
    for(uint j=0;j<9;++j)dataNormal[index*9+j]=blocks[j];
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 row=node+int2(x,y);if(any(row<0)||any(row>=g.bin.zw))continue;float norm=0;
        for(uint j=0;j<3;++j){float2 h=f5nodeH(nodes,row,f,j,g);norm+=dot(h,h);}
        float weight=g.objective.x*g.regularizer.z/(4*count)*edgeWeights[(f*g.bin.w+row.y)*g.bin.z+row.x]/sqrt(1+norm);float3 h=f5nodeWeight(row,node,g);
        for(uint j=0;j<3;++j){sum+=weight*h[j]*f5nodeH(nodes,row,f,j,g);diag+=weight*h[j]*h[j];}
    }
    gradient[index]=sum;diagonal[index]=max(float2(1e-12f),diag+g.regularizer.w);
}
kernel void f5_commit_motion(device float2 *nodes [[buffer(0)]],device const float2 *step [[buffer(1)]],constant float &alpha [[buffer(2)]],constant uint &n [[buffer(3)]],uint i [[thread_position_in_grid]]) {if(i<n)nodes[i]=fma(float2(alpha),step[i],nodes[i]);}

kernel void f5_down_guide(device const float4 *input [[buffer(0)]],device float4 *output [[buffer(1)]],constant uint4 &shape [[buffer(2)]],constant uint2 &outputShape [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=outputShape.x*outputShape.y)return;uint2 start=uint2(i%outputShape.x,i/outputShape.x)*shape.z;float sum=0,var=0,weight=0,total=0;
    for(uint y=start.y;y<min(shape.y,start.y+shape.z);++y)for(uint x=start.x;x<min(shape.x,start.x+shape.z);++x){float4 v=input[y*shape.x+x];sum+=v.x*v.z;var+=v.y*v.z*v.z;weight+=v.z;total+=1;}
    output[i]=float4(weight>0?sum/weight:0,weight>0?var/(weight*weight):0,total>0?weight/total:0,total);
}
kernel void f5_guide_sharpness(device const float4 *guide [[buffer(0)]],device float2 *scores [[buffer(1)]],constant uint4 &shape [[buffer(2)]],uint tile [[thread_position_in_grid]]) {
    uint columns=(shape.x+15)/16,rows=(shape.y+15)/16;if(tile>=columns*rows)return;if(shape.x<7||shape.y<7){scores[tile]=float2(-1,0);return;}uint2 start=uint2(tile%columns,tile/columns)*16;float highEnergy=0,gradientEnergy=0,noiseFloor=0,count=0;
    float norm0=0,norm1=0;for(int y=-3;y<=3;++y)for(int x=-3;x<=3;++x){norm0+=exp(-float(x*x+y*y)*4/(2*0.7f*0.7f));norm1+=exp(-float(x*x+y*y)*4/(2*1.4f*1.4f));}
    for(uint y=max(3u,start.y);y<min(shape.y-3,start.y+16);++y)for(uint x=max(3u,start.x);x<min(shape.x-3,start.x+16);++x){float band=0,bvar=0,gx=0,gy=0,gvar=0;bool valid=true;
        for(int dy=-3;dy<=3;++dy)for(int dx=-3;dx<=3;++dx){float4 value=guide[(int(y)+dy)*shape.x+int(x)+dx];if(value.z<0.99f){valid=false;continue;}
            float k0=exp(-float(dx*dx+dy*dy)*4/(2*0.7f*0.7f))/norm0,k1=exp(-float(dx*dx+dy*dy)*4/(2*1.4f*1.4f))/norm1;
            float kx=(exp(-float((dx-1)*(dx-1)+dy*dy)*4/(2*1.4f*1.4f))-exp(-float((dx+1)*(dx+1)+dy*dy)*4/(2*1.4f*1.4f)))/(4*norm1);
            float ky=(exp(-float(dx*dx+(dy-1)*(dy-1))*4/(2*1.4f*1.4f))-exp(-float(dx*dx+(dy+1)*(dy+1))*4/(2*1.4f*1.4f)))/(4*norm1);
            band+=(k0-k1)*value.x;bvar+=(k0-k1)*(k0-k1)*value.y;gx+=kx*value.x;gy+=ky*value.x;gvar+=(kx*kx+ky*ky)*value.y;
        }
        if(valid){highEnergy+=band*band-bvar;gradientEnergy+=gx*gx+gy*gy-gvar;noiseFloor+=gvar;count+=1;}
    }
    scores[tile]=float2(count>=4?max(0.0f,highEnergy)/max(1e-12f,max(gradientEnergy,noiseFloor)):-1,count);
}
uint f5hash(uint x) {x+=20261027u;x=(x^(x>>16))*0x7feb352du;x=(x^(x>>15))*0x846ca68bu;return x^(x>>16);}
kernel void f5_quality_samples(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device const float *coefficients [[buffer(2)]],device const float2 *motion [[buffer(3)]],device const float2 *motionDelta [[buffer(4)]],device F5Event *output [[buffer(5)]],constant F5Frame &frame [[buffer(6)]],constant F5Grid &g [[buffer(7)]],constant uint4 &batch [[buffer(8)]],constant F5LUT &lut [[buffer(9)]],device const float4 *lookup [[buffer(10)]],device const float *zero [[buffer(11)]],device const uint *eligibility [[buffer(12)]],uint i [[thread_position_in_grid]]) {
    if(i>=batch.w*24)return;uint local=i/24,sample=i%24,tile=batch.z+local,columns=batch.x;uint f=g.options.w,phase=sample/6;
    uint parity=0;for(uint j=0;j<4;++j)if(frame.cfa[j]==phase)parity=j;
    uint2 start=uint2(tile%columns,tile/columns)*32,extent=min(uint2(32),g.shape.xy-start),cells=max(uint2(1),extent/2);uint cellCount=cells.x*cells.y;
    uint offset=f5hash(tile*20+f*4+phase)%cellCount,cell=(offset+(sample%6)*max(1u,cellCount/6))%cellCount;
    float2 desired=float2(start+2*uint2(cell%cells.x,cell/cells.x)+uint2(parity%2,parity/2))+0.5f;
    float2 p=desired;for(uint j=0;j<8;++j)p=desired-f5motion(motion,motionDelta,p,f,g,false);
    p=floor(p/2)*2+float2(parity%2,parity/2)+0.5f;
    F5Event e;e.at=0;e.interval=0;e.score=0;e.info=uint4(0,phase,f,5);e.source=0;
    if(sample%6<cellCount&&all(p>=0.5f)&&all(p<float2(frame.active.zw))){e=f5canonical(uint2(p),f,raw,frame,table);uint index=uint(p.y)*frame.active.z+uint(p.x);if((eligibility[index/32]&(1u<<(index%32)))==0)e.info.w=3;e.at.xy=p+f5motion(motion,motionDelta,p,f,g,false);
        if(e.info.w<3&&all(e.at.xy>=0)&&all(e.at.xy<=float2(g.shape.xy))){float4 field=f5sample(coefficients,zero,e.at.xy,e.info.x,g,false);float4 likelihood=f5pg(e,field.x*e.at.z,lut,lookup);float li=log1p(-g.objective.w)-likelihood.x,lm=f5logadd(li,log(g.objective.w)+log(e.source.x));e.score=float4(field.x*e.at.z,field.y,field.z,exp(li-lm)*likelihood.z);}
        else e.info.w=5;
    }output[local*120+f*24+sample]=e;
}
kernel void f5_hypothesis_scores(device const F5Event *samples [[buffer(0)]],device const float *coefficients [[buffer(1)]],device const float2 *offsets [[buffer(2)]],device float4 *output [[buffer(3)]],device const float *zero [[buffer(4)]],constant F5Grid &g [[buffer(5)]],constant uint &count [[buffer(6)]],constant F5LUT &lut [[buffer(7)]],device const float4 *lookup [[buffer(8)]],uint i [[thread_position_in_grid]]) {
    if(i>=count)return;uint frame=i%5;float3 sums=0;float used=0;
    // Score the same observations against the same frozen latent image. All
    // hypotheses share the intersection of their support, preventing a candidate
    // from winning by moving difficult samples outside the field of view.
    for(uint j=0;j<24;++j){F5Event e=samples[i*24+j];if(e.info.w>=3)continue;bool duplicate=false;for(uint previous=0;previous<j;++previous)if(samples[i*24+previous].info.w<3&&all(samples[i*24+previous].source.yz==e.source.yz))duplicate=true;if(duplicate)continue;float3 nll=0;bool common=true;
        for(uint k=0;k<3;++k){float2 p=e.at.xy+offsets[frame*3+k];if(any(p<0)||any(p>float2(g.shape.xy))){common=false;break;}
            float field=f5sample(coefficients,zero,p,e.info.x,g,false).x;if(!(field>f5epsilon)){common=false;break;}
            float4 likelihood=f5pg(e,field*e.at.z,lut,lookup);
            nll[k]=-f5logadd(log1p(-g.objective.w)-likelihood.x,log(g.objective.w)+log(e.source.x));
            if(!isfinite(nll[k]))common=false;
        }if(common){sums+=nll;used+=1;}
    }output[i]=float4(sums,used);
}
kernel void f5_quality_summary(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device const float *coefficients [[buffer(2)]],device const float2 *motion [[buffer(3)]],device const float2 *motionDelta [[buffer(4)]],device float4 *output [[buffer(5)]],constant F5Frame &frame [[buffer(6)]],constant F5Grid &g [[buffer(7)]],constant uint4 &batch [[buffer(8)]],constant float4 &bounds [[buffer(9)]],device const float *zero [[buffer(10)]],device const uint *eligibility [[buffer(11)]],uint tid [[thread_index_in_threadgroup]],uint local [[threadgroup_position_in_grid]]) {
    if(local>=batch.w)return;uint tile=batch.z+local,f=g.options.w;int2 start=int2((tile%batch.x)*32,(tile/batch.x)*32),end=min(start+32,int2(g.shape.xy));
    int2 lo=max(int2(0),int2(floor(float2(start)-bounds.zw-1))),hi=min(int2(frame.active.zw),int2(ceil(float2(end)-bounds.xy+1)));int width=max(0,hi.x-lo.x),height=max(0,hi.y-lo.y);float4 counts=0,metrics=0;
    for(int i=tid;i<width*height;i+=256){uint2 p=uint2(lo+int2(i%width,i/width));F5Event e=f5canonical(p,f,raw,frame,table);float2 mapped=e.at.xy+f5motion(motion,motionDelta,e.at.xy,f,g,false);if(any(mapped<float2(start))||any(mapped>=float2(end)))continue;counts.x+=1;uint inputIndex=p.y*frame.active.z+p.x;if(e.info.w>=3||(eligibility[inputIndex/32]&(1u<<(inputIndex%32)))==0)continue;if(e.info.w==0)counts.y+=1;else if(e.info.w==1)counts.z+=1;else counts.w+=1;
        float mu=f5sample(coefficients,zero,mapped,e.info.x,g,false).x*e.at.z;float observed=e.info.w==1?max(mu,e.interval.x):e.info.w==2?min(mu,e.interval.y):(e.interval.x+e.interval.y)/2;
        float residual=(mu-observed)/sqrt(e.interval.z*max(0.0f,mu)+e.interval.w*e.interval.w);metrics.x+=residual*residual;metrics.y+=1;if(e.info.w==0){metrics.z+=residual;metrics.w+=1;}
    }
    threadgroup float4 c[256],r[256];c[tid]=counts;r[tid]=metrics;threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint stride=128;stride>0;stride/=2){if(tid<stride){c[tid]+=c[tid+stride];r[tid]+=r[tid+stride];}threadgroup_barrier(mem_flags::mem_threadgroup);}if(tid==0){output[(local*5+f)*2]=c[0];output[(local*5+f)*2+1]=r[0];}
}
kernel void f5_set_eligibility(device const ushort *raw [[buffer(0)]],device const float *table [[buffer(1)]],device const float2 *motion [[buffer(2)]],device const float2 *motionDelta [[buffer(3)]],device const uint *quality [[buffer(4)]],device uint *eligibility [[buffer(5)]],constant F5Frame &frame [[buffer(6)]],constant F5Grid &g [[buffer(7)]],uint word [[thread_position_in_grid]]) {
    uint pixels=frame.active.z*frame.active.w;if(word>=(pixels+31)/32)return;uint mask=0,columns=(g.shape.x+31)/32;
    for(uint j=0;j<32;++j){uint i=word*32+j;if(i>=pixels)break;uint2 p=uint2(i%frame.active.z,i/frame.active.z);float2 point=float2(p)+0.5f;point+=f5motion(motion,motionDelta,point,g.options.w,g,false);if(any(point<0)||any(point>=float2(g.shape.xy)))continue;
        uint tile=uint(point.y/32)*columns+uint(point.x/32),excluded=quality[tile];bool keep=(excluded&(1u<<g.options.w))==0||g.options.w==g.shape.w;
        if(keep)mask|=1u<<j;
    }eligibility[word]=mask;
}

struct F5Output {uint4 shape;float4 crop;uint4 options;};
float f5fieldValue(device const float *coefficients,float2 p,uint c,uint width,uint height,uint scale) {
    uint w=width*scale,h=height*scale;float2 uv=p*float(scale)-0.5f;int2 first=int2(floor(uv))-1;float value=0;
    for(int y=0;y<4;++y)for(int x=0;x<4;++x){int2 q=first+int2(x,y);value+=coefficients[(c*h+f5mirror(q.y,h))*w+f5mirror(q.x,w)]*f5b(uv.x-q.x)*f5b(uv.y-q.y);}return value;
}
float f5nativeOutputValue(device const float *coefficients,float2 p,uint c,uint width,uint height) {
    // Interpolate evaluated native samples, whose positivity was constrained.
    // The signed controls themselves are never clamped or interpolated as RGB.
    float2 uv=clamp(p-0.5f,float2(0),float2(width-1,height-1));uint2 q=uint2(uv);float2 a=uv-float2(q);
    uint x1=min(q.x+1,width-1),y1=min(q.y+1,height-1);
    float v00=f5fieldValue(coefficients,float2(q)+0.5f,c,width,height,1),v10=f5fieldValue(coefficients,float2(x1,q.y)+0.5f,c,width,height,1);
    float v01=f5fieldValue(coefficients,float2(q.x,y1)+0.5f,c,width,height,1),v11=f5fieldValue(coefficients,float2(x1,y1)+0.5f,c,width,height,1);
    return mix(mix(v00,v10,a.x),mix(v01,v11,a.x),a.y);
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
float f5srWeight(float2 p,device const uint *quality,uint width,uint height) {
    uint columns=(width+31)/32,rows=(height+31)/32;int2 tile=int2(p/32);tile=clamp(tile,int2(0),int2(columns-1,rows-1));if(quality[tile.y*columns+tile.x]!=0)return 0;
    float distance=10000;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 other=tile+int2(x,y);if(any(other<0)||any(other>=int2(columns,rows))||quality[other.y*columns+other.x]==0)continue;float2 start=float2(other*32),end=min(start+32,float2(width,height));float2 d=max(float2(0),max(start-p,p-end));distance=min(distance,length(d));}
    float t=clamp((distance-2)/16,0.0f,1.0f);return 0.5f-0.5f*cos(M_PI_F*t);
}
kernel void f5_output_strip(device const float *high [[buffer(0)]],device const float *native [[buffer(1)]],device const uint *quality [[buffer(2)]],device const float4 *warps [[buffer(3)]],device float4 *output [[buffer(4)]],device atomic_uint *failure [[buffer(5)]],constant F5Grid &g [[buffer(6)]],constant F5Output &o [[buffer(7)]],uint i [[thread_position_in_grid]]) {
    if(i>=o.shape.x*o.shape.w)return;uint x=i%o.shape.x,y=o.shape.z+i/o.shape.x;float2 p=o.crop.xy+(float2(x,y)+0.5f)/float(o.options.y);float3 value=0;float weight=1;float2 coordinates[3];float gains[3];
    for(uint c=0;c<3;++c){F5OutputMapping mapping=f5outputMapping(p,c,warps,o.options.x);coordinates[c]=mapping.point;gains[c]=mapping.gain;if(any(coordinates[c]<0)||any(coordinates[c]>float2(g.shape.xy))){atomic_store_explicit(failure,1,memory_order_relaxed);coordinates[c]=clamp(coordinates[c],float2(0),float2(g.shape.xy));}weight=min(weight,f5srWeight(coordinates[c],quality,g.shape.x,g.shape.y));}
    for(uint c=0;c<3;++c){float base=f5nativeOutputValue(native,coordinates[c],c,g.shape.x,g.shape.y);float full=base;
        if(weight>0){full=f5fieldValue(high,coordinates[c],c,g.shape.x,g.shape.y,g.shape.z);if(!isfinite(full)||full<f5epsilon)atomic_store_explicit(failure,2,memory_order_relaxed);}value[c]=mix(base,full,weight)*gains[c];}
    if(!all(isfinite(value))||any(value<0))atomic_store_explicit(failure,2,memory_order_relaxed);output[i]=float4(value,1);
}
kernel void f5_color_transform(device float4 *image [[buffer(0)]],constant float4 *rows [[buffer(1)]],constant uint &n [[buffer(2)]],device atomic_uint *failure [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=n)return;float3 v=image[i].xyz,result=float3(dot(rows[0].xyz,v),dot(rows[1].xyz,v),dot(rows[2].xyz,v));if(!all(isfinite(result)))atomic_store_explicit(failure,2,memory_order_relaxed);image[i]=float4(result,1);
}
kernel void f5_data_gather(device const F5Event *events [[buffer(0)]],device const uint *counts [[buffer(1)]],device const uint *entries [[buffer(2)]],device float *gradient [[buffer(3)]],device float *diagonal [[buffer(4)]],constant F5Grid &g [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    uint pixels=g.core.z*g.core.w;if(i>=pixels*3)return;uint channel=i/pixels;uint2 coefficient=g.core.xy+uint2(i%g.core.z,(i%pixels)/g.core.z);float sum=0,diag=0;
    for(int y=-2;y<=1;++y)for(int x=-2;x<=1;++x){int2 cell=int2(coefficient)+int2(x,y)-g.bin.xy;if(any(cell<0)||any(cell>=int2(g.counts.yz)))continue;uint bin=cell.y*g.counts.y+cell.x,n=min(counts[bin],g.counts.w);
        for(uint j=0;j<n;++j){F5Event e=events[entries[bin*g.counts.w+j]];if(e.info.x!=channel)continue;float weight=f5weight(int2(coefficient),e.at.xy,g)*e.at.z;sum+=weight*e.score.y;diag+=weight*weight*e.score.z;}
    }gradient[i]=sum;if(g.step.y!=1)diagonal[i]=max(1e-12f,diag);
}

// Optional bounded local-frequency experiment, not part of the RAW likelihood.
struct F5DCTGrid {uint4 image,tile,patches;float4 settings;};
int f5dctMirror(int i,int n) {int period=2*(n-1);i%=period;if(i<0)i+=period;return i<n?i:period-i;}
uint f5dctSource(uint patch,uint x,uint y,constant F5DCTGrid &g) {
    int2 p=int2(g.tile.xy)+int2(patch%g.patches.x,patch/g.patches.x)*int(g.image.w)-int(g.patches.z)+int2(x,y);
    p=int2(f5dctMirror(p.x,g.image.x),f5dctMirror(p.y,g.image.y));return uint(p.y)*g.image.x+uint(p.x);
}
kernel void f5_dct_noise(device const float4 *variance [[buffer(0)]],device float4 *noise [[buffer(1)]],constant F5DCTGrid &g [[buffer(2)]],uint p [[thread_position_in_grid]]) {
    if(p>=g.patches.x*g.patches.y)return;float3 sum=0;uint n=g.image.z;
    for(uint y=0;y<n;++y)for(uint x=0;x<n;++x)sum+=variance[f5dctSource(p,x,y,g)].xyz;
    sum/=float(n*n);noise[p]=float4((sum.x+sum.y+sum.z)/3,(sum.x+sum.z)/2,(sum.x+4*sum.y+sum.z)/6,0);
}
kernel void f5_dct_forward_rows(device const float4 *image [[buffer(0)]],device const float *basis [[buffer(1)]],device float4 *rows [[buffer(2)]],constant F5DCTGrid &g [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint n=g.image.z,area=n*n;if(i>=g.patches.x*g.patches.y*area)return;uint p=i/area,y=(i%area)/n,k=i%n;float3 sum=0;
    for(uint x=0;x<n;++x)sum+=basis[k*n+x]*f5opponent(image[f5dctSource(p,x,y,g)].xyz);rows[i]=float4(sum,0);
}
kernel void f5_dct_forward_columns(device const float4 *rows [[buffer(0)]],device const float *basis [[buffer(1)]],device const float4 *noise [[buffer(2)]],device float4 *spectrum [[buffer(3)]],constant F5DCTGrid &g [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    uint n=g.image.z,area=n*n;if(i>=g.patches.x*g.patches.y*area)return;uint p=i/area,ky=(i%area)/n,kx=i%n;float3 sum=0;
    for(uint y=0;y<n;++y)sum+=basis[ky*n+y]*rows[p*area+y*n+kx].xyz;
    float3 threshold=g.settings.x*sqrt(max(float3(0),noise[p].xyz));
    if(ky!=0||kx!=0)sum=select(float3(0),sum,abs(sum)>=threshold);spectrum[i]=float4(sum,0);
}
kernel void f5_dct_inverse_columns(device const float4 *spectrum [[buffer(0)]],device const float *basis [[buffer(1)]],device float4 *rows [[buffer(2)]],constant F5DCTGrid &g [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint n=g.image.z,area=n*n;if(i>=g.patches.x*g.patches.y*area)return;uint p=i/area,y=(i%area)/n,kx=i%n;float3 sum=0;
    for(uint ky=0;ky<n;++ky)sum+=basis[ky*n+y]*spectrum[p*area+ky*n+kx].xyz;rows[i]=float4(sum,0);
}
kernel void f5_dct_inverse_rows(device const float4 *rows [[buffer(0)]],device const float *basis [[buffer(1)]],device float4 *patches [[buffer(2)]],constant F5DCTGrid &g [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    uint n=g.image.z,area=n*n;if(i>=g.patches.x*g.patches.y*area)return;uint p=i/area,y=(i%area)/n,x=i%n;float3 sum=0;
    for(uint kx=0;kx<n;++kx)sum+=basis[kx*n+x]*rows[p*area+y*n+kx].xyz;patches[i]=float4(sum,0);
}
kernel void f5_dct_aggregate(device const float4 *patches [[buffer(0)]],device float4 *image [[buffer(1)]],constant F5DCTGrid &g [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=g.tile.z*g.tile.w)return;uint2 pixel=uint2(i%g.tile.z,i/g.tile.z),position=pixel+g.patches.z;uint n=g.image.z,stride=g.image.w;
    uint2 first=(position-(n-1)+stride-1)/stride,last=min(position/stride,g.patches.xy-1);float3 sum=0;float count=0;
    for(uint py=first.y;py<=last.y;++py)for(uint px=first.x;px<=last.x;++px){uint2 at=position-uint2(px,py)*stride;uint index=(py*g.patches.x+px)*n*n+at.y*n+at.x;sum+=patches[index].xyz;count+=1;}
    uint2 at=pixel+g.tile.xy;uint destination=g.settings.y==1?i:at.y*g.image.x+at.x;
    image[destination]=float4(f5rgb(sum/max(1.0f,count)),1);
}
kernel void f5_dct_information(device const float4 *image [[buffer(0)]],device const ushort *raw [[buffer(1)]],device const float *table [[buffer(2)]],device const uint *eligibility [[buffer(3)]],device float4 *information [[buffer(4)]],constant F5Frame &frame [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    uint w=frame.active.z,h=frame.active.w;if(i>=w*h)return;if((eligibility[i/32]&(1u<<(i%32)))==0)return;
    F5Event e=f5canonical(uint2(i%w,i/w),0,raw,frame,table);if(e.info.w>=3)return;
    float3 shot=float3(frame.kappa.x,(frame.kappa.y+frame.kappa.z)*0.5f,frame.kappa.w);
    float3 read=float3(frame.readSigma.x,(frame.readSigma.y+frame.readSigma.z)*0.5f,frame.readSigma.w);
    float3 variance=shot*max(float3(0),image[i].xyz*e.at.z)+read*read;
    information[i]+=float4(e.at.z*e.at.z/max(variance,float3(1e-20f)),0);
}
kernel void f5_dct_load_tile(device const float4 *image [[buffer(0)]],device const float4 *variance [[buffer(1)]],device float4 *localImage [[buffer(2)]],device float4 *localVariance [[buffer(3)]],constant uint4 &shape [[buffer(4)]],constant int2 &origin [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=shape.z*shape.w)return;int2 p=origin+int2(i%shape.z,i/shape.z);
    uint j=uint(f5dctMirror(p.y,shape.y))*shape.x+uint(f5dctMirror(p.x,shape.x));localImage[i]=image[j];localVariance[i]=variance[j];
}
kernel void f5_dct_store_tile(device const float4 *localOutput [[buffer(0)]],device float4 *output [[buffer(1)]],constant uint4 &shape [[buffer(2)]],constant uint2 &origin [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=shape.z*shape.w)return;uint2 p=origin+uint2(i%shape.z,i/shape.z);output[p.y*shape.x+p.x]=localOutput[i];
}
kernel void f5_dct_variance(device float4 *information [[buffer(0)]],constant uint &count [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i<count)information[i]=float4(1/max(information[i].xyz,float3(1e-12f)),0);
}
kernel void f5_dct_upsample(device const float4 *image [[buffer(0)]],device float4 *output [[buffer(1)]],constant uint2 &shape [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    uint width=shape.x*2;if(i>=shape.x*shape.y*4)return;float2 p=clamp((float2(i%width,i/width)+0.5f)/2-0.5f,float2(0),float2(shape-1));
    uint2 a=uint2(p),b=min(a+1,shape-1);float2 t=p-float2(a);
    output[i]=mix(mix(image[a.y*shape.x+a.x],image[a.y*shape.x+b.x],t.x),mix(image[b.y*shape.x+a.x],image[b.y*shape.x+b.x],t.x),t.y);
}
