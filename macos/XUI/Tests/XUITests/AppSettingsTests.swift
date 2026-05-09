import XCTest
@testable import XUI

final class AppSettingsTests: XCTestCase {
    func testDefaultSettingsAreReadyAfterClientID() {
        let settings = AppSettings(
            clientID: "client-id",
            baseURL: "https://api.x.com",
            callbackURL: "http://127.0.0.1:8787/callback"
        )

        XCTAssertNil(settings.loginSetupIssue())
    }

    func testMissingClientIDExplainsSetupStep() {
        let settings = AppSettings(
            clientID: " ",
            baseURL: "https://api.x.com",
            callbackURL: "http://127.0.0.1:8787/callback"
        )

        XCTAssertEqual(settings.loginSetupIssue(), "Add your X OAuth Client ID in Settings before logging in.")
    }

    func testInvalidBaseURLExplainsExpectedShape() {
        let settings = AppSettings(
            clientID: "client-id",
            baseURL: "api.x.com",
            callbackURL: "http://127.0.0.1:8787/callback"
        )

        XCTAssertEqual(settings.loginSetupIssue(), "API base URL must start with http or https.")
    }

    func testInvalidCallbackExplainsExpectedLocalhostURL() {
        let settings = AppSettings(
            clientID: "client-id",
            baseURL: "https://api.x.com",
            callbackURL: "xui://oauth/callback"
        )

        XCTAssertEqual(settings.loginSetupIssue(), "Callback URL must be http://127.0.0.1:<port>/callback or http://localhost:<port>/callback.")
    }
}
