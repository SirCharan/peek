import Foundation
import PeekCore

enum Eta {
    /// Regex step parse: "step 2/5", "phase 2 of 5", then bare "2/5".
    static func step(_ detail: String) -> (Int, Int)? {
        var nm: (Int, Int)?
        if let m = detail.firstMatch(of: /(?i)(?:step|phase)\s*(\d+)\s*(?:\/|of)\s*(\d+)/),
           let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        else if let m = detail.firstMatch(of: /(\d+)\/(\d+)/), let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        guard let (n, t) = nm, n > 0, n <= t, t <= 99 else { return nil }
        return (n, t)
    }

    static func hue(_ s: String) -> Double { PeekHue.hue(s) }

    /// Bash label: drop leading `cd <path> && ` / `cd <path>; `, collapse whitespace, cap at 48.
    static func bash(_ c: String) -> String {
        var t = c
        while let m = t.firstMatch(of: /^\s*cd\s+\S+\s*(?:&&|;)\s*/) { t = String(t[m.range.upperBound...]) }
        return String(t.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(48))
    }

    typealias Approval = (headline: String, detail: String, allowAlways: Bool, allowLabel: String, denyLabel: String)

    /// Human wording for a pending permission request.
    static func approval(_ tool: String, _ input: [String: Any]) -> Approval {
        func s(_ k: String) -> String { input[k] as? String ?? "" }
        func name(_ p: String) -> String { (p as NSString).lastPathComponent }
        switch tool {
        case "ExitPlanMode": return ("asks you to approve its plan", s("plan").isEmpty ? "plan text not available, see the terminal" : s("plan"), false, "Approve", "Keep planning")
        case "Bash": return ("wants to run", bash(s("command")), true, "Allow", "Deny")
        case "Edit", "Write", "NotebookEdit": return ("wants to edit", name(s("file_path")), true, "Allow", "Deny")
        case "Read": return ("wants to read", name(s("file_path")), true, "Allow", "Deny")
        case "WebFetch", "WebSearch":
            let u = s("url"), q = s("query")
            return ("wants to fetch", u.isEmpty ? q : (URL(string: u)?.host ?? u), true, "Allow", "Deny")
        case "Agent", "Task": return ("wants to start an agent", s("description"), true, "Allow", "Deny")
        default:
            let parts = tool.components(separatedBy: "__")
            if tool.hasPrefix("mcp__"), parts.count >= 3 { return ("wants to use \(parts[1])", parts[2...].joined(separator: "__"), true, "Allow", "Deny") }
            return ("wants to use \(tool)", "", true, "Allow", "Deny")
        }
    }

    static func base(_ cwd: String?) -> String {
        guard let c = cwd, !c.isEmpty else { return "" }
        return c == NSHomeDirectory() ? "~" : (c as NSString).lastPathComponent
    }
    static func words(_ s: String, _ n: Int) -> String { s.split(whereSeparator: \.isWhitespace).prefix(n).joined(separator: " ") }

    static func clean(_ s: String, _ n: Int = 6) -> String {
        let t = s.replacing(/`[^`]*`/, with: "").split(whereSeparator: \.isWhitespace)
            .filter { !$0.contains("/") && !$0.contains("~") && !$0.hasPrefix("!") }.joined(separator: " ")
        return String(words(t, n).prefix(40))
    }

    static func pct(phase: String, detail: String) -> Int {
        if let (n, t) = step(detail) { return n * 100 / t }
        return ["starting": 5, "plan": 20, "build": 50, "verify": 75, "report": 90, "done": 100, "failed": 100][phase] ?? 50
    }
}
