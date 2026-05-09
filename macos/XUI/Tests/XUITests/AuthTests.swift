import XCTest
@testable import XUI

final class AuthTests: XCTestCase {
    func testCallbackStrategyRecognizesLocalhostCallbacks() {
        let oauth = OAuthCoordinator()

        XCTAssertEqual(oauth.callbackStrategy(for: "http://127.0.0.1:8787/callback"), .localhost)
        XCTAssertEqual(oauth.callbackStrategy(for: "http://localhost:8787/callback"), .localhost)
    }

    func testCallbackStrategyRecognizesFutureNativeModes() {
        let oauth = OAuthCoordinator()

        XCTAssertEqual(oauth.callbackStrategy(for: "xui://oauth/callback"), .customScheme("xui"))
        XCTAssertEqual(oauth.callbackStrategy(for: "https://example.com/oauth/callback"), .webAssociatedDomain)
        XCTAssertEqual(oauth.callbackStrategy(for: "not a url"), .invalid)
    }

    func testAuthorizationURLIncludesXOAuthParameters() throws {
        let oauth = OAuthCoordinator()
        let challenge = PKCEChallenge(verifier: "verifier", challenge: "challenge")
        let settings = AppSettings(
            clientID: "client-id",
            baseURL: "https://api.x.com",
            callbackURL: "http://127.0.0.1:8787/callback"
        )

        let url = try oauth.authorizationURL(settings: settings, state: "state", challenge: challenge)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "x.com")
        XCTAssertEqual(components.path, "/i/oauth2/authorize")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "client-id")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:8787/callback")
        XCTAssertEqual(query["scope"], "tweet.read tweet.write users.read offline.access")
        XCTAssertEqual(query["state"], "state")
        XCTAssertEqual(query["code_challenge"], "challenge")
        XCTAssertEqual(query["code_challenge_method"], "S256")
    }

    func testPKCEChallengeUsesVerifierSafeCharacters() {
        let challenge = OAuthCoordinator().makeChallenge()
        let verifierCharacters = CharacterSet(charactersIn: challenge.verifier)
        let urlSafeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let challengeCharacters = CharacterSet(charactersIn: challenge.challenge)
        let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        XCTAssertEqual(challenge.verifier.count, 64)
        XCTAssertTrue(urlSafeCharacters.isSuperset(of: verifierCharacters))
        XCTAssertFalse(challenge.challenge.contains("="))
        XCTAssertTrue(base64URLCharacters.isSuperset(of: challengeCharacters))
    }

    func testFormURLEncoderEscapesOAuthValues() {
        let body = FormURLEncoder.encode([
            "redirect_uri": "http://127.0.0.1:8787/callback",
            "scope": "tweet.read tweet.write"
        ])

        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "redirect_uri=http%3A%2F%2F127.0.0.1%3A8787%2Fcallback&scope=tweet.read%20tweet.write"
        )
    }
}
