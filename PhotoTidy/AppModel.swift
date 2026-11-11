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
    /// Blurry: leave out photos with people in them.
    var keepBlurryPeople = true
    /// Address of the receipt filer on the PC, e.g. https://mydesktop.tail1234.ts.net
    var filerAddress = ""

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

    // Which part of each tab is showing
    var clutterSection: ClutterSection = .blurry
    var spaceSection: SpaceSection = .videos
    var phoneSection: PhoneSection = .files

    // Exact duplicates
    var duplicateSets: [DuplicateSet] = []
    var dupScanned = false
    var dupSelected: Set<String> = []

    // Receipts
    var receipts: [LooseItem] = []
    var receiptsScanned = false
    var receiptsChecked = 0
    var receiptSelected: Set<String> = []
    /// Receipts already sent to the filer (remembered between launches).
    var receiptsSent: Set<String> = []
    var isFiling = false
    var filingDone = 0
    var filingTotal = 0
    var filingReport: String?

    // Screen recordings
    var recordings: [LooseItem] = []
    var recordingsLoaded = false
    var recordingSelected: Set<String> = []

    // Live Photos
    var livePhotos: [LooseItem] = []
    var livePhotosLoaded = false
    var liveSelected: Set<String> = []

    // Shrinking Live Photos and videos
    var isShrinking = false
    var shrinkDone = 0
    var shrinkTotal = 0
    /// How far through the item being shrunk right now (0…1).
    var shrinkItemFraction: Double = 0
    var shrinkReport: String?

    // Results
    var lastCleanup: CleanupSummary?
    var lifetimeDeleted = 0
    var lifetimeBytes: Int64 = 0
    var errorMessage: String?

    @ObservationIgnored private let cache = AnalysisCache()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let receiptVerdicts = ReceiptVerdicts()

    // Phone tab helpers (each keeps its own state)
    @ObservationIgnored let files = FilesCleaner()
    @ObservationIgnored let contacts = ContactsCleaner()
    @ObservationIgnored let calendar = CalendarCleaner()
    @ObservationIgnored let checklist = Checklist()
    @ObservationIgnored private var shrinkTask: Task<Void, Never>?

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
        if defaults.object(forKey: "keepBlurryPeople") != nil {
            keepBlurryPeople = defaults.bool(forKey: "keepBlurryPeople")
        }
        filerAddress = defaults.string(forKey: "filerAddress") ?? ""
        receiptsSent = Set(defaults.stringArray(forKey: "receiptsSent") ?? [])
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
        defaults.set(keepBlurryPeople, forKey: "keepBlurryPeople")
        defaults.set(filerAddress, forKey: "filerAddress")
    }

    // MARK: Derived values

    var isScanning: Bool { activeScan == .similar }
    var isBlurScanning: Bool { activeScan == .blurry }
    var isDupScanning: Bool { activeScan == .duplicates }
    var isReceiptScanning: Bool { activeScan == .receipts }

    /// Every copy in the duplicate sets (the keepers are not in here).
    var duplicateCopies: [LooseItem] { duplicateSets.flatMap { $0.copies } }

    /// Whether a filer address has been entered and looks valid.
    var filerURL: URL? { FilerClient.address(from: filerAddress) }
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
        let skipPeople = keepBlurryPeople
        return blurCandidates
            .filter { $0.metric < threshold && !(skipPeople && $0.hasPeople) }
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
        receiptVerdicts.clear()
    }

    // MARK: Exact duplicates

    func startDuplicateScan() {
        guard !isBusy else { return }
        beginScan(.duplicates)
        dupScanned = false
        duplicateSets = []
        dupSelected = []

        let start = range.startDate
        let screenshots = includeScreenshots
        let model = self
        scanTask = Task {
            do {
                let sets = try await DuplicateFinder().scan(since: start, includeScreenshots: screenshots) { done, total in
                    await model.updateProgress(done: done, total: total)
                }
                model.duplicateSets = sets
                // Every copy starts marked; the keeper is never offered.
                model.dupSelected = Set(sets.flatMap { $0.copies.map { $0.id } })
            } catch is CancellationError {
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.dupScanned = true
            model.endScan()
        }
    }

    // MARK: Receipts

    func startReceiptScan() {
        guard !isBusy else { return }
        beginScan(.receipts)
        receiptsScanned = false
        receipts = []
        receiptSelected = []
        filingReport = nil

        let start = range.startDate
        let finder = ReceiptFinder(verdicts: receiptVerdicts)
        let model = self
        scanTask = Task {
            do {
                let checked = try await finder.scan(since: start, onProgress: { done, total in
                    await model.updateProgress(done: done, total: total)
                }, onFound: { found in
                    await model.appendReceipts(found)
                })
                model.receiptsChecked = checked
            } catch is CancellationError {
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.receiptsScanned = true
            model.endScan()
        }
    }

    private func appendReceipts(_ found: [LooseItem]) {
        receipts.append(contentsOf: found)
        // New receipts start marked; ones already sent to the filer don't.
        for item in found where !receiptsSent.contains(item.id) {
            receiptSelected.insert(item.id)
        }
    }

    /// Adds the receipts to the Receipts album, then sends any not sent before to the filer.
    func fileReceipts(_ ids: Set<String>) async {
        let chosen = receipts.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, !isFiling else { return }
        isFiling = true
        filingDone = 0
        filingTotal = chosen.count
        filingReport = nil

        var lines: [String] = []
        do {
            try await LibraryChanges.addToAlbum(titled: LibraryChanges.receiptsAlbumTitle,
                                                ids: chosen.map { $0.id })
            lines.append(chosen.count == 1 ? "Added 1 to the Receipts album." : "Added \(chosen.count) to the Receipts album.")
        } catch {
            lines.append("Couldn't add them to the Receipts album (\(error.localizedDescription)).")
        }

        if let base = filerURL {
            var sent = 0
            var rejected = 0
            var problem: String?
            for item in chosen {
                if receiptsSent.contains(item.id) {
                    filingDone += 1
                    continue
                }
                do {
                    let outcome = try await FilerClient.upload(item.asset, to: base)
                    switch outcome {
                    case .sent:
                        sent += 1
                        receiptsSent.insert(item.id)
                    case .rejected:
                        rejected += 1
                    }
                } catch {
                    problem = FilerClient.explain(error)
                    break
                }
                filingDone += 1
            }
            UserDefaults.standard.set(Array(receiptsSent), forKey: "receiptsSent")
            if sent > 0 {
                lines.append(sent == 1 ? "Sent 1 to your receipt filer." : "Sent \(sent) to your receipt filer.")
            }
            if rejected > 0 {
                lines.append("Your filer turned down \(rejected) (not a photo it accepts, or over 25 MB).")
            }
            if let problem {
                lines.append(problem)
            }
        } else {
            lines.append("To send them to your receipt filer too, add its address in Settings.")
        }

        receiptSelected.subtract(receiptsSent)
        filingReport = lines.joined(separator: " ")
        isFiling = false
    }

    /// Opens the filer's page to check the address works. Returns a short message.
    func testFiler() async -> String {
        saveSettings()
        guard let base = filerURL else {
            return "That doesn't look like an address. It should look like https://mydesktop.tail1234.ts.net"
        }
        do {
            try await FilerClient.check(base)
            return "Connected to your receipt filer."
        } catch {
            return FilerClient.explain(error)
        }
    }

    // MARK: Shrinking

    func shrinkLivePhotos(_ ids: Set<String>) {
        let assets: [PHAsset] = livePhotos.filter { ids.contains($0.id) }.map { $0.asset }
        guard !assets.isEmpty, !isShrinking else { return }
        beginShrink(assets.count)
        let model = self
        shrinkTask = Task {
            let result = await MediaShrinker.shrinkLivePhotos(assets) { done, total in
                await model.updateShrink(done: done, total: total)
            }
            model.finishShrink(result, singular: "Live Photo", plural: "Live Photos")
        }
    }

    func shrinkVideos(_ ids: Set<String>, from items: [LooseItem]) {
        let chosen = items.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, !isShrinking else { return }
        beginShrink(chosen.count)
        let model = self
        shrinkTask = Task {
            let result = await MediaShrinker.shrinkVideos(chosen, progress: { done, total in
                await model.updateShrink(done: done, total: total)
            }, partial: { fraction in
                await model.updateShrinkItem(fraction)
            })
            model.finishShrink(result, singular: "video", plural: "videos")
            await model.loadVideos()
            if model.recordingsLoaded {
                await model.loadRecordings()
            }
        }
    }

    func cancelShrink() {
        shrinkTask?.cancel()
    }

    private func beginShrink(_ count: Int) {
        isShrinking = true
        shrinkDone = 0
        shrinkTotal = count
        shrinkItemFraction = 0
        shrinkReport = nil
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func updateShrink(done: Int, total: Int) {
        shrinkDone = done
        shrinkTotal = total
    }

    private func updateShrinkItem(_ fraction: Double) {
        shrinkItemFraction = fraction
    }

    private func finishShrink(_ result: ShrinkResult, singular: String, plural: String) {
        isShrinking = false
        shrinkItemFraction = 0
        UIApplication.shared.isIdleTimerDisabled = false
        purge(Set(result.replacedIDs))

        var lines: [String] = []
        if result.shrunk > 0 {
            let noun = result.shrunk == 1 ? singular : plural
            var line = "Shrank \(result.shrunk) \(noun)"
            if result.bytesSaved > 0 {
                line += ", saving about \(formatBytes(result.bytesSaved))"
            }
            lines.append(line + ". The originals are in Recently Deleted; empty it to get the space back today.")
            lifetimeBytes += result.bytesSaved
            UserDefaults.standard.set(Int(lifetimeBytes), forKey: "lifetimeBytes")
        }
        if result.skipped > 0 {
            lines.append("\(result.skipped) left as they were (already compact, or slow motion).")
        }
        if result.failed > 0 {
            lines.append("\(result.failed) couldn't be shrunk.")
        }
        if result.cancelled {
            lines.append("Stopped. Anything not listed above was left exactly as it was.")
        }
        shrinkReport = lines.isEmpty ? "Nothing was changed." : lines.joined(separator: " ")
    }

    // MARK: Simple lists

    func loadScreenshots() async {
        let items = await LibraryLister.screenshots()
        screenshots = items
        screenshotsLoaded = true
        shotSelected = shotSelected.intersection(Set(items.map { $0.id }))
    }

    func loadRecordings() async {
        let items = await LibraryLister.screenRecordings()
        recordings = items
        recordingsLoaded = true
        recordingSelected = recordingSelected.intersection(Set(items.map { $0.id }))
    }

    func loadLivePhotos() async {
        let items = await LibraryLister.livePhotos()
        livePhotos = items
        livePhotosLoaded = true
        liveSelected = liveSelected.intersection(Set(items.map { $0.id }))
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

        for di in duplicateSets.indices {
            duplicateSets[di].copies.removeAll { ids.contains($0.id) }
        }
        duplicateSets.removeAll { $0.copies.isEmpty || ids.contains($0.keeper.id) }
        dupSelected.subtract(ids)
        receipts.removeAll { ids.contains($0.id) }
        receiptSelected.subtract(ids)
        recordings.removeAll { ids.contains($0.id) }
        recordingSelected.subtract(ids)
        livePhotos.removeAll { ids.contains($0.id) }
        liveSelected.subtract(ids)
    }
}
