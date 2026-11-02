import Foundation

private struct TL: Decodable { let at: String?; let state: String?; let text: String? }
private struct StateLite: Decodable { let state: String?; let name: String?; let createdAt: String? }

enum Eta {
    // ponytail: one formatter, not Sendable-annotated; only used read-only
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    /// "4m" / "1h12m"
    static func fmt(_ min: Int) -> String { min >= 60 ? "\(min / 60)h\(min % 60)m" : "\(min)m" }

    /// Regex step parse: "step 2/5", "phase 2 of 5", then bare "2/5".
    static func step(_ detail: String) -> (Int, Int)? {
        var nm: (Int, Int)?
        if let m = detail.firstMatch(of: /(?i)(?:step|phase)\s*(\d+)\s*(?:\/|of)\s*(\d+)/),
           let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        else if let m = detail.firstMatch(of: /(\d+)\/(\d+)/), let n = Int(m.1), let t = Int(m.2) { nm = (n, t) }
        guard let (n, t) = nm, n > 0, n <= t, t <= 99 else { return nil }
        return (n, t)
    }

    /// ETA = elapsed * (M-N)/N
    static func progress(_ detail: String, elapsedMin: Double) -> Int? {
        step(detail).map { Int(elapsedMin * Double($1 - $0) / Double($0)) }
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

    static func key(_ name: String) -> String { name.split(separator: " ").first.map { $0.lowercased() } ?? name }

    static func historyEta(name: String, elapsedMin: Double, hist: [String: Double]) -> Int? {
        hist[key(name)].map { Int(max(0, $0 - elapsedMin)) }
    }

    /// Median minutes per first-word-of-name across done jobs. Run off the main thread.
    static func scanHistory() -> [String: Double] {
        let jd = NSHomeDirectory() + "/.claude/jobs"
        var by: [String: [Double]] = [:]
        for d in (try? FileManager.default.contentsOfDirectory(atPath: jd)) ?? [] {
            guard let sd = FileManager.default.contents(atPath: "\(jd)/\(d)/state.json"),
                  let s = try? JSONDecoder().decode(StateLite.self, from: sd), s.state == "done",
                  let name = s.name, let c = s.createdAt.flatMap(iso),
                  let td = FileManager.default.contents(atPath: "\(jd)/\(d)/timeline.jsonl"),
                  let txt = String(data: td, encoding: .utf8) else { continue }
            let lines = txt.split(separator: "\n").compactMap { try? JSONDecoder().decode(TL.self, from: Data($0.utf8)) }
            guard let last = lines.last(where: { ($0.text ?? "").hasPrefix("result:") }) ?? lines.last(where: { $0.state == "done" }),
                  let at = last.at.flatMap(iso) else { continue }
            let mins = at.timeIntervalSince(c) / 60
            if mins > 0 { by[key(name), default: []].append(mins) }
        }
        return by.mapValues { v in let s = v.sorted(); return s[s.count / 2] }
    }
}
