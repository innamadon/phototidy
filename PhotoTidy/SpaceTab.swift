import SwiftUI
import Photos

/// Where the storage goes: big videos, screen recordings, Live Photos.
struct SpaceTab: View {
    @Environment(AppModel.self) private var model
    @State private var pending: SpaceAction?

    enum SpaceAction: Identifiable {
        case deleteVideos
        case shrinkVideos
        case shrinkLive
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            scrollContent
        }
        .tidyScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .withTabBar()
        .confirmationDialog(dialogTitle, isPresented: dialogShown, titleVisibility: .visible, presenting: pending) { action in
            dialogButton(action)
        } message: { action in
            Text(dialogMessage(action))
        }
        .task(id: model.spaceSection) {
            await loadCurrent()
        }
    }

    private var scrollContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Space", subtitle: "Heaviest first")
            SectionChips(items: SpaceSection.allCases, selection: $model.spaceSection)
            statusCards
            sectionView
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var statusCards: some View {
        if model.isShrinking {
            WorkCard(title: "Shrinking…",
                     done: model.shrinkDone,
                     total: model.shrinkTotal,
                     partial: model.shrinkItemFraction,
                     onStop: { model.cancelShrink() })
        }
        if let report = model.shrinkReport {
            NoteCard(text: report, onClose: { model.shrinkReport = nil })
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch model.spaceSection {
        case .videos:
            videosSection
        case .recordings:
            recordingsSection
        case .livePhotos:
            liveSection
        }
    }

    private func loadCurrent() async {
        switch model.spaceSection {
        case .videos:
            if !model.videosLoaded { await model.loadVideos() }
        case .recordings:
            if !model.recordingsLoaded { await model.loadRecordings() }
        case .livePhotos:
            if !model.livePhotosLoaded { await model.loadLivePhotos() }
        }
    }

    private func dialogButton(_ action: SpaceAction) -> some View {
        let title: String
        let role: ButtonRole?
        switch action {
        case .deleteVideos:
            title = "\(model.removeVerb) \(currentVideoIDs.count)"
            role = .destructive
        case .shrinkVideos:
            title = "Shrink \(currentVideoIDs.count)"
            role = nil
        case .shrinkLive:
            title = "Shrink \(liveIDs.count)"
            role = nil
        }
        return Button(title, role: role) {
            perform(action)
        }
    }

    private func perform(_ action: SpaceAction) {
        switch action {
        case .deleteVideos:
            let ids = currentVideoIDs
            let items = currentVideos
            Task { await model.removeSelected(ids, from: items) }
        case .shrinkVideos:
            model.shrinkVideos(currentVideoIDs, from: currentVideos)
        case .shrinkLive:
            model.shrinkLivePhotos(liveIDs)
        }
    }

    // MARK: Sections

    private var videosSection: some View {
        @Bindable var model = model
        let bytes = model.videos.reduce(Int64(0)) { $0 + $1.bytes }
        let title: String = model.videosLoaded ? count(model.videos.count, "video", "videos") : "Reading…"
        let size: String = bytes > 0 ? "\(formatBytes(bytes)) in total. " : ""
        let detail: String = size + "Tap a row to mark it,\ntap the picture to play it."
        return VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .space, title: title, detail: detail) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A few long videos often weigh\nmore than a thousand photos.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    Text("Shrinking re-saves a video in a smaller format at nearly the same quality.")
                        .font(.footnote)
                        .foregroundStyle(Tidy.muted)
                }
            }
            VideoList(items: model.videos, selected: $model.videoSelected)
        }
    }

    private var recordingsSection: some View {
        @Bindable var model = model
        let bytes = model.recordings.reduce(Int64(0)) { $0 + $1.bytes }
        let title: String = model.recordingsLoaded ? count(model.recordings.count, "recording", "recordings") : "Reading…"
        let size: String = bytes > 0 ? "\(formatBytes(bytes)) in total. " : ""
        let detail: String = size + "Screen recordings, biggest first."
        return VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .space, title: title, detail: detail) {
                Text("Recorded once,\nwatched once.")
                    .font(.tidySerif(26))
                    .foregroundStyle(Tidy.ink)
            }
            if model.recordingsLoaded && model.recordings.isEmpty {
                TipCard(title: "No screen recordings.", detail: "Nothing to clear here.")
            }
            VideoList(items: model.recordings, selected: $model.recordingSelected)
        }
    }

    private var liveSection: some View {
        @Bindable var model = model
        let saving = model.livePhotos.reduce(Int64(0)) { $0 + Int64($1.metric) }
        let title: String = model.livePhotosLoaded ? count(model.livePhotos.count, "Live Photo", "Live Photos") : "Reading…"
        let detail: String = saving > 0 ? "Their motion takes about \(formatBytes(saving)) in total." : "The short video inside each Live Photo."
        return VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .space, title: title, detail: detail) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep the photo;\nlet the motion go.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    Text("Shrinking keeps the still with its date, place and albums, and drops the 3-second video.")
                        .font(.footnote)
                        .foregroundStyle(Tidy.muted)
                }
            }
            if model.livePhotosLoaded && model.livePhotos.isEmpty {
                TipCard(title: "No Live Photos.", detail: "Nothing to shrink here.")
            }
            if !model.livePhotos.isEmpty {
                SelectionSection(items: model.livePhotos,
                                 selected: $model.liveSelected,
                                 filing: true,
                                 caption: { item in
                                     item.metric > 0 ? "saves \(formatBytes(Int64(item.metric)))" : " "
                                 })
            }
        }
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    // MARK: Bottom bar

    private var currentVideos: [LooseItem] {
        model.spaceSection == .recordings ? model.recordings : model.videos
    }

    private var currentVideoIDs: Set<String> {
        let selected = model.spaceSection == .recordings ? model.recordingSelected : model.videoSelected
        return selected.intersection(Set(currentVideos.map { $0.id }))
    }

    private var liveIDs: Set<String> {
        model.liveSelected.intersection(Set(model.livePhotos.map { $0.id }))
    }

    @ViewBuilder
    private var actionBar: some View {
        if !model.isShrinking {
            switch model.spaceSection {
            case .videos, .recordings:
                videoBar
            case .livePhotos:
                liveBar
            }
        }
    }

    @ViewBuilder
    private var videoBar: some View {
        let ids = currentVideoIDs
        if !ids.isEmpty {
            let bytes: Int64 = model.bytes(of: ids, in: currentVideos)
            let shrinkTitle: String = "Shrink \(ids.count)"
            let removeTitle: String = "\(model.removeVerb) \(ids.count)"
            HStack(spacing: 10) {
                Button(shrinkTitle) {
                    pending = .shrinkVideos
                }
                .buttonStyle(SoftButtonStyle())
                Button {
                    pending = .deleteVideos
                } label: {
                    HStack(spacing: 8) {
                        Text(removeTitle)
                        if bytes > 0 {
                            Text(formatBytes(bytes)).opacity(0.65)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var liveBar: some View {
        let ids = liveIDs
        if !ids.isEmpty {
            let saving: Int64 = model.livePhotos
                .filter { ids.contains($0.id) }
                .reduce(Int64(0)) { $0 + Int64($1.metric) }
            let title: String = "Shrink " + counted(ids.count, "Live Photo", "Live Photos")
            Button {
                pending = .shrinkLive
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                    if saving > 0 {
                        Text(formatBytes(saving)).opacity(0.65)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }

    // MARK: Dialog

    private var dialogShown: Binding<Bool> {
        Binding(get: { pending != nil },
                set: { shown in
                    if !shown { pending = nil }
                })
    }

    private var dialogTitle: String {
        switch pending {
        case .deleteVideos:
            return "\(model.removeVerb) \(currentVideoIDs.count)?"
        case .shrinkVideos:
            return "Shrink \(currentVideoIDs.count)?"
        case .shrinkLive:
            return "Shrink \(liveIDs.count) Live Photos?"
        case nil:
            return ""
        }
    }

    private func dialogMessage(_ action: SpaceAction) -> String {
        switch action {
        case .deleteVideos:
            return model.moveToAlbum
                ? "They go to the “Photo Tidy – To Review” album. Nothing is deleted."
                : "They wait in Recently Deleted for 30 days."
        case .shrinkVideos:
            return "Each is re-saved smaller (up to 1080p HD) with the same date, place and albums. iOS asks once to delete the originals, which wait in Recently Deleted for 30 days. Slow-motion videos are left alone."
        case .shrinkLive:
            return "Each becomes a still photo with the same date, place and albums; the short video is dropped. Edits are kept but can't be undone afterwards. iOS asks once to delete the originals, which wait in Recently Deleted for 30 days."
        }
    }
}

/// Secondary pill next to a primary one (card-coloured, ink text).
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Tidy.ink)
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .background(Tidy.raised, in: Capsule())
            .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Tidy.quick, value: configuration.isPressed)
    }
}
