import SwiftUI
import Photos
import AVKit

// Pieces shared by the Clutter, Space and Phone tabs.

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
    /// Receipts: marked means "file this", shown with a tick instead of a cross.
    var filing = false
    /// Items to label "Sent" (receipts already sent to the filer).
    var sentIDs: Set<String> = []
    /// Optional line under each tile (for example how much it would save).
    var caption: ((LooseItem) -> String)? = nil

    private let columns = [GridItem(.flexible(), spacing: 4),
                           GridItem(.flexible(), spacing: 4),
                           GridItem(.flexible(), spacing: 4)]

    private var visibleIDs: Set<String> { Set(items.map { $0.id }) }
    private var allSelected: Bool { visibleIDs.isSubset(of: selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            grid
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var header: some View {
        let marked: Int = selected.intersection(visibleIDs).count
        let countText: String = "\(marked) marked"
        let toggleTitle: String = allSelected ? "Unmark all" : "Mark all"
        return HStack {
            Text(countText).eyebrow()
            Spacer()
            Button(toggleTitle) {
                toggleAll()
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 8)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(items) { item in
                cell(item)
            }
        }
    }

    private func cell(_ item: LooseItem) -> some View {
        let isSelected: Bool = selected.contains(item.id)
        let isSent: Bool = sentIDs.contains(item.id)
        let line: String? = caption?(item)
        let title: String = menuTitle(isSelected: isSelected)
        return SelectableTile(item: item,
                              isSelected: isSelected,
                              filing: filing,
                              isSent: isSent,
                              caption: line)
            .onTapGesture {
                withAnimation(Tidy.quick) { toggle(item.id) }
            }
            .contextMenu {
                Button(title) {
                    toggle(item.id)
                }
            } preview: {
                LargePreview(asset: item.asset)
            }
    }

    private func menuTitle(isSelected: Bool) -> String {
        if isSelected { return "Unmark" }
        return filing ? "Mark to file" : "Mark to remove"
    }

    private func toggleAll() {
        let ids = visibleIDs
        let all = allSelected
        withAnimation(Tidy.quick) {
            if all {
                selected.subtract(ids)
            } else {
                selected.formUnion(ids)
            }
        }
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
    var filing = false
    var isSent = false
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            tile
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Tidy.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(Text(spoken))
    }

    private var tile: some View {
        // Things being removed fade; things being filed stay bright.
        let fade = isSelected && !filing
        return Thumb(asset: item.asset, side: 130)
            .aspectRatio(1, contentMode: .fit)
            .saturation(fade ? 0.1 : 1.0)
            .opacity(fade ? 0.45 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                SelectBadge(isSelected: isSelected, filing: filing)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if isSent {
                    Text("Sent")
                        .eyebrow(Color.black.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.92), in: Capsule())
                        .padding(6)
                }
            }
    }

    private var spoken: String {
        if !isSelected { return isSent ? "Already sent" : "Not marked" }
        return filing ? "Marked to file" : "Marked to remove"
    }
}

/// Empty ring when not marked, a white badge with a red cross when marked.
struct SelectBadge: View {
    let isSelected: Bool
    var filing = false

    var body: some View {
        ZStack {
            if isSelected && filing {
                Circle().fill(Tidy.ink)
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tidy.onInk)
            } else if isSelected {
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

/// The row of small pills that switches between the parts of a tab.
struct SectionChips<Item: Hashable & Identifiable & RawRepresentable>: View where Item.RawValue == String {
    let items: [Item]
    @Binding var selection: Item

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        withAnimation(Tidy.quick) {
                            selection = item
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(selection == item ? Tidy.onInk : Tidy.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(selection == item ? Tidy.ink : Tidy.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Progress for longer jobs (filing receipts, shrinking): a brush line, a caption and Stop.
struct WorkCard: View {
    let title: String
    let done: Int
    let total: Int
    /// How far through the current item (0…1), for long items like a video.
    var partial: Double = 0
    var onStop: (() -> Void)? = nil

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(done) + min(max(partial, 0), 1)) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SweepProgress(fraction: fraction)
            Text(title)
                .font(.tidySerif(24))
                .foregroundStyle(Tidy.ink)
            HStack {
                Text("\(done) of \(total)")
                    .font(.footnote)
                    .foregroundStyle(Tidy.muted)
                    .monospacedDigit()
                Spacer()
                if let onStop {
                    Button("Stop", action: onStop)
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(20)
        .tidyCard()
    }
}

/// A short report after a job, with a way to dismiss it.
struct NoteCard: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Tidy.terracotta)
                .frame(width: 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Tidy.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tidy.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .tidyCard(corner: 22)
    }
}

/// A list of videos with play and mark.
struct VideoList: View {
    let items: [LooseItem]
    @Binding var selected: Set<String>
    @State private var previewing: LooseItem?

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(items) { item in
                VideoRow(item: item,
                         isSelected: selected.contains(item.id),
                         onPreview: { previewing = item })
                    .onTapGesture {
                        withAnimation(Tidy.quick) {
                            if selected.contains(item.id) {
                                selected.remove(item.id)
                            } else {
                                selected.insert(item.id)
                            }
                        }
                    }
            }
        }
        .fullScreenCover(item: $previewing) { item in
            VideoPreview(asset: item.asset)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}
