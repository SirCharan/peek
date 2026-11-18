import XCTest
@testable import PeekCore

final class PromptMirrorTests: XCTestCase {
    func pre(_ tool: String, input: [String: Any], agent: String? = nil, t: Double = 1000) -> [String: Any] {
        var o: [String: Any] = ["ev": "PreToolUse", "tool_name": tool, "tool_input": input, "t": t]
        if let agent { o["agent_id"] = agent }
        return o
    }
    let qs: [String: Any] = ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]

    func testMakeQuestionAndPlan() throws {
        let q = try XCTUnwrap(PromptMirror.make(pre("AskUserQuestion", input: qs)))
        XCTAssertEqual(q.ask?.questions.first?.options.count, 2)
        XCTAssertEqual(q.agent, "")
        let p = try XCTUnwrap(PromptMirror.make(pre("ExitPlanMode", input: ["plan": "## P\n1. step"], agent: "sub1")))
        XCTAssertEqual(p.plan, "## P\n1. step")
        XCTAssertEqual(p.agent, "sub1")
        XCTAssertNil(PromptMirror.make(pre("Bash", input: ["command": "ls"])))
        var post = pre("AskUserQuestion", input: qs); post["ev"] = "PostToolUse"
        XCTAssertNil(PromptMirror.make(post))
    }

    func testQuestionBeyondHeldLimitsStillMirrors() throws {
        let opts = (1...6).map { ["label": "O\($0)"] }
        let m = try XCTUnwrap(PromptMirror.make(pre("AskUserQuestion", input: ["questions": [["question": "Q", "options": opts]]])))
        XCTAssertEqual(m.ask?.questions.first?.options.count, 6)
        XCTAssertNil(AskQuestion.parse(toolInput: ["questions": [["question": "Q", "options": opts]]]))  // the held card still refuses it
    }

    func testVisibilityGraceAndDedup() throws {
        let m = try XCTUnwrap(PromptMirror.make(pre("ExitPlanMode", input: ["plan": "p"], t: 1000)))
        XCTAssertFalse(m.visible(heldTools: [], nowMs: 1500))                      // inside the grace window
        XCTAssertTrue(m.visible(heldTools: [], nowMs: 1000 + PromptMirror.graceMs))
        XCTAssertFalse(m.visible(heldTools: ["ExitPlanMode"], nowMs: 9000))        // a held card for the same tool wins
        XCTAssertTrue(m.visible(heldTools: ["AskUserQuestion"], nowMs: 9000))      // a different tool does not hide it
    }

    func testClearingRules() {
        func c(_ ev: String, _ tool: String = "", _ agent: String = "", of pt: String = "AskUserQuestion", by pa: String = "") -> Bool {
            PromptMirror.clears(ev: ev, tool: tool, evAgent: agent, promptTool: pt, promptAgent: pa)
        }
        XCTAssertTrue(c("PostToolUse", "AskUserQuestion"))
        XCTAssertTrue(c("PostToolUseFailure", "AskUserQuestion"))
        XCTAssertFalse(c("PostToolUse", "Bash"))
        XCTAssertFalse(c("PostToolUse", "AskUserQuestion", "sub1"))          // a subagent's result does not clear the main prompt
        XCTAssertTrue(c("PostToolUse", "AskUserQuestion", "sub1", by: "sub1"))
        XCTAssertTrue(c("UserPromptSubmit")); XCTAssertTrue(c("Stop")); XCTAssertTrue(c("SessionEnd")); XCTAssertTrue(c("StopFailure"))
        XCTAssertFalse(c("Stop", "", "sub1"))                                 // subagent events never end the session's prompt
        XCTAssertTrue(c("SubagentStop", "", "sub1", by: "sub1"))
        XCTAssertFalse(c("SubagentStop", "", "sub1"))
        XCTAssertFalse(c("PreToolUse", "Read"))
        XCTAssertFalse(c("Notification"))
    }
}
