import Foundation
import Photos
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    var authStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var tab: AppTab = .similar
    var showSettings = false

    // Settings (remembered between launches)
    var range: ScanRange = .year
    var gap: ShotGap = .fiveMinutes
    var includeScreenshots = false
    var strictness: Double = 0.5
    var sort: GroupSort = .newest
    /// When on, "remove" sends items to an album instead of deleting them.
    var moveToAlbum = false
    /// 0 = only very blurry photos, 1 = also slightly soft ones.
    var blurSensitivity: Double = 0.5
    /// "system", "light" or "dark".
    var appearance = "system"

    // The running scan (only one at a time)
    var activeScan: ScanKind?
    var progressDone = 0
    var progressTotal = 0

    // Similar
    var hasScanned = false
    var photosChecked = 0
    var groups: [PhotoGroup] = []
    var path: [UUID] = []

    // Blurry
    var blurScanned = false
    var blurChecked = 0
    var blurCandidates: [LooseItem] = []
    var blurSelected: Set<String> = []

    // Screenshots
    var screenshots: [LooseItem] = []
    var screenshotsLoaded = false
    var shotSelected: Set<String> = []
    var shotAge: ShotAge = .all

    // Videos
    var videos: [LooseItem] = []
    var videosLoaded = false
    var videoSelected: Set<String> = []

    // Results
    var lastCleanup: CleanupSummary?
    var lifetimeDeleted = 0
    var lifetimeBytes: Int64 = 0
    var errorMessage: String?

    @ObservationIgnored private let cache = AnalysisCache()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "range"), let value = ScanRange(rawValue: raw) {
            range = value
        }
        if let value = ShotGap(rawValue: defaults.double(forKey: "gap")) {
            gap = value
        }
        if defaults.object(forKey: "strictness") != nil {
            strictness = defaults.double(forKey: "strictness")
        }
        if defaults.object(forKey: "blurSensitivity") != nil {
            blurSensitivity = defaults.double(forKey: "blurSensitivity")
        }
        if let raw = defaults.string(forKey: "sort"), let value = GroupSort(rawValue: raw) {
            sort = value
        }
        includeScreenshots = defaults.bool(forKey: "includeScreenshots")
        if let value = defaults.string(forKey: "appearance") {
            appearance = value
        }
        moveToAlbum = defaults.bool(forKey: "moveToAlbum")
        lifetimeDeleted = defaults.integer(forKey: "lifetimeDeleted")
        lifetimeBytes = Int64(defaults.integer(forKey: "lifetimeBytes"))
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(range.rawValue, forKey: "range")
        defaults.set(gap.rawValue, forKey: "gap")
        defaults.set(strictness, forKey: "strictness")
        defaults.set(blurSensitivity, forKey: "blurSensitivity")
        defaults.set(sort.rawValue, forKey: "sort")
        defaults.set(includeScreenshots, forKey: "includeScreenshots")
        defaults.set(moveToAlbum, forKey: "moveToAlbum")
        defaults.set(appearance, forKey: "appearance")
    }

    // MARK: Derived values

    var isScanning: Bool { activeScan == .similar }
    var isBlurScanning: Bool { activeScan == .blurry }
    var isBusy: Bool { activeScan != nil }

    var extrasCount: Int { groups.reduce(0) { $0 + $1.removeIDs.count } }
    var extrasBytes: Int64 { groups.reduce(Int64(0)) { $0 + $1.removeBytes } }
    var reviewedGroups: [PhotoGroup] { groups.filter { $0.reviewed } }
    var reviewedExtrasCount: Int { reviewedGroups.reduce(0) { $0 + $1.removeIDs.count } }

    var progressFraction: Double {
        guard progressTotal > 0 else { return 0 }
        return min(1, Double(progressDone) / Double(progressTotal))
    }

    var strictnessLabel: String {
        if strictness < 0.34 { return "loose match" }
        if strictness > 0.66 { return "strict match" }
        return "balanced match"
    }

    var optionsSummary: String {
        "\(range.label) · shots within \(gap.label) · \(strictnessLabel)"
    }

    /// Word used on buttons: "Delete" or "Move".
    var removeVerb: String { moveToAlbum ? "Move" : "Delete" }

    var sortedGroups: [PhotoGroup] {
        switch sort {
        case .newest:
            return groups.sorted { $0.date > $1.date }
        case .biggest:
            return groups.sorted { $0.removeBytes > $1.removeBytes }
        case .mostPhotos:
            return groups.sorted { $0.items.count > $1.items.count }
        }
    }

    func group(_ id: UUID) -> PhotoGroup? {
        groups.first { $0.id == id }
    }

    /// Blurry photos at the current sensitivity, blurriest first.
    var blurryVisible: [LooseItem] {
        let threshold = 24 + 56 * blurSensitivity
        return blurCandidates
            .filter { $0.metric < threshold }
            .sorted { $0.metric < $1.metric }
    }

    /// Screenshots matching the age filter, oldest first.
    var screenshotsVisible: [LooseItem] {
        guard let cutoff = shotAge.cutoff else { return screenshots }
        return screenshots.filter { item in
            guard let date = item.asset.creationDate else { return false }
            return date < cutoff
        }
    }

    func bytes(of ids: Set<String>, in items: [LooseItem]) -> Int64 {
        items.reduce(Int64(0)) { total, item in
            ids.contains(item.id) ? total + item.bytes : total
        }
    }

    // MARK: Access

    func requestAccess() async {
        authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func refreshAuth() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: Scanning

    private var scanOptions: ScanOptions {
        ScanOptions(startDate: range.startDate,
                    includeScreenshots: includeScreenshots,
                    strictness: strictness,
                    maxGap: gap.rawValue)
    }

    private func beginScan(_ kind: ScanKind) {
        saveSettings()
        activeScan = kind
        progressDone = 0
        progressTotal = 0
        errorMessage = nil
        UIApplication.shared.isIdleTimerDisabled = true   // keep the screen awake while scanning
    }

    private func endScan() {
        activeScan = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func startScan() {
        guard !isBusy else { return }
        beginScan(.similar)
        hasScanned = false
        groups = []
        path = []

        let options = scanOptions
        let engine = SimilarityEngine(cache: cache)
        let model = self
        scanTask = Task {
            do {
                let checked = try await engine.scan(options: options, onProgress: { done, total in
                    await model.updateProgress(done: done, total: total)
                }, onGroups: { found in
                    await model.appendGroups(found)
                })
                model.photosChecked = checked
            } catch is CancellationError {
                // Stopped by the user: keep whatever was found so far.
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.hasScanned = true
            model.endScan()
        }
    }

    func startBlurScan() {
        guard !isBusy else { return }
        beginScan(.blurry)
        blurScanned = false
        blurCandidates = []
        blurSelected = []

        let options = scanOptions
        let engine = SimilarityEngine(cache: cache)
        let model = self
        scanTask = Task {
            do {
                let checked = try await engine.scanBlurry(options: options, onProgress: { done, total in
                    await model.updateProgress(done: done, total: total)
                }, onFound: { found in
                    await model.appendBlurry(found)
                })
                model.blurChecked = checked
            } catch is CancellationError {
                // Stopped by the user: keep whatever was found so far.
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.blurScanned = true
            model.endScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func updateProgress(done: Int, total: Int) {
        progressDone = done
        progressTotal = total
    }

    private func appendGroups(_ found: [PhotoGroup]) {
        groups.append(contentsOf: found)
    }

    private func appendBlurry(_ found: [LooseItem]) {
        blurCandidates.append(contentsOf: found)
    }

    func clearSavedScanData() {
        cache.clear()
    }

    // MARK: Simple lists

    func loadScreenshots() async {
        let items = await LibraryLister.screenshots()
        screenshots = items
        screenshotsLoaded = true
        shotSelected = shotSelected.intersection(Set(items.map { $0.id }))
    }

    func loadVideos() async {
        let items = await LibraryLister.videos()
        videos = items
        videosLoaded = true
        videoSelected = videoSelected.intersection(Set(items.map { $0.id }))
    }

    // MARK: Choosing keepers (Similar)

    func toggleKeep(groupID: UUID, itemID: String) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[gi].keep.contains(itemID) {
            groups[gi].keep.remove(itemID)
        } else {
            groups[gi].keep.insert(itemID)
        }
    }

    func keepOnlyBest(groupID: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[gi].keep = Set(groups[gi].items.prefix(1).map { $0.id })
    }

    func keepAll(groupID: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[gi].keep = Set(groups[gi].items.map { $0.id })
    }

    /// "These aren't really the same" — hide the group without removing anything.
    func dismissGroup(_ groupID: UUID) {
        let next = nextUnreviewed(after: groupID)
        groups.removeAll { $0.id == groupID }
        if let next {
            path = [next]
        } else {
            path = []
        }
    }

    // MARK: Guided review (Similar)

    /// Opens the first group that still needs a look.
    func startReviewing() {
        if let first = sortedGroups.first(where: { !$0.reviewed }) ?? sortedGroups.first {
            path = [first.id]
        }
    }

    /// Marks this group as checked and moves on to the next one that isn't.
    func confirmAndAdvance(from groupID: UUID) {
        let next = nextUnreviewed(after: groupID)
        if let gi = groups.firstIndex(where: { $0.id == groupID }) {
            groups[gi].reviewed = true
        }
        if let next {
            path = [next]
        } else {
            path = []
        }
    }

    func unreviewedCount(excluding groupID: UUID) -> Int {
        groups.filter { !$0.reviewed && $0.id != groupID }.count
    }

    private func nextUnreviewed(after groupID: UUID) -> UUID? {
        let ordered = sortedGroups
        guard let index = ordered.firstIndex(where: { $0.id == groupID }) else {
            return ordered.first(where: { !$0.reviewed })?.id
        }
        let later = ordered[(index + 1)...]
        if let found = later.first(where: { !$0.reviewed }) {
            return found.id
        }
        let earlier = ordered[..<index]
        return earlier.first(where: { !$0.reviewed })?.id
    }

    // MARK: Removing

    /// Removes the extras (photos not marked "keep") in the given groups, or all groups if nil.
    func removeExtras(in groupIDs: Set<UUID>? = nil) async {
        let targets: [PhotoGroup] = groups.filter { group in
            if let groupIDs { return groupIDs.contains(group.id) }
            return true
        }
        let ids: [String] = targets.flatMap { $0.removeIDs }
        let bytes: Int64 = targets.reduce(Int64(0)) { $0 + $1.removeBytes }

        let done = await remove(ids: ids, bytes: bytes)
        if done {
            let targetIDs = Set(targets.map { $0.id })
            groups.removeAll { targetIDs.contains($0.id) }
            path.removeAll { targetIDs.contains($0) }
        }
    }

    /// Removes the selected items from one of the simple lists.
    func removeSelected(_ ids: Set<String>, from items: [LooseItem]) async {
        let chosen = items.filter { ids.contains($0.id) }
        let bytes: Int64 = chosen.reduce(Int64(0)) { $0 + $1.bytes }
        _ = await remove(ids: chosen.map { $0.id }, bytes: bytes)
    }

    /// Deletes the items (or moves them to the review album, depending on the setting),
    /// then takes them out of every list in the app.
    /// - Returns: true if it happened, false if the user cancelled or it failed.
    private func remove(ids: [String], bytes: Int64) async -> Bool {
        guard !ids.isEmpty else { return false }
        let toAlbum = moveToAlbum
        do {
            if toAlbum {
                try await LibraryChanges.addToReviewAlbum(ids: ids)
            } else {
                try await LibraryChanges.delete(ids: ids)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue {
                return false   // the user tapped "Don't Allow"
            }
            errorMessage = error.localizedDescription
            return false
        }

        purge(Set(ids))
        lifetimeDeleted += ids.count
        lifetimeBytes += bytes
        UserDefaults.standard.set(lifetimeDeleted, forKey: "lifetimeDeleted")
        UserDefaults.standard.set(Int(lifetimeBytes), forKey: "lifetimeBytes")
        lastCleanup = CleanupSummary(count: ids.count, bytes: bytes, movedToAlbum: toAlbum)
        return true
    }

    /// Takes removed items out of every list, so they never show up twice.
    private func purge(_ ids: Set<String>) {
        for gi in groups.indices {
            groups[gi].items.removeAll { ids.contains($0.id) }
            groups[gi].keep.subtract(ids)
        }
        let emptied = Set(groups.filter { $0.items.count < 2 }.map { $0.id })
        if !emptied.isEmpty {
            groups.removeAll { emptied.contains($0.id) }
            path.removeAll { emptied.contains($0) }
        }

        blurCandidates.removeAll { ids.contains($0.id) }
        blurSelected.subtract(ids)
        screenshots.removeAll { ids.contains($0.id) }
        shotSelected.subtract(ids)
        videos.removeAll { ids.contains($0.id) }
        videoSelected.subtract(ids)
    }
}
