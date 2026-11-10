import SwiftUI
import Photos
import AVKit

// MARK: - Blurry

/// Out-of-focus photos. Nothing is pre-selected: you pick what goes.
struct BlurryTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.blurryVisible

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Blurry", subtitle: "Photos where nothing is in focus")
                BlurryHero(visibleCount: items.count)
                if !items.isEmpty {
                    SelectionSection(items: items, selected: $model.blurSelected)
                } else if model.blurScanned && !model.isBlurScanning {
                    TipCard(title: "Nothing out of focus.",
                            detail: "Slide toward “More” to include slightly soft shots, or pick a longer time range in Settings.")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .tidyScreen()
        .modifier(RemoveFlow(items: items, selected: model.blurSelected, noun: "photos"))
        .withTabBar()
    }
}

struct BlurryHero: View {
    @Environment(AppModel.self) private var model
    let visibleCount: Int

    var body: some View {
        StoneCard(stone: .slate, title: title, detail: detail) {
            content
        }
        .animation(Tidy.spring, value: model.isBlurScanning)
    }

    private var title: String {
        if model.isBlurScanning { return "Looking closely…" }
        if !model.blurScanned { return "Soft focus" }
        return visibleCount == 1 ? "1 soft photo" : "\(visibleCount) soft photos"
    }

    private var detail: String {
        if model.blurScanned && !model.isBlurScanning {
            return "Checked \(model.blurChecked) photos. Blurriest first.\nPress and hold a photo to see it larger."
        }
        return "Every photo from \(model.range.label.lowercased()) is checked.\nFavorites are never suggested."
    }

    @ViewBuilder
    private var content: some View {
        if model.isBlurScanning {
            ScanProgress(caption: scanningCaption, found: foundCaption)
        } else if model.blurScanned {
            finished
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Some moments moved\nfaster than the shutter.")
                .font(.tidySerif(28))
                .foregroundStyle(Tidy.ink)
            HStack {
                Spacer(minLength: 8)
                ArrowButton(title: "Find blurry photos") {
                    model.startBlurScan()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var finished: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Text("How many to show").eyebrow()
            Slider(value: $model.blurSensitivity, in: 0...1) {
                Text("How many to show")
            } minimumValueLabel: {
                Text("Fewer").font(.caption).foregroundStyle(Tidy.muted)
            } maximumValueLabel: {
                Text("More").font(.caption).foregroundStyle(Tidy.muted)
            }
            .tint(Tidy.bronze)
            HStack {
                Spacer(minLength: 8)
                ArrowButton(title: "Scan again") {
                    model.startBlurScan()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var scanningCaption: String {
        if model.progressTotal == 0 {
            return "Reading your library…"
        }
        return "Checked \(model.progressDone) of \(model.progressTotal) photos"
    }

    private var foundCaption: String {
        visibleCount == 0 ? "Nothing yet." : "\(visibleCount) soft so far."
    }
}

// MARK: - Screenshots

struct ScreenshotsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.screenshotsVisible

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Screenshots", subtitle: "Oldest first")
                StoneCard(stone: .clay, title: title(items), detail: detail(items)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show").eyebrow()
                        Picker("Age", selection: $model.shotAge) {
                            ForEach(ShotAge.allCases) { age in
                                Text(age.label).tag(age)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if !items.isEmpty {
                    SelectionSection(items: items, selected: $model.shotSelected)
                } else if model.screenshotsLoaded {
                    TipCard(title: "Nothing here.",
                            detail: "No screenshots match this age.")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .tidyScreen()
        .modifier(RemoveFlow(items: items, selected: model.shotSelected, noun: "screenshots"))
        .withTabBar()
        .task {
            if !model.screenshotsLoaded {
                await model.loadScreenshots()
            }
        }
        .refreshable {
            await model.loadScreenshots()
        }
    }

    private func title(_ items: [LooseItem]) -> String {
        if !model.screenshotsLoaded { return "Reading…" }
        return items.count == 1 ? "1 screenshot" : "\(items.count) screenshots"
    }

    private func detail(_ items: [LooseItem]) -> String {
        let bytes: Int64 = items.reduce(Int64(0)) { $0 + $1.bytes }
        let size = bytes > 0 ? "\(formatBytes(bytes)) in total. " : ""
        return "\(size)Useful for a day, kept for years.\nTap to mark, press and hold to see it larger."
    }
}

// MARK: - Videos

struct VideosTab: View {
    @Environment(AppModel.self) private var model
    @State private var previewing: LooseItem?

    var body: some View {
        let items = model.videos

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Videos", subtitle: "Heaviest first")
                StoneCard(stone: .obsidian, title: title(items), detail: detail(items)) {
                    Text("A few long videos often weigh\nmore than a thousand photos.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                }
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        VideoRow(item: item,
                                 isSelected: model.videoSelected.contains(item.id),
                                 onPreview: { previewing = item })
                            .onTapGesture {
                                withAnimation(Tidy.quick) { toggle(item.id) }
                            }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .tidyScreen()
        .modifier(RemoveFlow(items: items, selected: model.videoSelected, noun: "videos"))
        .withTabBar()
        .fullScreenCover(item: $previewing) { item in
            VideoPreview(asset: item.asset)
        }
        .sensoryFeedback(.selection, trigger: model.videoSelected)
        .task {
            if !model.videosLoaded {
                await model.loadVideos()
            }
        }
        .refreshable {
            await model.loadVideos()
        }
    }

    private func toggle(_ id: String) {
        if model.videoSelected.contains(id) {
            model.videoSelected.remove(id)
        } else {
            model.videoSelected.insert(id)
        }
    }

    private func title(_ items: [LooseItem]) -> String {
        if !model.videosLoaded { return "Reading…" }
        return items.count == 1 ? "1 video" : "\(items.count) videos"
    }

    private func detail(_ items: [LooseItem]) -> String {
        let bytes: Int64 = items.reduce(Int64(0)) { $0 + $1.bytes }
        let size = bytes > 0 ? "\(formatBytes(bytes)) in total. " : ""
        return "\(size)Tap a row to mark it,\ntap the picture to play it."
    }
}

struct VideoRow: View {
    let item: LooseItem
    let isSelected: Bool
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play video")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.bytes > 0 ? formatBytes(item.bytes) : formatDuration(item.metric))
                    .font(.tidySerif(26))
                    .foregroundStyle(Tidy.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Tidy.muted)
            }
            Spacer(minLength: 0)
            SelectBadge(isSelected: isSelected)
        }
        .padding(10)
        .padding(.trailing, 6)
        .tidyCard(corner: 22)
        .opacity(isSelected ? 0.6 : 1.0)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        Thumb(asset: item.asset, side: 96)
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
    }

    private var detail: String {
        var parts: [String] = [formatDuration(item.metric)]
        if let date = item.asset.creationDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}

/// Plays one video full screen (downloads it from iCloud first if needed).
struct VideoPreview: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Text("This video couldn't be loaded.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(Color.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
        .task {
            if let item = await VideoLoader.playerItem(for: asset) {
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                newPlayer.play()
            } else {
                failed = true
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

enum VideoLoader {
    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        return await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let once = ResumeOnce()
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                if once.claim() {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}

// MARK: - Shared pieces for the simple lists

/// "Select all" row plus a three-column grid of tappable photos.
struct SelectionSection: View {
    let items: [LooseItem]
    @Binding var selected: Set<String>

    private let columns = [GridItem(.flexible(), spacing: 4),
                           GridItem(.flexible(), spacing: 4),
                           GridItem(.flexible(), spacing: 4)]

    private var visibleIDs: Set<String> { Set(items.map { $0.id }) }
    private var allSelected: Bool { visibleIDs.isSubset(of: selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(selected.intersection(visibleIDs).count) marked")
                    .eyebrow()
                Spacer()
                Button(allSelected ? "Unmark all" : "Mark all") {
                    withAnimation(Tidy.quick) {
                        if allSelected {
                            selected.subtract(visibleIDs)
                        } else {
                            selected.formUnion(visibleIDs)
                        }
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 8)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(items) { item in
                    SelectableTile(item: item, isSelected: selected.contains(item.id))
                        .onTapGesture {
                            withAnimation(Tidy.quick) { toggle(item.id) }
                        }
                        .contextMenu {
                            Button(selected.contains(item.id) ? "Unmark" : "Mark to remove") {
                                toggle(item.id)
                            }
                        } preview: {
                            LargePreview(asset: item.asset)
                        }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

struct SelectableTile: View {
    let item: LooseItem
    let isSelected: Bool

    var body: some View {
        Thumb(asset: item.asset, side: 130)
            .aspectRatio(1, contentMode: .fit)
            .saturation(isSelected ? 0.1 : 1.0)
            .opacity(isSelected ? 0.45 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                SelectBadge(isSelected: isSelected)
                    .padding(6)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(Text(isSelected ? "Marked to remove" : "Not marked"))
    }
}

/// Empty ring when not marked, a white badge with a red cross when marked.
struct SelectBadge: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Color.white)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tidy.terracotta)
            } else {
                Circle().fill(Color.black.opacity(0.25))
                Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// Bigger look at a photo, shown when you press and hold a tile.
struct LargePreview: View {
    let asset: PHAsset

    var body: some View {
        let width = CGFloat(max(asset.pixelWidth, 1))
        let height = CGFloat(max(asset.pixelHeight, 1))
        Thumb(asset: asset, side: 900)
            .aspectRatio(width / height, contentMode: .fit)
            .frame(width: 320)
    }
}

/// Adds the bottom remove bar and its confirmation to a simple list tab.
struct RemoveFlow: ViewModifier {
    @Environment(AppModel.self) private var model
    let items: [LooseItem]
    let selected: Set<String>
    let noun: String
    @State private var confirm = false

    func body(content: Content) -> some View {
        let ids: Set<String> = selected.intersection(Set(items.map { $0.id }))
        let bytes: Int64 = model.bytes(of: ids, in: items)

        return content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !ids.isEmpty {
                    RemoveBar(count: ids.count, bytes: bytes, noun: noun) {
                        confirm = true
                    }
                }
            }
            .confirmationDialog("\(model.removeVerb) \(ids.count) \(noun)?",
                                isPresented: $confirm,
                                titleVisibility: .visible) {
                Button("\(model.removeVerb) \(ids.count)", role: .destructive) {
                    Task { await model.removeSelected(ids, from: items) }
                }
            } message: {
                Text(model.moveToAlbum
                     ? "They go to the “Photo Tidy – To Review” album. Nothing is deleted."
                     : "They wait in Recently Deleted for 30 days, so you can still change your mind.")
            }
    }
}
