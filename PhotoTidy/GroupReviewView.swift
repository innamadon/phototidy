import SwiftUI
import Photos

private struct ViewerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// One group of look-alikes: the suggested keeper on top, the rest below.
struct GroupReviewView: View {
    let groupID: UUID
    @Environment(AppModel.self) private var model
    @State private var viewer: ViewerStart?
    @State private var confirmRemove = false

    var body: some View {
        if let group = model.group(groupID) {
            content(group)
        } else {
            Text("All done.")
                .font(.tidySerif(34))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tidy.paper.ignoresSafeArea())
        }
    }

    /// Where this group sits in the list, e.g. 2 of 38.
    private var position: (index: Int, total: Int) {
        let ordered = model.sortedGroups
        let index = ordered.firstIndex(where: { $0.id == groupID }) ?? 0
        return (index + 1, max(ordered.count, 1))
    }

    private func content(_ group: PhotoGroup) -> some View {
        let place = position
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SweepProgress(fraction: Double(place.index) / Double(place.total))
                    .padding(.horizontal, 4)
                header(group)
                if let best = group.best {
                    cell(best, index: 0, group: group, aspect: 4.0 / 3.0, side: 400)
                }
                grid(group)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .background(Tidy.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Tidy.paper, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(place.index) of \(place.total)").eyebrow()
            }
            ToolbarItem(placement: .topBarTrailing) {
                menu(group)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(group)
        }
        .confirmationDialog("\(model.removeVerb) \(group.removeIDs.count) photos now?",
                            isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("\(model.removeVerb) \(group.removeIDs.count) Photos", role: .destructive) {
                Task { await model.removeExtras(in: [groupID]) }
            }
        } message: {
            Text(model.moveToAlbum
                 ? "They go to the “Photo Tidy – To Review” album. Nothing is deleted."
                 : "They wait in Recently Deleted for 30 days.")
        }
        .fullScreenCover(item: $viewer) { start in
            PhotoViewer(groupID: groupID, startIndex: start.index)
                .environment(model)
        }
        .sensoryFeedback(.selection, trigger: group.keep)
    }

    private func header(_ group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.date, format: .dateTime.weekday(.wide))
            Text(group.date, format: .dateTime.day().month(.wide))
            Text("Tap a photo to keep it or let it go.")
                .font(.tidySerif(21, italic: true))
                .foregroundStyle(Tidy.muted)
                .padding(.top, 2)
        }
        .font(.tidySerif(38))
        .foregroundStyle(Tidy.ink)
        .padding(.horizontal, 8)
    }

    private func grid(_ group: PhotoGroup) -> some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        let rest = Array(group.items.enumerated().dropFirst())
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(rest, id: \.element.id) { index, item in
                cell(item, index: index, group: group, aspect: 1.0, side: 220)
            }
        }
    }

    private func cell(_ item: PhotoItem, index: Int, group: PhotoGroup, aspect: CGFloat, side: CGFloat) -> some View {
        ReviewCell(item: item,
                   isBest: index == 0,
                   isKept: group.keep.contains(item.id),
                   aspect: aspect,
                   side: side,
                   onExpand: { viewer = ViewerStart(index: index) })
            .onTapGesture {
                withAnimation(Tidy.spring) {
                    model.toggleKeep(groupID: groupID, itemID: item.id)
                }
            }
    }

    private func menu(_ group: PhotoGroup) -> some View {
        Menu {
            Button("Keep only the best", systemImage: "star") {
                withAnimation(Tidy.spring) { model.keepOnlyBest(groupID: groupID) }
            }
            Button("Keep all", systemImage: "checkmark.circle") {
                withAnimation(Tidy.spring) { model.keepAll(groupID: groupID) }
            }
            if !group.removeIDs.isEmpty {
                Button("Remove these now", systemImage: "trash", role: .destructive) {
                    confirmRemove = true
                }
            }
            Button("Not look-alikes – hide group", systemImage: "eye.slash") {
                model.dismissGroup(groupID)
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Tidy.ink)
                .frame(width: 36, height: 36)
        }
    }

    private func bottomBar(_ group: PhotoGroup) -> some View {
        let remaining = model.unreviewedCount(excluding: groupID)
        return VStack(spacing: 10) {
            Text(summary(group))
                .font(.footnote)
                .foregroundStyle(Tidy.muted)
            Button(remaining > 0 ? "Looks good — next" : "Looks good — finish") {
                model.confirmAndAdvance(from: groupID)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Tidy.paper.opacity(0.94))
    }

    private func summary(_ group: PhotoGroup) -> String {
        var text = "Keeping \(group.keep.count) · letting go of \(group.removeIDs.count)"
        if group.removeBytes > 0 {
            text += " · \(formatBytes(group.removeBytes))"
        }
        if group.keep.isEmpty {
            text += " · nothing kept"
        }
        return text
    }
}

// MARK: - One photo in the review

struct ReviewCell: View {
    let item: PhotoItem
    let isBest: Bool
    let isKept: Bool
    let aspect: CGFloat
    let side: CGFloat
    let onExpand: () -> Void

    private let corner: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            photo
            Text(caption)
                .font(.caption)
                .foregroundStyle(Tidy.muted)
                .lineLimit(2)
                .padding(.horizontal, 8)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(Text(spokenLabel))
    }

    private var spokenLabel: String {
        let state: String = isKept ? "Keeping" : "Letting go"
        return state + ". " + caption
    }

    private var photo: some View {
        Thumb(asset: item.asset, side: side)
            .aspectRatio(aspect, contentMode: .fit)
            .saturation(isKept ? 1.0 : 0.1)
            .opacity(isKept ? 1.0 : 0.4)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: isKept ? Tidy.shadow : Color.clear, radius: 14, x: 0, y: 10)
            .overlay(alignment: .topLeading) {
                if isBest { bestTag }
            }
            .overlay(alignment: .topTrailing) {
                stateBadge
            }
            .overlay(alignment: .bottomTrailing) {
                expandButton
            }
            .scaleEffect(isKept ? 1.0 : 0.97)
    }

    private var bestTag: some View {
        Text("Best")
            .eyebrow(Color.black.opacity(0.8))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.92), in: Capsule())
            .padding(12)
    }

    private var stateBadge: some View {
        Image(systemName: isKept ? "checkmark" : "xmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isKept ? Tidy.onInk : Tidy.terracotta)
            .frame(width: 28, height: 28)
            .background(isKept ? Tidy.ink : Color.white, in: Circle())
            .padding(12)
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.92), in: Circle())
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Compare full screen")
    }

    private var caption: String {
        var parts: [String] = item.notes
        if item.bytes > 0 {
            parts.append(formatBytes(item.bytes))
        }
        return parts.joined(separator: " · ")
    }
}
