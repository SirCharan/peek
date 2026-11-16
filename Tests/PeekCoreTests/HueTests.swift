import XCTest
@testable import PeekCore

final class HueTests: XCTestCase {
    func testHueStableAndInRange() {
        XCTAssertEqual(PeekHue.hue("abc"), PeekHue.hue("abc"))
        XCTAssertEqual(PeekHue.hue(""), Double(2166136261 % 360) / 360)
        for s in ["a", "peek", "session-1"] { XCTAssertTrue((0..<1).contains(PeekHue.hue(s))) }
    }
}
