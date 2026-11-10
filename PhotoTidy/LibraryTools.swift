import Foundation
import Photos

/// Simple library lists that need no image analysis.
/// These run off the main thread (they are plain async functions).
enum LibraryLister {

    /// Every screenshot, oldest first.
    static func screenshots() async -> [LooseItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0",
                                        Int(PHAssetMediaSubtype.photoScreenshot.rawValue))
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var items: [LooseItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(LooseItem(asset: asset,
                                   bytes: ImageLoader.fileSize(of: asset),
                                   metric: 0))
        }
        return items
    }

    /// Every video, biggest first (longest first if sizes aren't available).
    static func videos() async -> [LooseItem] {
        let result = PHAsset.fetchAssets(with: .video, options: nil)

        var items: [LooseItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(LooseItem(asset: asset,
                                   bytes: ImageLoader.fileSize(of: asset),
                                   metric: asset.duration))
        }
        items.sort { a, b in
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.metric > b.metric
        }
        return items
    }
}

/// Changes to the photo library. Kept outside the main-actor model on purpose:
/// Photos runs these change blocks on its own background queue.
enum LibraryChanges {
    static let reviewAlbumTitle = "Photo Tidy – To Review"

    /// Moves items to Recently Deleted. iOS shows its own confirmation.
    static func delete(ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Adds items to the "To Review" album (creating it the first time). Nothing is deleted.
    static func addToReviewAlbum(ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)

        let albumOptions = PHFetchOptions()
        albumOptions.predicate = NSPredicate(format: "title = %@", reviewAlbumTitle)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album,
                                                               subtype: .albumRegular,
                                                               options: albumOptions).firstObject
        let title = reviewAlbumTitle
        try await PHPhotoLibrary.shared().performChanges {
            if let existing {
                let request = PHAssetCollectionChangeRequest(for: existing)
                request?.addAssets(assets)
            } else {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                request.addAssets(assets)
            }
        }
    }
}
