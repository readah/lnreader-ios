#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Sample the entire scene once, including the cover fountain. Glass can only
// refract pixels in this layer: drawing a second fountain above it bypasses optics.
[[ stitchable ]] half4 liquidGlassLens(
    float2 position, SwiftUI::Layer layer, float2 center, float2 radius,
    float power, float dispersion
) {
    half4 original = layer.sample(position);
    float2 delta = position - center;
    float2 n = delta / max(radius, float2(1.0));
    float r = length(n);
    if (r > 1.005) return original;

    float2 direction = r > 0.0001 ? n / r : float2(0.0);
    float2 tangent = float2(-direction.y, direction.x);
    float zoom = mix(1.0, 0.425 + pow(r, 3.4) * 0.85, power);
    float split = pow(r, 2.6) * min(min(radius.x, radius.y) * 0.35, 27.0) * dispersion;
    // Clamp displacement to the maxSampleOffset declared by the SwiftUI view.
    float2 base = delta * (zoom - 1.0);
    float2 redOffset = clamp(base - direction * split * 1.15 + tangent * split * 0.25, -160.0, 160.0);
    float2 greenOffset = clamp(base, -160.0, 160.0);
    float2 blueOffset = clamp(base + direction * split * 1.25 - tangent * split * 0.25, -160.0, 160.0);
    half4 red = layer.sample(position + redOffset);
    half4 green = layer.sample(position + greenOffset);
    half4 blue = layer.sample(position + blueOffset);
    // Color comes exclusively from wavelength-separated samples. No rainbow
    // palette, colored caustic, cobalt crescent or warm tint is painted on glass.
    half3 color = half3(red.r, green.g, blue.b);

    float z = sqrt(max(1.0 - min(r * r, 1.0), 0.0));
    float frost = mix(0.12, 0.015, power) * (0.4 + 0.6 * (1.0 - z));
    color = mix(color, half3(0.12h), half(frost));
    float topLight = pow(max(dot(n, normalize(float2(-0.35, -0.85))), 0.0), 4.0);
    float specular = topLight * smoothstep(0.67, 0.985, r) * 0.38;
    float rim = smoothstep(0.965, 0.995, r) * (1.0 - smoothstep(0.995, 1.005, r));
    float shade = smoothstep(0.80, 0.965, r) * (1.0 - rim) * 0.025;
    color += half3(specular + rim * 0.32 - shade);
    float feather = 1.0 / max(min(radius.x, radius.y), 1.0);
    float mask = 1.0 - smoothstep(1.0 - feather, 1.0 + feather, r);
    return mix(original, half4(clamp(color, half3(0.0h), half3(1.0h)), 1.0h), half(mask));
}
