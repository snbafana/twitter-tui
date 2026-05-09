import XCTest
@testable import XUI

final class TextStylerTests: XCTestCase {
    func testBoldStylesLettersAndDigits() {
        XCTAssertEqual(TextStyler.apply(.bold, to: "Az 19!"), "𝐀𝐳 𝟏𝟗!")
    }

    func testItalicStylesLettersAndLeavesDigitsPlain() {
        XCTAssertEqual(TextStyler.apply(.italic, to: "Az 19!"), "𝐴𝑧 19!")
    }

    func testSerifStylesLettersAndLeavesDigitsPlain() {
        XCTAssertEqual(TextStyler.apply(.serif, to: "Az 19!"), "𝑨𝒛 19!")
    }
}
