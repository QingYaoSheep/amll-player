#include <metal_stdlib>
using namespace metal;

struct FlowingVertex { float4 position [[position]]; float2 uv; };
struct FlowingUniforms { float4 viewport; float4 motion; float4 covers; };

vertex FlowingVertex amllFlowingQuad(uint id [[vertex_id]]) {
    const float2 points[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return {float4(points[id], 0, 1), float2((points[id].x + 1) / 2, (1 - points[id].y) / 2)};
}

float2 flowingCoverUV(float2 uv, constant FlowingUniforms &u, float aspect) {
    float2 size = u.viewport.xy;
    float shortSide = min(size.x, size.y);
    float2 point = (uv - 0.5) * size;
    // Both waves together stay within the user-selected displacement bound.
    point += shortSide * u.viewport.w * 0.70710678
        * float2(sin(6.2831853 * uv.y + u.motion.x), sin(6.2831853 * uv.x + u.motion.y));
    float c = cos(u.viewport.z), s = sin(u.viewport.z);
    point = float2(c * point.x + s * point.y, -s * point.x + c * point.y);
    float side = length(size) + 0.16 * shortSide;
    float2 extent = aspect >= 1 ? float2(side * aspect, side) : float2(side, side / aspect);
    return point / extent + 0.5;
}

fragment float4 amllFlowingCompose(FlowingVertex input [[stage_in]],
    texture2d<float> cover [[texture(0)]], texture2d<float> outgoing [[texture(1)]],
    constant FlowingUniforms &u [[buffer(0)]]) {
    constexpr sampler imageSampler(filter::linear, address::clamp_to_edge);
    float4 next = cover.sample(imageSampler, flowingCoverUV(input.uv, u, u.covers.x));
    float2 oldUV = u.motion.w > 0.5 ? input.uv : flowingCoverUV(input.uv, u, u.covers.y);
    float4 previous = outgoing.sample(imageSampler, oldUV);
    float4 color = mix(previous, next, u.motion.z);
    // Album pixels can contain alpha; the backdrop itself remains opaque SDR.
    return float4(color.rgb + float3(0.08) * (1 - color.a), 1);
}

fragment float4 amllFlowingCopy(FlowingVertex input [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler imageSampler(filter::linear, address::clamp_to_edge);
    return image.sample(imageSampler, input.uv);
}
