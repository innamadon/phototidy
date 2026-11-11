//
//  Shaders.metal
//  GPU effect used by the full-screen viewer (see Effects.swift).
//
//  Conventions: `float` for coordinates and noise (they need the precision),
//  `half` for colour maths (cheaper on Apple GPUs).
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

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
