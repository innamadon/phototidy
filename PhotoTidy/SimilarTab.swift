import SwiftUI
import Photos

/// Look-alike photos: scan, review the groups, remove the extras.
struct SimilarTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Look-alikes", subtitle: subtitle)
                SimilarHero()
                results
                LifetimeFooter()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .tidyScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            removeBar
        }
        .withTabBar()
        .confirmationDialog("\(model.removeVerb) the extras?", isPresented: $confirmRemove, titleVisibility: .visible) {
            removeChoices
        } message: {
            Text(model.moveToAlbum
                 ? "Your picks stay where they are. The extras go to the “Photo Tidy – To Review” album; nothing is deleted."
                 : "Your picks are kept. Deleted photos wait in Recently Deleted for 30 days, so you can still change your mind.")
        }
    }

    private var subtitle: String {
        let today = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(today) · \(model.range.label.lowercased())"
    }

    @ViewBuilder
    private var results: some View {
        if !model.groups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ResultsHeader()
                LazyVStack(spacing: 14) {
                    ForEach(model.sortedGroups) { group in
                        NavigationLink(value: group.id) {
                            GroupCard(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if model.hasScanned && !model.isScanning {
            TipCard(title: "A quiet library.",
                    detail: "No look-alikes here. Try a longer time range, a longer gap between shots, or a looser match in Settings.")
        }
    }

    @ViewBuilder
    private var removeBar: some View {
        if model.extrasCount > 0 && !model.isScanning {
            RemoveBar(count: model.extrasCount, bytes: model.extrasBytes, noun: "extras") {
                confirmRemove = true
            }
        }
    }

    @ViewBuilder
    private var removeChoices: some View {
        let reviewed = model.reviewedExtrasCount
        if reviewed > 0 && reviewed < model.extrasCount {
            Button("\(model.removeVerb) \(reviewed) From Groups I Reviewed", role: .destructive) {
                let ids = Set(model.reviewedGroups.map { $0.id })
                Task { await model.removeExtras(in: ids) }
            }
        }
        Button("\(model.removeVerb) All \(model.extrasCount) Extras", role: .destructive) {
            Task { await model.removeExtras() }
        }
    }
}

// MARK: - Hero

struct SimilarHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StoneCard(stone: .bronze, title: title, detail: detail) {
            content
        }
        .animation(Tidy.spring, value: model.isScanning)
    }

    private var title: String {
        if model.isScanning { return "Gathering…" }
        if !model.hasScanned { return "Same moment, many shots" }
        let count = model.groups.count
        if count == 0 { return "All tidy" }
        return count == 1 ? "1 moment" : "\(count) moments"
    }

    private var detail: String {
        if model.hasScanned && !model.isScanning && model.groups.isEmpty {
            return "No look-alikes found in \(model.photosChecked) photos."
        }
        return "Shots of the same moment, gathered.\nThe best of each is chosen for you."
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ScanProgress(caption: scanningCaption, found: foundCaption)
        } else if model.hasScanned && !model.groups.isEmpty {
            finished
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 20) {
            statement
            HStack {
                optionsButton
                Spacer(minLength: 8)
                ArrowButton(title: model.hasScanned ? "Scan again" : "Find look-alikes") {
                    model.startScan()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 20) {
            statement
            HStack(alignment: .top, spacing: 16) {
                FactColumn(heading: "Keep", lines: keepLines)
                FactColumn(heading: "Let go", lines: letGoLines)
            }
            if reviewedFraction > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    SweepProgress(fraction: reviewedFraction)
                    Text("\(model.reviewedGroups.count) of \(model.groups.count) reviewed")
                        .font(.caption)
                        .foregroundStyle(Tidy.muted)
                }
            }
            HStack {
                Button("Scan again") {
                    model.startScan()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isBusy)
                Spacer(minLength: 8)
                ArrowButton(title: "Review one by one") {
                    model.startReviewing()
                }
            }
        }
    }

    private var statement: some View {
        Text("Keep the clearest one;\nlet its echoes go.")
            .font(.tidySerif(28))
            .foregroundStyle(Tidy.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                Orb()
                    .offset(x: 56, y: -6)
            }
    }

    private var optionsButton: some View {
        Button {
            model.showSettings = true
        } label: {
            Text("\(model.range.label) ›")
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var reviewedFraction: Double {
        guard !model.groups.isEmpty else { return 0 }
        return Double(model.reviewedGroups.count) / Double(model.groups.count)
    }

    private var keepLines: [String] {
        let kept = model.groups.reduce(0) { $0 + $1.keep.count }
        return [kept == 1 ? "1 best shot" : "\(kept) best shots", "Favorites, always"]
    }

    private var letGoLines: [String] {
        var lines = [model.extrasCount == 1 ? "1 extra" : "\(model.extrasCount) extras"]
        if model.extrasBytes > 0 {
            lines.append("about \(formatBytes(model.extrasBytes))")
        }
        return lines
    }

    private var scanningCaption: String {
        if model.progressTotal == 0 {
            return "Reading your library…"
        }
        return "Compared \(model.progressDone) of \(model.progressTotal) photos taken close together"
    }

    private var foundCaption: String {
        let count = model.groups.count
        if count == 0 { return "Nothing yet." }
        return count == 1 ? "1 moment so far." : "\(count) moments so far."
    }
}

// MARK: - Results list

struct ResultsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(alignment: .firstTextBaseline) {
            Text("Moments").eyebrow()
            Spacer()
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(GroupSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
            } label: {
                Text("\(model.sort.label) ›")
                    .font(.footnote)
                    .foregroundStyle(Tidy.muted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// One group in the list: the best shot big, the rest small beside it.
struct GroupCard: View {
    let group: PhotoGroup

    private var others: [PhotoItem] { Array(group.items.dropFirst().prefix(4)) }
    private var hiddenCount: Int { max(0, group.items.count - 1 - others.count) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            strip
            info
            Spacer(minLength: 0)
        }
        .padding(12)
        .tidyCard(corner: 26)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 4) {
            if let best = group.best {
                tile(best, size: 108)
            }
            miniGrid
        }
    }

    private var miniGrid: some View {
        let columns = [GridItem(.fixed(52), spacing: 4), GridItem(.fixed(52), spacing: 4)]
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(others.enumerated()), id: \.element.id) { index, item in
                tile(item, size: 52)
                    .overlay {
                        if index == others.count - 1 && hiddenCount > 0 {
                            moreBadge
                        }
                    }
            }
        }
        .frame(width: 108)
    }

    private var moreBadge: some View {
        ZStack {
            Color.black.opacity(0.5)
            Text("+\(hiddenCount)")
                .font(.caption)
                .foregroundStyle(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tile(_ item: PhotoItem, size: CGFloat) -> some View {
        let kept = group.keep.contains(item.id)
        let corner: CGFloat = size > 60 ? 14 : 9
        return Thumb(asset: item.asset, side: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .saturation(kept ? 1.0 : 0.1)
            .opacity(kept ? 1.0 : 0.4)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.date, format: .dateTime.day().month(.abbreviated))
                .font(.caption)
                .foregroundStyle(Tidy.muted)
            Text("\(group.items.count) photos")
                .font(.tidySerif(26))
                .foregroundStyle(Tidy.ink)
            Text("keep \(group.keep.count) · let go \(group.removeIDs.count)")
                .font(.caption)
                .foregroundStyle(Tidy.muted)
            if group.removeBytes > 0 {
                Text(formatBytes(group.removeBytes))
                    .font(.caption)
                    .foregroundStyle(Tidy.muted)
            }
            if group.reviewed {
                Text("Reviewed")
                    .eyebrow(Tidy.sage)
                    .padding(.top, 6)
            }
        }
    }
}

/// A plain card for tips and empty states.
struct TipCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.tidySerif(26))
                .foregroundStyle(Tidy.ink)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Tidy.muted)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tidyCard()
    }
}

struct LifetimeFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.lifetimeDeleted > 0 {
            Text(line)
                .font(.footnote)
                .foregroundStyle(Tidy.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    private var line: String {
        var text = "So far you've let go of \(model.lifetimeDeleted) items"
        if model.lifetimeBytes > 0 {
            text += " (\(formatBytes(model.lifetimeBytes)))"
        }
        return text + "."
    }
}
