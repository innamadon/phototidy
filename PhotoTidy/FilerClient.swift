import Foundation
import Photos
import UIKit

/// Sends receipts to Manni's receipt filer (the Flask app on the PC, reached over Tailscale).
///
/// The filer's upload page takes a normal form upload: POST to "/" with the
/// file in a field called "photos". It accepts JPG, PNG, HEIC and PDF up to 25 MB,
/// then redirects back to the page with a message like "Uploaded 1 file(s)".
enum FilerClient {

    enum Outcome {
        case sent
        /// The filer refused the file (wrong type or too large).
        case rejected
    }

    struct FilerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Turns what the user typed into the filer's address, e.g.
    /// "mydesktop.tail1234.ts.net" → "https://mydesktop.tail1234.ts.net/".
    static func address(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard var components = URLComponents(string: value), components.host?.isEmpty == false else { return nil }
        components.path = "/"
        components.query = nil
        return components.url
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Opens the upload page to check the filer can be reached.
    static func check(_ base: URL) async throws {
        let (_, response) = try await session.data(from: base)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FilerError(message: "Your filer answered, but not with its upload page.")
        }
    }

    /// Uploads one photo of a receipt.
    static func upload(_ asset: PHAsset, to base: URL) async throws -> Outcome {
        guard let file = await fileData(for: asset) else {
            throw FilerError(message: "Couldn't read that photo.")
        }

        let boundary = "PhotoTidy-" + UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(file.name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(file.mime)\r\n\r\n".data(using: .utf8)!)
        body.append(file.data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw FilerError(message: "No answer from your filer.")
        }
        guard http.statusCode == 200 else {
            throw FilerError(message: "Your filer answered with error \(http.statusCode).")
        }

        let page = String(decoding: data, as: UTF8.self)
        if page.contains("Uploaded 1 file") { return .sent }
        if page.contains("skipped") || page.contains("too large") { return .rejected }
        return .sent
    }

    /// A plain explanation for the most common problems.
    static func explain(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet,
                 .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return "Couldn't reach your receipt filer. Check that Tailscale is switched on on this iPhone and the filer is running on your PC."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "Couldn't make a secure connection to your filer. Check the address in Settings; it should be the https://…ts.net one."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Photo data

    private struct UploadFile {
        let data: Data
        let name: String
        let mime: String
    }

    private static let maxBytes = 24 * 1024 * 1024

    private static func fileData(for asset: PHAsset) async -> UploadFile? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let loaded: (Data?, String?) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String?), Never>) in
            let once = ResumeOnce()
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                if once.claim() {
                    continuation.resume(returning: (data, uti))
                }
            }
        }
        guard let data = loaded.0 else { return nil }
        let base = baseName(for: asset)
        let uti = loaded.1 ?? ""

        // Send the original when the filer understands it and it's small enough.
        if data.count <= maxBytes {
            switch uti {
            case "public.heic", "public.heif":
                return UploadFile(data: data, name: base + ".heic", mime: "image/heic")
            case "public.jpeg":
                return UploadFile(data: data, name: base + ".jpg", mime: "image/jpeg")
            case "public.png":
                return UploadFile(data: data, name: base + ".png", mime: "image/png")
            default:
                break
            }
        }

        // Anything else (or too big): convert to JPEG.
        guard let image = UIImage(data: data) else { return nil }
        for quality in [0.9, 0.75, 0.6] {
            if let jpeg = image.jpegData(compressionQuality: CGFloat(quality)), jpeg.count <= maxBytes {
                return UploadFile(data: jpeg, name: base + ".jpg", mime: "image/jpeg")
            }
        }
        return nil
    }

    private static func baseName(for asset: PHAsset) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "receipt-" + formatter.string(from: asset.creationDate ?? Date())
    }
}
