import XCTest
@testable import XUI

final class TokenRefreshPolicyTests: XCTestCase {
    func testMissingExpiryDoesNotForceRefresh() {
        XCTAssertFalse(TokenRefreshPolicy.needsRefresh(expiresAt: nil, now: Date(timeIntervalSince1970: 100)))
    }

    func testNearExpiryForcesRefresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(TokenRefreshPolicy.needsRefresh(expiresAt: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(TokenRefreshPolicy.needsRefresh(expiresAt: now.addingTimeInterval(30), now: now))
    }

    func testLaterExpiryDoesNotForceRefresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(TokenRefreshPolicy.needsRefresh(expiresAt: now.addingTimeInterval(61), now: now))
    }
}
