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

    func createPost(text: String, accessToken: String) async throws -> CreatedPost {
        let url = baseURL.appending(path: "/2/tweets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreatePostBody(text: text))

        let envelope: CreatePostEnvelope = try await send(request)
        return envelope.data
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw XAPIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data)
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

private struct UserEnvelope: Decodable {
    var data: AuthenticatedUser
}

private struct CreatePostBody: Encodable {
    var text: String
}

private struct CreatePostEnvelope: Decodable {
    var data: CreatedPost
}

enum XAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid X API URL"
        case .invalidResponse:
            "Invalid X API response"
        case let .httpStatus(status, body):
            "X API request failed with \(status): \(body)"
        }
    }
}
