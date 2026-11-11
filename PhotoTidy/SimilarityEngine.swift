import Foundation
import Photos
import Vision
import UIKit

struct ScanOptions: Sendable {
    var startDate: Date?
    var includeScreenshots: Bool
    /// 0 = loose (groups more), 1 = strict (only near-identical shots).
    var strictness: Double
    /// Max seconds between neighbouring shots in the same group.
    var maxGap: TimeInterval
}

/// Finds groups of look-alike photos and ranks each group best-first.
/// All work happens on the device.
struct SimilarityEngine: Sendable {
    let cache: AnalysisCache

    private typealias Member = (asset: PHAsset, analysis: PhotoAnalysis)

    /// Scans newest photos first and hands groups back as they are found.
    /// - Returns: how many photos were in the chosen time range.
    func scan(options: ScanOptions,
              onProgress: @escaping @Sendable (_ done: Int, _ total: Int) async -> Void,
              onGroups: @escaping @Sendable (_ groups: [PhotoGroup]) async -> Void) async throws -> Int {
        cache.loadIfNeeded()
        defer { cache.save() }

        let assets = fetchAssets(options)

        // Only photos with a neighbour inside the time window can be in a group,
        // so the (expensive) image analysis is skipped for everything else.
        let runs: [[PHAsset]] = Array(timeRuns(assets, maxGap: options.maxGap).reversed())
        let total: Int = runs.reduce(0) { $0 + $1.count }
        await onProgress(0, total)

        var done = 0
        var index = 0
        while index < runs.count {
            try Task.checkCancellation()

            // Work through a batch of runs at a time so memory stays low on big libraries.
            var batch: [[PHAsset]] = []
            var batchCount = 0
            while index < runs.count && (batch.isEmpty || batchCount < 48) {
                batch.append(runs[index])
                batchCount += runs[index].count
                index += 1
            }

            let flat: [PHAsset] = batch.flatMap { $0 }
            let base = done
            let analyses = try await analyze(flat) { finished in
                await onProgress(base + finished, total)
            }
            done += flat.count

            var found: [PhotoGroup] = []
            for run in batch {
                for members in makeClusters(run, analyses: analyses, options: options) {
                    found.append(rank(members))
                }
            }
            if !found.isEmpty {
                await onGroups(found)
            }
        }

        await onProgress(total, total)
        return assets.count
    }

    // MARK: - Blurry photos

    /// Photos whose crispest edges are weaker than this are offered as "blurry" candidates.
    /// The app then narrows the list with the sensitivity slider.
    static let blurCeiling: Double = 80

    /// Measures every photo in the range (newest first) and hands back the soft ones.
    /// - Returns: how many photos were checked.
    func scanBlurry(options: ScanOptions,
                    onProgress: @escaping @Sendable (_ done: Int, _ total: Int) async -> Void,
                    onFound: @escaping @Sendable (_ items: [LooseItem]) async -> Void) async throws -> Int {
        cache.loadIfNeeded()
        defer { cache.save() }

        var photoOptions = options
        photoOptions.includeScreenshots = false
        let assets: [PHAsset] = Array(fetchAssets(photoOptions).reversed())
        let total = assets.count
        await onProgress(0, total)

        var index = 0
        while index < total {
            try Task.checkCancellation()
            let end = min(index + 48, total)
            let batch: [PHAsset] = Array(assets[index..<end])
            let base = index
            let analyses = try await analyze(batch) { finished in
                await onProgress(base + finished, total)
            }

            var found: [LooseItem] = []
            for asset in batch {
                guard let analysis = analyses[asset.localIdentifier] else { continue }
                if asset.isFavorite { continue }   // never suggest a favourite
                if analysis.edgePeak < Self.blurCeiling {
                    found.append(LooseItem(asset: asset,
                                           bytes: ImageLoader.fileSize(of: asset),
                                           metric: analysis.edgePeak,
                                           hasPeople: analysis.hasPeople))
                }
            }
            if !found.isEmpty {
                await onFound(found)
            }
            index = end
        }

        await onProgress(total, total)
        return total
    }

    // MARK: - Fetching

    private func fetchAssets(_ options: ScanOptions) -> [PHAsset] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if let start = options.startDate {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        }
        let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.creationDate == nil { return }
            if !options.includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
            assets.append(asset)
        }
        return assets
    }

    /// Splits the timeline into runs of photos taken close together (2+ photos each).
    private func timeRuns(_ assets: [PHAsset], maxGap: TimeInterval) -> [[PHAsset]] {
        var runs: [[PHAsset]] = []
        var current: [PHAsset] = []
        for asset in assets {
            if let last = current.last,
               let lastDate = last.creationDate,
               let date = asset.creationDate,
               date.timeIntervalSince(lastDate) <= maxGap {
                current.append(asset)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [asset]
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    // MARK: - Analysis

    private func analyze(_ assets: [PHAsset],
                         progress: @escaping @Sendable (Int) async -> Void) async throws -> [String: PhotoAnalysis] {
        var results: [String: PhotoAnalysis] = [:]
        let cache = self.cache
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let maxConcurrent = max(2, min(6, cores - 2))

        try await withThrowingTaskGroup(of: (String, PhotoAnalysis?).self) { group in
            var next = 0
            while next < min(maxConcurrent, assets.count) {
                let asset = assets[next]
                group.addTask {
                    let analysis = await Self.analyzeOne(asset, cache: cache)
                    return (asset.localIdentifier, analysis)
                }
                next += 1
            }

            var finished = 0
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let analysis = result.1 {
                    results[result.0] = analysis
                }
                finished += 1
                await progress(finished)

                if next < assets.count {
                    let asset = assets[next]
                    group.addTask {
                        let analysis = await Self.analyzeOne(asset, cache: cache)
                        return (asset.localIdentifier, analysis)
                    }
                    next += 1
                }
            }
        }
        return results
    }

    private static func analyzeOne(_ asset: PHAsset, cache: AnalysisCache) async -> PhotoAnalysis? {
        if let saved = cache.lookup(asset) {
            return saved
        }

        guard let uiImage = await ImageLoader.image(for: asset, side: 768, contentMode: .aspectFit),
              let cgImage = uiImage.cgImage else { return nil }
        let orientation = OrientationMapper.cgOrientation(uiImage.imageOrientation)

        // Feature print (what the photo "looks like") + face capture quality.
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.imageCropAndScaleOption = .scaleFill
        let faceRequest = VNDetectFaceCaptureQualityRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([featureRequest, faceRequest, humanRequest])
        } catch {
            return nil
        }
        guard let observation = featureRequest.results?.first,
              let vector = unitVector(from: observation) else { return nil }

        // Ignore tiny background faces; weight the worst face (someone blinking) heavily.
        var faceScores: [Double] = []
        for face in faceRequest.results ?? [] {
            let area = face.boundingBox.width * face.boundingBox.height
            if area > 0.004, let quality = face.faceCaptureQuality {
                faceScores.append(Double(quality))
            }
        }
        var faceQuality: Double?
        if let worst = faceScores.min() {
            let average = faceScores.reduce(0, +) / Double(faceScores.count)
            faceQuality = 0.5 * average + 0.5 * worst
        }

        // Anyone in the shot at all? (Used to keep blurry photos of people.)
        let faceCount = faceRequest.results?.count ?? 0
        let confidentHumans = (humanRequest.results ?? []).filter { $0.confidence > 0.5 }
        let hasPeople = faceCount > 0 || !confidentHumans.isEmpty

        let metrics = ImageMetrics.measure(cgImage)

        // Apple's built-in "how good does this photo look" score (iOS 18+).
        var aesthetic: Double?
        if #available(iOS 18.0, *) {
            let request = CalculateImageAestheticsScoresRequest()
            if let scores = try? await request.perform(on: cgImage, orientation: orientation) {
                aesthetic = Double((scores.overallScore + 1) / 2)
            }
        }

        let analysis = PhotoAnalysis(vector: vector,
                                     sharpness: metrics.sharpness,
                                     exposure: metrics.exposure,
                                     edgePeak: metrics.edgePeak,
                                     hasPeople: hasPeople,
                                     faceQuality: faceQuality,
                                     aesthetic: aesthetic)
        cache.store(analysis, for: asset)
        return analysis
    }

    /// Copies the feature print into a plain unit-length vector, so two photos can be
    /// compared with simple math (and saved between scans).
    private static func unitVector(from observation: VNFeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        let data = observation.data

        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return nil }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    values[i] = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
                }
            }
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return nil }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    let value = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Double>.size, as: Double.self)
                    values[i] = Float(value)
                }
            }
        default:
            return nil
        }

        var sum: Float = 0
        for value in values { sum += value * value }
        let length = sum.squareRoot()
        guard length > 0 else { return nil }
        for i in 0..<count { values[i] /= length }
        return values
    }

    /// Distance between two unit vectors: 0 = identical, ~1.4 = unrelated.
    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return Float.greatestFiniteMagnitude }
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count {
                    let d = pa[i] - pb[i]
                    sum += d * d
                }
            }
        }
        return sum.squareRoot()
    }

    // MARK: - Grouping

    private func makeClusters(_ run: [PHAsset],
                              analyses: [String: PhotoAnalysis],
                              options: ScanOptions) -> [[Member]] {
        // Loose 0.75 · default ≈0.52 · strict 0.30
        let threshold = Float(0.75 - 0.45 * options.strictness)
        var clusters: [[Member]] = []

        for asset in run {
            guard let analysis = analyses[asset.localIdentifier],
                  let date = asset.creationDate else { continue }

            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for ci in clusters.indices {
                guard let lastDate = clusters[ci].last?.asset.creationDate,
                      date.timeIntervalSince(lastDate) <= options.maxGap else { continue }
                for member in clusters[ci].suffix(6) {
                    let d = Self.distance(member.analysis.vector, analysis.vector)
                    if d < bestDistance {
                        bestDistance = d
                        bestIndex = ci
                    }
                }
            }

            if let bestIndex, bestDistance <= threshold {
                clusters[bestIndex].append((asset: asset, analysis: analysis))
            } else {
                clusters.append([(asset: asset, analysis: analysis)])
            }
        }
        return clusters.filter { $0.count >= 2 }
    }

    // MARK: - Ranking

    private struct Scored {
        let asset: PHAsset
        let analysis: PhotoAnalysis
        let score: Double
        let sharpRel: Double
    }

    private func rank(_ members: [Member]) -> PhotoGroup {
        let maxSharp: Double = members.map { $0.analysis.sharpness.squareRoot() }.max() ?? 1
        let maxPixels: Double = members.map { Double($0.asset.pixelWidth * $0.asset.pixelHeight) }.max() ?? 1
        let anyFaces = members.contains { $0.analysis.faceQuality != nil }
        let hasAesthetic = members.contains { $0.analysis.aesthetic != nil }

        var scored: [Scored] = []
        for member in members {
            let asset = member.asset
            let a = member.analysis
            let sharpRel: Double = maxSharp > 0 ? a.sharpness.squareRoot() / maxSharp : 0
            let pixels = Double(asset.pixelWidth * asset.pixelHeight)
            let pixelRel: Double = maxPixels > 0 ? pixels / maxPixels : 0

            var weightSum = 0.45
            var total = 0.30 * sharpRel + 0.10 * a.exposure + 0.05 * pixelRel
            if hasAesthetic {
                weightSum += 0.30
                total += 0.30 * (a.aesthetic ?? 0.5)
            }
            if anyFaces {
                weightSum += 0.25
                total += 0.25 * (a.faceQuality ?? 0)
            }

            var score = total / weightSum
            if asset.isFavorite { score += 1 }          // you already marked it as a keeper
            if asset.hasAdjustments { score += 0.05 }   // you took time to edit it
            scored.append(Scored(asset: asset, analysis: a, score: score, sharpRel: sharpRel))
        }
        scored.sort { $0.score > $1.score }

        let bestFace: Double? = scored.compactMap { $0.analysis.faceQuality }.max()
        let bestAesthetic: Double? = scored.compactMap { $0.analysis.aesthetic }.max()

        var items: [PhotoItem] = []
        for (index, entry) in scored.enumerated() {
            var notes: [String] = []
            if entry.asset.isFavorite { notes.append("Favorite") }
            if entry.asset.hasAdjustments { notes.append("Edited") }
            if index == 0 {
                if entry.sharpRel >= 0.999 { notes.append("Sharpest") }
                if let fq = entry.analysis.faceQuality, let bestFace, fq >= bestFace { notes.append("Best faces") }
                if let ae = entry.analysis.aesthetic, let bestAesthetic, ae >= bestAesthetic { notes.append("Best looking") }
                if notes.isEmpty { notes.append("Best overall") }
            } else {
                if entry.sharpRel < 0.6 { notes.append("Blurry") }
                if entry.analysis.exposure < 0.4 { notes.append("Poor lighting") }
                if let fq = entry.analysis.faceQuality, let bestFace, fq < bestFace - 0.15 { notes.append("Weaker faces") }
            }
            items.append(PhotoItem(asset: entry.asset,
                                   score: entry.score,
                                   notes: notes,
                                   bytes: ImageLoader.fileSize(of: entry.asset)))
        }

        let keep: Set<String> = Set(items.prefix(1).map { $0.id })
        return PhotoGroup(items: items, keep: keep)
    }
}
