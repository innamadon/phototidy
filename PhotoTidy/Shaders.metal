//
//  Shaders.metal
//  Two small GPU effects used by the SwiftUI views (see Effects.swift).
//
//  Conventions: `float` for coordinates and noise (they need the precision),
//  `half` for colour maths (cheaper on Apple GPUs).
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Noise helpers

static float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

static float valueNoise(float2 uv) {
    float2 i = floor(uv);
    float2 f = fract(uv);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Four octaves is plenty for a soft background.
static float fbm(float2 uv) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 4; i++) {
        value += amplitude * valueNoise(uv * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// MARK: - Stone strata
//
// A slab of layered stone: warped sedimentary bands, fine laminations,
// thin mineral veins and a sandy grain. Domain-warped noise bends the
// layers the way pressure bends rock. Static, so it costs nothing once drawn.
// Used with `.colorEffect` on a plain rectangle.
//   seed  - picks a different slab
//   dark / mid / light - the three tones of the layers
//   vein  - colour of the mineral veins

[[ stitchable ]] half4 stoneStrata(float2 position,
                                   half4 color,
                                   float2 size,
                                   float seed,
                                   half4 dark,
                                   half4 mid,
                                   half4 light,
                                   half4 vein) {
    float longSide = max(max(size.x, size.y), 1.0);
    float2 uv = (position / longSide) * 3.0;

    // Tilt the slab so the layers run diagonally (rotation by -0.5 rad).
    float ca = 0.8775826;
    float sa = -0.4794255;
    float2 r = float2(uv.x * ca - uv.y * sa, uv.x * sa + uv.y * ca);
    r += float2(seed * 3.7, seed * 1.9);

    // Two rounds of warping.
    float2 q = float2(fbm(r), fbm(r + float2(5.2, 1.3)));
    float2 w = float2(fbm(r + 1.8 * q + float2(1.7, 9.2)),
                      fbm(r + 1.8 * q + float2(8.3, 2.8)));

    // Position across the layers, bent by the warp.
    float band = r.y * 2.0 + 1.5 * fbm(float2(r.x * 0.6, r.y * 1.4) + 2.0 * w);
    float layers = fbm(float2(band * 1.7, seed * 5.0 + 0.3 * r.x));
    float fine = 0.5 + 0.5 * sin(band * 16.0 + 5.0 * w.x);
    float tone = layers * 0.8 + fine * 0.2;

    half3 rgb = mix(dark.rgb, mid.rgb, half(smoothstep(0.30, 0.52, tone)));
    rgb = mix(rgb, light.rgb, half(smoothstep(0.52, 0.70, tone)));

    // Mineral veins: thin lines where a noise field crosses its midpoint,
    // present only in some regions of the slab.
    float crossing = abs(fbm(r * 1.3 + 3.0 * w + float2(seed, 0.0)) - 0.5);
    float region = smoothstep(0.35, 0.6, fbm(r * 0.7 + float2(9.0, seed)));
    float veinMask = (1.0 - smoothstep(0.0, 0.03, crossing)) * region;
    rgb = mix(rgb, vein.rgb, half(veinMask * 0.85));

    // Sandy grain.
    half grain = half(hash21(position + float2(13.0, 17.0))) - 0.5h;
    rgb += grain * 0.07h;

    return half4(rgb, 1.0h) * color.a;
}

// MARK: - Focus check
//
// Lights up the parts of a photo that are truly sharp (strong fine detail),
// and mutes everything else, like focus peaking on a camera.
// Used with `.layerEffect`. `stepSize` is one screen pixel in points.

static half luma(half4 c) {
    return dot(c.rgb, half3(0.299h, 0.587h, 0.114h));
}

[[ stitchable ]] half4 focusPeaking(float2 position,
                                    SwiftUI::Layer layer,
                                    float stepSize,
                                    float threshold,
                                    half4 tint) {
    half4 c = layer.sample(position);

    half center = luma(c);
    half north = luma(layer.sample(position + float2(0.0, -stepSize)));
    half south = luma(layer.sample(position + float2(0.0, stepSize)));
    half east = luma(layer.sample(position + float2(stepSize, 0.0)));
    half west = luma(layer.sample(position + float2(-stepSize, 0.0)));

    // Laplacian: large where there is crisp, fine detail.
    half detail = abs(north + south + east + west - 4.0h * center);
    half lo = half(threshold);
    half amount = smoothstep(lo, lo * 2.5h, detail);

    // Mute the photo so the highlights stand out.
    half3 muted = mix(c.rgb, half3(center, center, center), 0.7h) * 0.6h;
    half3 rgb = mix(muted, tint.rgb, amount);

    return half4(rgb * c.a, c.a);
}
