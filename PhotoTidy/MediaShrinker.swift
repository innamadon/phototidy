import Foundation
import Photos
import AVFoundation

/// What happened during a shrink.
struct ShrinkResult {
    var shrunk = 0
    /// Already compact, or a kind of video that can't be safely re-saved (slow motion).
    var skipped = 0
    var failed = 0
    var bytesSaved: Int64 = 0
    /// The user said "Don't Allow" to the delete prompt; nothing in that batch changed.
    var cancelled = false
    /// Originals that were replaced (and are now in Recently Deleted).
    var replacedIDs: [String] = []
}

/// Replaces Live Photos with plain stills, and big videos with smaller copies.
///
/// Each batch is one change to the library: the smaller copies are created
/// and the originals are deleted together, so iOS asks once per batch, and
/// if you tap "Don't Allow" nothing in that batch changes at all.
/// The new copy keeps the date, place, favourite and hidden state, and is
/// added back to the same albums.
enum MediaShrinker {

    private struct Replacement {
        let original: PHAsset
        let fileURL: URL
        let resourceType: PHAssetResourceType
        let filename: String
        let albums: [PHAssetCollection]
        let saved: Int64
    }

    // MARK: - Sizes

    static func resourceSize(_ resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    /// Size of a Live Photo's motion part: what shrinking it saves.
    static func motionBytes(of asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) {
            switch resource.type {
            case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
                total += resourceSize(resource)
            default:
                break
            }
        }
        return total
    }

    // MARK: - Live Photos

    static func shrinkLivePhotos(_ assets: [PHAsset],
                                 progress: @escaping @Sendable (Int, Int) async -> Void) async -> ShrinkResult {
        var result = ShrinkResult()
        var done = 0
        await progress(0, assets.count)

        var index = 0
        while index < assets.count && !result.cancelled {
            let end = min(index + 30, assets.count)
            var batch: [Replacement] = []
            for asset in assets[index..<end] {
                if Task.isCancelled { break }
                if let replacement = await prepareStill(asset) {
                    batch.append(replacement)
                } else {
                    result.failed += 1
                }
                done += 1
                await progress(done, assets.count)
            }
            if Task.isCancelled {
                // Stopped: leave the library exactly as it is.
                for item in batch { cleanUp(item.fileURL) }
                result.cancelled = true
                break
            }
            await commit(batch, into: &result)
            index = end
        }
        return result
    }

    private static func prepareStill(_ asset: PHAsset) async -> Replacement? {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo }
        // If the photo was edited, keep the edited look.
        guard let source = resources.first(where: { $0.type == .fullSizePhoto }) ?? original else { return nil }

        let baseName = ((original ?? source).originalFilename as NSString).deletingPathExtension
        let ext = (source.originalFilename as NSString).pathExtension
        let filename = baseName + "." + (ext.isEmpty ? "jpg" : ext)
        let url = temporaryURL(named: filename)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let ok = await write(source, to: url, options: options)
        guard ok else { return nil }

        return Replacement(original: asset,
                           fileURL: url,
                           resourceType: .photo,
                           filename: filename,
                           albums: albums(containing: asset),
                           saved: motionBytes(of: asset))
    }

    // MARK: - Videos

    static func shrinkVideos(_ items: [LooseItem],
                             progress: @escaping @Sendable (Int, Int) async -> Void,
                             partial: @escaping @Sendable (Double) async -> Void) async -> ShrinkResult {
        var result = ShrinkResult()
        var done = 0
        await progress(0, items.count)

        var index = 0
        while index < items.count && !result.cancelled {
            let end = min(index + 5, items.count)
            var batch: [Replacement] = []
            for item in items[index..<end] {
                if Task.isCancelled { break }
                await partial(0)
                switch await prepareSmallerVideo(item, partial: partial) {
                case .ready(let replacement):
                    batch.append(replacement)
                case .skipped:
                    result.skipped += 1
                case .failed:
                    result.failed += 1
                case .stopped:
                    break
                }
                done += 1
                await partial(0)
                await progress(done, items.count)
            }
            if Task.isCancelled {
                // Stopped: leave the library exactly as it is.
                for item in batch { cleanUp(item.fileURL) }
                result.cancelled = true
                break
            }
            await commit(batch, into: &result)
            index = end
        }
        return result
    }

    private enum VideoPrep {
        case ready(Replacement)
        case skipped
        case failed
        /// The user tapped Stop during the export.
        case stopped
    }

    private static func prepareSmallerVideo(_ item: LooseItem,
                                            partial: @escaping @Sendable (Double) async -> Void) async -> VideoPrep {
        let asset = item.asset
        // Slow-motion videos would lose their slow-motion editing; leave them alone.
        if asset.mediaSubtypes.contains(.videoHighFrameRate) { return .skipped }
        // Without the original size we can't tell whether the copy is smaller.
        guard item.bytes > 0 else { return .skipped }

        let longSide = max(asset.pixelWidth, asset.pixelHeight)
        let preset = longSide > 1920 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        guard let session = await exportSession(for: asset, preset: preset, options: options) else { return .failed }

        let resources = PHAssetResource.assetResources(for: asset)
        let videoResource = resources.first { $0.type == .video } ?? resources.first
        let baseName = ((videoResource?.originalFilename ?? "Video") as NSString).deletingPathExtension
        let filename = baseName + ".mov"
        let url = temporaryURL(named: filename)

        session.outputURL = url
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        // Report progress a few times a second while the export runs.
        let ticker = Task {
            while !Task.isCancelled {
                await partial(Double(session.progress))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        await run(session)
        ticker.cancel()

        guard session.status == .completed else {
            cleanUp(url)
            return (session.status == .cancelled || Task.isCancelled) ? .stopped : .failed
        }

        let newSize = fileSize(at: url)
        // Only worth it if the copy is at least 15% smaller.
        guard newSize > 0, Double(newSize) < Double(item.bytes) * 0.85 else {
            cleanUp(url)
            return .skipped
        }

        let replacement = Replacement(original: asset,
                                      fileURL: url,
                                      resourceType: .video,
                                      filename: filename,
                                      albums: albums(containing: asset),
                                      saved: item.bytes - newSize)
        return .ready(replacement)
    }

    private static func exportSession(for asset: PHAsset,
                                      preset: String,
                                      options: PHVideoRequestOptions) async -> AVAssetExportSession? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVAssetExportSession?, Never>) in
            let once = ResumeOnce()
            PHImageManager.default().requestExportSession(forVideo: asset,
                                                          options: options,
                                                          exportPreset: preset) { session, _ in
                if once.claim() {
                    continuation.resume(returning: session)
                }
            }
        }
    }

    /// Runs the export. If the user taps Stop, the export is cancelled straight away.
    private static func run(_ session: AVAssetExportSession) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    // MARK: - Committing a batch

    private static func commit(_ batch: [Replacement], into result: inout ShrinkResult) async {
        guard !batch.isEmpty else { return }
        let originals = PHAsset.fetchAssets(withLocalIdentifiers: batch.map { $0.original.localIdentifier },
                                            options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for item in batch {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = item.filename
                    options.shouldMoveFile = true
                    request.addResource(with: item.resourceType, fileURL: item.fileURL, options: options)
                    request.creationDate = item.original.creationDate
                    request.location = item.original.location
                    request.isFavorite = item.original.isFavorite
                    request.isHidden = item.original.isHidden
                    if let placeholder = request.placeholderForCreatedAsset {
                        for album in item.albums {
                            PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                        }
                    }
                }
                PHAssetChangeRequest.deleteAssets(originals)
            }
            result.shrunk += batch.count
            result.bytesSaved += batch.reduce(Int64(0)) { $0 + $1.saved }
            result.replacedIDs.append(contentsOf: batch.map { $0.original.localIdentifier })
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue {
                result.cancelled = true
            } else {
                result.failed += batch.count
            }
        }
        for item in batch {
            cleanUp(item.fileURL)
        }
    }

    // MARK: - Helpers

    private static func albums(containing asset: PHAsset) -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        let found = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        found.enumerateObjects { album, _, _ in
            if album.canPerform(.addContent) {
                albums.append(album)
            }
        }
        return albums
    }

    private static func write(_ resource: PHAssetResource,
                              to url: URL,
                              options: PHAssetResourceRequestOptions) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// A fresh folder per file, so the file keeps its original name.
    private static func temporaryURL(named name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrink-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
