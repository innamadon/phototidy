import SwiftUI
import UniformTypeIdentifiers
import Contacts
import EventKit

/// Cleanup beyond Photos: files, contacts, reminders and events, and a storage checklist.
struct PhoneTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmFiles = false

    var body: some View {
        let fileCount: Int = model.files.selected.count
        let deleteTitle: String = "Delete \(fileCount) files?"
        let deleteButton: String = "Delete \(fileCount)"
        ScrollView {
            scrollContent
        }
        .tidyScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            filesBar
        }
        .withTabBar()
        .confirmationDialog(deleteTitle, isPresented: $confirmFiles, titleVisibility: .visible) {
            Button(deleteButton, role: .destructive) {
                Task { await model.files.deleteSelected() }
            }
        } message: {
            Text("Files are deleted from that folder straight away. Files in iCloud Drive can usually be brought back from Recently Deleted in the Files app for 30 days; files kept only on this iPhone can't.")
        }
    }

    private var scrollContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Phone", subtitle: "Beyond your photos")
            SectionChips(items: PhoneSection.allCases, selection: $model.phoneSection)
            sectionView
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var sectionView: some View {
        switch model.phoneSection {
        case .files:
            FilesSection(cleaner: model.files)
        case .contacts:
            ContactsSection(cleaner: model.contacts)
        case .reminders:
            RemindersSection(cleaner: model.calendar)
        case .checklist:
            ChecklistSection(checklist: model.checklist)
        }
    }

    @ViewBuilder
    private var filesBar: some View {
        let files = model.files
        if model.phoneSection == .files && !files.selected.isEmpty && !files.scanning {
            Button {
                confirmFiles = true
            } label: {
                HStack(spacing: 8) {
                    Text("Delete " + counted(files.selected.count, "file", "files"))
                    Text(formatBytes(files.bytes(of: files.selected))).opacity(0.65)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .shadow(color: Tidy.shadow, radius: 12, x: 0, y: 8)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Files

struct FilesSection: View {
    @Bindable var cleaner: FilesCleaner
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .phone, title: title, detail: detail) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Downloads pile up\nwhere no one looks.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    if cleaner.scanning {
                        ProgressView()
                            .tint(Tidy.bronze)
                    }
                    HStack {
                        if cleaner.hasFolder {
                            Button("Scan again") {
                                Task { await cleaner.scan() }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(cleaner.scanning)
                        }
                        Spacer(minLength: 8)
                        ArrowButton(title: cleaner.hasFolder ? "Choose another folder" : "Choose a folder") {
                            picking = true
                        }
                    }
                }
            }

            if let report = cleaner.report {
                NoteCard(text: report) { cleaner.report = nil }
            }

            if cleaner.scannedOnce && !cleaner.scanning {
                Picker("Show", selection: $cleaner.filter) {
                    ForEach(FileFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                let files = cleaner.visible
                if files.isEmpty {
                    TipCard(title: "Nothing here.", detail: emptyText)
                } else {
                    HStack {
                        Text("\(cleaner.selected.count) marked").eyebrow()
                        Spacer()
                        Button(allMarked(files) ? "Unmark all" : "Mark all") {
                            let ids = Set(files.map { $0.id })
                            withAnimation(Tidy.quick) {
                                if allMarked(files) {
                                    cleaner.selected.subtract(ids)
                                } else {
                                    cleaner.selected.formUnion(ids)
                                }
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    .padding(.horizontal, 8)
                    LazyVStack(spacing: 10) {
                        ForEach(files) { file in
                            FileRow(file: file, isSelected: cleaner.selected.contains(file.id))
                                .onTapGesture {
                                    withAnimation(Tidy.quick) {
                                        if cleaner.selected.contains(file.id) {
                                            cleaner.selected.remove(file.id)
                                        } else {
                                            cleaner.selected.insert(file.id)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await cleaner.choose(url) }
            }
        }
        .sensoryFeedback(.selection, trigger: cleaner.selected)
    }

    private var title: String {
        if cleaner.scanning { return "Reading…" }
        guard let name = cleaner.folderName else { return "Files" }
        return name
    }

    private var detail: String {
        if cleaner.scannedOnce {
            let count = cleaner.entries.count
            return "\(count == 1 ? "1 file" : "\(count) files") · \(formatBytes(cleaner.totalBytes)).\nUnder Copies, the original of each is never listed."
        }
        return "Pick a folder in Files (Downloads, iCloud Drive,\nOn My iPhone) to find big, old and duplicate files."
    }

    private func allMarked(_ files: [FileEntry]) -> Bool {
        files.allSatisfy { cleaner.selected.contains($0.id) }
    }

    private var emptyText: String {
        switch cleaner.filter {
        case .biggest: return "This folder is empty."
        case .oldest: return "Everything here was touched in the last year."
        case .copies: return "No identical copies in this folder."
        }
    }
}

struct FileRow: View {
    let file: FileEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Tidy.bronze)
                .frame(width: 44, height: 44)
                .background(Tidy.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(Tidy.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Tidy.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(formatBytes(file.size))
                .font(.tidySerif(20))
                .foregroundStyle(Tidy.ink)
            SelectBadge(isSelected: isSelected)
        }
        .padding(10)
        .padding(.trailing, 4)
        .tidyCard(corner: 20)
        .opacity(isSelected ? 0.6 : 1.0)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if let copyOf = file.copyOf { parts.append("copy of \(copyOf)") }
        if !file.place.isEmpty { parts.append(file.place) }
        if let modified = file.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "archivebox"
        default: return "doc"
        }
    }
}

// MARK: - Contacts

struct ContactsSection: View {
    @Bindable var cleaner: ContactsCleaner
    @State private var confirmAll = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .phone, title: title, detail: detail) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("One person,\none card.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    if cleaner.scanning || cleaner.merging {
                        ProgressView()
                            .tint(Tidy.bronze)
                    }
                    HStack {
                        Spacer(minLength: 8)
                        if cleaner.status == .denied || cleaner.status == .restricted {
                            ArrowButton(title: "Allow in Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            ArrowButton(title: cleaner.scannedOnce ? "Look again" : "Find duplicates") {
                                Task { await cleaner.start() }
                            }
                            .disabled(cleaner.scanning || cleaner.merging)
                        }
                    }
                }
            }

            if let report = cleaner.report {
                NoteCard(text: report) { cleaner.report = nil }
            }

            if !cleaner.groups.isEmpty {
                HStack {
                    Text(counted(cleaner.groups.count, "person", "people")).eyebrow()
                    Spacer()
                    Button("Merge all") { confirmAll = true }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(cleaner.merging)
                }
                .padding(.horizontal, 8)
                LazyVStack(spacing: 10) {
                    ForEach(cleaner.groups) { group in
                        ContactGroupRow(group: group, disabled: cleaner.merging) {
                            Task { await cleaner.merge(group) }
                        }
                    }
                }
            } else if cleaner.scannedOnce && !cleaner.scanning {
                TipCard(title: "No duplicates.", detail: "Every contact is saved once.")
            }
        }
        .confirmationDialog("Merge \(cleaner.groups.count) contacts?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Merge \(cleaner.groups.count)") {
                Task { await cleaner.mergeAll() }
            }
        } message: {
            Text("For each person, the fullest card is kept and the other cards' numbers, emails and addresses are added to it. The extra cards are deleted. iCloud contacts can be restored at iCloud.com → Settings → Restore Contacts.")
        }
    }

    private var title: String {
        if cleaner.scanning { return "Reading…" }
        if cleaner.scannedOnce {
            return cleaner.groups.count == 1 ? "1 duplicate" : "\(cleaner.groups.count) duplicates"
        }
        return "Contacts"
    }

    private var detail: String {
        if cleaner.status == .denied || cleaner.status == .restricted {
            return "Photo Tidy isn't allowed to see your contacts.\nTurn it on in Settings."
        }
        return "Cards with the same name, number or email.\nNothing is merged until you tap Merge."
    }
}

struct ContactGroupRow: View {
    let group: ContactGroup
    let disabled: Bool
    let onMerge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.tidySerif(22))
                .foregroundStyle(Tidy.ink)
                .frame(width: 44, height: 44)
                .background(Tidy.sand, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline)
                    .foregroundStyle(Tidy.ink)
                    .lineLimit(1)
                Text(group.summary)
                    .font(.caption)
                    .foregroundStyle(Tidy.muted)
            }
            Spacer(minLength: 0)
            Button("Merge", action: onMerge)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Tidy.onInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Tidy.ink, in: Capsule())
                .buttonStyle(.plain)
                .disabled(disabled)
        }
        .padding(10)
        .tidyCard(corner: 20)
    }

    private var initials: String {
        let words = group.name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "·" : letters.uppercased()
    }
}

// MARK: - Reminders and events

struct RemindersSection: View {
    @Bindable var cleaner: CalendarCleaner
    @State private var confirm: Kind?

    enum Kind: Identifiable {
        case reminders
        case events
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .phone, title: title, detail: "Completed reminders older than a month,\nand one-off events that ended over two years ago.") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Done is done.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    if cleaner.loading || cleaner.working {
                        ProgressView()
                            .tint(Tidy.bronze)
                    }
                    HStack {
                        Spacer(minLength: 8)
                        ArrowButton(title: cleaner.loadedOnce ? "Look again" : "Look for old items") {
                            Task { await cleaner.start() }
                        }
                        .disabled(cleaner.loading || cleaner.working)
                    }
                }
            }

            if let report = cleaner.report {
                NoteCard(text: report) { cleaner.report = nil }
            }

            if cleaner.loadedOnce && !cleaner.loading {
                group(title: cleaner.reminders.count == 1 ? "1 completed reminder" : "\(cleaner.reminders.count) completed reminders",
                      allowed: cleaner.remindersAllowed,
                      lines: cleaner.reminders.prefix(30).map { reminder in
                          let title = reminder.title ?? "Untitled"
                          if let date = reminder.completionDate {
                              return title + " · " + date.formatted(date: .abbreviated, time: .omitted)
                          }
                          return title
                      },
                      more: max(0, cleaner.reminders.count - 30),
                      kind: .reminders)

                group(title: cleaner.events.count == 1 ? "1 old event" : "\(cleaner.events.count) old events",
                      allowed: cleaner.eventsAllowed,
                      lines: cleaner.events.prefix(30).map { event in
                          (event.title ?? "Untitled") + " · " + event.startDate.formatted(date: .abbreviated, time: .omitted)
                      },
                      more: max(0, cleaner.events.count - 30),
                      kind: .events)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmShown, titleVisibility: .visible, presenting: confirm) { kind in
            Button("Delete", role: .destructive) {
                Task {
                    if kind == .reminders {
                        await cleaner.deleteReminders()
                    } else {
                        await cleaner.deleteEvents()
                    }
                }
            }
        } message: { kind in
            Text(kind == .reminders
                 ? "Completed reminders older than a month are deleted from every list you can edit."
                 : "One-off events that ended more than two years ago are deleted from your own calendars. Repeating events, birthdays and subscribed calendars are left alone.")
        }
    }

    private var title: String {
        if cleaner.loading { return "Reading…" }
        return "Reminders & events"
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { shown in if !shown { confirm = nil } })
    }

    private var confirmTitle: String {
        switch confirm {
        case .reminders: return "Delete \(cleaner.reminders.count) completed reminders?"
        case .events: return "Delete \(cleaner.events.count) old events?"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func group(title: String, allowed: Bool, lines: [String], more: Int, kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.tidySerif(24)).foregroundStyle(Tidy.ink)
                Spacer()
                if allowed && !lines.isEmpty {
                    Button("Delete all") { confirm = kind }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(cleaner.working)
                }
            }
            if !allowed {
                Text("Photo Tidy isn't allowed to see these. Turn it on in Settings → Apps → Photo Tidy.")
                    .font(.footnote)
                    .foregroundStyle(Tidy.muted)
            } else if lines.isEmpty {
                Text("Nothing old here.")
                    .font(.footnote)
                    .foregroundStyle(Tidy.muted)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Tidy.ink.opacity(0.8))
                        .lineLimit(1)
                }
                if more > 0 {
                    Text("and \(more) more")
                        .font(.footnote)
                        .foregroundStyle(Tidy.muted)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tidyCard()
    }
}

// MARK: - Checklist

struct ChecklistSection: View {
    @Bindable var checklist: Checklist

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StoneCard(stone: .phone,
                      title: "\(checklist.done.count) of \(checklist.items.count) done",
                      detail: "Things only you can do in Settings.\nTick them off as you go.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("iOS keeps some doors\nfor you alone.")
                        .font(.tidySerif(26))
                        .foregroundStyle(Tidy.ink)
                    SweepProgress(fraction: checklist.items.isEmpty ? 0 : Double(checklist.done.count) / Double(checklist.items.count))
                    if !checklist.done.isEmpty {
                        Button("Start over") { checklist.reset() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            LazyVStack(spacing: 10) {
                ForEach(checklist.items) { item in
                    ChecklistRow(item: item, isDone: checklist.done.contains(item.id))
                        .onTapGesture {
                            withAnimation(Tidy.quick) { checklist.toggle(item.id) }
                        }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: checklist.done)
    }
}

struct ChecklistRow: View {
    let item: ChecklistItem
    let isDone: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if isDone {
                    Circle().fill(Tidy.ink)
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Tidy.onInk)
                } else {
                    Circle().strokeBorder(Tidy.muted, lineWidth: 1.2)
                }
            }
            .frame(width: 24, height: 24)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.tidySerif(22))
                    .foregroundStyle(Tidy.ink)
                    .strikethrough(isDone, color: Tidy.muted)
                Text(item.steps)
                    .font(.footnote)
                    .foregroundStyle(Tidy.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .tidyCard(corner: 22)
        .opacity(isDone ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }
}
