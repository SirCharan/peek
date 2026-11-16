import XCTest
@testable import PeekCore

final class HookTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func ev(_ raw: [String: Any]) -> [String: Any]? { Hook.event(raw, pid: 42, tty: "ttys001", now: now) }

    func testBaseFields() throws {
        let o = try XCTUnwrap(ev(["session_id": "abc-1", "hook_event_name": "Stop", "cwd": "/x/y", "last_assistant_message": String(repeating: "a", count: 900)]))
        XCTAssertEqual(o["t"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(o["ev"] as? String, "Stop")
        XCTAssertEqual(o["sid"] as? String, "abc-1")
        XCTAssertEqual(o["pid"] as? Int, 42)
        XCTAssertEqual(o["tty"] as? String, "ttys001")
        XCTAssertEqual((o["last_assistant_message"] as? String)?.count, 400)
    }

    func testRejectsBadSession() {
        XCTAssertNil(ev(["hook_event_name": "Stop"]))
        XCTAssertNil(ev(["session_id": "../etc", "hook_event_name": "Stop"]))
        XCTAssertNil(ev(["session_id": "a", "hook_event_name": ""]))
    }

    func testPromptTitleNotification() throws {
        let o = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "UserPromptSubmit", "prompt": String(repeating: "p", count: 500), "session_title": "My title"]))
        XCTAssertEqual((o["prompt"] as? String)?.count, 200)
        XCTAssertEqual(o["session_title"] as? String, "My title")
        let n = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "waiting"]))
        XCTAssertEqual(n["notification_type"] as? String, "idle_prompt")
        XCTAssertEqual(n["message"] as? String, "waiting")
    }

    func testBashAndReadInputTrimmed() throws {
        let long = String(repeating: "x", count: 300)
        let b = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                  "tool_input": ["command": long, "description": "d", "timeout": 5, "old_string": "nope"]]))
        let i = try XCTUnwrap(b["tool_input"] as? [String: Any])
        XCTAssertEqual((i["command"] as? String)?.count, 120)
        XCTAssertNil(i["timeout"]); XCTAssertNil(i["old_string"])
        let r = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": ["file_path": "/a/b.swift", "content": "z"]]))
        let ri = try XCTUnwrap(r["tool_input"] as? [String: Any])
        XCTAssertEqual(ri["file_path"] as? String, "/a/b.swift")
        XCTAssertNil(ri["content"])
    }

    func testEditKeepsDiffMaterialCapped() throws {
        let big = String(repeating: "é", count: 30_000)  // 60 KB in UTF-8
        let e = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PostToolUse", "tool_name": "Edit",
                                  "tool_input": ["file_path": "/f", "old_string": "a\nb", "new_string": big]]))
        let i = try XCTUnwrap(e["tool_input"] as? [String: Any])
        XCTAssertEqual(i["old_string"] as? String, "a\nb")
        XCTAssertLessThanOrEqual((i["new_string"] as? String)?.utf8.count ?? .max, 20_000)
        let m = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PostToolUse", "tool_name": "MultiEdit",
                                  "tool_input": ["file_path": "/f", "edits": [["old_string": "1", "new_string": "2"], ["old_string": "3", "new_string": big]]]]))
        let edits = try XCTUnwrap((m["tool_input"] as? [String: Any])?["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)  // second edit pushes past the cap
        let w = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": ["file_path": "/f", "content": "hello"]]))
        XCTAssertEqual((w["tool_input"] as? [String: Any])?["content"] as? String, "hello")
    }

    func testLineIsOneJSONLine() throws {
        let l = try XCTUnwrap(Hook.line(["a": "x\ny", "b": 1]))
        XCTAssertFalse(l.contains("\n"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(l.utf8)))
    }

    func testDecisionJSON() throws {
        XCTAssertEqual(Hook.decision("allow"), #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(Hook.decision("always"), Hook.decision("allow"))  // no suggestion: always degrades to allow
        let d = try XCTUnwrap(Hook.decision(#"deny:no "rm" please"#))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(d.utf8)) as? [String: Any])
        let dec = try XCTUnwrap((o["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(dec["behavior"] as? String, "deny")
        XCTAssertEqual(dec["message"] as? String, #"no "rm" please"#)
        let bare = try XCTUnwrap(Hook.decision("deny"))
        XCTAssertTrue(bare.contains("Denied from the notch"))
        XCTAssertNil(Hook.decision(""))
        XCTAssertNil(Hook.decision("maybe"))
    }

    func testAlwaysBecomesUpdatedPermissions() throws {
        let sug: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf node_modules"]], "behavior": "allow", "destination": "localSettings"]]
        let a = try XCTUnwrap(Hook.always(sug))
        XCTAssertEqual(a.label, "always allow Bash(rm -rf node_modules)")
        let out = try XCTUnwrap(Hook.decision("always", tool: "Bash", rawInput: ["command": "x"], always: a.update))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let h = try XCTUnwrap(o["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(h["hookEventName"] as? String, "PermissionRequest")
        let d = try XCTUnwrap(h["decision"] as? NSDictionary)
        XCTAssertEqual(d, ["behavior": "allow", "updatedPermissions": sug] as NSDictionary)  // echoed verbatim, no updatedInput for Bash
        XCTAssertNil(Hook.always([]))
        XCTAssertNil(Hook.always([["type": "addDirectories", "directories": ["/x"], "destination": "session"]]))
        XCTAssertEqual(Hook.always([["type": "setMode", "mode": "acceptEdits", "destination": "session"]])?.label, "switch to acceptEdits mode")
        XCTAssertEqual(Hook.always([["type": "addRules", "rules": [["toolName": "mcp__a__b"]], "behavior": "allow", "destination": "session"]])?.label, "always allow mcp__a__b")
    }

    func testPlanApprovalEchoesInput() throws {
        let out = try XCTUnwrap(Hook.decision("allow", tool: "ExitPlanMode", rawInput: ["plan": "## P", "planFilePath": "/p.md"]))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let d = try XCTUnwrap((o["hookSpecificOutput"] as? [String: Any])?["decision"] as? NSDictionary)
        XCTAssertEqual(d, ["behavior": "allow", "updatedInput": ["plan": "## P", "planFilePath": "/p.md"]] as NSDictionary)
    }

    func testAskQuestionsKeptInTrimmedInput() throws {
        let q: [[String: Any]] = [["question": "Q?", "header": "H", "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]], "multiSelect": false]]
        let e = try XCTUnwrap(ev(["session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": ["questions": q]]))
        XCTAssertNotNil(AskQuestion.parse(toolInput: try XCTUnwrap(e["tool_input"] as? [String: Any])))
    }

    func testStatus() throws {
        let raw: [String: Any] = ["session_id": "s1", "session_name": "named", "context_window": ["used_percentage": 41.6],
                                  "rate_limits": ["five_hour": ["used_percentage": 23.5, "resets_at": 1738425600], "spend_limit": ["x": 1]]]
        let s = try XCTUnwrap(Hook.status(raw, now: now))
        XCTAssertEqual(s.sid, "s1")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: s.json) as? [String: Any])
        XCTAssertEqual(o["ctx"] as? Int, 42)
        XCTAssertEqual(o["session_name"] as? String, "named")
        XCTAssertEqual(Set((o["rate_limits"] as? [String: Any])?.keys.map { $0 } ?? []), ["five_hour"])
        XCTAssertNil(Hook.status(["context_window": [:]]))
        let n = try XCTUnwrap(Hook.status(["session_id": "s2", "context_window": ["used_percentage": NSNull()]]))
        XCTAssertNil((try JSONSerialization.jsonObject(with: n.json) as? [String: Any])?["ctx"])
    }
}
