import Foundation

@MainActor
final class ComposerModel: ObservableObject {
    let characterLimit = 280
    private let keychain = KeychainStore()
    private let oauth = OAuthCoordinator()

    @Published var text = ""
    @Published var status = ComposerStatus.idle("Not connected")
    @Published var account: AccountSummary?
    @Published var settings = AppSettings.load()
    @Published var clientSecret = ""
    @Published var isSending = false
    @Published var isLoggingIn = false

    init() {
        do {
            clientSecret = try keychain.read(.clientSecret) ?? ""
            if let accessToken = try keychain.read(.accessToken), !accessToken.isEmpty {
                status = .idle("Access token found")
                Task {
                    await loadAccount()
                }
            }
        } catch {
            status = .warning(error.localizedDescription)
        }
    }

    var rawCount: Int {
        text.count
    }

    var remaining: Int {
        characterLimit - rawCount
    }

    var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining >= 0
    }

    var counterLabel: String {
        if remaining >= 0 {
            "\(rawCount)/\(characterLimit)"
        } else {
            "\(abs(remaining)) over"
        }
    }

    func saveSettings() {
        settings.save()
        do {
            if clientSecret.isEmpty {
                try keychain.delete(.clientSecret)
            } else {
                try keychain.write(clientSecret, for: .clientSecret)
            }
            status = .idle("Saved local app credentials")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func prepareLogin() {
        do {
            let state = oauth.makeState()
            let challenge = oauth.makeChallenge()
            _ = try oauth.authorizationURL(settings: settings, state: state, challenge: challenge)
            let strategy = oauth.callbackStrategy(for: settings.callbackURL)
            status = .idle(strategy.explanation)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func login() async {
        guard !isLoggingIn else {
            return
        }

        saveSettings()
        isLoggingIn = true
        status = .working("Opening X authorization...")
        defer {
            isLoggingIn = false
        }

        do {
            let bundle = try await oauth.login(
                settings: settings,
                clientSecret: clientSecret.isEmpty ? nil : clientSecret
            )
            try persistTokens(bundle)

            await loadAccount(accessToken: bundle.accessToken)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func clear() {
        text = ""
        status = .idle("Composer cleared")
    }

    func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            status = .warning("Nothing to send")
            return
        }
        guard remaining >= 0 else {
            status = .failure("Post is over the character limit")
            return
        }

        isSending = true
        status = .working("Sending...")
        defer { isSending = false }

        do {
            guard let accessToken = try await currentAccessToken(), !accessToken.isEmpty else {
                status = .warning("Log in before sending")
                return
            }
            guard let baseURL = URL(string: settings.baseURL) else {
                status = .failure("Invalid API base URL")
                return
            }

            let post = try await XAPIClient(baseURL: baseURL).createPost(text: body, accessToken: accessToken)
            text = ""
            status = .success("Posted \(post.id)")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func loadAccount(accessToken existingToken: String? = nil) async {
        do {
            let accessToken: String
            if let existingToken {
                accessToken = existingToken
            } else if let token = try await currentAccessToken() {
                accessToken = token
            } else {
                status = .warning("Log in to load account")
                return
            }
            guard let baseURL = URL(string: settings.baseURL) else {
                status = .failure("Invalid API base URL")
                return
            }
            let user = try await XAPIClient(baseURL: baseURL).authenticatedUser(accessToken: accessToken)
            account = AccountSummary(username: user.username, displayName: user.name)
            status = .success("Authenticated as @\(user.username)")
        } catch {
            status = .warning(error.localizedDescription)
        }
    }

    private func currentAccessToken() async throws -> String? {
        guard let accessToken = try keychain.read(.accessToken), !accessToken.isEmpty else {
            return nil
        }
        guard try tokenNeedsRefresh() else {
            return accessToken
        }
        guard let refreshToken = try keychain.read(.refreshToken), !refreshToken.isEmpty else {
            return accessToken
        }

        status = .working("Refreshing access token...")
        let bundle = try await oauth.refresh(
            settings: settings,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret,
            refreshToken: refreshToken
        )
        try persistTokens(bundle)
        return bundle.accessToken
    }

    private func tokenNeedsRefresh() throws -> Bool {
        guard let raw = try keychain.read(.tokenExpiresAt),
              let expiresAt = ISO8601DateFormatter().date(from: raw)
        else {
            return false
        }
        return TokenRefreshPolicy.needsRefresh(expiresAt: expiresAt)
    }

    private func persistTokens(_ bundle: OAuthTokenBundle) throws {
        try keychain.write(bundle.accessToken, for: .accessToken)
        if let refreshToken = bundle.refreshToken {
            try keychain.write(refreshToken, for: .refreshToken)
        }
        if let expiresAt = bundle.expiresAt {
            try keychain.write(ISO8601DateFormatter().string(from: expiresAt), for: .tokenExpiresAt)
        }
    }
}

struct AccountSummary: Equatable {
    var username: String
    var displayName: String
}

struct AppSettings: Equatable {
    private static let clientIDKey = "xui.clientID"
    private static let baseURLKey = "xui.baseURL"
    private static let callbackURLKey = "xui.callbackURL"

    var clientID: String
    var baseURL: String
    var callbackURL: String

    static func load(defaults: UserDefaults = .standard) -> AppSettings {
        AppSettings(
            clientID: defaults.string(forKey: clientIDKey) ?? "",
            baseURL: defaults.string(forKey: baseURLKey) ?? "https://api.x.com",
            callbackURL: defaults.string(forKey: callbackURLKey) ?? "http://127.0.0.1:8787/callback"
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(clientID, forKey: Self.clientIDKey)
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(callbackURL, forKey: Self.callbackURLKey)
    }
}

enum ComposerStatus: Equatable {
    case idle(String)
    case working(String)
    case warning(String)
    case failure(String)
    case success(String)

    var message: String {
        switch self {
        case let .idle(message),
             let .working(message),
             let .warning(message),
             let .failure(message),
             let .success(message):
            message
        }
    }
}

struct TokenRefreshPolicy {
    static let refreshWindow: TimeInterval = 60

    static func needsRefresh(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= now.addingTimeInterval(refreshWindow)
    }
}
