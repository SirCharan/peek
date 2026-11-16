import XCTest
@testable import PeekCore

final class TerminalsTests: XCTestCase {
    func testHostPrefersBundleId() {
        XCTAssertEqual(Terminals.host(termProgram: "ghostty", bundleId: "com.cmuxterm.app"), "com.cmuxterm.app")
        XCTAssertEqual(Terminals.host(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92"), "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(Terminals.host(termProgram: "iTerm.app", bundleId: ""), Terminals.iterm)
        XCTAssertEqual(Terminals.host(termProgram: "Apple_Terminal", bundleId: "com.apple.dt.Xcode"), Terminals.terminal)
        XCTAssertNil(Terminals.host(termProgram: "", bundleId: ""))
        XCTAssertNil(Terminals.host(termProgram: "tmux", bundleId: "com.example.x"))
    }

    func testScriptable() {
        XCTAssertTrue(Terminals.scriptable(Terminals.terminal)); XCTAssertTrue(Terminals.scriptable(Terminals.iterm))
        XCTAssertFalse(Terminals.scriptable("com.mitchellh.ghostty")); XCTAssertFalse(Terminals.scriptable(nil))
    }

    func testQuoteEscapesQuotesBackslashesNewlines() {
        XCTAssertEqual(Terminals.quote(#"say "hi" \ there"#), #""say \"hi\" \\ there""#)
        XCTAssertEqual(Terminals.quote("a\nb"), #""a\nb""#)
        XCTAssertEqual(Terminals.quote(#"\""#), #""\\\"""#)
    }

    func testDeviceAndGuidValidation() {
        XCTAssertEqual(Terminals.device("ttys003"), "/dev/ttys003")
        XCTAssertNil(Terminals.device("")); XCTAssertNil(Terminals.device("ttys"))
        XCTAssertNil(Terminals.device(#"ttys0"; do shell script "x"#))
        XCTAssertEqual(Terminals.itermGuid("w0t1p0:A1B2-C3D4"), "A1B2-C3D4")
        XCTAssertEqual(Terminals.itermGuid(#"w0t0p0:x" & (do shell script "x") & ""#), "")
        XCTAssertEqual(Terminals.itermGuid(""), "")
    }

    func testScripts() throws {
        XCTAssertNil(Terminals.terminalFind(tty: ""))
        XCTAssertTrue(try XCTUnwrap(Terminals.terminalFind(tty: "ttys004")).contains(#"is "/dev/ttys004""#))
        XCTAssertEqual(Terminals.terminalSend(window: 2, tab: 3, text: #"a "b" \c"#),
                       #"tell application "Terminal" to do script "a \"b\" \\c" in tab 3 of window 2"#)
        XCTAssertNil(Terminals.itermJump(guid: "", tty: ""))
        let s = try XCTUnwrap(Terminals.itermSend(guid: "AB-12", tty: "ttys009", text: #"x"y\"#))
        XCTAssertTrue(s.contains(#"(unique id of s) is "AB-12" or (tty of s) is "/dev/ttys009""#))
        XCTAssertTrue(s.contains(#"write text "x\"y\\""#))
        XCTAssertTrue(try XCTUnwrap(Terminals.itermJump(guid: "", tty: "ttys009")).contains("tell s to select"))
    }
}
