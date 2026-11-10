import Photos
import UIKit
import ImageIO

/// Loads images from the photo library (downloading from iCloud when needed).
enum ImageLoader {
    static let manager = PHCachingImageManager()

    static func image(for asset: PHAsset,
                      side: CGFloat,
                      contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // handler is called exactly once
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let size = CGSize(width: side, height: side)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let once = ResumeOnce()
            manager.requestImage(for: asset,
                                 targetSize: size,
                                 contentMode: contentMode,
                                 options: options) { image, _ in
                if once.claim() {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Space the photo takes up (all of its files: Live Photo video, edits, etc.).
    /// Returns 0 if the system doesn't report it.
    static func fileSize(of asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        let selector = NSSelectorFromString("fileSize")
        for resource in PHAssetResource.assetResources(for: asset) {
            guard resource.responds(to: selector) else { continue }
            if let number = resource.value(forKey: "fileSize") as? NSNumber {
                total += number.int64Value
            }
        }
        return total
    }
}

/// Guards a continuation so it is resumed only once.
final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum OrientationMapper {
    static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
