import Foundation

/// Everything lives under `~/.peek` (HOME honoured so tests can use a fake home).
public enum PeekPaths {
    public static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    public static var dir: String { home + "/.peek" }
    public static var events: String { dir + "/events" }
    public static var status: String { dir + "/status" }
    public static var sock: String { dir + "/peek.sock" }
    public static var sounds: String { dir + "/sounds" }
    public static var prevStatusline: String { dir + "/prev-statusline" }
}

public enum Hook {
    static let bigCap = 20_000

    static func cap(_ s: String, _ n: Int) -> String { String(s.prefix(n)) }
    static func capBytes(_ s: String, _ n: Int) -> String {
        s.utf8.count <= n ? s : String(decoding: s.utf8.prefix(n), as: UTF8.self)
    }

    /// Session ids become file names; refuse anything that could escape the directory.
    public static func safeSid(_ s: Any?) -> String? {
        guard let s = s as? String, !s.isEmpty, s.count <= 128,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return s
    }

    static func trimInput(_ tool: String, _ i: [String: Any]) -> [String: Any] {
        var o: [String: Any] = [:]
        for k in ["file_path", "notebook_path", "pattern", "url", "query", "path"] { if let s = i[k] as? String { o[k] = cap(s, 300) } }
        for k in ["command", "description"] { if let s = i[k] as? String { o[k] = cap(s, 120) } }
        if tool == "AskUserQuestion", let q = i["questions"], let d = try? JSONSerialization.data(withJSONObject: q), d.count < 16_000 { o["questions"] = q }
        guard ["Edit", "Write", "MultiEdit"].contains(tool) else { return o }
        for k in ["old_string", "new_string", "content"] { if let s = i[k] as? String { o[k] = capBytes(s, bigCap) } }
        if let es = i["edits"] as? [[String: Any]] {
            var kept: [[String: Any]] = [], size = 0
            for e in es {
                var t: [String: Any] = [:]
                for k in ["old_string", "new_string"] { if let s = e[k] as? String { t[k] = capBytes(s, bigCap) } }
                if let r = e["replace_all"] as? Bool { t["replace_all"] = r }
                size += ((t["old_string"] as? String)?.utf8.count ?? 0) + ((t["new_string"] as? String)?.utf8.count ?? 0)
                if size > bigCap, !kept.isEmpty { break }
                kept.append(t)
            }
            o["edits"] = kept
            if kept.count < es.count { o["edits_dropped"] = es.count - kept.count }
        }
        return o
    }

    /// Compact event record for the events file (and the socket). nil when the payload has no usable session id or event name.
    public static func event(_ raw: [String: Any], pid: Int32, tty: String, env: [String: String] = [:], now: Date = Date()) -> [String: Any]? {
        guard let sid = safeSid(raw["session_id"]), let ev = raw["hook_event_name"] as? String, !ev.isEmpty else { return nil }
        var o: [String: Any] = ["t": Int(now.timeIntervalSince1970 * 1000), "ev": ev, "sid": sid, "pid": Int(pid), "tty": tty]
        if let c = raw["cwd"] as? String { o["cwd"] = c }
        for (k, e) in [("tp", "TERM_PROGRAM"), ("bid", "__CFBundleIdentifier"), ("itsid", "ITERM_SESSION_ID")] {
            if let v = env[e], !v.isEmpty { o[k] = cap(v, 64) }
        }
        if let t = raw["tool_name"] as? String {
            o["tool_name"] = t
            o["tool_input"] = trimInput(t, raw["tool_input"] as? [String: Any] ?? [:])
        }
        if let s = raw["last_assistant_message"] as? String { o["last_assistant_message"] = cap(s, 400) }
        if let s = raw["prompt"] as? String { o["prompt"] = cap(s, 200) }
        if let s = raw["session_title"] as? String, !s.isEmpty { o["session_title"] = cap(s, 200) }
        if let s = raw["notification_type"] as? String { o["notification_type"] = s }
        if let s = raw["message"] as? String { o["message"] = cap(s, 200) }
        if let s = raw["agent_id"] as? String { o["agent_id"] = s }
        return o
    }

    public static func line(_ o: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// The one permission suggestion that "Always" applies: the first allow-rule (else the first mode change), echoed verbatim
    /// as `updatedPermissions`. `label` is a short description for the button tooltip. nil = no Always for this request.
    public static func always(_ suggestions: [[String: Any]]) -> (update: [String: Any], label: String)? {
        let pick = suggestions.first { $0["type"] as? String == "addRules" && $0["behavior"] as? String == "allow" }
            ?? suggestions.first { $0["type"] as? String == "setMode" }
        guard let u = pick else { return nil }
        if u["type"] as? String == "setMode" { return (u, "switch to \(u["mode"] as? String ?? "?") mode") }
        let rules = (u["rules"] as? [[String: Any]] ?? []).compactMap { r -> String? in
            guard let t = r["toolName"] as? String else { return nil }
            return (r["ruleContent"] as? String).map { "\(t)(\($0))" } ?? t
        }
        guard !rules.isEmpty else { return nil }
        return (u, "always allow " + rules.joined(separator: ", "))
    }

    /// Button text for the `always` label: "Always" for an allow rule, the mode itself ("Accept edits") for a mode switch.
    public static func alwaysButton(_ label: String) -> String {
        guard label.hasPrefix("switch to "), label.hasSuffix(" mode") else { return "Always" }
        var words = ""
        for ch in label.dropFirst(10).dropLast(5) { words += ch.isUppercase ? " " + ch.lowercased() : String(ch) }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Reply verbs: `allow`, `always`, `deny` or `deny:<reason>`. nil = no decision (Claude Code shows its own dialog).
    /// `always` becomes allow plus `updatedPermissions` (only when `always` is given, else a plain allow).
    /// ExitPlanMode and AskUserQuestion need `updatedInput` with an allow, so the original input is echoed.
    public static func decision(_ reply: String, tool: String = "", rawInput: [String: Any] = [:], always: [String: Any]? = nil) -> String? {
        var d: [String: Any]
        switch reply {
        case "allow", "always":
            d = ["behavior": "allow"]
            if tool == "ExitPlanMode" || tool == "AskUserQuestion" { d["updatedInput"] = rawInput }
            if reply == "always", let always { d["updatedPermissions"] = [always] }
        case _ where reply == "deny" || reply.hasPrefix("deny:"):
            let m = reply.hasPrefix("deny:") ? String(reply.dropFirst(5)) : ""
            d = ["behavior": "deny", "message": m.isEmpty ? "Denied from the notch" : m]
        default: return nil
        }
        return line(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]])
    }

    /// `--ask` output: allow the AskUserQuestion call with the original questions plus the answers the app sent.
    public static func askOutput(questions: [[String: Any]], reply: String) -> String? {
        guard let a = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any], !a.isEmpty else { return nil }
        return line(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                            "updatedInput": ["questions": questions, "answers": a]]])
    }

    /// Statusline stdin -> the small record the app reads from `~/.peek/status/<sid>.json`.
    public static func status(_ raw: [String: Any], now: Date = Date()) -> (sid: String, json: Data)? {
        guard let sid = safeSid(raw["session_id"]) else { return nil }
        var o: [String: Any] = ["t": Int(now.timeIntervalSince1970 * 1000)]
        if let p = ((raw["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue { o["ctx"] = Int(p.rounded()) }
        if let n = raw["session_name"] as? String, !n.isEmpty { o["session_name"] = n }
        if let r = raw["rate_limits"] as? [String: Any] {
            let keep = r.filter { $0.key == "five_hour" || $0.key == "seven_day" }
            if !keep.isEmpty { o["rate_limits"] = keep }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return nil }
        return (sid, d)
    }
}

/// Minimal blocking Unix-socket client shared by `peek-hook`.
public enum PeekSocket {
    public static func connect(_ path: String, timeout: TimeInterval) -> Int32? {
        guard path.utf8.count < MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let c = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in c.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    public static func send(_ fd: Int32, _ text: String) -> Bool {
        let b = Array((text + "\n").utf8)
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// First reply line, or nil on EOF / error / timeout.
    public static func readLine(_ fd: Int32, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(), buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let ms = Int32(max(0, min(deadline.timeIntervalSinceNow, 3600)) * 1000)
            if ms == 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, ms)
            if r < 0 { if errno == EINTR { continue }; return nil }
            if r == 0 { return nil }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
            if let i = data.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: data[data.startIndex..<i], as: UTF8.self)
            }
        }
    }
}
