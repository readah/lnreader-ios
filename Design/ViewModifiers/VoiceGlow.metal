// VoiceGlow.metal
// A narrator's voice as light moving through glass.
//
// GlassGlow turns an alpha mask into a distance field, floats ten lights
// through it and refracts them at the edge. A voice chip, a card and a dot have
// known rounded-rect shapes, so the distance field here is analytic: one SDF
// gives the bevel, the refracted light and the rim without a mask pass, a jump
// flood or a mip chain. That is what makes it cheap enough to sit in a list.
//
// Everything is measured in units of the view's height, so a capsule, an 82pt
// card and a 12pt dot share one look instead of three.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float3 voiceHSV(float h, float s, float v) {
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

/// One soft light, a gaussian streak moving on a Lissajous path. Every frequency
/// is an integer number of turns over one loop, so the field repeats seamlessly.
static float3 voiceStreak(float2 q, float2 centre, float2 dir, float2 radii, float energy, float3 colour) {
    float2 d = q - centre;
    float2 perp = float2(-dir.y, dir.x);
    float u = dot(d, dir) / radii.x;
    float v = dot(d, perp) / radii.y;
    return energy * exp(-(u * u + v * v)) * colour;
}

/// The light field in shape-centred units: x spans the shape's aspect, y spans
/// one height, origin at the centre. Three streaks carry the voice's analogous
/// hues and a fourth is a cool highlight, the same family GlassGlow's ten
/// lights cycle through. Streaks, not blobs: a voice reading as a shape needs
/// direction, and ribbons catch the bevel along their length.
static float3 voiceField(float2 q, float aspect, float t, float3 hues, float intensity) {
    q.x /= max(aspect, 1.0);
    float3 e = float3(0.0);
    e += voiceStreak(q, float2(0.26 * sin(t + 0.4), 0.20 * cos(t + 1.1)),
                     normalize(float2(cos(t + 0.3), sin(t + 0.3))), float2(0.46, 0.13),
                     1.10 * intensity, voiceHSV(hues.x, 0.72, 1.0));
    e += voiceStreak(q, float2(0.32 * cos(t + 2.6), 0.22 * sin(t + 0.7)),
                     normalize(float2(cos(-t + 1.2), sin(-t + 1.2))), float2(0.40, 0.10),
                     0.90 * intensity, voiceHSV(hues.y, 0.60, 1.0));
    e += voiceStreak(q, float2(0.30 * sin(t * 2.0 + 4.1), 0.18 * cos(2.0 * t + 3.3)),
                     normalize(float2(cos(2.0 * t + 2.2), sin(2.0 * t + 2.2))), float2(0.34, 0.09),
                     0.80 * intensity, voiceHSV(hues.z, 0.65, 1.0));
    e += voiceStreak(q, float2(0.24 * cos(2.0 * t + 5.2), 0.24 * sin(3.0 * t + 1.9)),
                     normalize(float2(cos(t + 4.0), sin(t + 4.0))), float2(0.20, 0.07),
                     0.70 * intensity, voiceHSV(hues.x, 0.30, 1.0));
    return e;
}

/// Signed distance to a rounded rectangle, positive outside.
static float voiceSD(float2 p, float2 halfSize, float radius) {
    float2 d = abs(p - halfSize) - (halfSize - radius);
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

[[ stitchable ]] half4 voiceGlass(
    float2 position, half4 color,
    float2 size, float cornerRadius, float phase, float3 hues, float intensity
) {
    float2 halfSize = max(size, float2(1.0)) * 0.5;
    float radius = clamp(cornerRadius, 0.0, min(halfSize.x, halfSize.y));
    float sd = voiceSD(position, halfSize, radius);
    float coverage = clamp(0.5 - sd, 0.0, 1.0);
    if (coverage <= 0.0) return half4(0.0h);

    // Outward normal from central differences, so the edge refraction follows
    // the corners instead of the bounding box.
    float probe = 0.75;
    float2 gradient = float2(
        voiceSD(position + float2(probe, 0.0), halfSize, radius) - voiceSD(position - float2(probe, 0.0), halfSize, radius),
        voiceSD(position + float2(0.0, probe), halfSize, radius) - voiceSD(position - float2(0.0, probe), halfSize, radius));
    float gradientLength = length(gradient);
    float2 normal = gradientLength > 1e-5 ? gradient / gradientLength : float2(0.0);

    float height = max(size.y, 1.0);
    float2 p = (position - halfSize) / height;
    p.y = -p.y;
    float aspect = size.x / height;
    float depth = max(-sd, 0.0) / height;
    float t = phase * 6.28318530718;

    // Bevel: light is pulled inward at the edge, and split per channel like a
    // prism, which is where the colour fringe along the rim comes from.
    float bevel = pow(clamp(1.0 - depth / 0.22, 0.0, 1.0), 2.0);
    float bend = 0.10 * bevel;
    float split = 0.05 * bevel;
    float3 e = float3(
        voiceField(p - normal * (bend - split), aspect, t, hues, intensity).r,
        voiceField(p - normal * bend, aspect, t, hues, intensity).g,
        voiceField(p - normal * (bend + split), aspect, t, hues, intensity).b);

    // Saturating light instead of a clipped sum: GlassGlow's 1-exp curve keeps
    // highlights bright without flattening them to white.
    float3 light = 1.0 - exp(-1.9 * e);
    light = pow(clamp(light, 1e-4, 1.0), float3(0.9));

    // Deep voice-tinted glass under the lights, dark enough for white labels.
    float3 glass = voiceHSV(hues.x, 0.85, 0.13) + float3(0.012, 0.010, 0.018);
    glass += light * 0.62;

    // A slow specular sweep, the "light moving through the glass" of the film.
    float2 q = p * float2(1.0 / max(aspect, 1.0), 1.0);
    float sweep = exp(-pow((q.x * 0.8 + q.y * 0.6 - sin(t + 2.0) * 0.55) / 0.30, 2.0));
    glass += sweep * 0.10 * voiceHSV(hues.y, 0.35, 1.0);

    // Rim: a thin band that catches the nearest light, plus a little ambient
    // so the silhouette stays legible on a dark page.
    float rim = exp(-abs(sd) / max(height * 0.075, 1.0));
    glass += rim * (0.18 * voiceHSV(hues.z, 0.30, 1.0) + 0.55 * light + 0.05);

    // A touch of depth: the top of the glass is the lit side.
    glass *= mix(1.06, 0.88, clamp(position.y / height, 0.0, 1.0));

    // Half a step of ordered noise; the deep base would band on 8-bit displays.
    float dither = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    glass += dither / 255.0;

    half alpha = half(coverage) * color.a;
    return half4(half3(clamp(glass, 0.0, 1.0)) * alpha, alpha);
}
