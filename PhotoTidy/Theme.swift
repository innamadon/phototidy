import SwiftUI
import UIKit
import CoreText

/// The look of the app: editorial and quiet.
/// Near-white paper, soft grey floating cards, a light serif for headlines,
/// midnight-navy buttons, and stone textures in bronze, ochre and slate.
/// Every colour has a dark twin (deep navy paper) for night use.
enum Tidy {
    private static func pair(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(UIColor(dynamicProvider: { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1)
        }))
    }

    /// Screen background.
    static let paper = pair((0.984, 0.980, 0.973), (0.043, 0.059, 0.094))
    /// Floating cards.
    static let card = pair((0.953, 0.949, 0.937), (0.082, 0.102, 0.149))
    /// Raised controls (round buttons, tab bar).
    static let raised = pair((1.0, 1.0, 1.0), (0.118, 0.141, 0.196))
    /// Main text and primary buttons: midnight navy by day, warm white by night.
    static let ink = pair((0.059, 0.086, 0.149), (0.945, 0.933, 0.910))
    /// Text on primary buttons.
    static let onInk = pair((0.984, 0.980, 0.973), (0.059, 0.086, 0.149))
    /// Secondary text.
    static let muted = pair((0.467, 0.451, 0.424), (0.639, 0.627, 0.604))
    /// Quiet lines and fills.
    static let line = pair((0.863, 0.847, 0.816), (0.176, 0.200, 0.259))
    /// Photo placeholders.
    static let sand = pair((0.906, 0.898, 0.878), (0.118, 0.141, 0.196))
    /// Bronze: the "best" mark and small accents.
    static let bronze = pair((0.604, 0.482, 0.310), (0.812, 0.686, 0.478))
    /// Brush-line red: progress strokes and anything being let go.
    static let terracotta = pair((0.710, 0.322, 0.231), (0.847, 0.498, 0.396))
    /// Anything being kept.
    static let sage = pair((0.431, 0.502, 0.396), (0.616, 0.682, 0.557))

    static let shadow = Color(UIColor(dynamicProvider: { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0, alpha: 0.5)
        }
        return UIColor(red: 0.24, green: 0.19, blue: 0.14, alpha: 0.11)
    }))

    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let quick = Animation.spring(response: 0.28, dampingFraction: 0.85)
}

// MARK: - Type

/// The headline serif (Cormorant Garamond, bundled with the app).
/// If it can't be loaded, the system serif is used instead.
enum Fonts {
    static let regular = "CormorantGaramond-Regular"
    static let italic = "CormorantGaramond-Italic"
    static let medium = "CormorantGaramond-Medium"
    private(set) static var available = false

    /// Call once at launch.
    static func register() {
        for name in [regular, italic, medium] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        available = UIFont(name: regular, size: 12) != nil
    }
}

extension Font {
    /// Serif headline at a point size that still scales with the user's text size.
    static func tidySerif(_ size: CGFloat, italic: Bool = false, medium: Bool = false) -> Font {
        if Fonts.available {
            let name = italic ? Fonts.italic : (medium ? Fonts.medium : Fonts.regular)
            return Font.custom(name, size: size, relativeTo: .title)
        }
        let fallback = Font.system(size: size * 0.86, weight: .regular, design: .serif)
        return italic ? fallback.italic() : fallback
    }
}

extension View {
    /// Small, widely spaced capitals used as labels.
    func eyebrow(_ color: Color = Tidy.muted) -> some View {
        self
            .font(.caption2.weight(.medium))
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// A soft, borderless floating card.
    func tidyCard(corner: CGFloat = 26) -> some View {
        self
            .background(Tidy.card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: Tidy.shadow, radius: 16, x: 0, y: 10)
    }

    func chip(active: Bool = false) -> some View {
        modifier(ChipStyle(active: active))
    }

    /// Paper background and no system navigation bar (tab screens draw their own header).
    func tidyScreen() -> some View {
        self
            .background(Tidy.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }

    /// Adds the floating tab bar under everything else on a tab's root screen.
    func withTabBar() -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingTabBar()
            }
    }
}

/// Large serif title with a small line under it, at the top of each tab.
struct ScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.tidySerif(38))
                .foregroundStyle(Tidy.ink)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Tidy.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Brush strokes

/// A long sweeping curve, drawn from its start up to `progress` (0…1).
struct SweepArc: Shape {
    var progress: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static func points(in rect: CGRect) -> (start: CGPoint, control: CGPoint, end: CGPoint) {
        let start = CGPoint(x: rect.minX + 4, y: rect.maxY - 5)
        let control = CGPoint(x: rect.minX + rect.width * 0.5, y: rect.minY - rect.height * 0.75)
        let end = CGPoint(x: rect.maxX - 6, y: rect.minY + rect.height * 0.5)
        return (start, control, end)
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Where the tip of the stroke is at `t`.
    static func head(in rect: CGRect, at t: CGFloat) -> CGPoint {
        let p = points(in: rect)
        let a = mix(p.start, p.control, t)
        let b = mix(p.control, p.end, t)
        return mix(a, b, t)
    }

    func path(in rect: CGRect) -> Path {
        let t = min(max(progress, 0), 1)
        let p = Self.points(in: rect)
        var path = Path()
        path.move(to: p.start)
        if t > 0 {
            // The first part of a curve is itself a curve (de Casteljau).
            path.addQuadCurve(to: Self.head(in: rect, at: t), control: Self.mix(p.start, p.control, t))
        }
        return path
    }
}

/// The same sweep as a brush mark: it swells in the middle and tapers to a
/// point at both ends, the way a line pulled with a calligraphy brush does.
struct SweepBrush: Shape {
    var progress: CGFloat = 1
    var weight: CGFloat = 3

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(max(progress, 0), 1)
        var path = Path()
        guard t > 0 else { return path }
        let p = SweepArc.points(in: rect)
        let head = SweepArc.head(in: rect, at: t)
        let control = SweepArc.mix(p.start, p.control, t)
        let belly = CGPoint(x: control.x, y: control.y + weight * 2)
        path.move(to: p.start)
        path.addQuadCurve(to: head, control: control)
        path.addQuadCurve(to: p.start, control: belly)
        path.closeSubpath()
        return path
    }
}

/// Progress drawn as a sweeping red brush line with a dot at its tip,
/// over a faint guide that ends in a small pale dot.
struct SweepProgress: View {
    var fraction: Double

    var body: some View {
        let t = CGFloat(min(max(fraction, 0), 1))
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                SweepArc(progress: 1)
                    .stroke(Tidy.line, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                Circle()
                    .fill(Tidy.line)
                    .frame(width: 5, height: 5)
                    .position(SweepArc.head(in: rect, at: 1))
                SweepBrush(progress: t)
                    .fill(Tidy.terracotta.opacity(0.55))
                SweepArc(progress: t)
                    .stroke(Tidy.terracotta, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                Circle()
                    .fill(Tidy.terracotta)
                    .frame(width: 6, height: 6)
                    .position(SweepArc.head(in: rect, at: 0))
                Circle()
                    .fill(Tidy.terracotta)
                    .frame(width: 8, height: 8)
                    .position(SweepArc.head(in: rect, at: t))
            }
        }
        .frame(height: 40)
        .animation(Tidy.quick, value: fraction)
        .accessibilityHidden(true)
    }
}

/// A soft blurred glow of ochre and sage, placed in the corner of a card.
struct Orb: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Color(red: 0.84, green: 0.69, blue: 0.38).opacity(0.75),
                                        Color(red: 0.49, green: 0.55, blue: 0.44).opacity(0.3),
                                        Color(red: 0.49, green: 0.55, blue: 0.44).opacity(0.0)],
                               center: .center,
                               startRadius: 0,
                               endRadius: 70)
            )
            .frame(width: 140, height: 140)
            .blur(radius: 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// Main action: a midnight pill.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Tidy.onInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 24)
            .background(Tidy.ink, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(Tidy.quick, value: configuration.isPressed)
    }
}

/// Secondary action: quiet grey text.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(Tidy.muted)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

/// "Label  (→)": the main action inside a card.
struct ArrowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Tidy.ink)
                Image(systemName: "arrow.right")
                    .font(.subheadline)
                    .foregroundStyle(Tidy.ink)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Circle().strokeBorder(Tidy.muted, lineWidth: 1.2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small pill used for toggles and minor actions.
struct ChipStyle: ViewModifier {
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.medium))
            .foregroundStyle(active ? Tidy.onInk : Tidy.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(active ? AnyShapeStyle(Tidy.ink) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
    }
}

// MARK: - Floating tab bar

struct FloatingTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                item(.similar, "Similar", "square.on.square")
                item(.clutter, "Clutter", "tray")
                item(.space, "Space", "internaldrive")
                item(.phone, "Phone", "iphone")
            }
            .padding(6)
            .background(Tidy.raised.opacity(0.92), in: Capsule())
            .shadow(color: Tidy.shadow, radius: 16, x: 0, y: 8)

            Button {
                model.showSettings = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gearshape")
                        .font(.body)
                    Text("Settings")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Tidy.ink)
                .frame(width: 66, height: 66)
                .background(Tidy.raised.opacity(0.92), in: Circle())
                .shadow(color: Tidy.shadow, radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func item(_ tab: AppTab, _ title: String, _ symbol: String) -> some View {
        let selected = model.tab == tab
        return Button {
            withAnimation(Tidy.quick) {
                model.tab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(Tidy.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(selected ? Tidy.line.opacity(0.6) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Stone hero card

/// Which stone photo a card shows. Each tab has its own crop.
enum Stone {
    case similar
    case clutter
    case space
    case phone
    case welcome

    var imageName: String {
        switch self {
        case .similar: return "stone-similar"
        case .clutter: return "stone-clutter"
        case .space: return "stone-space"
        case .phone: return "stone-phone"
        case .welcome: return "stone-welcome"
        }
    }
}

/// A stone photo that fills its frame.
struct StoneImage: View {
    let stone: Stone

    var body: some View {
        GeometryReader { proxy in
            Image(stone.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .accessibilityHidden(true)
    }
}

/// A card with a stone panel on top (white serif title over it) and plain content below.
struct StoneCard<Content: View>: View {
    let stone: Stone
    let title: String
    let detail: String
    private let content: Content

    init(stone: Stone, title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.stone = stone
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panel
            content
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tidy.card)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: Tidy.shadow, radius: 18, x: 0, y: 12)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.tidySerif(34))
                .contentTransition(.numericText())
            Text(detail)
                .font(.footnote)
                .lineSpacing(3)
                .opacity(0.95)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 84)
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .bottomLeading)
        .background {
            ZStack {
                StoneImage(stone: stone)
                // The stone sinks into midnight navy, where the text sits.
                LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.12).opacity(0.0),
                                        Color(red: 0.04, green: 0.06, blue: 0.12).opacity(0.78)],
                               startPoint: UnitPoint(x: 0.5, y: 0.15),
                               endPoint: .bottom)
            }
        }
        .clipped()
    }
}

/// Serif heading with two or three short plain lines under it (the "Keep / Let go" columns).
struct FactColumn: View {
    let heading: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.tidySerif(28))
                .foregroundStyle(Tidy.ink)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Tidy.ink.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Brush-line progress, caption and Stop, shown in a card while scanning.
struct ScanProgress: View {
    @Environment(AppModel.self) private var model
    let caption: String
    let found: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SweepProgress(fraction: model.progressFraction)
            Text(found)
                .font(.tidySerif(26))
                .foregroundStyle(Tidy.ink)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Tidy.muted)
            Button("Stop") {
                model.cancelScan()
            }
            .buttonStyle(QuietButtonStyle())
        }
    }
}

/// Floating pill with the remove action, shared by every tab.
struct RemoveBar: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let bytes: Int64
    let noun: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(model.removeVerb) \(count) \(noun)")
                if bytes > 0 {
                    Text(formatBytes(bytes))
                        .opacity(0.65)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}
