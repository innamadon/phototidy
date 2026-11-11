import Foundation
import Photos

/// One photo inside a group of look-alikes.
struct PhotoItem: Identifiable {
    let asset: PHAsset
    let score: Double
    /// Short labels shown under the photo, e.g. "Sharpest", "Blurry".
    let notes: [String]
    /// Space the photo takes on the phone (0 if unknown).
    let bytes: Int64

    var id: String { asset.localIdentifier }
}

/// A set of photos that look alike. `items` is sorted best first.
struct PhotoGroup: Identifiable {
    let id = UUID()
    var items: [PhotoItem]
    /// Local identifiers of the photos the user wants to keep.
    var keep: Set<String>
    /// True once the user has looked at the group and confirmed the picks.
    var reviewed = false

    var best: PhotoItem? { items.first }
    var date: Date { items.compactMap { $0.asset.creationDate }.min() ?? .distantPast }
    var removeItems: [PhotoItem] { items.filter { !keep.contains($0.id) } }
    var removeIDs: [String] { removeItems.map(\.id) }
    var removeBytes: Int64 { removeItems.reduce(Int64(0)) { $0 + $1.bytes } }
}

/// Shown after a delete so the result feels finished.
struct CleanupSummary: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
    /// True when the items went to the review album instead of being deleted.
    let movedToAlbum: Bool
}

enum ScanRange: String, CaseIterable, Identifiable {
    case month
    case quarter
    case year
    case everything

    var id: Self { self }

    var label: String {
        switch self {
        case .month: return "Last 30 days"
        case .quarter: return "Last 3 months"
        case .year: return "Last year"
        case .everything: return "Everything"
        }
    }

    var startDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .month: return calendar.date(byAdding: .day, value: -30, to: Date())
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: Date())
        case .year: return calendar.date(byAdding: .year, value: -1, to: Date())
        case .everything: return nil
        }
    }
}

/// How far apart two shots can be and still count as "the same moment".
enum ShotGap: Double, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case thirtyMinutes = 1800

    var id: Self { self }

    var label: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .thirtyMinutes: return "30 minutes"
        }
    }
}

enum GroupSort: String, CaseIterable, Identifiable {
    case newest
    case biggest
    case mostPhotos

    var id: Self { self }

    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .biggest: return "Most space first"
        case .mostPhotos: return "Most photos first"
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A single photo or video in one of the simple lists (blurry, screenshots, videos).
struct LooseItem: Identifiable {
    let asset: PHAsset
    /// Space it takes on the phone (0 if unknown).
    let bytes: Int64
    /// Blurry: edge strength (lower = blurrier). Videos: length in seconds.
    /// Live Photos: bytes saved by shrinking.
    let metric: Double
    /// A face or person is in the photo (Blurry list only).
    var hasPeople: Bool = false

    var id: String { asset.localIdentifier }
}

enum AppTab: Hashable {
    case similar
    case clutter
    case space
    case phone
}

enum ClutterSection: String, CaseIterable, Identifiable {
    case blurry = "Blurry"
    case duplicates = "Duplicates"
    case screenshots = "Screenshots"
    case receipts = "Receipts"
    var id: Self { self }
}

enum SpaceSection: String, CaseIterable, Identifiable {
    case videos = "Videos"
    case recordings = "Recordings"
    case livePhotos = "Live Photos"
    var id: Self { self }
}

enum PhoneSection: String, CaseIterable, Identifiable {
    case files = "Files"
    case contacts = "Contacts"
    case reminders = "Reminders"
    case checklist = "Checklist"
    var id: Self { self }
}

/// Identical copies of one photo. The keeper stays; the copies are offered for removal.
struct DuplicateSet: Identifiable {
    let id = UUID()
    var keeper: LooseItem
    var copies: [LooseItem]
}

enum ScanKind {
    case similar
    case blurry
    case duplicates
    case receipts
}

/// Filter for the screenshots list.
enum ShotAge: String, CaseIterable, Identifiable {
    case all
    case month
    case halfYear
    case year

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All"
        case .month: return "1 mo+"
        case .halfYear: return "6 mo+"
        case .year: return "1 yr+"
        }
    }

    /// Only screenshots older than this date are shown (nil = show all).
    var cutoff: Date? {
        let calendar = Calendar.current
        switch self {
        case .all: return nil
        case .month: return calendar.date(byAdding: .month, value: -1, to: Date())
        case .halfYear: return calendar.date(byAdding: .month, value: -6, to: Date())
        case .year: return calendar.date(byAdding: .year, value: -1, to: Date())
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// "1 photo" / "7 photos" as a plain string.
func counted(_ n: Int, _ one: String, _ many: String) -> String {
    n == 1 ? "1 \(one)" : "\(n) \(many)"
}
