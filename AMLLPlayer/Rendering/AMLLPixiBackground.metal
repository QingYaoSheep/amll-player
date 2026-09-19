#include <metal_stdlib>
using namespace metal;

// Port of core@0.5.2 PixiRenderer and pinned Pixi 7.4.3 / bulge-pinch 5.1.1.
struct PixiVertex { float4 position [[position]]; float2 uv; };
struct PixiUniforms { float4 viewport; float4 sprites[4]; };
vertex PixiVertex amllPixiQuad(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return {float4(p[id],0,1), float2((p[id].x+1)*0.5,(1-p[id].y)*0.5)};
}
fragment float4 amllPixiSprites(PixiVertex in [[stage_in]], texture2d<float> cover [[texture(0)]],
                               constant PixiUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 result = 0;
    for (uint i=0;i<4;i++) {
        float4 sprite=u.sprites[i];
        float2 d=in.uv*u.viewport.xy-sprite.xy;
        float c=cos(sprite.w), t=sin(sprite.w);
        float2 uv=float2(c*d.x+t*d.y,-t*d.x+c*d.y)/sprite.z+0.5;
        if (all(uv>=0) && all(uv<=1)) {
            float4 color=cover.sample(s,uv)*u.viewport.z;
            result=color+result*(1-color.a);
        }
    }
    return result;
}
fragment float4 amllPixiBlur(PixiVertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                            constant float4 &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // generateBlurFragSource(5), with strength/quality supplied per axis.
    return image.sample(s,in.uv-2*u.xy)*0.153388
         + image.sample(s,in.uv-u.xy)*0.221461
         + image.sample(s,in.uv)*0.250301
         + image.sample(s,in.uv+u.xy)*0.221461
         + image.sample(s,in.uv+2*u.xy)*0.153388;
}
fragment float4 amllPixiColor(PixiVertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                             constant float4 &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c=image.sample(s,in.uv);
    float3 rgb=c.a>0 ? c.rgb/c.a : c.rgb;
    if(u.x==0) rgb=2.2*rgb-0.4*(rgb.r+rgb.g+rgb.b); // saturate(1.2)
    else if(u.x==1) rgb*=0.6;
    else rgb=rgb*1.3-0.15/255.0; // contrast(0.3,true) normalizes matrix offsets
    return float4(rgb*c.a,c.a);
}
fragment float4 amllPixiBulge(PixiVertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                             constant float4 &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 coord=in.uv*u.xy-u.zw*u.xy;
    float distance=length(coord), radius=(u.x+u.y)/2;
    if(distance>0 && distance<radius) coord*=mix(1.0,smoothstep(0.0,radius/distance,distance/radius),0.75);
    coord=(coord+u.zw*u.xy)/u.xy;
    float2 clamped=clamp(coord,0.5/u.xy,1-0.5/u.xy);
    return image.sample(s,clamped)*max(0.0,1-length(coord-clamped));
}
fragment float4 amllPixiCopy(PixiVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    return image.sample(s,in.uv);
}
