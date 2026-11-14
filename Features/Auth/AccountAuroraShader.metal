// Aurora shader from the user's MetalLoginDemo/AuroraShader.metal.
#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 5; i++) {
        value += amplitude * valueNoise(p);
        p = p * 2.02 + 13.7;
        amplitude *= 0.5;
    }
    return value;
}

[[ stitchable ]] half4 auroraBackground(float2 position, half4 color,
                                        float2 size, float time, float2 touch) {
    float2 p = (position - 0.5 * size) / size.y;
    float2 t = (touch - 0.5 * size) / size.y;
    float2 away = p - t;
    float influence = exp(-dot(away, away) * 6.0);
    p += away * influence * 0.25;
    float2 q = float2(fbm(p * 1.6 + time * 0.05),
                      fbm(p * 1.6 - time * 0.04 + 5.2));
    float n = fbm(p * 1.8 + q * 2.0 + float2(0.0, time * 0.08));
    float3 deep = float3(0.03, 0.04, 0.12);
    float3 violet = float3(0.45, 0.22, 0.85);
    float3 teal = float3(0.10, 0.80, 0.75);
    float3 col = mix(deep, violet, smoothstep(0.25, 0.65, n));
    col = mix(col, teal, smoothstep(0.55, 0.90, q.x) * 0.8);
    col += float3(0.35, 0.45, 1.0) * influence * 0.25;
    // Equivalent to the demo's intended reversed smoothstep, with defined edges.
    float vignette = 1.0 - smoothstep(0.2, 1.1, length(p));
    col *= mix(0.55, 1.0, vignette);
    return half4(half3(col), 1.0h);
}

// A static charcoal light field with physical-pixel grain. No moving particles
// or extra animation loop: the texture remains still behind every onboarding step.
[[ stitchable ]] half4 onboardingBackdrop(float2 position, half4 color, float2 size, float scale) {
    float2 uv = position / max(size, float2(1.0));
    float2 upper = (uv - float2(0.12, 0.18)) * float2(0.85, 1.0);
    float2 lower = (uv - float2(0.90, 0.82)) * float2(1.0, 0.85);
    float light = 0.008 + 0.052 * exp(-dot(upper, upper) * 4.5)
                        + 0.018 * exp(-dot(lower, lower) * 6.0);
    light += (valueNoise(uv * float2(3.0, 4.0)) - 0.5) * 0.008;
    float grain = (hash21(floor(position * max(scale, 1.0))) - 0.5) * 0.025;
    return half4(half3(max(light + grain, 0.0)), 1.0h);
}
