import Foundation
import simd

struct PeripheralGlassUniforms {
    var photo: SIMD4<Float>
    var viewport: SIMD2<Float>
    var blackOpacity: Float
    var padding: Float = 0
    var photoToOuter: simd_float3x3
    var gain: SIMD4<Float>
}

/// Original app shader: explicit outer-only fragment ownership. Refraction,
/// fog and highlights never cover the central photo, even during transitions.
enum PeripheralGlassShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float4 photo;
        float2 viewport;
        float blackOpacity;
        float padding;
        float3x3 photoToOuter;
        float4 gain;
    };
    vertex float4 glassVertex(uint id [[vertex_id]]) {
        const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        return float4(p[id],0,1);
    }
    fragment float4 glassFragment(float4 position [[position]],
                                   constant Uniforms& u [[buffer(0)]],
                                   texture2d<float> camera [[texture(0)]]) {
        float2 uv = position.xy / u.viewport;
        float2 end = u.photo.xy + u.photo.zw;
        if (all(uv >= u.photo.xy) && all(uv < end)) discard_fragment();
        if (u.blackOpacity >= 0.9999) return float4(0,0,0,1);
        float2 photoUV = (uv-u.photo.xy)/u.photo.zw;
        float3 projected = u.photoToOuter * float3(photoUV,1);
        if (projected.z <= 0.00001) return float4(0,0,0,1);
        float2 sampleUV = projected.xy / projected.z;
        float2 outside = (uv-clamp(uv,u.photo.xy,end))*u.viewport;
        float distance = length(outside);
        float2 direction = outside / max(distance,0.0001);
        float2 texel = 1.0/float2(camera.get_width(),camera.get_height());
        // A shallow bevel bends the transmitted scene only on the outside.
        sampleUV += direction * texel * (5.0*exp(-distance/20.0));
        constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
        float3 color = float3(0);
        float weights = 0;
        for (int y=-2;y<=2;++y) for (int x=-2;x<=2;++x) {
            float weight = exp(-float(x*x+y*y)*0.32);
            color += camera.sample(s,sampleUV+float2(x,y)*texel*2.3).rgb * weight;
            weights += weight;
        }
        color = color/weights*u.gain.xyz;
        float rim = exp(-distance/2.4);
        color = max(float3(0), color*(0.77-0.10*exp(-distance/38.0)) + 0.008 + rim*0.032);
        return float4(color*(1-clamp(u.blackOpacity,0.0,1.0)),1);
    }
    """#
}
