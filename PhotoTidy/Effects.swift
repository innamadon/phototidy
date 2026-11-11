import SwiftUI

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
