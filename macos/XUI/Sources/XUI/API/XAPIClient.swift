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
        return try load(data: data, filename: url.lastPathComponent, mediaType: mediaType(for: url))
    }

    static func load(from image: NSImage, filename: String) throws -> AttachedImage {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw XAPIError.unsupportedImage("Dropped image could not be converted to PNG.")
        }
        return try load(data: data, filename: filename, mediaType: "image/png")
    }

    private static func load(data: Data, filename: String, mediaType: String) throws -> AttachedImage {
        guard data.count <= maxImageBytes else {
            throw XAPIError.unsupportedImage("Images must be 5 MB or smaller for X upload.")
        }
        return AttachedImage(filename: filename, data: data, mediaType: mediaType)
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
