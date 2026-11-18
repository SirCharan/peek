import SwiftUI
import AppKit
import PeekCore

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let rowH: CGFloat = 30
    static let maxRows = 6
    static let emptyH: CGFloat = 30
    static let wing: CGFloat = 72

    static func bandW(_ g: Geo) -> CGFloat { g.notchW + 2 * wing }
    static func cardW(_ g: Geo) -> CGFloat { max(440, g.notchW + 144) }

    /// Question card: header 22 + per question (6 top, title 14 per line, 4, options 24 each, Other 22, 4) + footer 32, capped (it scrolls past the cap).
    static func askTitle(_ q: AskItem) -> String { q.header.isEmpty ? q.question : "\(q.header.uppercased()) \u{00B7} \(q.question)" }
    static func askTitleH(_ q: AskItem) -> CGFloat { askTitle(q).count > 64 ? 28 : 14 }
    static func askQH(_ q: AskItem) -> CGFloat { 36 + askTitleH(q) + 24 * CGFloat(q.options.count) }
    static func askH(_ a: AskQuestion) -> CGFloat { min(520, 22 + a.questions.reduce(0) { $0 + askQH($1) } + 32) }
    static let diffH: CGFloat = 130
    static let footerH: CGFloat = 18
    static func diffExtra(_ j: Job, _ diff: String?) -> CGFloat { diff == j.id && j.edit?.hunks.isEmpty == false ? diffH : 0 }
    /// Plan card: header 22 + scrolling plan text + footer 32. Mirror card: header 22 + body + footer 32.
    static let planBodyH: CGFloat = 130
    static let planH: CGFloat = 22 + planBodyH + 32
    static func mirrorBodyH(_ m: PromptMirror) -> CGFloat {
        if let a = m.ask { return min(200, a.questions.reduce(CGFloat(0)) { $0 + 20 + 15 * CGFloat($1.options.count) }) }
        return m.tool == "ExitPlanMode" && !m.plan.isEmpty ? planBodyH : 18
    }
    static func mirrorH(_ m: PromptMirror) -> CGFloat { 22 + mirrorBodyH(m) + 32 }
    static func h(_ j: Job, replying: String? = nil) -> CGFloat {
        if j.state == "approval", j.flash.isEmpty { return j.perm?.ask.map(askH) ?? (j.perm?.planCard == true ? planH : 52) }
        if j.state == "input", j.flash.isEmpty, let m = j.mirror { return mirrorH(m) }
        return j.state == "input" && replying == j.id ? 52 : rowH
    }
    static func cardH(_ jobs: [Job], _ g: Geo, replying: String? = nil, diff: String? = nil, footer: Bool = false) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : jobs.prefix(maxRows).reduce(0) { $0 + h($1, replying: replying) + diffExtra($1, diff) }
        return g.notchH + body + 10 + (footer ? footerH : 0)
    }

    /// Panel size + horizontal offset from screen centre. Collapsed = menu bar band only.
    static func rect(expanded: Bool, g: Geo, jobs: [Job], replying: String? = nil, diff: String? = nil, footer: Bool = false) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: cardW(g), height: cardH(jobs, g, replying: replying, diff: diff, footer: footer)), 0) }
        return (CGSize(width: bandW(g), height: g.notchH), 0)
    }
}

let amber = Color.orange

/// 6pt session-hue dot with a 1.5pt state ring outside it.
struct StateDot: View {
    let job: Job
    let alerting: Bool
    @State private var pulse = false
    private var ring: Color? {
        switch job.state {
        case "approval", "input": return amber
        case "done": return .green
        case "failed": return .red
        case "compacting": return Color(hue: 0.6, saturation: 0.25, brightness: 0.8)
        case "working": return nil
        default: return .gray
        }
    }
    var body: some View {
        Circle().fill(Color(hue: Eta.hue(job.title), saturation: 0.75, brightness: 0.95)).frame(width: 6, height: 6)
            .overlay { if let ring { Circle().stroke(ring, lineWidth: 1.5).frame(width: 9, height: 9) } }
            .frame(width: 10, height: 10)
            .opacity(alerting && pulse ? 0.4 : 1)
            .animation(alerting ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

@MainActor var notchPanel: NSWindow? { NSApp.windows.first { $0 is NSPanel && $0.level == .statusBar } }

struct ApprovalButtons: View {
    let job: Job
    let store: Store
    @Binding var denying: Bool
    @State private var reason = ""
    @FocusState private var focus: Bool
    private func endDeny() { denying = false; notchPanel?.resignKey() }
    var body: some View {
        let p = job.perm
        if denying {
            HStack(spacing: 8) {
                TextField("Reason (Enter to deny)", text: $reason).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                    .focused($focus)
                    .onSubmit {
                        let t = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.reply(job, t.isEmpty ? "deny" : "deny:" + t)
                    }
                    .onExitCommand { endDeny() }
            }.onAppear { reason = ""; notchPanel?.makeKey(); focus = true }
        } else {
        HStack(spacing: 6) {
            Button { store.reply(job, "allow") } label: {
                Text(p?.allowLabel ?? "Allow").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(amber)).contentShape(Capsule())
            }.buttonStyle(.plain)
            Button { denying = true } label: {
                Text(p?.denyLabel ?? "Deny").font(.system(size: 11)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(.white.opacity(0.2))).contentShape(Capsule())
            }.buttonStyle(.plain)
            if p?.allowAlways ?? true {
                Button { store.reply(job, "always") } label: {
                    Text(p?.alwaysButton ?? "Always").font(.system(size: 11)).foregroundStyle(amber)
                        .padding(.horizontal, 4).frame(height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).help(p?.always ?? "")
            }
        }.fixedSize()
        }
    }
}

struct RowView: View {
    let job: Job
    let alerting: Bool
    let store: Store

    private var phrase: Text {
        let dim = Color.white.opacity(0.6)
        if !job.flash.isEmpty { return Text(job.flash).foregroundStyle(dim) }
        switch job.state {
        case "done", "failed": return Text(job.state).foregroundStyle(dim)
        case "approval": return Text(job.perm?.headline ?? "wants to run").foregroundStyle(dim)
        case "input":
            let a = job.ask2.isEmpty ? job.ask : job.ask2
            return Text(a.isEmpty ? "needs you" : "needs you · \(a)").foregroundStyle(amber)
        case "compacting": return Text("compacting").foregroundStyle(Color(hue: 0.6, saturation: 0.25, brightness: 0.8))
        default: break
        }
        var s: String
        if !job.tool.isEmpty { s = job.doing.isEmpty ? job.tool : "\(job.tool) · \(job.doing)" }
        else { s = job.doing.isEmpty ? job.phase : "\(job.phase) · \(job.doing)" }
        if job.agents > 0 && s.count <= 40 { s += " · \(job.agents) agent\(job.agents == 1 ? "" : "s")" }
        return Text(s).foregroundStyle(dim) + Text(job.stuck ? " · stuck" : "").foregroundStyle(amber)
    }

    var body: some View {
        let (bar, frac): (Color, CGFloat) = {
            if let c = job.ctxPct {
                return (c >= 95 ? .red : c >= 80 ? amber : .white.opacity(0.45), CGFloat(min(max(c, 0), 100)) / 100)
            }
            let b: Color = job.state == "done" ? .green : job.state == "failed" ? .red : (job.needsYou || job.stuck) ? amber : .white.opacity(0.45)
            return (b, job.state == "done" || job.state == "failed" ? 1 : CGFloat(min(max(job.pct, 0), 100)) / 100)
        }()
        Group {
        if job.state == "approval", job.flash.isEmpty, let a = job.perm?.ask { QuestionCard(job: job, ask: a, store: store, alerting: alerting) }
        else if job.state == "approval", job.flash.isEmpty, job.perm?.planCard == true { PlanCard(job: job, store: store, alerting: alerting) }
        else if job.state == "approval", job.flash.isEmpty { approval(bar: bar, frac: frac) }
        else if job.state == "input", job.flash.isEmpty, let m = job.mirror { MirrorCard(job: job, mirror: m, store: store, alerting: alerting) }
        else if job.state == "input", store.replying == job.id { replyRow(bar: bar, frac: frac) }
        else {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(SessionTitle.short(job.title, 26)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                if job.state == "working", job.flash.isEmpty, let e = job.edit { ticker(e) }
                else {
                    phrase.font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if job.state == "input", Focus.canType(job) {
                    Button { startReply() } label: {
                        Text("Reply…").font(.system(size: 11)).foregroundStyle(amber.opacity(hasTab ? 1 : 0.4)).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!hasTab).help(hasTab ? "" : "no terminal tab")
                }
            }
            .frame(height: Layout.rowH - 2)
            GeometryReader { p in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) { Capsule().fill(bar).frame(width: p.size.width * frac) }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 14)
        .frame(height: Layout.rowH)
        }
        }
        .contentShape(Rectangle())
        .onTapGesture { Focus.jump(job, store: store) }
        .task(id: job.id + job.state) { if job.state == "input" { hasTab = await Focus.hasTab(job) } }
    }

    /// Latest edit as `name +N −M`; tapping the text toggles the diff (the rest of the row still jumps to the terminal).
    private func ticker(_ e: FileDiff) -> some View {
        var t = Text(e.name).foregroundStyle(.white.opacity(0.6))
        if !e.capped {
            t = t + Text(" +\(e.added)").foregroundStyle(.green)
            if !e.isNew { t = t + Text(" \u{2212}\(e.removed)").foregroundStyle(.red) }
        }
        return HStack(spacing: 0) {
            t.font(.system(size: 12)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .onTapGesture { if !e.hunks.isEmpty { store.diffOpen = store.diffOpen == job.id ? nil : job.id } }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var hasTab = true
    @State private var text = ""
    @FocusState private var fieldFocus: Bool
    @State private var denying = false
    var panel: NSWindow? { notchPanel }

    private func startReply() {
        text = ""; store.replying = job.id
    }
    private func endReply() {
        store.replying = nil; panel?.resignKey()
    }
    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { Focus.send(job, t) }
        endReply()
    }

    private func replyRow(bar: Color, frac: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: false)
                Text(SessionTitle.short(job.title, 22)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 18)
            HStack(spacing: 8) {
                TextField("Reply…", text: $text).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                    .focused($fieldFocus).onSubmit { send() }
                    .onExitCommand { endReply() }
                Button { send() } label: {
                    Text("Send").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(amber)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }.frame(height: 30)
            Color.clear.frame(height: 2)
        }
        .padding(.horizontal, 14).frame(height: 52)
        .onAppear { panel?.makeKey(); fieldFocus = true }
    }

    private func approval(bar: Color, frac: CGFloat) -> some View {
        let p = job.perm
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(SessionTitle.short(job.title, 22)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                phrase.font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 18)
            HStack(spacing: 8) {
                if !denying {
                    Text(p?.detail ?? "")
                        .font(.system(size: 11, design: (p?.mono ?? false) ? .monospaced : .default)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }
                ApprovalButtons(job: job, store: store, denying: $denying)
            }.frame(height: 30)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) { Capsule().fill(bar).frame(width: g.size.width * frac) }
            }.frame(height: 2)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

/// ExitPlanMode held request: this request's own plan text (scrolls), Approve or Keep planning. The terminal shows the same dialog.
struct PlanCard: View {
    let job: Job
    let store: Store
    let alerting: Bool
    @State private var denying = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(SessionTitle.short(job.title, 22)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(job.perm?.headline ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 22)
            ScrollView(.vertical) {
                Text(job.perm?.plan ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: Layout.planBodyH)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ApprovalButtons(job: job, store: store, denying: $denying)
            }.frame(height: 32)
        }
        .padding(.horizontal, 14).frame(height: Layout.planH)
    }
}

/// Read-only copy of a question or plan the terminal is showing, for when Peek holds no request for it.
struct MirrorCard: View {
    let job: Job
    let mirror: PromptMirror
    let store: Store
    let alerting: Bool
    private var what: String {
        (mirror.agent.isEmpty ? "" : "(subagent) ") + (mirror.tool == "ExitPlanMode" ? "plan waits for your approval" : "has a question for you")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(SessionTitle.short(job.title, 22)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(what).font(.system(size: 11)).foregroundStyle(amber).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 22)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let a = mirror.ask {
                        ForEach(a.questions.indices, id: \.self) { i in
                            let q = a.questions[i]
                            Text(Layout.askTitle(q)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).frame(height: 20, alignment: .bottom)
                            ForEach(q.options.indices, id: \.self) { k in
                                Text("\(q.multiSelect ? "\u{25A1}" : "\u{25CB}") \(q.options[k].label)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).frame(height: 15, alignment: .leading)
                            }
                        }
                    } else if !mirror.plan.isEmpty {
                        Text(mirror.plan).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                    } else {
                        Text("Answer it in the terminal.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: Layout.mirrorBodyH(mirror))
            HStack(spacing: 6) {
                Text("answer in the terminal").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                Button { Focus.jump(job, store: store) } label: {
                    Text("Go to terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(amber)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }.frame(height: 32)
        }
        .padding(.horizontal, 14).frame(height: Layout.mirrorH(mirror))
    }
}

/// AskUserQuestion, answerable here while the terminal shows the same question: 1-4 questions, single or multi select, a free-text Other line, Submit.
/// Whichever side answers first wins.
struct QuestionCard: View {
    let job: Job
    let ask: AskQuestion
    let store: Store
    let alerting: Bool
    @State private var picked: [[String]]
    @State private var other: [String]
    @FocusState private var focus: Int?

    init(job: Job, ask: AskQuestion, store: Store, alerting: Bool) {
        self.job = job; self.ask = ask; self.store = store; self.alerting = alerting
        _picked = State(initialValue: Array(repeating: [], count: ask.questions.count))
        _other = State(initialValue: Array(repeating: "", count: ask.questions.count))
    }

    /// Labels chosen for question i: the Other text counts as an extra label (single-select: it replaces the pick).
    private func selection(_ i: Int) -> [String] {
        let o = other[i].trimmingCharacters(in: .whitespacesAndNewlines)
        if o.isEmpty { return picked[i] }
        return ask.questions[i].multiSelect ? picked[i] + [o] : [o]
    }
    private var complete: Bool { ask.questions.indices.allSatisfy { !selection($0).isEmpty } }

    private func toggle(_ i: Int, _ label: String) {
        if ask.questions[i].multiSelect {
            if let k = picked[i].firstIndex(of: label) { picked[i].remove(at: k) } else { picked[i].append(label) }
        } else {
            picked[i] = [label]; other[i] = ""
        }
    }
    private func submit() {
        let sel = ask.questions.indices.map(selection)
        let a = AskQuestion.buildAnswers(questions: ask.questions, selections: sel)
        guard complete, let d = try? JSONSerialization.data(withJSONObject: a), let j = String(data: d, encoding: .utf8) else { return }
        notchPanel?.resignKey()
        store.reply(job, j)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(SessionTitle.short(job.title, 22)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("has a question for you").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 22)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ask.questions.indices, id: \.self) { i in questionView(i) }
                }
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button { submit() } label: {
                    Text("Submit").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(amber.opacity(complete ? 1 : 0.35))).contentShape(Capsule())
                }.buttonStyle(.plain).disabled(!complete)
            }.frame(height: 32)
        }
        .padding(.horizontal, 14)
        .frame(height: Layout.askH(ask))
    }

    private func questionView(_ i: Int) -> some View {
        let q = ask.questions[i]
        return VStack(alignment: .leading, spacing: 0) {
            Text(Layout.askTitle(q)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).frame(height: Layout.askTitleH(q), alignment: .topLeading).padding(.top, 6).padding(.bottom, 4)
            ForEach(q.options.indices, id: \.self) { k in
                let o = q.options[k], on = picked[i].contains(o.label)
                Button { toggle(i, o.label) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "circle.inset.filled" : "circle"))
                            .font(.system(size: 11)).foregroundStyle(on ? amber : .white.opacity(0.5))
                        Text(o.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(o.description).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }.frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            TextField("Other…", text: $other[i]).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                .focused($focus, equals: i)
                .simultaneousGesture(TapGesture().onEnded { notchPanel?.makeKey() })  // typing needs the panel to be key
                .onChange(of: other[i]) { _, v in if !q.multiSelect && !v.isEmpty { picked[i] = [] } }
                .onSubmit { submit() }
                .onExitCommand { focus = nil; notchPanel?.resignKey() }
            Color.clear.frame(height: 4)
        }
        .frame(height: Layout.askQH(q), alignment: .top)
    }
}

/// Compact unified diff of a session's latest edit.
struct DiffView: View {
    let diff: FileDiff
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.hunks.indices, id: \.self) { h in
                    if h > 0 { Text("\u{22EF}").foregroundStyle(.white.opacity(0.4)) }
                    ForEach(diff.hunks[h].lines.indices, id: \.self) { i in
                        let l = diff.hunks[h].lines[i]
                        let (p, c): (String, Color) = l.kind == .added ? ("+", .green) : l.kind == .removed ? ("\u{2212}", .red) : (" ", .white.opacity(0.6))
                        Text("\(p) \(l.text)").foregroundStyle(c).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(l.kind == .context ? Color.clear : c.opacity(0.12))
                    }
                }
            }.font(.system(size: 10, design: .monospaced)).padding(.vertical, 2)
        }
        .padding(.horizontal, 14).frame(height: Layout.diffH)
    }
}

/// One thin line of plan usage; amber at 80%, red at 95%, like the context bar. Shows "muted" at the right while sounds are off.
struct UsageFooter: View {
    let usage: PlanUsage?
    let muted: Bool
    private func part(_ label: String, _ w: PlanWindow?, weekday: Bool) -> some View {
        Group {
            if let w {
                Text(Usage.text(label, w, weekday: weekday)).monospacedDigit()
                    .foregroundStyle(w.usedPct >= 95 ? .red : w.usedPct >= 80 ? amber : .white.opacity(0.45))
            }
        }
    }
    var body: some View {
        HStack(spacing: 16) {
            part("5h", usage?.fiveHour, weekday: false)
            part("week", usage?.sevenDay, weekday: true)
            Spacer(minLength: 0)
            if muted { Label("muted", systemImage: "speaker.slash").foregroundStyle(.white.opacity(0.45)) }
        }.font(.system(size: 10)).lineLimit(1).padding(.horizontal, 14).frame(height: Layout.footerH)
    }
}

struct Wings: View {
    let store: Store
    let geo: Geo

    var body: some View {
        let al = store.alert
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                if store.jobs.isEmpty {
                    Circle().fill(.gray).frame(width: 6, height: 6)
                } else {
                    ForEach(store.jobs.prefix(6)) { j in
                        let alerting = j.id == store.alertJobID
                        StateDot(job: j, alerting: alerting)
                    }
                }
            }
            .frame(width: Layout.wing, height: geo.notchH)
            Spacer(minLength: 0).frame(width: geo.notchW)
            HStack(spacing: 4) {
                if !store.jobs.isEmpty { Mascot(state: MascotState(buddy: store.buddy), accent: al.map { $0.kind == "needs" ? amber : $0.kind == "done" ? .green : .red }, pointer: store.pointer) }
                if let al {
                    let (label, col): (String, Color) = al.kind == "needs" ? ("NEEDS", amber) : al.kind == "done" ? ("DONE", .green) : ("FAILED", .red)
                    Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(col)
                } else if !store.jobs.isEmpty {
                    Text("\(store.jobs.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .lineLimit(1).fixedSize()
            .frame(width: Layout.wing, height: geo.notchH)
        }
        .frame(width: Layout.bandW(geo), height: geo.notchH)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: store.bounceTick) { v, y in v.offset(y: y) } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-3, duration: 0.15); SpringKeyframe(0, duration: 0.15)
                SpringKeyframe(-3, duration: 0.15); SpringKeyframe(0, duration: 0.15)
                SpringKeyframe(-3, duration: 0.15); SpringKeyframe(0, duration: 0.15)
            }
        }
    }
}

struct Card: View {
    let store: Store
    let geo: Geo
    var body: some View {
        VStack(spacing: 0) {
            Wings(store: store, geo: geo)
            if store.shown.isEmpty {
                HStack(spacing: 8) {
                    Mascot(state: .idle, accent: nil, pointer: store.pointer, scale: 1.8)
                    Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }.frame(height: Layout.emptyH)
            }
            ForEach(store.shown.prefix(Layout.maxRows)) { j in
                RowView(job: j, alerting: j.id == store.alertJobID, store: store)
                if Layout.diffExtra(j, store.diffOpen) > 0, let e = j.edit { DiffView(diff: e) }
            }
            Spacer(minLength: 0)
            if store.showFooter { UsageFooter(usage: store.usage, muted: Sounds.muted) }
        }
        .foregroundStyle(.white)
        .frame(width: Layout.cardW(geo), height: Layout.cardH(store.shown, geo, replying: store.replying, diff: store.diffOpen, footer: store.showFooter), alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black))
    }
}

struct Root: View {
    let store: Store
    let geo: Geo
    @Namespace private var ns
    private let spring = Animation.spring(duration: 0.35, bounce: 0.25)

    var body: some View {
        ZStack(alignment: .top) {
            if store.open {
                Card(store: store, geo: geo)
                    .matchedGeometryEffect(id: 1, in: ns)
            } else if store.presence != .hidden {
                collapsed.matchedGeometryEffect(id: 2, in: ns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .animation(spring, value: store.open)
        .ignoresSafeArea()
    }

    private var collapsed: some View {
        Wings(store: store, geo: geo)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
    }
}
