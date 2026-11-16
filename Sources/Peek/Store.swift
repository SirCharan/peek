import Foundation
import Observation
import AppKit
import PeekCore

struct Job: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var state: String
    var phase: String
    var pct: Int
    var ask: String
    var project = ""
    var doing = ""
    var agents = 0
    var stuck = false
    var tool = ""
    var ctxPct: Int?
    var compacting = false
    var ntype = ""
    var ask2 = ""
    var perm: Perm?
    var flash = ""
    var sid = ""
    var edit: FileDiff?
    var needsYou: Bool { state == "approval" || state == "input" }
}

struct Perm: Equatable, Sendable {
    var id: String; var tool: String; var target: String
    var headline = "", detail = "", allowAlways = true, allowLabel = "Allow", denyLabel = "Deny", always = ""
    var ask: AskQuestion?
    var mono: Bool { tool == "Bash" || ["Edit", "Write", "NotebookEdit", "Read"].contains(tool) }
    var tall: Bool { tool == "ExitPlanMode" && detail.count > 55 }
}

@MainActor @Observable final class Store {
    var jobs: [Job] = []
    var expanded = false
    var open = false
    var diffOpen: String?
    var usage: PlanUsage?
    var alert: (kind: String, text: String)?
    @ObservationIgnored var popUntil = Date.distantPast
    @ObservationIgnored var popID = ""
    var bounceUntil = Date.distantPast
    var bounceTick = 0
    private static let fallback = ["needs": "Ping", "done": "Glass", "fail": "Basso"]
    private static var sounds: [String: NSSound] = [:]
    static func sound(_ n: String) -> NSSound? {
        if let s = sounds[n] { return s }
        let s = Bundle.module.url(forResource: n, withExtension: "wav", subdirectory: "Sounds")
            .flatMap { NSSound(contentsOf: $0, byReference: true) } ?? fallback[n].flatMap { NSSound(named: $0) }
        sounds[n] = s
        return s
    }
    static func play(_ n: String) { sound(n)?.stop(); sound(n)?.play() }
    /// overall state for the buddy glyph
    var buddy: String {
        if jobs.contains(where: { $0.needsYou }) { return "needs" }
        if jobs.contains(where: { $0.state == "failed" }) { return "failed" }
        if jobs.contains(where: { $0.state == "done" }) { return "done" }
        if jobs.contains(where: { $0.state == "compacting" }) { return "compacting" }
        return running > 0 ? "working" : "idle"
    }
    var shown: [Job] { !expanded && open ? (jobs.contains { $0.id == popID } ? jobs.filter { $0.id == popID } : jobs) : jobs }
    @ObservationIgnored private var acked: Set<String> = []
    @ObservationIgnored private var alertKey: String?
    var alertJobID: String? { alertKey?.split(separator: "|").first.map(String.init) }
    func syncOpen() {
        if expanded, let k = alertKey, acked.insert(k).inserted { updateAlert() }
        let o = expanded || Date() < popUntil; if o != open { open = o }
        if !expanded && diffOpen != nil { diffOpen = nil }
    }
    private func updateAlert() {
        func t(_ k: String, _ l: String) -> (kind: String, text: String, key: String)? {
            jobs.first { (k == "needs" ? $0.needsYou : $0.state == k) && !acked.contains("\($0.id)|\($0.state)") }
                .map { (k, "\(l) · \($0.title.prefix(18))", "\($0.id)|\($0.state)") }
        }
        let al = t("needs", "NEEDS YOU") ?? t("done", "DONE") ?? t("failed", "FAILED")
        alertKey = al?.key
        let v = al.map { (kind: $0.kind, text: $0.text) }
        if v?.kind != alert?.kind || v?.text != alert?.text { alert = v }
    }

    /// Everything the rows need, folded from one session's events.
    private struct Sess {
        var cwd = "", title = "", prompt = "", state = "idle", tool = "", last = "", ntype = "", msg = ""
        var recent: [String] = []
        var compacting = false, ended = false
        var edit: FileDiff?
        var agents = 0, pid = 0
        var lastT = 0.0, stopT = 0.0
    }
    @ObservationIgnored private var sess: [String: Sess] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var pending: [String: [PermRequest]] = [:]
    @ObservationIgnored private var lastState: [String: String] = [:]
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var server: Server?

    private static let inputTypes: Set<String> = ["idle_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog", "permission_prompt"]
    private static let reads: Set<String> = ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "LS"]
    private static let edits: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// "Edit main.swift", "Bash npm test", "Read Store.swift"
    private static func toolLabel(_ tool: String, _ i: [String: Any]) -> String {
        func s(_ k: String) -> String { i[k] as? String ?? "" }
        let tg: String
        if !s("file_path").isEmpty { tg = (s("file_path") as NSString).lastPathComponent }
        else if !s("notebook_path").isEmpty { tg = (s("notebook_path") as NSString).lastPathComponent }
        else if tool == "Bash" { tg = Eta.bash(s("command")) }
        else if !s("pattern").isEmpty { tg = s("pattern") }
        else if !s("url").isEmpty { tg = URL(string: s("url"))?.host ?? s("url") }
        else { tg = s("query").isEmpty ? s("description") : s("query") }
        return tg.isEmpty ? tool : "\(tool) \(String(tg.prefix(40)))"
    }

    private static func phase(_ recent: [String]) -> String {
        guard let last = recent.last else { return "starting" }
        if last.hasPrefix("Bash "), last.firstMatch(of: /(?i)test|build|lint|tsc|pytest/) != nil { return "verify" }
        let names = recent.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        if names.filter({ reads.contains($0) }).count * 2 > names.count { return "plan" }
        return "build"
    }

    private func fold(_ o: [String: Any], _ sid: String, rewound: Bool) {
        guard let ev = o["ev"] as? String, let t = (o["t"] as? NSNumber)?.doubleValue else { return }
        var s = sess[sid] ?? Sess()
        if rewound && t <= s.lastT { return }  // file was trimmed and re-read: skip what we already folded
        s.lastT = max(s.lastT, t)
        if let c = o["cwd"] as? String, !c.isEmpty { s.cwd = c }
        if let p = (o["pid"] as? NSNumber)?.intValue, p > 0 { s.pid = p }
        if let n = o["session_title"] as? String, !n.isEmpty { s.title = n }
        switch ev {
        case "SessionStart": s.ended = false
        case "UserPromptSubmit":
            s.ended = false; s.state = "working"; s.tool = ""; s.last = ""; s.ntype = ""; s.msg = ""; s.recent = []; s.compacting = false; s.edit = nil
            if s.prompt.isEmpty { s.prompt = o["prompt"] as? String ?? "" }
        case "PreToolUse":
            let tool = o["tool_name"] as? String ?? "", label = Store.toolLabel(tool, o["tool_input"] as? [String: Any] ?? [:])
            s.state = "working"; s.tool = label; s.ntype = ""; s.msg = ""; s.edit = nil
            s.recent = Array((s.recent + [label]).suffix(10))
        case "PostToolUse", "PostToolUseFailure":
            s.state = "working"; s.tool = ""; s.ntype = ""; s.msg = ""
            s.edit = ev == "PostToolUse" ? DiffEngine.forTool(o["tool_name"] as? String ?? "", o["tool_input"] as? [String: Any] ?? [:]) : nil
        case "Notification": s.ntype = o["notification_type"] as? String ?? ""; s.msg = o["message"] as? String ?? ""
        case "PreCompact": s.compacting = true
        case "PostCompact": s.compacting = false
        case "SubagentStart": s.agents += 1
        case "SubagentStop": s.agents = max(0, s.agents - 1)
        case "Stop": s.state = "done"; s.stopT = t; s.tool = ""; s.ntype = ""; s.msg = ""; s.agents = 0; s.compacting = false; s.edit = nil; s.last = o["last_assistant_message"] as? String ?? ""
        case "StopFailure": s.state = "failed"; s.stopT = t; s.tool = ""; s.agents = 0; s.compacting = false
        case "SessionEnd": s.ended = true
        default: break
        }
        sess[sid] = s
    }

    /// Tails ~/.peek/events/*.jsonl by byte offset; a launch re-read from 0 rebuilds the same state.
    private func tailEvents() {
        let fm = FileManager.default, dir = PeekPaths.events
        for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") {
            let path = "\(dir)/\(n)", sid = String(n.dropLast(6))
            guard let at = try? fm.attributesOfItem(atPath: path), let size = at[.size] as? UInt64 else { continue }
            var off = offsets[path] ?? 0, rewound = false
            if size < off { off = 0; rewound = true }  // the hook trimmed the file
            if offsets[path] == nil, let m = at[.modificationDate] as? Date, Date().timeIntervalSince(m) > 1800 { offsets[path] = size; continue }  // cold file: no row to show
            guard size > off, let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: off)
            guard let data = try? fh.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }  // whole lines only
            offsets[path] = off + UInt64(end - data.startIndex + 1)
            for l in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
                if let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any] { fold(o, sid, rewound: rewound) }
            }
        }
    }

    private func statusFile(_ sid: String) -> (ctx: Int?, name: String) {
        guard let d = FileManager.default.contents(atPath: "\(PeekPaths.status)/\(sid).json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, "") }
        return ((o["ctx"] as? NSNumber)?.intValue, o["session_name"] as? String ?? "")
    }

    /// Freshest rate_limits across every session's status file.
    private func readUsage() -> PlanUsage? {
        let dir = PeekPaths.status
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { n -> PlanUsage? in
            guard let d = FileManager.default.contents(atPath: "\(dir)/\(n)"),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return Usage.parse(o)
        }
        return Usage.freshest(all)
    }

    private static func perm(_ r: PermRequest) -> Perm {
        let a = Eta.approval(r.tool, r.input)
        return Perm(id: r.id, tool: r.tool, target: Store.toolLabel(r.tool, r.input), headline: a.headline, detail: a.detail,
                    allowAlways: a.allowAlways && !r.always.isEmpty, allowLabel: a.allowLabel, denyLabel: a.denyLabel, always: r.always, ask: r.ask)
    }

    private func gone(_ id: String) {
        for (sid, q) in pending where q.contains(where: { $0.id == id }) { pending[sid] = q.filter { $0.id != id }.nilIfEmpty }
        refresh()
    }
    private func arrived(_ r: PermRequest) {
        pending[r.sid, default: []].append(r)
        var s = sess[r.sid] ?? Sess()
        if s.cwd.isEmpty { s.cwd = r.cwd }
        s.lastT = max(s.lastT, Date().timeIntervalSince1970 * 1000)
        sess[r.sid] = s
        refresh()
    }

    @ObservationIgnored private var flashes: [String: (String, Date)] = [:]
    func reply(_ j: Job, _ verb: String) {
        guard let p = j.perm, let r = pending[j.sid]?.first(where: { $0.id == p.id }) else { return }
        if verb == "open" { r.answer(""); Focus.jump(j, store: self); refresh(); return }  // hang up: Claude Code shows its own dialog
        let (body, label) = verb == "allow" ? ("allow", "allowed") : verb == "deny" ? ("deny:denied from notch", "denied")
            : verb.hasPrefix("deny:") ? (verb, "denied") : verb.hasPrefix("{") ? (verb, "answered") : ("always", "allowed")
        r.answer(body)
        pending[j.sid] = pending[j.sid]?.filter { $0.id != r.id }.nilIfEmpty
        flashes[j.id] = (label, Date().addingTimeInterval(3))
        refresh()
    }
    func flash(_ id: String, _ text: String, secs: Double = 3) {
        flashes[id] = (text, Date().addingTimeInterval(secs)); refresh()
    }
    var replying: String?

    var running: Int { jobs.filter { $0.state == "working" || $0.needsYou }.count }
    var dotKind: String {
        if jobs.contains(where: { $0.needsYou }) { return "blocked" }
        if jobs.contains(where: { $0.state == "failed" }) { return "failed" }
        return running > 0 ? "working" : "idle"
    }
    var summary: String {
        let b = jobs.filter { $0.needsYou }.count, w = jobs.filter { $0.state == "working" }.count
        var p: [String] = []
        if b > 0 { p.append("\(b) needs you") }
        if w > 0 { p.append("\(w) running") }
        return p.isEmpty ? "idle" : p.joined(separator: " · ")
    }

    init() {
        let nudge: @Sendable () -> Void = { Task { @MainActor in self.refresh() } }
        server = Server(onNudge: nudge, onPermission: { r in Task { @MainActor in self.arrived(r) } }, onGone: { id in Task { @MainActor in self.gone(id) } })
        server?.start()
        refresh()
        // slow fallback so a missed nudge self-heals (and done rows expire)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    func refresh() {
        let now = Date(), nowMs = now.timeIntervalSince1970 * 1000
        tailEvents()
        flashes = flashes.filter { $0.value.1 > now }
        var rows: [Job] = []
        for (sid, s) in sess {
            let perm = pending[sid]?.first.map(Store.perm)
            guard perm != nil || (!s.ended && nowMs - s.lastT < 1_800_000) else { continue }
            let age = (nowMs - s.lastT) / 1000
            var st = s.state
            if perm != nil { st = "approval" }
            else if Store.inputTypes.contains(s.ntype) { st = "input" }
            else if s.compacting { st = "compacting" }
            if st == "idle" || ((st == "done" || st == "failed") && nowMs - s.stopT > 60_000) { continue }
            let ph = st == "done" || st == "failed" ? st : Store.phase(s.recent)
            let status = statusFile(sid)
            let lastSentence = s.last.split(whereSeparator: { ".!?\n".contains($0) }).first.map { Eta.clean(String($0), 12) } ?? ""
            rows.append(Job(id: sid, title: Eta.title(name: s.title.isEmpty ? status.name : s.title, text: s.prompt, cwd: s.cwd), state: st, phase: ph,
                            pct: Eta.pct(phase: ph, detail: s.last), ask: "", project: Eta.base(s.cwd), doing: lastSentence, agents: s.agents,
                            stuck: st == "working" && age > 120, tool: s.tool, ctxPct: status.ctx, compacting: s.compacting,
                            ntype: s.ntype, ask2: Eta.clean(s.msg, 8), perm: perm, flash: flashes[sid].map { $0.0 } ?? "", sid: sid, edit: s.edit))
        }

        func w(_ j: Job) -> Int { j.needsYou ? 0 : j.state == "working" ? 1 : 2 }
        rows.sort { (w($0), $0.id) < (w($1), $1.id) }
        var fired: [(Job, String)] = []
        for j in rows where lastState[j.id] != j.state {
            let snd = j.needsYou ? "needs" : j.state == "done" ? "done" : j.state == "failed" ? "fail" : nil
            if seeded, let snd { fired.append((j, snd)) }
            lastState[j.id] = j.state
        }
        if !fired.isEmpty {
            Task {
                for (j, snd) in fired {
                    let front = await Focus.isFront(j)
                    FileHandle.standardError.write(Data("alert: \(j.title) front=\(front)\n".utf8))
                    if front {
                        FileHandle.standardError.write(Data("alert: front→bounce\n".utf8))
                        bounceUntil = Date().addingTimeInterval(0.9); bounceTick += 1
                    } else {
                        Store.play(snd)
                        popUntil = Date().addingTimeInterval(4); popID = j.id
                    }
                }
                syncOpen()
            }
        }
        seeded = true
        if rows != jobs { jobs = rows }
        let u = readUsage(); if u != usage { usage = u }
        acked = acked.filter { k in rows.contains { k.hasPrefix($0.id + "|") } }
        updateAlert()
        syncOpen()
    }
}

private extension Array { var nilIfEmpty: [Element]? { isEmpty ? nil : self } }
