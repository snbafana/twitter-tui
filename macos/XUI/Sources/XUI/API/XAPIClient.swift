import AppKit
import Foundation

struct XAPIClient {
    var baseURL: URL
    var session: URLSession = .shared

    func authenticatedUser(accessToken: String) async throws -> AuthenticatedUser {
        var components = URLComponents(url: baseURL.appending(path: "/2/users/me"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user.fields", value: "created_at,verified")
        ]
        guard let url = components?.url else {
            throw XAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let envelope: UserEnvelope = try await send(request)
        return envelope.data
    }

    func uploadImage(_ image: AttachedImage, accessToken: String) async throws -> UploadedMedia {
        let url = baseURL.appending(path: "/2/media/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UploadMediaBody(image: image))

        let envelope: UploadMediaEnvelope = try await send(request)
        return envelope.data
    }

    func createPost(text: String, mediaIDs: [String] = [], accessToken: String) async throws -> CreatedPost {
        let url = baseURL.appending(path: "/2/tweets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreatePostBody(text: text, mediaIDs: mediaIDs))

        let envelope: CreatePostEnvelope = try await send(request)
        return envelope.data
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw XAPIError.httpStatus(http.statusCode, XAPIErrorBody.message(from: data))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

struct XAPIErrorBody {
    static func message(from data: Data) -> String {
        guard !data.isEmpty else {
            return "Empty response body"
        }
        if let payload = try? JSONDecoder().decode(XErrorEnvelope.self, from: data) {
            if let errors = payload.errors, !errors.isEmpty {
                return errors.map(\.message).joined(separator: "; ")
            }
            if let title = payload.title, let detail = payload.detail {
                return "\(title): \(detail)"
            }
            if let detail = payload.detail {
                return detail
            }
            if let title = payload.title {
                return title
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? "Unreadable response body"
        return String(raw.prefix(500))
    }
}

struct AuthenticatedUser: Decodable, Equatable {
    var id: String
    var name: String
    var username: String
}

struct CreatedPost: Decodable, Equatable {
    var id: String
    var text: String
}

struct UploadedMedia: Decodable, Equatable {
    var id: String
    var mediaKey: String?
    var expiresAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case mediaKey = "media_key"
        case expiresAfterSeconds = "expires_after_secs"
    }
}

struct AttachedImage: Identifiable, Equatable {
    static let maxImageBytes = 5 * 1024 * 1024
    private static let maxPixelDimension: CGFloat = 4096
    private static let jpegQualities: [CGFloat] = [0.92, 0.84, 0.76, 0.68, 0.60, 0.52]

    var id = UUID()
    var filename: String
    var data: Data
    var mediaType: String

    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(data.count))
    }

    static func load(from url: URL) throws -> AttachedImage {
        let data = try Data(contentsOf: url)
        let mediaType = try mediaType(for: url)
        if data.count <= maxImageBytes {
            return AttachedImage(filename: url.lastPathComponent, data: data, mediaType: mediaType)
        }
        guard let image = NSImage(data: data) else {
            throw XAPIError.unsupportedImage("Image could not be read for compression.")
        }
        return try compressedImage(from: image, filename: compressedFilename(from: url))
    }

    static func load(from image: NSImage, filename: String) throws -> AttachedImage {
        try compressedImage(from: image, filename: filename)
    }

    private static func compressedImage(from image: NSImage, filename: String) throws -> AttachedImage {
        guard let bitmap = bitmap(for: image) else {
            throw XAPIError.unsupportedImage("Image could not be converted for upload.")
        }
        for quality in jpegQualities {
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                continue
            }
            if data.count <= maxImageBytes {
                return AttachedImage(filename: filename, data: data, mediaType: "image/jpeg")
            }
        }
        throw XAPIError.unsupportedImage("Image could not be compressed below 5 MB for X upload.")
    }

    private static func bitmap(for image: NSImage) -> NSBitmapImageRep? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let scale = min(1, maxPixelDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        rendered.unlockFocus()

        guard let tiff = rendered.tiffRepresentation else {
            return nil
        }
        return NSBitmapImageRep(data: tiff)
    }

    private static func compressedFilename(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return "\(base)-xui.jpg"
    }

    private static func mediaType(for url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        default:
            throw XAPIError.unsupportedImage("Use JPG, PNG, WebP, BMP, or TIFF images.")
        }
    }
}

private struct UserEnvelope: Decodable {
    var data: AuthenticatedUser
}

private struct CreatePostBody: Encodable {
    var text: String
    var media: CreatePostMedia?

    init(text: String, mediaIDs: [String]) {
        self.text = text
        if mediaIDs.isEmpty {
            self.media = nil
        } else {
            self.media = CreatePostMedia(mediaIDs: mediaIDs)
        }
    }
}

private struct CreatePostMedia: Encodable {
    var mediaIDs: [String]

    enum CodingKeys: String, CodingKey {
        case mediaIDs = "media_ids"
    }
}

private struct CreatePostEnvelope: Decodable {
    var data: CreatedPost
}

private struct UploadMediaBody: Encodable {
    var media: String
    var mediaCategory = "tweet_image"
    var mediaType: String
    var shared = false

    init(image: AttachedImage) {
        self.media = image.data.base64EncodedString()
        self.mediaType = image.mediaType
    }

    enum CodingKeys: String, CodingKey {
        case media
        case mediaCategory = "media_category"
        case mediaType = "media_type"
        case shared
    }
}

private struct UploadMediaEnvelope: Decodable {
    var data: UploadedMedia
}

enum XAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case unsupportedImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid X API URL"
        case .invalidResponse:
            "Invalid X API response"
        case let .httpStatus(status, body):
            "X API request failed with \(status): \(body)"
        case let .unsupportedImage(message):
            message
        }
    }
}

private struct XErrorEnvelope: Decodable {
    var title: String?
    var detail: String?
    var errors: [XErrorItem]?
}

private struct XErrorItem: Decodable {
    var title: String?
    var detail: String?
    var rawMessage: String?
    var type: String?

    var message: String {
        if let title, let detail {
            return "\(title): \(detail)"
        }
        if let rawMessage {
            return rawMessage
        }
        if let detail {
            return detail
        }
        if let title {
            return title
        }
        return type ?? "Unknown X API error"
    }

    enum CodingKeys: String, CodingKey {
        case title
        case detail
        case rawMessage = "message"
        case type
    }
}
