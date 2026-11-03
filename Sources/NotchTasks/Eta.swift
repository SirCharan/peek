import Foundation

enum Eta {
    // ponytail: one formatter, not Sendable-annotated; only used read-only
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    /// Regex step parse: "step 2/5", "phase 2 of 5", then bare "2/5".
    static func step(_ detail: String) -> (Int, Int)? {
        var nm: (Int, Int)?
        if let m = detail.firstMatch(of: /(?i)(?:step|phase)\s*(\d+)\s*(?:\/|of)\s*(\d+)/),
           let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        else if let m = detail.firstMatch(of: /(\d+)\/(\d+)/), let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        guard let (n, t) = nm, n > 0, n <= t, t <= 99 else { return nil }
        return (n, t)
    }

    static func hashLike(_ s: String) -> Bool { s.isEmpty || s.wholeMatch(of: /[0-9a-f]{8}/) != nil }
    static func base(_ cwd: String?) -> String {
        guard let c = cwd, !c.isEmpty else { return "" }
        return c == NSHomeDirectory() ? "~" : (c as NSString).lastPathComponent
    }
    static func words(_ s: String, _ n: Int) -> String { s.split(whereSeparator: \.isWhitespace).prefix(n).joined(separator: " ") }

    /// name, else first 5 words of text (intent / first user message), else cwd basename.
    static func title(name: String, text: String, cwd: String?) -> String {
        if !hashLike(name) { return name }
        let w = words(text, 5)
        return w.isEmpty ? base(cwd) : w
    }

    static func clean(_ s: String, _ n: Int = 6) -> String {
        let t = s.replacing(/`[^`]*`/, with: "").split(whereSeparator: \.isWhitespace)
            .filter { !$0.contains("/") && !$0.contains("~") && !$0.hasPrefix("!") }.joined(separator: " ")
        return String(words(t, n).prefix(40))
    }

    static func phase(state: String, text: String) -> String {
        if state == "blocked" { return "needs you" }
        if state == "done" || state == "failed" { return state }
        let t = text.lowercased()
        if t.isEmpty { return "starting" }
        func has(_ ks: [String]) -> Bool { ks.contains { t.contains($0) } }
        if has(["test", "verif", "check", "lint", "gate", "screenshot", "spot-read", "confirm"]) { return "verify" }
        if has(["report", "summar", "vault note", "wrap", "writing up"]) { return "report" }
        if has(["plan", "interview", "explor", "inventor", "research", "reading", "look"]) { return "plan" }
        return "build"
    }

    static func pct(phase: String, detail: String) -> Int {
        if let (n, t) = step(detail) { return n * 100 / t }
        return ["starting": 5, "plan": 20, "build": 50, "verify": 75, "report": 90, "done": 100, "failed": 100][phase] ?? 50
    }

    /// First user message text of a session transcript (first 64KB only).
    static func firstUser(sessionId: String, cwd: String) -> String {
        let slug = cwd.replacingOccurrences(of: "/", with: "-")
        guard let fh = FileHandle(forReadingAtPath: NSHomeDirectory() + "/.claude/projects/\(slug)/\(sessionId).jsonl") else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 65536)) ?? Data()
        for l in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any], o["type"] as? String == "user",
                  let m = o["message"] as? [String: Any] else { continue }
            if let s = m["content"] as? String { return s }
            if let a = m["content"] as? [[String: Any]] { return a.compactMap { $0["text"] as? String }.joined(separator: " ") }
        }
        return ""
    }
}

/// ponytail: blocking; call from Task.detached. Output assumed to be a JSON ARRAY of messages; we take the "result" element.
func runHaiku(_ prompt: String) -> String? {
    let p = Process()
    let home = NSHomeDirectory()
    let dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    var exe = dirs.map { $0 + "/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    if exe == nil {
        let w = Process(); let o = Pipe()
        w.executableURL = URL(fileURLWithPath: "/usr/bin/which"); w.arguments = ["claude"]
        w.environment = ["PATH": dirs.joined(separator: ":") + ":/usr/bin:/bin"]
        w.standardOutput = o; w.standardError = FileHandle.nullDevice
        if (try? w.run()) != nil {
            let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { exe = out }
        }
    }
    guard let exe else { return nil }
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["-p", "--model", "haiku", "--output-format", "json", "--strict-mcp-config", "--no-session-persistence",
                   "--disable-slash-commands", "--setting-sources", "", "--tools", ""]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = dirs.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
    let inP = Pipe(), outP = Pipe()
    p.standardInput = inP; p.standardOutput = outP; p.standardError = FileHandle.nullDevice
    var phrase: String?
    defer { fputs("haiku: \(phrase ?? "nil")\n", stderr) }
    do { try p.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
    try? inP.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try? inP.fileHandleForWriting.close()
    let data = outP.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // ponytail: this CLI version emits a single object; older ones an array of messages — accept both
    let j = try? JSONSerialization.jsonObject(with: data)
    let obj = (j as? [String: Any]) ?? (j as? [[String: Any]])?.first(where: { $0["type"] as? String == "result" })
    guard let r = obj?["result"] as? String else { return nil }
    let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t.count <= 80, !t.hasPrefix("Failed"), !t.hasPrefix("Not logged") else { return nil }
    phrase = t
    return t
}

@MainActor final class HaikuCache {
    private var cache: [String: String] = [:]
    private var last: [String: Date] = [:]
    private var inFlight = 0

    func get(_ id: String, _ key: String) -> String? { cache["\(id)|\(key)"] }

    func request(id: String, key: String, prompt: String) {
        let k = "\(id)|\(key)"
        guard cache[k] == nil, inFlight < 2, Date().timeIntervalSince(last[id] ?? .distantPast) >= 8 else { return }
        inFlight += 1; last[id] = Date()
        Task {
            let r = await Task.detached { runHaiku(prompt) }.value
            inFlight -= 1
            if let r { cache[k] = r }
        }
    }
}
