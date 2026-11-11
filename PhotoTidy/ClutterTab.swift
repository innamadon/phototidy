import SwiftUI
import Photos

/// Blurry shots, exact duplicates, screenshots and receipts.
struct ClutterTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = removable
        ScrollView {
            scrollContent
        }
        .tidyScreen()
        .modifier(RemoveFlow(items: target.items, selected: target.selected, noun: target.noun))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            fileBar
        }
        .withTabBar()
        .task(id: model.clutterSection) {
            if model.clutterSection == .screenshots && !model.screenshotsLoaded {
                await model.loadScreenshots()
            }
        }
    }

    private var scrollContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Clutter", subtitle: "Photos that don't need to stay")
            SectionChips(items: ClutterSection.allCases, selection: $model.clutterSection)
            sectionView
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var sectionView: some View {
        switch model.clutterSection {
        case .blurry:
            BlurrySection()
        case .duplicates:
            DuplicatesSection()
        case .screenshots:
            ScreenshotsSection()
        case .receipts:
            ReceiptsSection()
        }
    }

    /// What the remove bar works on, for the part that's showing.
    private var removable: (items: [LooseItem], selected: Set<String>, noun: String) {
        switch model.clutterSection {
        case .blurry:
            return (model.blurryVisible, model.blurSelected, "photos")
        case .duplicates:
            return (model.duplicateCopies, model.dupSelected, "copies")
        case .screenshots:
            return (model.screenshotsVisible, model.shotSelected, "screenshots")
        case .receipts:
            return ([], [], "")
        }
    }

    @ViewBuilder
    private var fileBar: some View {
        let ids: Set<String> = model.receiptSelected.intersection(Set(model.receipts.map { $0.id }))
        let showing: Bool = model.clutterSection == .receipts && !ids.isEmpty && !model.isFiling && !model.isReceiptScanning
        if showing {
            let title: String = "File " + counted(ids.count, "receipt", "receipts")
            Button(title) {
                Task { await model.fileReceipts(ids) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Blurry

struct BlurrySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.blurryVisible

        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .clutter, title: title(items.count), detail: detail) {
                content(items.count)
            }
            .animation(Tidy.spring, value: model.isBlurScanning)

            if !items.isEmpty {
                SelectionSection(items: items, selected: $model.blurSelected)
            } else if model.blurScanned && !model.isBlurScanning {
                TipCard(title: "Nothing out of focus.",
                        detail: "Slide toward “More” to include slightly soft shots, or pick a longer time range in Settings.")
            }
        }
    }

    private func title(_ count: Int) -> String {
        if model.isBlurScanning { return "Looking closely…" }
        if !model.blurScanned { return "Soft focus" }
        return count == 1 ? "1 soft photo" : "\(count) soft photos"
    }

    private var detail: String {
        let people = model.keepBlurryPeople ? " Photos with people are kept." : ""
        if model.blurScanned && !model.isBlurScanning {
            return "Checked \(model.blurChecked) photos. Blurriest first.\(people)\nPress and hold a photo to see it larger."
        }
        return "Every photo from \(model.range.label.lowercased()) is checked.\nFavorites are never suggested.\(people)"
    }

    @ViewBuilder
    private func content(_ count: Int) -> some View {
        if model.isBlurScanning {
            ScanProgress(caption: progressCaption, found: count == 0 ? "Nothing yet." : "\(count) soft so far.")
        } else if model.blurScanned {
            finished
        } else {
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

    private var progressCaption: String {
        model.progressTotal == 0 ? "Reading your library…" : "Checked \(model.progressDone) of \(model.progressTotal) photos"
    }
}

// MARK: - Exact duplicates

struct DuplicatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .clutter, title: title, detail: detail) {
                content
            }
            .animation(Tidy.spring, value: model.isDupScanning)

            if !model.duplicateSets.isEmpty {
                HStack {
                    Text("\(model.dupSelected.count) copies marked").eyebrow()
                    Spacer()
                }
                .padding(.horizontal, 8)
                LazyVStack(spacing: 14) {
                    ForEach(model.duplicateSets) { set in
                        DuplicateSetCard(set: set, selected: $model.dupSelected)
                    }
                }
            } else if model.dupScanned && !model.isDupScanning {
                TipCard(title: "No copies found.",
                        detail: "Every photo from \(model.range.label.lowercased()) is one of a kind.")
            }
        }
    }

    private var copyBytes: Int64 {
        model.duplicateCopies.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private var title: String {
        if model.isDupScanning { return "Comparing…" }
        if !model.dupScanned { return "Exact copies" }
        let count = model.duplicateCopies.count
        return count == 1 ? "1 copy" : "\(count) copies"
    }

    private var detail: String {
        if model.dupScanned && !model.isDupScanning && copyBytes > 0 {
            return "\(formatBytes(copyBytes)) in copies. The best copy of each\nphoto is kept; the rest are marked."
        }
        return "The same photo saved twice, or re-saved\nsmaller by a messaging app."
    }

    @ViewBuilder
    private var content: some View {
        if model.isDupScanning {
            ScanProgress(caption: model.progressTotal == 0 ? "Reading your library…" : "Looked at \(model.progressDone) of \(model.progressTotal) photos",
                         found: "Fingerprinting each photo.")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("One of each is enough.")
                    .font(.tidySerif(28))
                    .foregroundStyle(Tidy.ink)
                HStack {
                    Spacer(minLength: 8)
                    ArrowButton(title: model.dupScanned ? "Scan again" : "Find copies") {
                        model.startDuplicateScan()
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }
}

struct DuplicateSetCard: View {
    let set: DuplicateSet
    @Binding var selected: Set<String>

    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4),
                           GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Thumb(asset: set.keeper.asset, side: 96)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("Keep")
                            .eyebrow(Color.black.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.92), in: Capsule())
                            .padding(6)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    if let date = set.keeper.asset.creationDate {
                        Text(date, format: .dateTime.day().month(.abbreviated).year())
                            .font(.caption)
                            .foregroundStyle(Tidy.muted)
                    }
                    Text(counted(set.copies.count, "copy", "copies"))
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    Text("Keeping the \(set.keeper.asset.pixelWidth) × \(set.keeper.asset.pixelHeight) original")
                        .font(.caption)
                        .foregroundStyle(Tidy.muted)
                    let bytes = set.copies.reduce(Int64(0)) { $0 + $1.bytes }
                    if bytes > 0 {
                        Text("copies: \(formatBytes(bytes))")
                            .font(.caption)
                            .foregroundStyle(Tidy.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(set.copies) { copy in
                    SelectableTile(item: copy, isSelected: selected.contains(copy.id))
                        .onTapGesture {
                            withAnimation(Tidy.quick) {
                                if selected.contains(copy.id) {
                                    selected.remove(copy.id)
                                } else {
                                    selected.insert(copy.id)
                                }
                            }
                        }
                }
            }
        }
        .padding(12)
        .tidyCard(corner: 24)
    }
}

// MARK: - Screenshots

struct ScreenshotsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.screenshotsVisible

        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .clutter, title: title(items), detail: detail(items)) {
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
                TipCard(title: "Nothing here.", detail: "No screenshots match this age.")
            }
        }
    }

    private func title(_ items: [LooseItem]) -> String {
        if !model.screenshotsLoaded { return "Reading…" }
        return items.count == 1 ? "1 screenshot" : "\(items.count) screenshots"
    }

    private func detail(_ items: [LooseItem]) -> String {
        let bytes: Int64 = items.reduce(Int64(0)) { $0 + $1.bytes }
        let size = bytes > 0 ? "\(formatBytes(bytes)) in total. " : ""
        return "\(size)Useful for a day, kept for years.\nOldest first. Tap to mark, hold to see it larger."
    }
}

// MARK: - Receipts

struct ReceiptsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .clutter, title: title, detail: detail) {
                content
            }
            .animation(Tidy.spring, value: model.isReceiptScanning)

            if model.isFiling {
                WorkCard(title: "Filing receipts…", done: model.filingDone, total: model.filingTotal)
            }
            if let report = model.filingReport {
                NoteCard(text: report) {
                    model.filingReport = nil
                }
            }

            if !model.receipts.isEmpty {
                SelectionSection(items: model.receipts,
                                 selected: $model.receiptSelected,
                                 filing: true,
                                 sentIDs: model.receiptsSent)
            } else if model.receiptsScanned && !model.isReceiptScanning {
                TipCard(title: "No receipts found.",
                        detail: "Nothing in \(model.range.label.lowercased()) looked like a receipt. Try a longer time range in Settings.")
            }
        }
    }

    private var title: String {
        if model.isReceiptScanning { return "Reading…" }
        if !model.receiptsScanned { return "Receipts" }
        let count = model.receipts.count
        return count == 1 ? "1 receipt" : "\(count) receipts"
    }

    private var detail: String {
        if model.filerURL != nil {
            return "Marked receipts go to your Receipts album\nand to your receipt filer."
        }
        return "Marked receipts go to your Receipts album.\nAdd your filer's address in Settings to send them there too."
    }

    @ViewBuilder
    private var content: some View {
        if model.isReceiptScanning {
            ScanProgress(caption: model.progressTotal == 0 ? "Reading your library…" : "Checked \(model.progressDone) of \(model.progressTotal) photos",
                         found: model.receipts.isEmpty ? "Nothing yet." : "\(model.receipts.count) found so far.")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("Paper worth keeping,\nput where it belongs.")
                    .font(.tidySerif(28))
                    .foregroundStyle(Tidy.ink)
                HStack {
                    if model.filerURL == nil {
                        Button("Add filer address ›") {
                            model.showSettings = true
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    Spacer(minLength: 8)
                    ArrowButton(title: model.receiptsScanned ? "Scan again" : "Find receipts") {
                        model.startReceiptScan()
                    }
                    .disabled(model.isBusy || model.isFiling)
                }
            }
        }
    }
}
