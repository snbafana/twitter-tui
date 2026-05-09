import AuthenticationServices
import AppKit
import CryptoKit
import Foundation

struct OAuthCoordinator {
    private let authorizeURL = URL(string: "https://x.com/i/oauth2/authorize")!
    private let tokenURL = URL(string: "https://api.x.com/2/oauth2/token")!
    private let scopes = "tweet.read tweet.write users.read offline.access"

    func login(settings: AppSettings, clientSecret: String?) async throws -> OAuthTokenBundle {
        let strategy = callbackStrategy(for: settings.callbackURL)
        guard strategy == .localhost else {
            throw AuthError.unsupportedCallback(strategy.explanation)
        }

        let state = makeState()
        let challenge = makeChallenge()
        let url = try authorizationURL(settings: settings, state: state, challenge: challenge)

        async let callback = LocalhostCallbackServer().waitForCallback(redirectURI: settings.callbackURL)
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }

        let payload = try await callback
        guard payload.state == state else {
            throw AuthError.stateMismatch
        }
        guard let code = payload.code, !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchangeCode(
            code,
            verifier: challenge.verifier,
            settings: settings,
            clientSecret: clientSecret
        )
    }

    func refresh(settings: AppSettings, clientSecret: String?, refreshToken: String) async throws -> OAuthTokenBundle {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let clientSecret, !clientSecret.isEmpty {
            let credentials = Data("\(settings.clientID):\(clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = FormURLEncoder.encode([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": settings.clientID
        ])

        return try await decodeTokenResponse(request)
    }

    func authorizationURL(settings: AppSettings, state: String, challenge: PKCEChallenge) throws -> URL {
        guard !settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthError.missingClientID
        }
        guard var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidAuthorizationURL
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: settings.clientID),
            URLQueryItem(name: "redirect_uri", value: settings.callbackURL),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components.url else {
            throw AuthError.invalidAuthorizationURL
        }
        return url
    }

    func makeChallenge() -> PKCEChallenge {
        let verifier = randomToken(length: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCEChallenge(verifier: verifier, challenge: challenge)
    }

    func makeState() -> String {
        randomToken(length: 32)
    }

    func callbackStrategy(for callbackURL: String) -> CallbackStrategy {
        guard let url = URL(string: callbackURL), let scheme = url.scheme else {
            return .invalid
        }
        if scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" {
            return .localhost
        }
        if scheme == "https" {
            return .webAssociatedDomain
        }
        return .customScheme(scheme)
    }

    private func randomToken(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        settings: AppSettings,
        clientSecret: String?
    ) async throws -> OAuthTokenBundle {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let clientSecret, !clientSecret.isEmpty {
            let credentials = Data("\(settings.clientID):\(clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = FormURLEncoder.encode([
            "code": code,
            "grant_type": "authorization_code",
            "client_id": settings.clientID,
            "redirect_uri": settings.callbackURL,
            "code_verifier": verifier
        ])

        return try await decodeTokenResponse(request)
    }

    private func decodeTokenResponse(_ request: URLRequest) async throws -> OAuthTokenBundle {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try TokenResponseDecoder.decode(data: data, response: response)
    }

}

struct TokenResponseDecoder {
    static func decode(data: Data, response: URLResponse, now: Date = Date()) throws -> OAuthTokenBundle {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidTokenResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.tokenExchangeFailed(http.statusCode, XAPIErrorBody.message(from: data))
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokenBundle(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }
}

struct FormURLEncoder {
    static func encode(_ values: [String: String]) -> Data {
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.formURLEncoded)=\(value.formURLEncoded)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}

struct PKCEChallenge: Equatable {
    var verifier: String
    var challenge: String
}

struct OAuthTokenBundle: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

enum CallbackStrategy: Equatable {
    case localhost
    case customScheme(String)
    case webAssociatedDomain
    case invalid

    var explanation: String {
        switch self {
        case .localhost:
            "Use a temporary localhost callback listener, matching the current Rust flow."
        case let .customScheme(scheme):
            "Use ASWebAuthenticationSession with callback scheme \(scheme). This requires registering the URL scheme in the macOS app bundle."
        case .webAssociatedDomain:
            "Use ASWebAuthenticationSession with a web callback. This requires associated-domain setup."
        case .invalid:
            "Callback URL is invalid."
        }
    }
}

enum AuthError: Error, LocalizedError {
    case missingClientID
    case invalidAuthorizationURL
    case invalidCallbackURL
    case unsupportedCallback(String)
    case stateMismatch
    case missingAuthorizationCode
    case invalidTokenResponse
    case tokenExchangeFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Add an X OAuth Client ID in Settings first."
        case .invalidAuthorizationURL:
            "Could not build the X authorization URL."
        case .invalidCallbackURL:
            "Callback URL must be http://127.0.0.1:<port>/callback or http://localhost:<port>/callback."
        case let .unsupportedCallback(explanation):
            "This native build currently supports localhost callbacks first. \(explanation)"
        case .stateMismatch:
            "OAuth callback state did not match."
        case .missingAuthorizationCode:
            "OAuth callback did not include an authorization code."
        case .invalidTokenResponse:
            "Invalid token response from X."
        case let .tokenExchangeFailed(status, body):
            "Token exchange failed with \(status): \(body)"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .formURLEncodedAllowed) ?? self
    }
}

private extension CharacterSet {
    static let formURLEncodedAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
