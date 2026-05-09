import XCTest
@testable import XUI

final class CallbackParserTests: XCTestCase {
    func testParsesSuccessfulOAuthCallback() throws {
        let request = "GET /callback?code=abc123&state=state-456 HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n"

        let payload = try LocalhostCallbackParser.parse(request)

        XCTAssertEqual(payload.code, "abc123")
        XCTAssertEqual(payload.state, "state-456")
        XCTAssertNil(payload.error)
    }

    func testParsesDeniedOAuthCallback() throws {
        let request = "GET /callback?error=access_denied&error_description=User%20cancelled HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n"

        let payload = try LocalhostCallbackParser.parse(request)

        XCTAssertEqual(payload.error, "access_denied")
        XCTAssertEqual(payload.errorDescription, "User cancelled")
    }

    func testRejectsMalformedCallbackRequest() {
        XCTAssertThrowsError(try LocalhostCallbackParser.parse("bad request"))
    }
}
