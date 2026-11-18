// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/AskQuestion.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation

public struct AskOption: Equatable, Sendable {
    public var label: String
    public var description: String
}

public struct AskItem: Equatable, Sendable {
    public var question: String
    public var header: String
    public var options: [AskOption]
    public var multiSelect: Bool
}

public struct AskQuestion: Equatable, Sendable {
    public var questions: [AskItem]

    /// Open question: the docs say multi-select answers are the labels joined with commas; another client sends an array.
    /// Flip this one constant to send an array instead.
    public static let multiSelectAsArray = false

    /// 1-4 questions with 2-4 options each; nil when the payload is malformed (the terminal then asks).
    /// `loose` (read-only mirror) accepts up to 8 questions and 12 options each, since nothing is sent back.
    public static func parse(toolInput: [String: Any], loose: Bool = false) -> AskQuestion? {
        let maxQ = loose ? 8 : 4, maxO = loose ? 12 : 4, minO = loose ? 1 : 2
        guard let rawQs = toolInput["questions"] as? [[String: Any]], !rawQs.isEmpty, rawQs.count <= maxQ else { return nil }
        var items: [AskItem] = []
        for raw in rawQs {
            guard let question = raw["question"] as? String, !question.isEmpty,
                  let rawOpts = raw["options"] as? [[String: Any]], rawOpts.count >= minO, rawOpts.count <= maxO else { return nil }
            var opts: [AskOption] = []
            for opt in rawOpts {
                guard let label = opt["label"] as? String, !label.isEmpty else { return nil }
                opts.append(AskOption(label: label, description: opt["description"] as? String ?? ""))
            }
            items.append(AskItem(question: question, header: String((raw["header"] as? String ?? "").prefix(12)),
                                 options: opts, multiSelect: raw["multiSelect"] as? Bool ?? false))
        }
        return AskQuestion(questions: items)
    }

    /// `selections[i]` = labels chosen for question i. Maps question text to the answer; unanswered questions are left out.
    public static func buildAnswers(questions: [AskItem], selections: [[String]]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (i, item) in questions.enumerated() {
            guard i < selections.count, !selections[i].isEmpty else { continue }
            if item.multiSelect {
                answers[item.question] = multiSelectAsArray ? selections[i] as Any : selections[i].joined(separator: ", ")
            } else {
                answers[item.question] = selections[i][0]
            }
        }
        return answers
    }
}
