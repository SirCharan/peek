import XCTest
@testable import PeekCore

final class EditUsageTests: XCTestCase {
    func testEditCounts() throws {
        let d = try XCTUnwrap(DiffEngine.forTool("Edit", ["file_path": "/a/b/f.swift", "old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"]))
        XCTAssertEqual(d.name, "f.swift"); XCTAssertEqual(d.added, 2); XCTAssertEqual(d.removed, 1); XCTAssertFalse(d.capped)
    }

    func testMultiEditSums() throws {
        let d = try XCTUnwrap(DiffEngine.forTool("MultiEdit", ["file_path": "f", "edits": [
            ["old_string": "x", "new_string": "y\nz"], ["old_string": "p\nq", "new_string": "p"]]]))
        XCTAssertEqual(d.added, 2); XCTAssertEqual(d.removed, 2)
    }

    func testWriteIsAllAdded() throws {
        let d = try XCTUnwrap(DiffEngine.forTool("Write", ["file_path": "f", "content": "a\nb\nc\n"]))
        XCTAssertEqual(d.added, 3); XCTAssertEqual(d.removed, 0); XCTAssertTrue(d.isNew)
        XCTAssertNil(DiffEngine.forTool("Write", ["file_path": "f", "content": ""]))
        XCTAssertNil(DiffEngine.forTool("Bash", ["file_path": "f"]))
    }

    func testCappedInputsHaveNoCounts() throws {
        let big = String(repeating: "line\n", count: 4000)  // 20 000 bytes = the hook cap
        let w = try XCTUnwrap(DiffEngine.forTool("Write", ["file_path": "f", "content": big]))
        XCTAssertTrue(w.capped); XCTAssertEqual(w.added, 0); XCTAssertTrue(w.hunks.isEmpty)
        let e = try XCTUnwrap(DiffEngine.forTool("Edit", ["file_path": "f", "old_string": big, "new_string": "x"]))
        XCTAssertTrue(e.capped); XCTAssertEqual(e.removed, 0)
        let m = try XCTUnwrap(DiffEngine.forTool("MultiEdit", ["file_path": "f", "edits": [["old_string": "a", "new_string": "b"]], "edits_dropped": 2]))
        XCTAssertTrue(m.capped); XCTAssertEqual(m.added, 0)
    }

    func testHookMarksDroppedEdits() throws {
        let edits = (0..<3).map { _ in ["old_string": String(repeating: "a", count: 15_000), "new_string": "b"] }
        let o = Hook.trimInput("MultiEdit", ["file_path": "f", "edits": edits])
        XCTAssertEqual((o["edits"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(o["edits_dropped"] as? Int, 2)
    }

    func testHunkSanity() throws {
        let old = (1...10).map { "l\($0)" }.joined(separator: "\n")
        let d = DiffEngine.fromEdit(old: old, new: old.replacingOccurrences(of: "l5", with: "five"), path: "f")
        XCTAssertEqual(d.hunks.count, 1)
        let kinds = d.hunks[0].lines.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .added }.count, 1); XCTAssertEqual(kinds.filter { $0 == .removed }.count, 1)
        XCTAssertEqual(d.hunks[0].lines.count, 8)  // 3 context each side + the pair
        XCTAssertEqual(d.hunks[0].lines.first(where: { $0.kind == .added })?.text, "five")
    }

    // MARK: usage

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func payload(_ five: (Double, Double)?, _ seven: (Double, Double)?) -> [String: Any] {
        var r: [String: Any] = [:]
        if let f = five { r["five_hour"] = ["used_percentage": f.0, "resets_at": f.1] }
        if let s = seven { r["seven_day"] = ["used_percentage": s.0, "resets_at": s.1] }
        return ["rate_limits": r]
    }

    func testParse() throws {
        let u = try XCTUnwrap(Usage.parse(payload((42, 1_700_003_600), (250, 1_700_100_000)), now: now))
        XCTAssertEqual(u.fiveHour?.usedPct, 42)
        XCTAssertNil(u.sevenDay)  // 250% is garbage
        XCTAssertNil(Usage.parse([:], now: now))
        XCTAssertNil(Usage.parse(["rate_limits": ["five_hour": ["used_percentage": 10, "resets_at": 1_700_000_000_000.0]]], now: now))  // milliseconds
    }

    func testMergeStaleVsFresh() throws {
        let fresh = try XCTUnwrap(Usage.parse(payload((60, 1_700_007_200), (20, 1_700_100_000)), now: now))
        let stale = try XCTUnwrap(Usage.parse(payload((10, 1_700_003_600), (15, 1_700_100_000)), now: now))
        let m = Usage.merge(fresh, with: stale)
        XCTAssertEqual(m.fiveHour?.usedPct, 60)   // later reset wins
        XCTAssertEqual(m.sevenDay?.usedPct, 20)   // same window keeps the higher %
        let partial = try XCTUnwrap(Usage.parse(payload((5, 1_700_003_600), nil), now: now))
        XCTAssertEqual(Usage.merge(fresh, with: partial).sevenDay?.usedPct, 20)  // missing window kept
    }

    func testFreshestDropsExpired() throws {
        let a = try XCTUnwrap(Usage.parse(payload((90, 1_699_999_000), (30, 1_700_100_000)), now: now))
        let u = try XCTUnwrap(Usage.freshest([a], now: now))
        XCTAssertNil(u.fiveHour); XCTAssertEqual(u.sevenDay?.usedPct, 30)
        let b = try XCTUnwrap(Usage.parse(payload((90, 1_699_999_000), nil), now: now))
        XCTAssertNil(Usage.freshest([b], now: now))
        XCTAssertNil(Usage.freshest([], now: now))
    }
}
