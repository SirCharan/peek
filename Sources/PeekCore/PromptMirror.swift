import Foundation

/// A prompt the terminal is showing (a question or a plan approval), built from the logged `PreToolUse` event.
/// Read-only: Peek shows it and points at the terminal. A held `PermissionRequest` card for the same session and tool replaces it.
public struct PromptMirror: Equatable, Sendable {
    public var tool: String
    public var t: Double
    /// Empty for the main session; the subagent's id otherwise.
    public var agent: String
    public var ask: AskQuestion?
    public var plan: String

    public static let tools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// A held request arrives within milliseconds of its `PreToolUse`; wait this long before showing the mirror.
    public static let graceMs = 1200.0

    public static func make(_ ev: [String: Any]) -> PromptMirror? {
        guard ev["ev"] as? String == "PreToolUse", let tool = ev["tool_name"] as? String, tools.contains(tool),
              let t = (ev["t"] as? NSNumber)?.doubleValue else { return nil }
        let i = ev["tool_input"] as? [String: Any] ?? [:]
        return PromptMirror(tool: tool, t: t, agent: ev["agent_id"] as? String ?? "",
                            ask: tool == "AskUserQuestion" ? AskQuestion.parse(toolInput: i, loose: true) : nil,
                            plan: tool == "ExitPlanMode" ? i["plan"] as? String ?? "" : "")
    }

    /// Hidden while a held request of the same tool is on screen, and during the grace window.
    public func visible(heldTools: Set<String>, nowMs: Double) -> Bool {
        !heldTools.contains(tool) && nowMs - t >= Self.graceMs
    }

    /// Whether a later event of the session means the prompt was answered. Main-session events clear main-session prompts;
    /// a subagent's tool result clears only that subagent's prompt.
    public static func clears(ev: String, tool: String, evAgent: String, promptTool: String, promptAgent: String) -> Bool {
        switch ev {
        case "PostToolUse", "PostToolUseFailure": return tool == promptTool && evAgent == promptAgent
        case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd": return evAgent.isEmpty
        case "SubagentStop": return !promptAgent.isEmpty && (evAgent.isEmpty || evAgent == promptAgent)
        default: return false
        }
    }
}
