#include <metal_stdlib>
using namespace metal;

struct LyricsHDRVertex {
    float2 position;
    float2 uv;
    float2 mask; // local horizontal coordinate and filled edge
    float4 appearance; // feather, dark alpha, bright alpha, linear gain
    float4 crop;
    float2 glow;
};
struct LyricsHDRVarying {
    float4 position [[position]];
    float2 uv;
    float2 mask;
    float4 appearance;
    float4 crop;
    float2 glow;
};
vertex LyricsHDRVarying lyricsHDRVertex(uint id [[vertex_id]],
                                      const device LyricsHDRVertex *vertices [[buffer(0)]]) {
    LyricsHDRVertex v = vertices[id];
    return {float4(v.position, 0, 1), v.uv, v.mask, v.appearance, v.crop, v.glow};
}
fragment half4 lyricsHDRFragment(LyricsHDRVarying in [[stage_in]],
                                texture2d<float> glyphs [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float glyph = glyphs.sample(linearSampler, in.uv).a;
    if (in.glow.x > 0 || in.glow.y > 0) {
        float sum = 0, weight = 0;
        for (int y = -3; y <= 3; ++y) {
            for (int x = -3; x <= 3; ++x) {
                float2 offset = float2(x, y);
                float w = exp(-dot(offset, offset) / 2.0f);
                float2 uv = in.uv + offset * in.glow;
                if (all(uv >= in.crop.xy) && all(uv <= in.crop.zw))
                    sum += glyphs.sample(linearSampler, uv).a * w;
                weight += w;
            }
        }
        glyph = sum / weight;
    }
    float feather = max(0.0001f, in.appearance.x);
    float coverage = clamp((in.mask.y + feather - in.mask.x) / feather, 0.0f, 1.0f);
    float dark = in.appearance.y;
    float bright = in.appearance.z;
    float alpha = glyph * mix(dark, bright, coverage);
    // Replace, rather than overlay, the SDR glyph: only its filled portion
    // receives extended luminance, with the same feather in both terms.
    float light = glyph * (dark * (1.0f - coverage) + bright * coverage * in.appearance.w);
    return half4(half3(light), half(alpha));
}
