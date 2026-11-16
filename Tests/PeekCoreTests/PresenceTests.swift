import XCTest
import CoreGraphics
@testable import PeekCore

final class PresenceTests: XCTestCase {
    func testHoverClimbsOneStepAtATime() {
        var s = Presence.hidden
        s = PresenceMachine.next(s, hasSessions: false, inside: true); XCTAssertEqual(s, .small)
        s = PresenceMachine.next(s, hasSessions: false, inside: true); XCTAssertEqual(s, .home)
        s = PresenceMachine.next(s, hasSessions: false, inside: false); XCTAssertEqual(s, .hidden)
    }
    func testSessionsKeepTheBand() {
        XCTAssertEqual(PresenceMachine.next(.hidden, hasSessions: true, inside: false), .small)
        XCTAssertEqual(PresenceMachine.next(.home, hasSessions: true, inside: false), .small)
        XCTAssertEqual(PresenceMachine.next(.small, hasSessions: true, inside: true), .home)
        XCTAssertEqual(PresenceMachine.next(.small, hasSessions: false, inside: false), .hidden)
    }
    func testDemoPinsHome() {
        XCTAssertEqual(PresenceMachine.next(.hidden, hasSessions: false, inside: false, demo: true), .home)
    }
    func testNotchWidthFromAuxAreas() {
        let g = BarGeometry(screenWidth: 1512, safeAreaTop: 32, auxLeft: 664, auxRight: 664, menuBarHeight: 38)
        XCTAssertTrue(g.hasNotch && g.width == 184 && g.height == 32)
        let bad = BarGeometry(screenWidth: 1512, safeAreaTop: 32, auxLeft: nil, auxRight: nil, menuBarHeight: 38)
        XCTAssertEqual(bad.width, BarGeometry.fallbackNotchWidth)
    }
    func testNoNotchUsesRealMenuBarHeight() {
        let g = BarGeometry(screenWidth: 2560, safeAreaTop: 0, auxLeft: nil, auxRight: nil, menuBarHeight: 25)
        XCTAssertTrue(!g.hasNotch && g.width == 80 && g.height == 25)
        XCTAssertEqual(BarGeometry(screenWidth: 2560, safeAreaTop: 0, auxLeft: nil, auxRight: nil, menuBarHeight: 0).height, 24)
    }
    func testChoiceRoundTrip() {
        for s in ["notch", "main", "mouse", "ABC-123"] { XCTAssertEqual(ScreenChoice(s).stored, s) }
        XCTAssertEqual(ScreenChoice(nil), .notch)
    }
    func testResolver() {
        let a = ScreenCandidate(uuid: "A", hasNotch: false, containsMouse: false)
        let b = ScreenCandidate(uuid: "B", hasNotch: true, containsMouse: false)
        let c = ScreenCandidate(uuid: "C", hasNotch: false, containsMouse: true)
        let all = [a, b, c]
        XCTAssertEqual(ScreenResolver.index(.notch, in: all), 1)
        XCTAssertEqual(ScreenResolver.index(.notch, in: [a, c]), 0)
        XCTAssertEqual(ScreenResolver.index(.main, in: all), 0)
        XCTAssertEqual(ScreenResolver.index(.mouse, in: all), 2)
        XCTAssertEqual(ScreenResolver.index(.display("C"), in: all), 2)
        XCTAssertEqual(ScreenResolver.index(.display("gone"), in: all), 1)
        XCTAssertEqual(ScreenResolver.index(.notch, in: []), nil)
    }
}
