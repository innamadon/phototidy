import Foundation
import Photos

/// Everything we measure about one photo.
struct PhotoAnalysis: Sendable {
    /// What the photo "looks like": a unit-length vector from Apple's Vision framework.
    var vector: [Float]
    var sharpness: Double
    var exposure: Double
    /// Strength of the crispest edges (0…1020). Low = nothing in the photo is sharp.
    var edgePeak: Double
    var faceQuality: Double?   // nil = no faces
    var aesthetic: Double?     // 0…1, iOS 18+
}

/// Remembers the analysis of photos between scans, so a second scan
/// only has to look at photos that are new or changed.
final class AnalysisCache: @unchecked Sendable {

    private struct Entry: Codable {
        var modified: Date?
        var vector: Data
        var sharpness: Double
        var exposure: Double
        var edgePeak: Double
        var faceQuality: Double?
        var aesthetic: Double?
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private let lock = NSLock()

    private var fileURL: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("photo-analysis-v3.plist")
    }

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func lookup(_ asset: PHAsset) -> PhotoAnalysis? {
        lock.lock()
        let entry = entries[asset.localIdentifier]
        lock.unlock()

        guard let entry else { return nil }
        // Edited since we last looked? Then measure it again.
        if let saved = entry.modified, let current = asset.modificationDate {
            if abs(saved.timeIntervalSince(current)) > 1 { return nil }
        } else if (entry.modified == nil) != (asset.modificationDate == nil) {
            return nil
        }

        let vector = Self.floats(from: entry.vector)
        guard !vector.isEmpty else { return nil }
        return PhotoAnalysis(vector: vector,
                             sharpness: entry.sharpness,
                             exposure: entry.exposure,
                             edgePeak: entry.edgePeak,
                             faceQuality: entry.faceQuality,
                             aesthetic: entry.aesthetic)
    }

    func store(_ analysis: PhotoAnalysis, for asset: PHAsset) {
        let entry = Entry(modified: asset.modificationDate,
                          vector: Self.data(from: analysis.vector),
                          sharpness: analysis.sharpness,
                          exposure: analysis.exposure,
                          edgePeak: analysis.edgePeak,
                          faceQuality: analysis.faceQuality,
                          aesthetic: analysis.aesthetic)
        lock.lock()
        entries[asset.localIdentifier] = entry
        dirty = true
        lock.unlock()
    }

    func save() {
        lock.lock()
        let snapshot = entries
        let needsSave = dirty
        dirty = false
        lock.unlock()

        guard needsSave else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        lock.lock()
        entries = [:]
        dirty = false
        loaded = true
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Float <-> Data

    private static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                result[i] = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        return result
    }
}
