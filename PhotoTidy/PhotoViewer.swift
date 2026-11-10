import SwiftUI
import Photos

/// Full-screen compare: swipe between the look-alikes, pinch to zoom,
/// hold to flip to the best shot, and check what's actually in focus.
struct PhotoViewer: View {
    let groupID: UUID
    @State private var index: Int
    @State private var peaking = false
    @State private var comparing = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(groupID: UUID, startIndex: Int) {
        self.groupID = groupID
        _index = State(initialValue: startIndex)
    }

    private var group: PhotoGroup? { model.group(groupID) }
    private var items: [PhotoItem] { group?.items ?? [] }
    private var current: PhotoItem? { items.indices.contains(index) ? items[index] : nil }
    private var isKept: Bool {
        guard let group, let current else { return false }
        return group.keep.contains(current.id)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            bestOverlay
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: isKept)
        .sensoryFeedback(.impact, trigger: comparing)
    }

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                FullImage(asset: item.asset, peaking: peaking)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// The best shot, kept loaded so it can appear instantly while the button is held.
    @ViewBuilder
    private var bestOverlay: some View {
        if let best = items.first {
            FullImage(asset: best.asset, peaking: peaking)
                .background(Color.black)
                .opacity(comparing ? 1.0 : 0.0)
                .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            Text(positionLabel)
                .viewerChip(active: comparing || index == 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var positionLabel: String {
        if comparing { return "★ Best" }
        if index == 0 { return "★ Best · 1 of \(items.count)" }
        return "\(index + 1) of \(items.count)"
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let current {
            VStack(alignment: .leading, spacing: 12) {
                if !current.notes.isEmpty {
                    Text(current.notes.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                HStack(spacing: 8) {
                    Button {
                        withAnimation(Tidy.quick) { peaking.toggle() }
                    } label: {
                        Label("Focus check", systemImage: "scope")
                            .viewerChip(active: peaking)
                    }
                    .buttonStyle(.plain)

                    if index != 0 {
                        holdToCompare
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    withAnimation(Tidy.spring) {
                        model.toggleKeep(groupID: groupID, itemID: current.id)
                    }
                } label: {
                    Label(isKept ? "Keeping" : "Letting go",
                          systemImage: isKept ? "checkmark" : "xmark")
                }
                .buttonStyle(ViewerKeepStyle(kept: isKept))
            }
            .padding(16)
            .background {
                LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.7)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }

    private var holdToCompare: some View {
        Label("Hold for Best", systemImage: "star.fill")
            .viewerChip(active: comparing)
            .onLongPressGesture(minimumDuration: 120, maximumDistance: 200, perform: {}, onPressingChanged: { pressing in
                comparing = pressing
            })
            .accessibilityHint("Shows the best shot while you hold")
    }
}

// MARK: - One full-size photo

struct FullImage: View {
    let asset: PHAsset
    var peaking: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, peaking: peaking)
            } else {
                ProgressView()
                    .tint(Color.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            image = await ImageLoader.image(for: asset, side: 2400, contentMode: .aspectFit)
        }
    }
}

/// Pinch to zoom, drag to pan while zoomed, double-tap to jump in and out.
struct ZoomableImage: View {
    let image: UIImage
    var peaking: Bool

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .focusPeaking(peaking)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify)
            .highPriorityGesture(scale > 1.01 ? pan : nil)
            .onTapGesture(count: 2) {
                withAnimation(Tidy.spring) {
                    if scale > 1.01 {
                        reset()
                    } else {
                        scale = 2.5
                        baseScale = 2.5
                    }
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let proposed = baseScale * value.magnification
                scale = min(max(proposed, 1), 6)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 {
                    withAnimation(Tidy.spring) { reset() }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

// MARK: - Viewer controls (always on black, so they use fixed colours)

private struct ViewerChip: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.medium))
            .foregroundStyle(active ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
    }
}

private extension View {
    func viewerChip(active: Bool) -> some View {
        modifier(ViewerChip(active: active))
    }
}

/// White pill while the photo is kept; a quiet glass pill once it's let go.
private struct ViewerKeepStyle: ButtonStyle {
    var kept: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(kept ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(kept ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
