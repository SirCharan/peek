import XCTest
@testable import PeekCore

final class ShortcutsTests: XCTestCase {
    func testDisplayAndCarbon() {
        let s = Shortcut(keyCode: 38, flags: Shortcut.ctrl | Shortcut.opt)
        XCTAssertEqual(s.display, "\u{2303}\u{2325}J")
        XCTAssertEqual(s.carbonModifiers, (1 << 12 | 1 << 11))
        XCTAssertEqual(Shortcut(keyCode: 49, flags: Shortcut.cmd | Shortcut.shift).display, "\u{21E7}\u{2318}Space")
        XCTAssertEqual(Shortcut(keyCode: 49, flags: Shortcut.cmd | Shortcut.shift).carbonModifiers, (1 << 8 | 1 << 9))
    }
    func testStoredRoundTrip() {
        for a in HotkeyAction.allCases { XCTAssertTrue(Shortcut(stored: a.defaultShortcut.stored) == a.defaultShortcut) }
        XCTAssertEqual(Shortcut(stored: "bad"), nil)
        XCTAssertTrue(Shortcut(stored: "38:0") == nil)  // a modifier is required
        XCTAssertEqual(Shortcut(keyCode: 1, flags: 0xFFFF_FFFF).flags, Shortcut.mask)
    }
    func testResolveStates() {
        XCTAssertEqual(HotkeyAction.jump.resolve(nil)?.display, "\u{2303}\u{2325}J")
        XCTAssertEqual(HotkeyAction.jump.resolve(""), nil)
        XCTAssertEqual(HotkeyAction.jump.resolve("0:786432")?.display, "\u{2303}\u{2325}A")
        XCTAssertEqual(HotkeyAction.jump.resolve("junk"), HotkeyAction.jump.defaultShortcut)
    }
    func testDefaultsAreDistinct() {
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.defaultShortcut)).count, HotkeyAction.allCases.count)
        XCTAssertEqual(HotkeyAction.allCases.map { $0.defaultShortcut.display }, ["\u{2303}\u{2325}J", "\u{2303}\u{2325}A", "\u{2303}\u{2325}D", "\u{2303}\u{2325}P", "\u{2303}\u{2325}M"])
    }
    func testAlwaysButtonLabel() {
        XCTAssertEqual(Hook.alwaysButton("always allow Bash(npm test)"), "Always")
        XCTAssertEqual(Hook.alwaysButton("switch to acceptEdits mode"), "Accept edits")
        XCTAssertEqual(Hook.alwaysButton("switch to plan mode"), "Plan")
        XCTAssertEqual(Hook.alwaysButton("switch to bypassPermissions mode"), "Bypass permissions")
    }
}
