import CoreGraphics

/// Simple pixel-level quality measures.
enum ImageMetrics {
    struct Result {
        /// Variance of the Laplacian; higher = more fine detail. Good for comparing look-alikes.
        var sharpness: Double
        /// 0…1; 1 = well exposed, low = too dark, too bright or clipped.
        var exposure: Double
        /// Strength of the crispest edges in the photo (0…1020).
        /// A photo with plain areas but one crisp edge still scores high,
        /// so a low value means "nothing in this photo is sharp".
        var edgePeak: Double
    }

    static func measure(_ image: CGImage) -> Result {
        let maxSide = 768.0
        let scale = min(1.0, maxSide / Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width) * scale))
        let h = max(3, Int(Double(image.height) * scale))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: w,
                                          height: h,
                                          bitsPerComponent: 8,
                                          bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return Result(sharpness: 0, exposure: 0.5, edgePeak: 1020) }

        var histogram = [Int](repeating: 0, count: 1021)

        return pixels.withUnsafeBufferPointer { p -> Result in
            // Laplacian over the whole image.
            var sum = 0.0
            var sumSquares = 0.0
            var count = 0
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let i = row + x
                    let lap = Int(p[i - 1]) + Int(p[i + 1]) + Int(p[i - w]) + Int(p[i + w]) - 4 * Int(p[i])
                    let v = Double(lap)
                    sum += v
                    sumSquares += v * v
                    histogram[min(1020, abs(lap))] += 1
                    count += 1
                }
            }
            let n = Double(max(count, 1))
            let mean = sum / n
            let variance = max(0, sumSquares / n - mean * mean)

            // Edge peak: the value that only the strongest 0.5% of pixels exceed.
            let target = max(1, count / 200)
            var seen = 0
            var edgePeak = 0
            var bin = 1020
            while bin >= 0 {
                seen += histogram[bin]
                if seen >= target {
                    edgePeak = bin
                    break
                }
                bin -= 1
            }

            // Exposure: mid-tone average and few clipped pixels.
            var lumSum = 0.0
            var clipped = 0
            for value in p {
                lumSum += Double(value)
                if value < 6 || value > 249 { clipped += 1 }
            }
            let total = Double(p.count)
            let meanLum = lumSum / total / 255
            let clippedFraction = Double(clipped) / total
            let exposure = max(0, min(1, 1 - abs(meanLum - 0.5) * 1.2 - clippedFraction * 1.5))

            return Result(sharpness: variance, exposure: exposure, edgePeak: Double(edgePeak))
        }
    }
}
