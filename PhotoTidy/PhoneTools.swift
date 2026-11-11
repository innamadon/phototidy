import Foundation
import Observation
import Contacts
import EventKit
import CryptoKit

// MARK: - Files

struct FileEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Folder inside the chosen folder, e.g. "Downloads/Old".
    let place: String
    let size: Int64
    let modified: Date?
    /// Set when this file is an identical copy of another; holds the other file's name.
    var copyOf: String?

    var id: String { url.path }
}

enum FileFilter: String, CaseIterable, Identifiable {
    case biggest = "Biggest"
    case oldest = "Untouched 1 yr+"
    case copies = "Copies"
    var id: Self { self }
}

/// Lists big, old and duplicate files in a folder the user picks (Files app locations).
@MainActor
@Observable
final class FilesCleaner {
    var folderName: String?
    var entries: [FileEntry] = []
    var scanning = false
    var scannedOnce = false
    var selected: Set<String> = []
    var filter: FileFilter = .biggest
    var report: String?

    @ObservationIgnored private var folderURL: URL?
    private static let bookmarkKey = "filesFolderBookmark"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            folderURL = url
            folderName = url.lastPathComponent
            if stale { remember(url) }
        }
    }

    var hasFolder: Bool { folderURL != nil }

    var visible: [FileEntry] {
        switch filter {
        case .biggest:
            return Array(entries.sorted { $0.size > $1.size }.prefix(300))
        case .oldest:
            let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            return entries
                .filter { ($0.modified ?? Date()) < cutoff }
                .sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .copies:
            return entries.filter { $0.copyOf != nil }.sorted { $0.size > $1.size }
        }
    }

    var totalBytes: Int64 { entries.reduce(Int64(0)) { $0 + $1.size } }

    func bytes(of ids: Set<String>) -> Int64 {
        entries.reduce(Int64(0)) { ids.contains($1.id) ? $0 + $1.size : $0 }
    }

    /// Called with the folder the user picked.
    func choose(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        remember(url)
        if access { url.stopAccessingSecurityScopedResource() }
        folderURL = url
        folderName = url.lastPathComponent
        await scan()
    }

    func scan() async {
        guard let root = folderURL, !scanning else { return }
        scanning = true
        report = nil
        selected = []
        let found = await Task.detached(priority: .userInitiated) {
            FileScanner.scan(root)
        }.value
        entries = found
        scanning = false
        scannedOnce = true
    }

    func deleteSelected() async {
        guard let root = folderURL else { return }
        let targets = entries.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        let urls = targets.map { $0.url }
        let result = await Task.detached(priority: .userInitiated) {
            FileScanner.delete(urls, inside: root)
        }.value
        let removed = Set(result.deleted)
        let freed = targets.filter { removed.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        entries.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        var text = result.deleted.count == 1 ? "Deleted 1 file" : "Deleted \(result.deleted.count) files"
        if freed > 0 { text += " (\(formatBytes(freed)))" }
        text += "."
        if result.failed > 0 {
            text += " \(result.failed) couldn't be deleted (they may be read-only or in use)."
        }
        report = text
    }

    private func remember(_ url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }
}

/// The file work itself, off the main thread.
enum FileScanner {
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                                 .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

    static func scan(_ root: URL) -> [FileEntry] {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }

        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var entries: [FileEntry] = []
        var localFlags: [String: Bool] = [:]
        let rootPath = root.standardizedFileURL.path

        for case let url as URL in enumerator {
            if entries.count >= 20000 { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            var place = parentPath.hasPrefix(rootPath) ? String(parentPath.dropFirst(rootPath.count)) : ""
            if place.hasPrefix("/") { place.removeFirst() }
            let entry = FileEntry(url: url,
                                  name: url.lastPathComponent,
                                  place: place,
                                  size: Int64(values.fileSize ?? 0),
                                  modified: values.contentModificationDate,
                                  copyOf: nil)
            entries.append(entry)
            // Only files actually on the phone can be compared byte for byte.
            let isLocal = values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
            localFlags[entry.id] = isLocal
        }

        markCopies(&entries, local: localFlags)
        return entries
    }

    /// Same size first, then same contents (SHA-256). The oldest of each set is the original.
    private static func markCopies(_ entries: inout [FileEntry], local: [String: Bool]) {
        var bySize: [Int64: [Int]] = [:]
        for (i, entry) in entries.enumerated() where entry.size >= 4096 && local[entry.id] == true {
            bySize[entry.size, default: []].append(i)
        }
        for indices in bySize.values where indices.count > 1 {
            var byHash: [String: [Int]] = [:]
            for i in indices {
                if let digest = digest(of: entries[i].url) {
                    byHash[digest, default: []].append(i)
                }
            }
            for same in byHash.values where same.count > 1 {
                let ordered = same.sorted { a, b in
                    (entries[a].modified ?? .distantFuture) < (entries[b].modified ?? .distantFuture)
                }
                let original = entries[ordered[0]].name
                for i in ordered.dropFirst() {
                    entries[i].copyOf = original
                }
            }
        }
    }

    private static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var reading = true
        while reading {
            autoreleasepool {
                let chunk = handle.readData(ofLength: 1 << 20)
                if chunk.isEmpty {
                    reading = false
                } else {
                    hasher.update(data: chunk)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func delete(_ urls: [URL], inside root: URL) -> (deleted: [String], failed: Int) {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var deleted: [String] = []
        var failed = 0
        for url in urls {
            var coordinationError: NSError?
            var ok = false
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { actual in
                do {
                    try FileManager.default.removeItem(at: actual)
                    ok = true
                } catch {
                    ok = false
                }
            }
            if ok {
                deleted.append(url.path)
            } else {
                failed += 1
            }
        }
        return (deleted, failed)
    }
}

// MARK: - Contacts

struct ContactGroup: Identifiable, @unchecked Sendable {
    let id = UUID()
    let contacts: [CNContact]
    let name: String
    let summary: String
}

/// Finds contacts saved more than once (same name, phone number or email) and merges them.
@MainActor
@Observable
final class ContactsCleaner {
    var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    var groups: [ContactGroup] = []
    var scanning = false
    var scannedOnce = false
    var merging = false
    var report: String?

    var allowed: Bool {
        if status == .authorized { return true }
        if #available(iOS 18.0, *) {
            return status == .limited
        }
        return false
    }

    func start() async {
        if status == .notDetermined {
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
        }
        if allowed {
            await scan()
        }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        report = nil
        groups = await Task.detached(priority: .userInitiated) {
            ContactMatcher.findDuplicates()
        }.value
        scanning = false
        scannedOnce = true
    }

    func merge(_ group: ContactGroup) async {
        await mergeGroups([group])
    }

    func mergeAll() async {
        await mergeGroups(groups)
    }

    private func mergeGroups(_ chosen: [ContactGroup]) async {
        guard !chosen.isEmpty, !merging else { return }
        merging = true
        let sets: [[CNContact]] = chosen.map { $0.contacts }
        let merged = await Task.detached(priority: .userInitiated) {
            sets.reduce(0) { count, contacts in
                ContactMatcher.merge(contacts) ? count + 1 : count
            }
        }.value
        let failed = chosen.count - merged
        var text = merged == 1 ? "Merged 1 contact." : "Merged \(merged) contacts."
        if failed > 0 {
            text += " \(failed) couldn't be merged (they may be in a read-only account, like a work directory)."
        }
        report = text
        merging = false
        await scan()
        report = text
    }
}

enum ContactMatcher {
    static var keys: [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
         CNContactGivenNameKey as CNKeyDescriptor,
         CNContactFamilyNameKey as CNKeyDescriptor,
         CNContactMiddleNameKey as CNKeyDescriptor,
         CNContactNicknameKey as CNKeyDescriptor,
         CNContactOrganizationNameKey as CNKeyDescriptor,
         CNContactJobTitleKey as CNKeyDescriptor,
         CNContactPhoneNumbersKey as CNKeyDescriptor,
         CNContactEmailAddressesKey as CNKeyDescriptor,
         CNContactPostalAddressesKey as CNKeyDescriptor,
         CNContactUrlAddressesKey as CNKeyDescriptor,
         CNContactBirthdayKey as CNKeyDescriptor]
    }

    static func digits(_ phone: String) -> String {
        let only = phone.filter { $0.isNumber }
        return only.count > 10 ? String(only.suffix(10)) : only
    }

    static func findDuplicates() -> [ContactGroup] {
        let store = CNContactStore()
        let containers = (try? store.containers(matching: nil)) ?? []
        var seen = Set<String>()
        var result: [ContactGroup] = []

        for container in containers {
            let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            guard let all = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { continue }
            let contacts = all.filter { seen.insert($0.identifier).inserted }
            result.append(contentsOf: groups(in: contacts))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func groups(in contacts: [CNContact]) -> [ContactGroup] {
        var parent = Array(0..<contacts.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        var owner: [String: Int] = [:]
        func link(_ key: String, _ index: Int) {
            if let other = owner[key] {
                let a = find(other)
                let b = find(index)
                if a != b { parent[b] = a }
            } else {
                owner[key] = index
            }
        }

        for (i, contact) in contacts.enumerated() {
            let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? "")
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2 { link("n:" + name, i) }
            for phone in contact.phoneNumbers {
                let d = digits(phone.value.stringValue)
                if d.count >= 7 { link("p:" + d, i) }
            }
            for email in contact.emailAddresses {
                let e = (email.value as String).lowercased().trimmingCharacters(in: .whitespaces)
                if e.contains("@") { link("e:" + e, i) }
            }
        }

        var buckets: [Int: [CNContact]] = [:]
        for i in 0..<contacts.count {
            buckets[find(i), default: []].append(contacts[i])
        }

        var groups: [ContactGroup] = []
        for members in buckets.values where members.count >= 2 && members.count <= 6 {
            let best = members.max { score($0) < score($1) } ?? members[0]
            let name = CNContactFormatter.string(from: best, style: .fullName)
                ?? best.organizationName
            let phones = Set(members.flatMap { $0.phoneNumbers.map { digits($0.value.stringValue) } }).count
            let emails = Set(members.flatMap { $0.emailAddresses.map { ($0.value as String).lowercased() } }).count
            var parts = ["\(members.count) cards"]
            if phones > 0 { parts.append(phones == 1 ? "1 number" : "\(phones) numbers") }
            if emails > 0 { parts.append(emails == 1 ? "1 email" : "\(emails) emails") }
            groups.append(ContactGroup(contacts: members,
                                       name: name.isEmpty ? "No name" : name,
                                       summary: parts.joined(separator: " · ")))
        }
        return groups
    }

    private static func score(_ contact: CNContact) -> Int {
        var s = contact.phoneNumbers.count + contact.emailAddresses.count + contact.postalAddresses.count
        if !contact.givenName.isEmpty { s += 1 }
        if !contact.familyName.isEmpty { s += 1 }
        if !contact.organizationName.isEmpty { s += 1 }
        if contact.birthday != nil { s += 1 }
        return s
    }

    /// Keeps the fullest card, adds anything the others have that it doesn't, deletes the others.
    static func merge(_ contacts: [CNContact]) -> Bool {
        let ordered = contacts.sorted { score($0) > score($1) }
        guard let primary = ordered.first,
              let merged = primary.mutableCopy() as? CNMutableContact else { return false }

        var phones = merged.phoneNumbers
        var phoneKeys = Set(phones.map { digits($0.value.stringValue) })
        var emails = merged.emailAddresses
        var emailKeys = Set(emails.map { ($0.value as String).lowercased() })
        var postals = merged.postalAddresses
        var postalKeys = Set(postals.map { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).lowercased() })
        var urls = merged.urlAddresses
        var urlKeys = Set(urls.map { ($0.value as String).lowercased() })

        for other in ordered.dropFirst() {
            for phone in other.phoneNumbers {
                let key = digits(phone.value.stringValue)
                if phoneKeys.insert(key).inserted {
                    phones.append(CNLabeledValue(label: phone.label, value: phone.value))
                }
            }
            for email in other.emailAddresses {
                let key = (email.value as String).lowercased()
                if emailKeys.insert(key).inserted {
                    emails.append(CNLabeledValue(label: email.label, value: email.value))
                }
            }
            for postal in other.postalAddresses {
                let key = CNPostalAddressFormatter.string(from: postal.value, style: .mailingAddress).lowercased()
                if postalKeys.insert(key).inserted {
                    postals.append(CNLabeledValue(label: postal.label, value: postal.value))
                }
            }
            for url in other.urlAddresses {
                let key = (url.value as String).lowercased()
                if urlKeys.insert(key).inserted {
                    urls.append(CNLabeledValue(label: url.label, value: url.value))
                }
            }
            if merged.givenName.isEmpty { merged.givenName = other.givenName }
            if merged.familyName.isEmpty { merged.familyName = other.familyName }
            if merged.middleName.isEmpty { merged.middleName = other.middleName }
            if merged.nickname.isEmpty { merged.nickname = other.nickname }
            if merged.organizationName.isEmpty { merged.organizationName = other.organizationName }
            if merged.jobTitle.isEmpty { merged.jobTitle = other.jobTitle }
            if merged.birthday == nil { merged.birthday = other.birthday }
        }
        merged.phoneNumbers = phones
        merged.emailAddresses = emails
        merged.postalAddresses = postals
        merged.urlAddresses = urls

        let request = CNSaveRequest()
        request.update(merged)
        for other in ordered.dropFirst() {
            if let doomed = other.mutableCopy() as? CNMutableContact {
                request.delete(doomed)
            }
        }
        do {
            try CNContactStore().execute(request)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Reminders and events

/// Completed reminders older than a month, and one-off events older than two years.
@MainActor
@Observable
final class CalendarCleaner {
    var reminders: [EKReminder] = []
    var events: [EKEvent] = []
    var remindersAllowed = false
    var eventsAllowed = false
    var loading = false
    var loadedOnce = false
    var working = false
    var report: String?

    @ObservationIgnored private let store = EKEventStore()

    func start() async {
        remindersAllowed = (try? await store.requestFullAccessToReminders()) ?? false
        eventsAllowed = (try? await store.requestFullAccessToEvents()) ?? false
        await load()
    }

    func load() async {
        loading = true
        report = nil
        if remindersAllowed {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())
            let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil,
                                                                 ending: cutoff,
                                                                 calendars: nil)
            reminders = await fetchReminders(predicate)
                .filter { $0.calendar?.allowsContentModifications ?? false }
                .sorted { ($0.completionDate ?? .distantPast) < ($1.completionDate ?? .distantPast) }
        } else {
            reminders = []
        }
        events = eventsAllowed ? oldEvents() : []
        loading = false
        loadedOnce = true
    }

    private func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }
    }

    /// One-off events (not repeating) in your own calendars that ended more than two years ago.
    private func oldEvents() -> [EKEvent] {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .year, value: -2, to: Date()),
              var chunkStart = calendar.date(byAdding: .year, value: -14, to: Date()) else { return [] }
        let calendars = store.calendars(for: .event).filter { cal in
            cal.allowsContentModifications && cal.type != .subscription && cal.type != .birthday
        }
        guard !calendars.isEmpty else { return [] }

        var seen = Set<String>()
        var found: [EKEvent] = []
        // Event searches are limited to a few years at a time.
        while chunkStart < end {
            let chunkEnd = min(calendar.date(byAdding: .year, value: 3, to: chunkStart) ?? end, end)
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
            for event in store.events(matching: predicate) where !event.hasRecurrenceRules {
                let key = (event.eventIdentifier ?? UUID().uuidString) + "@" + String(event.startDate.timeIntervalSince1970)
                if seen.insert(key).inserted {
                    found.append(event)
                }
            }
            chunkStart = chunkEnd
        }
        return found.sorted { $0.startDate < $1.startDate }
    }

    func deleteReminders() async {
        guard !reminders.isEmpty, !working else { return }
        working = true
        var removed = 0
        for reminder in reminders {
            if (try? store.remove(reminder, commit: false)) != nil {
                removed += 1
            }
        }
        do {
            try store.commit()
            report = removed == 1 ? "Cleared 1 completed reminder." : "Cleared \(removed) completed reminders."
        } catch {
            store.reset()
            report = "Couldn't clear the reminders (\(error.localizedDescription))."
        }
        working = false
        await load()
    }

    func deleteEvents() async {
        guard !events.isEmpty, !working else { return }
        working = true
        var removed = 0
        for event in events {
            if (try? store.remove(event, span: .thisEvent, commit: false)) != nil {
                removed += 1
            }
        }
        do {
            try store.commit()
            report = removed == 1 ? "Cleared 1 old event." : "Cleared \(removed) old events."
        } catch {
            store.reset()
            report = "Couldn't clear the events (\(error.localizedDescription))."
        }
        working = false
        await load()
    }
}

// MARK: - Storage checklist

struct ChecklistItem: Identifiable {
    let id: String
    let title: String
    let steps: String
}

@MainActor
@Observable
final class Checklist {
    var done: Set<String> = []

    init() {
        done = Set(UserDefaults.standard.stringArray(forKey: "checklistDone") ?? [])
    }

    func toggle(_ id: String) {
        if done.contains(id) {
            done.remove(id)
        } else {
            done.insert(id)
        }
        UserDefaults.standard.set(Array(done), forKey: "checklistDone")
    }

    func reset() {
        done = []
        UserDefaults.standard.set([String](), forKey: "checklistDone")
    }

    let items: [ChecklistItem] = [
        ChecklistItem(id: "messages-attachments",
                      title: "Review big Messages attachments",
                      steps: "Settings → General → iPhone Storage → Messages → Review Large Attachments. Swipe left on anything you don't need."),
        ChecklistItem(id: "messages-keep",
                      title: "Keep Messages for 1 year",
                      steps: "Settings → Apps → Messages (on older iOS: Settings → Messages) → Keep Messages → 1 Year. Older messages and their photos are removed."),
        ChecklistItem(id: "offload",
                      title: "Offload apps you don't use",
                      steps: "Settings → General → iPhone Storage → Offload Unused Apps. The app is removed but its data stays, so nothing is lost when you reinstall."),
        ChecklistItem(id: "app-data",
                      title: "Check apps with big “Documents & Data”",
                      steps: "In Settings → General → iPhone Storage, tap the largest apps. For music, podcast, video and messaging apps, remove downloads inside the app itself, or delete and reinstall the app to clear its cache."),
        ChecklistItem(id: "safari",
                      title: "Clear Safari's website data",
                      steps: "Settings → Apps → Safari (on older iOS: Settings → Safari) → Clear History and Website Data."),
        ChecklistItem(id: "photos-deleted",
                      title: "Empty Recently Deleted in Photos",
                      steps: "Photos → Albums → Recently Deleted → Select → Delete All. This is when the space from Photo Tidy actually comes back."),
        ChecklistItem(id: "files-deleted",
                      title: "Empty Recently Deleted in Files",
                      steps: "Files → Browse → Recently Deleted → Select → Delete All."),
        ChecklistItem(id: "icloud-photos",
                      title: "Let iCloud keep the full-size photos",
                      steps: "If you use iCloud Photos: Settings → Apps → Photos → Optimize iPhone Storage. Full-size originals stay in iCloud; the phone keeps smaller copies.")
    ]
}
