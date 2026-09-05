#include <metal_stdlib>
using namespace metal;

struct AMLLBackgroundVertex {
    float2 position;
    float2 uv;
};

struct AMLLBackgroundVarying {
    float4 position [[position]];
    float2 uv;
};

struct AMLLBackgroundUniforms {
    float time;
    float volume;
    float alpha;
    float padding;
};

vertex AMLLBackgroundVarying amllMeshVertex(uint id [[vertex_id]], const device AMLLBackgroundVertex *vertices [[buffer(0)]]) {
    AMLLBackgroundVarying output;
    output.position = float4(vertices[id].position, 0.0, 1.0);
    output.uv = vertices[id].uv;
    return output;
}

fragment float4 amllMeshFragment(AMLLBackgroundVarying input [[stage_in]],
                                 texture2d<float> album [[texture(0)]],
                                 constant AMLLBackgroundUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler albumSampler(address::mirrored_repeat, filter::linear);
    const float angle = (uniforms.time + uniforms.volume) * 2.0;
    const float sine = sin(angle);
    const float cosine = cos(angle);
    const float2 centered = input.uv - float2(0.2);
    const float2 rotated = float2(cosine * centered.x - sine * centered.y,
                                  sine * centered.x + cosine * centered.y);
    const float2 finalUV = rotated * max(0.001, 1.0 - uniforms.volume * 2.0) + float2(0.5);
    const float2 texel = float2(1.0 / 32.0);
    float4 result = album.sample(albumSampler, finalUV) * 0.227027;
    result += album.sample(albumSampler, finalUV + float2(texel.x, 0)) * 0.1945946;
    result += album.sample(albumSampler, finalUV - float2(texel.x, 0)) * 0.1945946;
    result += album.sample(albumSampler, finalUV + float2(0, texel.y)) * 0.1216216;
    result += album.sample(albumSampler, finalUV - float2(0, texel.y)) * 0.1216216;
    result += album.sample(albumSampler, finalUV + texel) * 0.0351351;
    result += album.sample(albumSampler, finalUV - texel) * 0.0351351;
    result += album.sample(albumSampler, finalUV + float2(texel.x, -texel.y)) * 0.0351351;
    result += album.sample(albumSampler, finalUV + float2(-texel.x, texel.y)) * 0.0351351;

    // Exact color pipeline used when AMLL prepares its 32×32 album texture.
    result.rgb = (result.rgb - 0.5) * 0.4 + 0.5;
    const float gray = dot(result.rgb, float3(0.3, 0.59, 0.11));
    result.rgb = gray * -2.0 + result.rgb * 3.0;
    result.rgb = ((result.rgb - 0.5) * 1.7 + 0.5) * 0.75;

    const float alphaVolume = uniforms.alpha * max(0.5, 1.0 - uniforms.volume * 0.5);
    result.rgb *= alphaVolume;
    result.a *= alphaVolume;
    const float dither = (1.0 / 255.0) * fract(52.9829189 * fract(dot(input.position.xy, float2(0.06711056, 0.00583715)))) - (0.5 / 255.0);
    result.rgb += dither;
    const float vignette = smoothstep(0.8, 0.3, distance(input.uv, float2(0.5)));
    result.rgb *= 0.6 + vignette * 0.4;
    return result;
}
