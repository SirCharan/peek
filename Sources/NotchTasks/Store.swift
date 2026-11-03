import Foundation
import Observation
import AppKit

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
}

private struct Ev { var tool = "", ntype = "", msg = "", last = "", compacting = false }

// ponytail: tolerant text field — any non-string value decodes to nil instead of failing the file
private struct Txt: Decodable {
    let s: String?
    init(from d: Decoder) throws { s = try? d.singleValueContainer().decode(String.self) }
}
private struct Fan: Decodable { let kind: String?; let label: String?; let startedAt: Double? }
private struct JobFile: Decodable {
    let state: String, name: String, createdAt: String, updatedAt: String
    let detail: Txt?, needs: Txt?, intent: Txt?
    let cwd: String?, sessionId: String?
    let fan: [Fan]?
}
private struct SessionFile: Decodable {
    let pid: Int?, status: String?, statusUpdatedAt: Double?, kind: String?, name: String?, jobId: String?, spare: Bool?, startedAt: Double?, cwd: String?, sessionId: String?
}

@MainActor @Observable final class Store {
    var jobs: [Job] = []
    var expanded = false
    var open = false
    var alert: (kind: String, text: String)?
    @ObservationIgnored var popUntil = Date.distantPast
    @ObservationIgnored var popID = ""
    var shown: [Job] { !expanded && open ? (jobs.contains { $0.id == popID } ? jobs.filter { $0.id == popID } : jobs) : jobs }
    @ObservationIgnored private var acked: Set<String> = []
    @ObservationIgnored private var alertKey: String?
    var alertJobID: String? { alertKey?.split(separator: "|").first.map(String.init) }
    func syncOpen() {
        if expanded, let k = alertKey, acked.insert(k).inserted { updateAlert() }
        let o = expanded || Date() < popUntil; if o != open { open = o }
    }
    private func updateAlert() {
        func t(_ k: String, _ l: String) -> (kind: String, text: String, key: String)? {
            jobs.first { $0.state == k && !acked.contains("\($0.id)|\($0.state)") }
                .map { (k == "blocked" ? "needs" : k, "\(l) · \($0.title.prefix(18))", "\($0.id)|\($0.state)") }
        }
        let al = t("blocked", "NEEDS YOU") ?? t("done", "DONE") ?? t("failed", "FAILED")
        alertKey = al?.key
        let v = al.map { (kind: $0.kind, text: $0.text) }
        if v?.kind != alert?.kind || v?.text != alert?.text { alert = v }
    }

    @ObservationIgnored private var cache: [String: (Date, JobFile?)] = [:]
    @ObservationIgnored private let haiku = HaikuCache()
    @ObservationIgnored private var firstMsg: [String: String] = [:]
    @ObservationIgnored private var lastState: [String: String] = [:]
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var startDetail: [String: String] = [:]
    @ObservationIgnored private var evOffset: [String: UInt64] = [:]
    @ObservationIgnored private var evBySid: [String: Ev] = [:]

    /// Tails ~/.claude/notch-events/*.jsonl by byte offset and folds new lines into per-session state.
    private func tailEvents(_ dir: String) {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") {
            let path = "\(dir)/\(n)", sid = String(n.dropLast(6))
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
            var off = evOffset[path] ?? 0
            if size < off { off = 0 }  // hook truncated the file
            guard size > off, let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: off)
            guard let data = try? fh.readToEnd() else { continue }
            // only consume complete lines
            guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            evOffset[path] = off + UInt64(end - data.startIndex + 1)
            var e = evBySid[sid] ?? Ev()
            for l in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any], let ev = o["ev"] as? String else { continue }
                let tool = o["tool"] as? String ?? "", target = o["target"] as? String ?? ""
                switch ev {
                case "PreToolUse": e.tool = target.isEmpty ? tool : "\(tool) \(target)"
                case "PostToolUse", "Stop", "UserPromptSubmit":
                    e.tool = ""
                    if ev == "Stop" { e.last = o["last"] as? String ?? "" }
                    if ev != "PostToolUse" { e.ntype = ""; e.msg = "" }
                case "Notification": e.ntype = o["ntype"] as? String ?? ""; e.msg = o["msg"] as? String ?? ""
                case "PreCompact": e.compacting = true
                case "PostCompact": e.compacting = false
                default: break
                }
            }
            evBySid[sid] = e
        }
    }
    private func ctxPct(_ sid: String?, _ home: String) -> Int? {
        guard let sid, let s = try? String(contentsOfFile: "\(home)/.claude/notch-events/ctx/\(sid)", encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var running: Int { jobs.filter { $0.state == "working" || $0.state == "blocked" }.count }
    var dotKind: String {
        if jobs.contains(where: { $0.state == "blocked" }) { return "blocked" }
        if jobs.contains(where: { $0.state == "failed" }) { return "failed" }
        return running > 0 ? "working" : "idle"
    }
    var summary: String {
        let b = jobs.filter { $0.state == "blocked" }.count, w = jobs.filter { $0.state == "working" }.count
        var p: [String] = []
        if b > 0 { p.append("\(b) needs you") }
        if w > 0 { p.append("\(w) running") }
        return p.isEmpty ? "idle" : p.joined(separator: " · ")
    }

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    private func load(_ path: String) -> JobFile? {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let c = cache[path], c.0 == m { return c.1 }
        let f = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(JobFile.self, from: $0) }
        cache[path] = (m, f)
        return f
    }

    func refresh() {
        let now = Date()
        let fm = FileManager.default
        let home = NSHomeDirectory()

        struct Sess { let status: String; let at: Double }
        var sessByJob: [String: Sess] = [:], sessBySid: [String: Sess] = [:]
        var sessions: [SessionFile] = []
        let sd = home + "/.claude/sessions"
        for n in (try? fm.contentsOfDirectory(atPath: sd)) ?? [] where n.hasSuffix(".json") {
            guard let data = fm.contents(atPath: "\(sd)/\(n)"),
                  let s = try? JSONDecoder().decode(SessionFile.self, from: data),
                  s.spare != true, let pid = s.pid, kill(Int32(pid), 0) == 0 else { continue }
            sessions.append(s)
            let v = Sess(status: s.status ?? "", at: (s.statusUpdatedAt ?? 0) / 1000)
            if let j = s.jobId { sessByJob[j] = v }
            if let sid = s.sessionId { sessBySid[sid] = v }
        }

        tailEvents(home + "/.claude/notch-events")
        var rows: [Job] = []
        var rowIDs = Set<String>(), known = Set<String>()
        let jd = home + "/.claude/jobs"
        for d in (try? fm.contentsOfDirectory(atPath: jd)) ?? [] {
            guard let f = load("\(jd)/\(d)/state.json"),
                  let updated = Eta.iso(f.updatedAt) else { continue }
            known.insert(d)
            let sess = sessByJob[d] ?? f.sessionId.flatMap { sessBySid[$0] }
            var st = f.state
            if let sess {
                if sess.status == "busy" { st = "working" } else if sess.status == "waiting" { st = "blocked" }
            }
            let last = max(updated.timeIntervalSince1970, sess?.at ?? 0)
            let age = now.timeIntervalSince1970 - last
            let show = (st == "working" && age < 900) || (st == "blocked" && age < 7200)
                || ((st == "done" || st == "failed") && age < 60)
            guard show else { continue }
            let detail = f.detail?.s ?? ""
            let newest = (f.fan ?? []).max { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }?.label ?? ""
            let text = detail.isEmpty ? newest : detail
            let override = st == "working" && f.state != "working"
            if override { if startDetail[d] == nil { startDetail[d] = detail } } else { startDetail[d] = nil }
            let starting = override && startDetail[d] == detail
            let phase = starting ? "starting" : Eta.phase(state: st, text: text)
            let needs = f.needs?.s ?? ""
            var doing = Eta.clean(text), ask = ""
            if st == "working", !text.isEmpty {
                let src = String(text.prefix(300))
                haiku.request(id: d, key: src, prompt: "A coding task reports: \"\(src)\". Rewrite as one plain phrase under 8 words for a non-technical status board, present tense, no file names, paths, commands or code. Reply with the phrase only.")
                doing = haiku.get(d, src) ?? doing
            } else if st == "blocked" {
                let src = String(needs.prefix(300))
                ask = Eta.clean(needs, 8)
                if !src.isEmpty {
                    haiku.request(id: d, key: src, prompt: "A coding task is waiting on its user and says it needs: \"\(src)\". Rewrite as one plain question under 8 words. Reply with the question only.")
                    ask = haiku.get(d, src) ?? ask
                }
            }
            rows.append(Job(id: d, title: Eta.title(name: f.name, text: f.intent?.s ?? "", cwd: f.cwd), state: st, phase: phase,
                            pct: starting ? 5 : Eta.pct(phase: phase, detail: detail),
                            ask: ask, project: Eta.base(f.cwd), doing: doing,
                            agents: (f.fan ?? []).filter { $0.kind == "agent" }.count,
                            stuck: st == "working" && age > 120,
                            tool: f.sessionId.flatMap { evBySid[$0]?.tool } ?? "",
                            ctxPct: ctxPct(f.sessionId, home),
                            compacting: f.sessionId.flatMap { evBySid[$0]?.compacting } ?? false,
                            ntype: f.sessionId.flatMap { evBySid[$0]?.ntype } ?? ""))
            rowIDs.insert(d)
        }

        for s in sessions where s.status == "busy" || s.status == "waiting" {
            guard let pid = s.pid else { continue }
            if let j = s.jobId {
                if rowIDs.contains(j) { continue }
                if s.kind == "bg" && known.contains(j) { continue }
            }
            let cwd = s.cwd ?? ""
            var msg = ""
            if let sid = s.sessionId, Eta.hashLike(s.name ?? "") {
                if let c = firstMsg[sid] { msg = c } else { msg = Eta.firstUser(sessionId: sid, cwd: cwd); firstMsg[sid] = msg }
            }
            rows.append(Job(id: "s\(pid)", title: Eta.title(name: s.name ?? "", text: msg, cwd: cwd), state: s.status == "waiting" ? "blocked" : "working", phase: s.status == "waiting" ? "blocked" : "working",
                            pct: 50, ask: "", project: Eta.base(cwd),
                            tool: s.sessionId.flatMap { evBySid[$0]?.tool } ?? "",
                            ctxPct: ctxPct(s.sessionId, home),
                            compacting: s.sessionId.flatMap { evBySid[$0]?.compacting } ?? false,
                            ntype: s.sessionId.flatMap { evBySid[$0]?.ntype } ?? ""))
        }

        func w(_ j: Job) -> Int { j.state == "blocked" ? 0 : j.state == "working" ? 1 : 2 }
        rows.sort { (w($0), $0.id) < (w($1), $1.id) }
        for j in rows where lastState[j.id] != j.state {
            let snd = j.state == "blocked" ? "Ping" : j.state == "done" ? "Glass" : j.state == "failed" ? "Basso" : nil
            if seeded, let snd {
                NSSound(named: snd)?.play()
                popUntil = now + 4; popID = j.id
            }
            lastState[j.id] = j.state
        }
        seeded = true
        if rows != jobs { jobs = rows }
        acked = acked.filter { k in rows.contains { k.hasPrefix($0.id + "|") } }
        updateAlert()
        syncOpen()
    }
}
