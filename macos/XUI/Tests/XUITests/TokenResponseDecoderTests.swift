import XCTest
@testable import XUI

final class TokenResponseDecoderTests: XCTestCase {
    func testDecodesSuccessfulTokenResponse() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.x.com/2/oauth2/token")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let now = Date(timeIntervalSince1970: 100)

        let bundle = try TokenResponseDecoder.decode(
            data: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8),
            response: response,
            now: now
        )

        XCTAssertEqual(bundle.accessToken, "access")
        XCTAssertEqual(bundle.refreshToken, "refresh")
        XCTAssertEqual(bundle.expiresAt, now.addingTimeInterval(3600))
    }

    func testTokenErrorUsesParsedXPayload() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.x.com/2/oauth2/token")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!

        do {
            _ = try TokenResponseDecoder.decode(
                data: Data(#"{"title":"Invalid Request","detail":"Bad verifier"}"#.utf8),
                response: response
            )
            XCTFail("Expected token decoding to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Token exchange failed with 400: Invalid Request: Bad verifier")
        }
    }
}
