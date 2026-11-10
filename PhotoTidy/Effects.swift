import SwiftUI

/// A slab of layered stone, drawn on the GPU by `stoneStrata` in Shaders.metal.
/// It is static, so it is only drawn when the card appears or changes size.
struct StoneTexture: View {
    let stone: Stone

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.black)
                .colorEffect(shader(size: proxy.size))
        }
        .accessibilityHidden(true)
    }

    private func shader(size: CGSize) -> Shader {
        let c = stone.colors
        return ShaderLibrary.stoneStrata(
            .float2(size),
            .float(stone.seed),
            .color(c[0]),
            .color(c[1]),
            .color(c[2]),
            .color(c[3])
        )
    }
}

/// Highlights the sharp parts of a photo. Drawn by `focusPeaking` in Shaders.metal.
struct FocusPeaking: ViewModifier {
    var enabled: Bool
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.layerEffect(shader,
                            maxSampleOffset: CGSize(width: 2, height: 2),
                            isEnabled: enabled)
    }

    private var shader: Shader {
        let step = Float(1.0 / max(displayScale, 1.0))
        return ShaderLibrary.focusPeaking(
            .float(step),
            .float(Float(0.07)),
            .color(Color(red: 0.90, green: 0.50, blue: 0.36))
        )
    }
}

extension View {
    func focusPeaking(_ enabled: Bool) -> some View {
        modifier(FocusPeaking(enabled: enabled))
    }
}
