import XCTest
@testable import PeekCore

final class AskQuestionTests: XCTestCase {
    /// The AskUserQuestion example from the hooks docs.
    let docsQuestions: [[String: Any]] = [[
        "question": "Which framework?", "header": "Framework",
        "options": [["label": "React", "description": "Component library"], ["label": "Vue", "description": "Progressive framework"]],
        "multiSelect": false]]

    func testParseDocsExample() throws {
        let q = try XCTUnwrap(AskQuestion.parse(toolInput: ["questions": docsQuestions]))
        XCTAssertEqual(q.questions.count, 1)
        XCTAssertEqual(q.questions[0].question, "Which framework?")
        XCTAssertEqual(q.questions[0].header, "Framework")
        XCTAssertEqual(q.questions[0].options, [AskOption(label: "React", description: "Component library"), AskOption(label: "Vue", description: "Progressive framework")])
        XCTAssertFalse(q.questions[0].multiSelect)
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(AskQuestion.parse(toolInput: [:]))
        XCTAssertNil(AskQuestion.parse(toolInput: ["questions": []]))
        XCTAssertNil(AskQuestion.parse(toolInput: ["questions": [["question": "Q", "options": [["label": "only one"]]]]]))
        XCTAssertNil(AskQuestion.parse(toolInput: ["questions": Array(repeating: docsQuestions[0], count: 5)]))
    }

    func testBuildAnswersSingleAndMulti() throws {
        let q = try XCTUnwrap(AskQuestion.parse(toolInput: ["questions": docsQuestions + [[
            "question": "Which extras?", "header": "Extras", "options": [["label": "Lint"], ["label": "Tests"]], "multiSelect": true]]]))
        let a = AskQuestion.buildAnswers(questions: q.questions, selections: [["React"], ["Lint", "Tests"]])
        XCTAssertEqual(a["Which framework?"] as? String, "React")  // docs: {"Which framework?": "React"}
        if AskQuestion.multiSelectAsArray { XCTAssertEqual(a["Which extras?"] as? [String], ["Lint", "Tests"]) }
        else { XCTAssertEqual(a["Which extras?"] as? String, "Lint, Tests") }  // docs: multi-select joins labels with commas
        XCTAssertNil(AskQuestion.buildAnswers(questions: q.questions, selections: [[], ["Lint"]])["Which framework?"])
    }

    func testAskOutputIsTheDocumentedJSON() throws {
        let out = try XCTUnwrap(Hook.askOutput(questions: docsQuestions, reply: #"{"Which framework?":"React"}"#))
        let want: NSDictionary = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                  "updatedInput": ["questions": docsQuestions, "answers": ["Which framework?": "React"]]]]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? NSDictionary, want)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertNil(Hook.askOutput(questions: docsQuestions, reply: ""))
        XCTAssertNil(Hook.askOutput(questions: docsQuestions, reply: "{}"))
    }
}
