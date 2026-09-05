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
    float aspect;
};

vertex AMLLBackgroundVarying amllMeshVertex(uint id [[vertex_id]],
                                            const device AMLLBackgroundVertex *vertices [[buffer(0)]],
                                            constant AMLLBackgroundUniforms &uniforms [[buffer(1)]]) {
    AMLLBackgroundVarying output;
    float2 position = vertices[id].position;
    if (uniforms.aspect > 1.0) {
        position.y *= uniforms.aspect;
    } else {
        position.x /= max(0.001, uniforms.aspect);
    }
    output.position = float4(position, 0.0, 1.0);
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
    float4 result = album.sample(albumSampler, finalUV);

    const float alphaVolume = uniforms.alpha * max(0.5, 1.0 - uniforms.volume * 0.5);
    result.rgb *= alphaVolume;
    result.a *= alphaVolume;
    const float dither = (1.0 / 255.0) * fract(52.9829189 * fract(dot(input.position.xy, float2(0.06711056, 0.00583715)))) - (0.5 / 255.0);
    result.rgb += dither;
    const float vignette = smoothstep(0.8, 0.3, distance(input.uv, float2(0.5)));
    result.rgb *= 0.6 + vignette * 0.4;
    return result;
}
