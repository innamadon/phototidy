import Foundation
import Photos
import Vision
import UIKit

/// Photos in the chosen time range, newest first.
enum PhotoFetch {
    static func images(since start: Date?, includeScreenshots: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let start {
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        }
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if !includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
            assets.append(asset)
        }
        return assets
    }
}

/// Runs `work` on every asset, a few at a time, reporting progress.
enum Concurrently {
    static func map<T: Sendable>(_ assets: [PHAsset],
                       width: Int,
                       work: @escaping @Sendable (PHAsset) async -> T?,
                       progress: @escaping @Sendable (Int) async -> Void) async throws -> [String: T] {
        var results: [String: T] = [:]
        try await withThrowingTaskGroup(of: (String, T?).self) { group in
            var next = 0
            while next < min(width, assets.count) {
                let asset = assets[next]
                group.addTask { (asset.localIdentifier, await work(asset)) }
                next += 1
            }
            var finished = 0
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let value = result.1 { results[result.0] = value }
                finished += 1
                await progress(finished)
                if next < assets.count {
                    let asset = assets[next]
                    group.addTask { (asset.localIdentifier, await work(asset)) }
                    next += 1
                }
            }
        }
        return results
    }
}

// MARK: - Receipts

/// Finds photos of receipts: lots of printed text, prices, and words like "total" or "tax".
struct ReceiptFinder: Sendable {
    let verdicts: ReceiptVerdicts

    func scan(since start: Date?,
              onProgress: @escaping @Sendable (Int, Int) async -> Void,
              onFound: @escaping @Sendable ([LooseItem]) async -> Void) async throws -> Int {
        verdicts.loadIfNeeded()
        defer { verdicts.save() }

        // Screenshots are included: e-receipts are often saved that way.
        let assets = PhotoFetch.images(since: start, includeScreenshots: true)
        let total = assets.count
        await onProgress(0, total)

        let memo = self.verdicts
        var index = 0
        while index < total {
            try Task.checkCancellation()
            let end = min(index + 40, total)
            let batch = Array(assets[index..<end])
            let base = index
            let results: [String: Bool] = try await Concurrently.map(batch, width: 3, work: { asset in
                if let known = memo.verdict(for: asset) { return known }
                let isReceipt = await Self.isReceipt(asset)
                memo.store(isReceipt, for: asset)
                return isReceipt
            }, progress: { finished in
                await onProgress(base + finished, total)
            })

            let found: [LooseItem] = batch.compactMap { asset in
                guard results[asset.localIdentifier] == true else { return nil }
                return LooseItem(asset: asset, bytes: ImageLoader.fileSize(of: asset), metric: 0)
            }
            if !found.isEmpty { await onFound(found) }
            index = end
        }
        await onProgress(total, total)
        return total
    }

    static func isReceipt(_ asset: PHAsset) async -> Bool {
        guard let uiImage = await ImageLoader.image(for: asset, side: 1600, contentMode: .aspectFit),
              let cgImage = uiImage.cgImage else { return false }
        let orientation = OrientationMapper.cgOrientation(uiImage.imageOrientation)

        // Quick look first: is there a lot of text, or does it look like paper?
        let boxes = VNDetectTextRectanglesRequest()
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([boxes, classify])

        let textBoxes = boxes.results?.count ?? 0
        let labels: [String] = (classify.results ?? [])
            .filter { $0.confidence > 0.15 }
            .map { $0.identifier.lowercased() }
        let looksLikePaper = labels.contains { label in
            label.contains("receipt") || label.contains("document") || label.contains("paper") || label == "text"
        }
        guard textBoxes >= 8 || looksLikePaper else { return false }

        // Then actually read it.
        let read = VNRecognizeTextRequest()
        read.recognitionLevel = .accurate
        read.usesLanguageCorrection = false
        let reader = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? reader.perform([read])
        let lines: [String] = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return ReceiptText.looksLikeReceipt(lines)
    }
}

enum ReceiptText {
    private static let words = ["total", "subtotal", "sub total", "tax", "visa", "mastercard", "amex",
                                "discover", "debit", "credit", "cash", "change", "receipt", "invoice",
                                "order", "qty", "amount", "balance", "tip", "gratuity", "thank you",
                                "merchant", "auth", "approval", "card", "purchase", "item", "server",
                                "table", "guest", "check #", "transaction"]

    private static let price = try? NSRegularExpression(pattern: "\\b\\d{1,5}[.,]\\d{2}\\b")

    static func looksLikeReceipt(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n").lowercased()
        guard !text.isEmpty else { return false }
        var hits = 0
        for word in words where text.contains(word) {
            hits += 1
        }
        let range = NSRange(text.startIndex..., in: text)
        let prices = price?.numberOfMatches(in: text, options: [], range: range) ?? 0
        let hasTotal = text.contains("total")
        return (hasTotal && prices >= 2 && hits >= 2) || (hits >= 3 && prices >= 3)
    }
}

/// Remembers which photos were already checked for receipts, so later scans are quick.
final class ReceiptVerdicts: @unchecked Sendable {
    private var entries: [String: Bool] = [:]
    private var loaded = false
    private var dirty = false
    private let lock = NSLock()

    private var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipt-verdicts-v1.plist")
    }

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: Bool].self, from: data) {
            entries = decoded
        }
    }

    func verdict(for asset: PHAsset) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return entries[asset.localIdentifier]
    }

    func store(_ value: Bool, for asset: PHAsset) {
        lock.lock()
        entries[asset.localIdentifier] = value
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
}

// MARK: - Exact duplicates

/// Finds copies of the same image, even when one copy was re-saved smaller
/// (for example by a messaging app). Bursts and look-alikes are left to the
/// Similar tab: only near-pixel-identical images count here.
struct DuplicateFinder: Sendable {

    private struct Print: Sendable {
        let hash: UInt64       // difference hash of a 9×8 grey thumbnail
        let tiny: [UInt8]      // 16×16 grey thumbnail
        let aspect: Int        // width/height, in twentieths
    }

    func scan(since start: Date?,
              includeScreenshots: Bool,
              onProgress: @escaping @Sendable (Int, Int) async -> Void) async throws -> [DuplicateSet] {
        let assets = PhotoFetch.images(since: start, includeScreenshots: includeScreenshots)
        let total = assets.count
        await onProgress(0, total)

        let prints: [String: Print] = try await Concurrently.map(assets, width: 6, work: { asset in
            guard let image = await ImageLoader.image(for: asset, side: 96, contentMode: .aspectFit),
                  let cgImage = image.cgImage else { return nil }
            return Self.fingerprint(cgImage, asset: asset)
        }, progress: { finished in
            await onProgress(finished, total)
        })
        try Task.checkCancellation()

        // Line the fingerprints up by position once, so the comparisons below are plain array reads.
        let ordered: [Print?] = assets.map { prints[$0.localIdentifier] }

        // Group by shape, then compare within each shape.
        var byAspect: [Int: [Int]] = [:]
        for (i, entry) in ordered.enumerated() {
            if let entry {
                byAspect[entry.aspect, default: []].append(i)
            }
        }

        var parent = Array(0..<assets.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        for indices in byAspect.values where indices.count > 1 {
            try Task.checkCancellation()
            let hashes: [UInt64] = indices.map { ordered[$0]?.hash ?? 0 }
            let count = indices.count
            for a in 0..<(count - 1) {
                let ha = hashes[a]
                for b in (a + 1)..<count {
                    // Cheap test first (64 bits); the closer look only for near matches.
                    if (ha ^ hashes[b]).nonzeroBitCount > 4 { continue }
                    guard let pa = ordered[indices[a]], let pb = ordered[indices[b]] else { continue }
                    if Self.meanDifference(pa.tiny, pb.tiny) <= 3.5 {
                        let ra = find(indices[a])
                        let rb = find(indices[b])
                        if ra != rb { parent[rb] = ra }
                    }
                }
            }
        }

        var groups: [Int: [PHAsset]] = [:]
        for i in 0..<assets.count where ordered[i] != nil {
            groups[find(i), default: []].append(assets[i])
        }

        var sets: [DuplicateSet] = []
        for members in groups.values where members.count > 1 {
            let ordered = members.sorted(by: Self.betterKeeper)
            let items = ordered.map { LooseItem(asset: $0, bytes: ImageLoader.fileSize(of: $0), metric: 0) }
            sets.append(DuplicateSet(keeper: items[0], copies: Array(items.dropFirst())))
        }
        sets.sort { a, b in
            a.copies.reduce(Int64(0)) { $0 + $1.bytes } > b.copies.reduce(Int64(0)) { $0 + $1.bytes }
        }
        await onProgress(total, total)
        return sets
    }

    /// Which copy to keep: a favourite, then the biggest, then an edited one, then the oldest.
    private static func betterKeeper(_ a: PHAsset, _ b: PHAsset) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        let pixelsA = a.pixelWidth * a.pixelHeight
        let pixelsB = b.pixelWidth * b.pixelHeight
        if pixelsA != pixelsB { return pixelsA > pixelsB }
        if a.hasAdjustments != b.hasAdjustments { return a.hasAdjustments }
        return (a.creationDate ?? .distantFuture) < (b.creationDate ?? .distantFuture)
    }

    private static func fingerprint(_ image: CGImage, asset: PHAsset) -> Print? {
        guard let small = grey(image, width: 9, height: 8),
              let tiny = grey(image, width: 16, height: 16) else { return nil }
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if small[y * 9 + x] > small[y * 9 + x + 1] {
                    hash |= (UInt64(1) << UInt64(bit))
                }
                bit += 1
            }
        }
        let height = max(asset.pixelHeight, 1)
        let aspect = Int((Double(asset.pixelWidth) / Double(height) * 20).rounded())
        return Print(hash: hash, tiny: tiny, aspect: aspect)
    }

    private static func grey(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count)
    }
}
