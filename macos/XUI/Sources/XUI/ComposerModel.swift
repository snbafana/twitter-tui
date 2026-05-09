import AppKit
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
    @Published var attachedImages: [AttachedImage] = []
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
        !isSending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty) && remaining >= 0
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
            if let issue = settings.loginSetupIssue() {
                status = .failure(issue)
                return
            }
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
        if let issue = settings.loginSetupIssue() {
            status = .failure(issue)
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
        attachedImages = []
        status = .idle("Composer cleared")
    }

    func attachImage(from url: URL) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try appendImage(AttachedImage.load(from: url))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func attachDroppedImage(_ image: NSImage) {
        do {
            try appendImage(AttachedImage.load(from: image, filename: "dropped-image.png"))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func removeImage(_ image: AttachedImage) {
        attachedImages.removeAll { $0.id == image.id }
        status = .idle("Image removed")
    }

    private func appendImage(_ image: AttachedImage) throws {
        guard attachedImages.count < 4 else {
            throw XAPIError.unsupportedImage("X supports up to 4 images per post.")
        }
        attachedImages.append(image)
        status = .idle("Attached \(image.filename) · \(image.sizeLabel)")
    }

    func applyTextStyle(_ style: ComposerTextStyle) {
        text = TextStyler.apply(style, to: text)
        status = .idle("\(style.label) applied")
    }

    func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachedImages.isEmpty else {
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

            let client = XAPIClient(baseURL: baseURL)
            var mediaIDs: [String] = []
            if !attachedImages.isEmpty {
                status = .working("Uploading image...")
                for image in attachedImages {
                    let media = try await client.uploadImage(image, accessToken: accessToken)
                    mediaIDs.append(media.id)
                }
            }

            status = .working("Sending...")
            let post = try await client.createPost(text: body, mediaIDs: mediaIDs, accessToken: accessToken)
            text = ""
            attachedImages = []
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

    func loginSetupIssue() -> String? {
        if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add your X OAuth Client ID in Settings before logging in."
        }
        guard URL(string: baseURL)?.scheme?.hasPrefix("http") == true else {
            return "API base URL must start with http or https."
        }
        guard let callback = URL(string: callbackURL),
              callback.scheme == "http",
              callback.host == "127.0.0.1" || callback.host == "localhost",
              callback.port != nil
        else {
            return "Callback URL must be http://127.0.0.1:<port>/callback or http://localhost:<port>/callback."
        }
        return nil
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

enum ComposerTextStyle: CaseIterable {
    case bold
    case italic
    case serif

    var label: String {
        switch self {
        case .bold:
            "Bold"
        case .italic:
            "Italic"
        case .serif:
            "Serif"
        }
    }
}

struct TextStyler {
    static func apply(_ style: ComposerTextStyle, to text: String) -> String {
        text.unicodeScalars.map { scalar in
            styledScalar(scalar, style: style).map(String.init) ?? String(scalar)
        }.joined()
    }

    private static func styledScalar(_ scalar: UnicodeScalar, style: ComposerTextStyle) -> UnicodeScalar? {
        let value = scalar.value
        switch style {
        case .bold:
            return mappedScalar(value, uppercaseStart: 0x1D400, lowercaseStart: 0x1D41A, digitStart: 0x1D7CE)
        case .italic:
            return mappedScalar(value, uppercaseStart: 0x1D434, lowercaseStart: 0x1D44E, digitStart: nil)
        case .serif:
            return mappedScalar(value, uppercaseStart: 0x1D468, lowercaseStart: 0x1D482, digitStart: nil)
        }
    }

    private static func mappedScalar(
        _ value: UInt32,
        uppercaseStart: UInt32,
        lowercaseStart: UInt32,
        digitStart: UInt32?
    ) -> UnicodeScalar? {
        if (65...90).contains(value) {
            return UnicodeScalar(uppercaseStart + value - 65)
        }
        if (97...122).contains(value) {
            return UnicodeScalar(lowercaseStart + value - 97)
        }
        if let digitStart, (48...57).contains(value) {
            return UnicodeScalar(digitStart + value - 48)
        }
        return nil
    }
}
