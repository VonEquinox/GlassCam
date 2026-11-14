#include <metal_stdlib>
using namespace metal;

struct PeripheralGlassShaderUniforms {
    float4 photo;
    float2 viewport;
    float blackOpacity;
    float centerEnabled;
    float3x3 photoToOuter;
    float4 gain;
    float4 gainTop;
    float4 gainBottom;
    float4 gainLeft;
    float4 gainRight;
    float4 biasTop;
    float4 biasBottom;
    float4 biasLeft;
    float4 biasRight;
    float4 edgeOpacity;
};

static float3 gc_peripheral_encode_srgb(float3 v) {
    return select(1.055 * pow(max(v, float3(0)), float3(1.0 / 2.4)) - 0.055, 12.92 * v, v <= 0.0031308);
}

static float3 gc_peripheral_decode_srgb(float3 v) {
    return select(pow(max((v + 0.055) / 1.055, float3(0)), float3(2.4)), v / 12.92, v <= 0.04045);
}

static float3 gc_peripheral_correct_edge(float3 original, float4 gain, float4 bias) {
    return gain.w > 1.5 ? gc_peripheral_decode_srgb(max(float3(0), gc_peripheral_encode_srgb(original) * gain.xyz + bias.xyz)) :
        max(float3(0), original * gain.xyz);
}

vertex float4 glassVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(p[id], 0, 1);
}

static float4 gc_shade_periphery(float4 position, constant PeripheralGlassShaderUniforms& u, texture2d<float> camera) {
    float2 uv = position.xy / u.viewport;
    float2 end = u.photo.xy + u.photo.zw;
    if (all(uv >= u.photo.xy) && all(uv < end)) discard_fragment();
    if (u.blackOpacity >= 0.9999) return float4(0, 0, 0, 1);
    float2 photoUV = (uv - u.photo.xy) / u.photo.zw;
    float3 projected = u.photoToOuter * float3(photoUV, 1);
    if (projected.z <= 0.00001) return float4(0, 0, 0, 1);
    float2 sampleUV = projected.xy / projected.z;
    constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
    float3 original = camera.sample(s, sampleUV).rgb;
    float3 color = max(float3(0), original * u.gain.xyz);
    if (u.gainTop.w > 0) {
        float4 distance = max(float4(-photoUV.y, photoUV.y - 1, -photoUV.x, photoUV.x - 1), float4(0));
        float total = dot(distance, float4(1));
        if (total > 0) {
            color = (distance.x * gc_peripheral_correct_edge(original, u.gainTop, u.biasTop) +
                distance.y * gc_peripheral_correct_edge(original, u.gainBottom, u.biasBottom) +
                distance.z * gc_peripheral_correct_edge(original, u.gainLeft, u.biasLeft) +
                distance.w * gc_peripheral_correct_edge(original, u.gainRight, u.biasRight)) / total;
        }
    }
    float regional = u.blackOpacity;
    if (photoUV.y < 0) regional = max(regional, u.edgeOpacity.x);
    if (photoUV.y > 1) regional = max(regional, u.edgeOpacity.y);
    if (photoUV.x < 0) regional = max(regional, u.edgeOpacity.z);
    if (photoUV.x > 1) regional = max(regional, u.edgeOpacity.w);
    return float4(color * (1 - clamp(regional, 0.0, 1.0)), 1);
}

fragment float4 glassFragment(float4 position [[position]],
                              constant PeripheralGlassShaderUniforms& u [[buffer(0)]],
                              texture2d<float> camera [[texture(0)]]) {
    return gc_shade_periphery(position, u, camera);
}

fragment float4 pairedPreviewFragment(float4 position [[position]],
                                      constant PeripheralGlassShaderUniforms& u [[buffer(0)]],
                                      texture2d<float> camera [[texture(0)]],
                                      texture2d<float> center [[texture(1)]]) {
    float2 uv = position.xy / u.viewport;
    if (all(uv >= u.photo.xy) && all(uv < u.photo.xy + u.photo.zw) && u.centerEnabled > 0.5) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return float4(center.sample(s, (uv - u.photo.xy) / u.photo.zw).rgb, 1);
    }
    return gc_shade_periphery(position, u, camera);
}
