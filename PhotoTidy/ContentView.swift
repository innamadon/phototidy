import SwiftUI
import Photos

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        root
            .tint(Tidy.ink)
            .foregroundStyle(Tidy.ink)
            .preferredColorScheme(scheme)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshAuth() }
            }
    }

    /// nil follows the phone's own light/dark setting.
    private var scheme: ColorScheme? {
        switch model.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    @ViewBuilder
    private var root: some View {
        switch model.authStatus {
        case .authorized, .limited:
            MainTabs()
        case .notDetermined:
            WelcomeView()
        default:
            AccessDeniedView()
        }
    }
}

// MARK: - Tabs

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.tab) {
            NavigationStack(path: $model.path) {
                SimilarTab()
                    .navigationDestination(for: UUID.self) { id in
                        GroupReviewView(groupID: id)
                            .id(id)
                    }
            }
            .tag(AppTab.similar)

            NavigationStack {
                ClutterTab()
            }
            .tag(AppTab.clutter)

            NavigationStack {
                SpaceTab()
            }
            .tag(AppTab.space)

            NavigationStack {
                PhoneTab()
            }
            .tag(AppTab.phone)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
                .environment(model)
        }
        .sheet(item: $model.lastCleanup) { summary in
            CleanupSheet(summary: summary)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: model.lifetimeDeleted)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { newValue in
                    if !newValue { model.errorMessage = nil }
                })
    }
}

// MARK: - First launch

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StoneImage(stone: .welcome)
                .frame(height: 300)
                .overlay {
                    LinearGradient(colors: [Tidy.paper.opacity(0.0), Tidy.paper],
                                   startPoint: UnitPoint(x: 0.5, y: 0.45),
                                   endPoint: .bottom)
                }
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keep the clearest one;")
                    Text("let its echoes go.")
                        .font(.tidySerif(40, italic: true))
                }
                .font(.tidySerif(40))

                VStack(alignment: .leading, spacing: 16) {
                    WelcomePoint(title: "Look-alikes",
                                 detail: "Shots of the same moment are gathered and the best one is chosen for you.")
                    WelcomePoint(title: "Clutter",
                                 detail: "Blurry shots, old screenshots and oversized videos, each in its own place.")
                    WelcomePoint(title: "Private",
                                 detail: "Everything stays on this phone. Deleted photos wait 30 days in Recently Deleted.")
                }

                Spacer(minLength: 0)

                Button("Allow photo access") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
        }
        .background(Tidy.paper.ignoresSafeArea())
    }
}

private struct WelcomePoint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).eyebrow()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Tidy.ink.opacity(0.8))
        }
    }
}

struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photo Tidy can't see your photos.")
                .font(.tidySerif(36))
            Text("Turn on photo access in Settings, then come back.")
                .font(.subheadline)
                .foregroundStyle(Tidy.muted)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 12)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Tidy.paper.ignoresSafeArea())
    }
}

// MARK: - After a remove

struct CleanupSheet: View {
    let summary: CleanupSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.movedToAlbum ? "Set aside" : "Let go").eyebrow()
            Text(headline)
                .font(.tidySerif(46))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Tidy.muted)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(26)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topTrailing) {
            Orb()
                .offset(x: 30, y: -20)
        }
        .background(Tidy.paper.ignoresSafeArea())
        .foregroundStyle(Tidy.ink)
        .presentationDetents([.medium])
    }

    private var countText: String {
        summary.count == 1 ? "1 item" : "\(summary.count) items"
    }

    private var headline: String {
        if summary.movedToAlbum {
            return "\(countText) moved."
        }
        if summary.bytes > 0 {
            return "\(formatBytes(summary.bytes)) cleared."
        }
        return "\(countText) cleared."
    }

    private var detail: String {
        if summary.movedToAlbum {
            return "They're in the “\(LibraryChanges.reviewAlbumTitle)” album in Photos. Nothing was deleted; delete them from that album whenever you're ready."
        }
        return "\(countText) now in Recently Deleted. To get the space back today, open Photos → Albums → Recently Deleted and tap Delete All. Otherwise iOS removes them in 30 days."
    }
}

// MARK: - Thumbnail

struct Thumb: View {
    let asset: PHAsset
    /// Longest side in points; used to ask the library for the right size.
    var side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Tidy.sand
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: asset.localIdentifier) {
                let loaded = await ImageLoader.image(for: asset, side: side * displayScale)
                withAnimation(.easeOut(duration: 0.2)) {
                    image = loaded
                }
            }
    }
}
