import Foundation
import Observation
import AppKit
import PeekCore

/// Where a session's hook ran: parent pid, controlling tty and the terminal env vars.
struct TermId: Equatable, Sendable { var pid = 0, tty = "", tp = "", bid = "", itsid = "" }

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
    var mirror: PromptMirror?
    var flash = ""
    var sid = ""
    var edit: FileDiff?
    var term = TermId()
    var lastT = 0.0
    var needsYou: Bool { state == "approval" || state == "input" }
}

struct Perm: Equatable, Sendable {
    var id: String; var tool: String; var target: String
    var headline = "", detail = "", allowAlways = true, allowLabel = "Allow", denyLabel = "Deny", always = ""
    var ask: AskQuestion?
    /// ExitPlanMode: this request's own plan text ("" when the hook did not carry it).
    var plan = ""
    var fromAgent = false
    var mono: Bool { tool == "Bash" || ["Edit", "Write", "NotebookEdit", "Read"].contains(tool) }
    var planCard: Bool { tool == "ExitPlanMode" && !plan.isEmpty }
    /// "Always" for an allow rule; the mode name ("Accept edits") when Always would switch permission mode.
    var alwaysButton: String { Hook.alwaysButton(always) }
}

/// Latest pointer position in screen coordinates (bottom-left origin), published at most 30 times a second
/// and only while the band or card is visible. The mascot's eyes read `location`.
@MainActor @Observable final class Pointer { var location = CGPoint.zero }

@MainActor @Observable final class Store {
    var jobs: [Job] = []
    var presence = Presence.hidden
    let pointer = Pointer()
    @ObservationIgnored private var level = Presence.hidden
    @ObservationIgnored private var inside = false
    var expanded = false
    var open = false
    /// Card held open by the hotkey (the pointer no longer decides).
    var pinned = false
    var diffOpen: String?
    var usage: PlanUsage?
    /// `PEEK_DEMO=1`: card forced open for screenshots.
    static let demo = ProcessInfo.processInfo.environment["PEEK_DEMO"] == "1"
    var alert: (kind: String, text: String)?
    @ObservationIgnored var popUntil = Date.distantPast
    @ObservationIgnored var popID = ""
    var bounceUntil = Date.distantPast
    var bounceTick = 0
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
        let p: Presence = open ? .home : level; if p != presence { presence = p }
    }
    var showFooter: Bool { expanded && (usage != nil || Sounds.muted) }
    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }
    /// Hotkey: pin the card open, or close it (a still pointer over the card reopens it on the next move).
    func toggleCard() {
        if open { inside = false; pinned = false; popUntil = .distantPast } else { pinned = true }
        stepLevel()
    }
    /// Pointer inside the hit area (notch or bar, band, or card, depending on `presence`).
    func setInside(_ v: Bool) { if v != inside { inside = v; stepLevel() } }
    private func stepLevel() {
        level = pinned ? .home : PresenceMachine.next(level, hasSessions: !jobs.isEmpty, inside: inside, demo: Store.demo)
        let e = level == .home; if e != expanded { expanded = e }
        syncOpen()
    }
    private func updateAlert() {
        func t(_ k: String, _ l: String) -> (kind: String, text: String, key: String)? {
            jobs.first { (k == "needs" ? $0.needsYou : $0.state == k) && !acked.contains("\($0.id)|\($0.state)") }
                .map { (k, "\(l) · \(SessionTitle.short($0.title, 24))", "\($0.id)|\($0.state)") }
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
        var mirrors: [PromptMirror] = []
        var compacting = false, ended = false
        var edit: FileDiff?
        var agents = 0
        var term = TermId()
        var lastT = 0.0, stopT = 0.0
    }
    @ObservationIgnored private var sess: [String: Sess] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var pending: [String: [PermRequest]] = [:]
    @ObservationIgnored private var lastState: [String: String] = [:]
    @ObservationIgnored private var titles: [String: (title: String, source: SessionTitle.Source)] = [:]
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
        // a subagent shares the session id but not its name, folder or first prompt
        let agent = o["agent_id"] as? String ?? ""
        if agent.isEmpty {
            if let c = o["cwd"] as? String, !c.isEmpty { s.cwd = c }
            if let p = (o["pid"] as? NSNumber)?.intValue, p > 0 { s.term.pid = p }
            for (k, kp) in [("tty", \TermId.tty), ("tp", \TermId.tp), ("bid", \TermId.bid), ("itsid", \TermId.itsid)] {
                if let v = o[k] as? String, !v.isEmpty { s.term[keyPath: kp] = v }
            }
            if let n = o["session_title"] as? String, !n.isEmpty { s.title = n }
        }
        let tool0 = o["tool_name"] as? String ?? ""
        s.mirrors.removeAll { PromptMirror.clears(ev: ev, tool: tool0, evAgent: agent, promptTool: $0.tool, promptAgent: $0.agent) }
        if let m = PromptMirror.make(o) { s.mirrors.removeAll { $0.tool == m.tool && $0.agent == m.agent }; s.mirrors.append(m) }
        switch ev {
        case "SessionStart": s.ended = false
        case "UserPromptSubmit":
            s.ended = false; s.state = "working"; s.tool = ""; s.last = ""; s.ntype = ""; s.msg = ""; s.recent = []; s.compacting = false; s.edit = nil
            if agent.isEmpty, s.prompt.isEmpty, let p = SessionTitle.prompt(o["prompt"] as? String ?? "") { s.prompt = p }
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
        // a later event of the same session means its terminal prompt was answered there: hang up and drop the card
        if let q = pending[sid], !q.isEmpty, ev != "PreToolUse" {
            let tool = o["tool_name"] as? String ?? ""
            let done = q.filter { $0.t < t && PromptMirror.clears(ev: ev, tool: tool, evAgent: agent, promptTool: $0.tool, promptAgent: $0.agent) }
            if !done.isEmpty {
                for r in done { r.answer("") }
                pending[sid] = q.filter { r in !done.contains { $0.id == r.id } }.nilIfEmpty
            }
        }
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
        return Perm(id: r.id, tool: r.tool, target: Store.toolLabel(r.tool, r.input), headline: (r.agent.isEmpty ? "" : "(subagent) ") + a.headline, detail: a.detail,
                    allowAlways: a.allowAlways && !r.always.isEmpty, allowLabel: a.allowLabel, denyLabel: a.denyLabel, always: r.always, ask: r.ask,
                    plan: r.tool == "ExitPlanMode" ? r.input["plan"] as? String ?? "" : "", fromAgent: !r.agent.isEmpty)
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
            let held = pending[sid] ?? []
            let perm = held.first.map(Store.perm)
            let heldTools = Set(held.map(\.tool))
            let mirror = perm == nil ? s.mirrors.filter { $0.visible(heldTools: heldTools, nowMs: nowMs) }.min { $0.t < $1.t } : nil
            guard perm != nil || (!s.ended && nowMs - s.lastT < 1_800_000) else { continue }
            let age = (nowMs - s.lastT) / 1000
            var st = s.state
            if perm != nil { st = "approval" }
            else if mirror != nil { st = "input" }
            else if Store.inputTypes.contains(s.ntype) { st = "input" }
            else if s.compacting { st = "compacting" }
            if st == "idle" || ((st == "done" || st == "failed") && nowMs - s.stopT > 60_000) { continue }
            let ph = st == "done" || st == "failed" ? st : Store.phase(s.recent)
            let status = statusFile(sid)
            let lastSentence = SessionTitle.sentence(s.last, 60)
            let t = SessionTitle.pick(name: status.name.isEmpty ? s.title : status.name, prompt: s.prompt, cwdBase: Eta.base(s.cwd), previous: titles[sid])
            titles[sid] = t
            // idle prompt: say what it is waiting for instead of the generic message
            let waiting = s.ntype == "idle_prompt" && !lastSentence.isEmpty ? lastSentence : Eta.clean(s.msg, 8)
            rows.append(Job(id: sid, title: t.title, state: st, phase: ph,
                            pct: Eta.pct(phase: ph, detail: s.last), ask: "", project: Eta.base(s.cwd), doing: lastSentence, agents: s.agents,
                            stuck: st == "working" && age > 120, tool: s.tool, ctxPct: status.ctx, compacting: s.compacting,
                            ntype: s.ntype, ask2: waiting, perm: perm, mirror: mirror, flash: flashes[sid].map { $0.0 } ?? "", sid: sid, edit: s.edit, term: s.term, lastT: s.lastT))
            // further held requests of the same session wait behind the first, oldest first
            for (n, r) in held.dropFirst().enumerated() {
                rows.append(Job(id: "\(sid)~\(n + 2)", title: t.title, state: "approval", phase: ph, pct: 0, ask: "", project: Eta.base(s.cwd), perm: Store.perm(r),
                                sid: sid, term: s.term, lastT: s.lastT))
            }
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
                        Sounds.play(snd)
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
        stepLevel()
    }
}

private extension Array { var nilIfEmpty: [Element]? { isEmpty ? nil : self } }

/// Event sounds: `~/.peek/sounds/<event>.{wav,aiff,caf,m4a,mp3}` first, then the bundled WAV, then a system sound.
@MainActor @Observable final class Sounds {
    // Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/SoundEngine.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
    nonisolated static let extensions = ["wav", "aiff", "caf", "m4a", "mp3"]
    private static let fallback = ["needs": "Ping", "done": "Glass", "fail": "Basso"]
    private static let shared = Sounds()
    private var mutedFlag = UserDefaults.standard.bool(forKey: "muted")
    private var cache: [String: NSSound] = [:]
    /// UserDefaults key `muted`. Reads are observed, so the card footer follows it.
    static var muted: Bool {
        get { shared.mutedFlag }
        set { shared.mutedFlag = newValue; UserDefaults.standard.set(newValue, forKey: "muted") }
    }

    nonisolated static func customURL(_ name: String) -> URL? {
        for ext in extensions {
            let u = URL(fileURLWithPath: PeekPaths.sounds).appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.isReadableFile(atPath: u.path) { return u }
        }
        return nil
    }
    private func sound(_ n: String) -> NSSound? {
        let custom = Sounds.customURL(n)
        let key = custom?.path ?? n
        if let s = cache[key] { return s }
        let s = custom.flatMap { NSSound(contentsOf: $0, byReference: true) }  // an undecodable file falls through to the bundled one
            ?? Bundle.module.url(forResource: n, withExtension: "wav", subdirectory: "Sounds").flatMap { NSSound(contentsOf: $0, byReference: true) }
            ?? Sounds.fallback[n].flatMap { NSSound(named: $0) }
        cache[key] = s
        return s
    }
    /// `preview` plays even while muted (the Settings play button).
    static func play(_ n: String, preview: Bool = false) {
        guard preview || !muted else { return }
        let s = shared.sound(n); s?.stop(); s?.play()
    }
}
