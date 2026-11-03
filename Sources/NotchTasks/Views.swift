import SwiftUI
import AppKit

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let rowH: CGFloat = 30
    static let maxRows = 6
    static let emptyH: CGFloat = 30
    static let wing: CGFloat = 72

    static func bandW(_ g: Geo) -> CGFloat { g.notchW + 2 * wing }
    static func cardW(_ g: Geo) -> CGFloat { max(440, g.notchW + 144) }

    static func h(_ j: Job, replying: String? = nil) -> CGFloat { j.state == "approval" && j.flash.isEmpty ? (j.perm?.tall == true ? 64 : 52) : (j.state == "input" && replying == j.id) ? 52 : rowH }
    static func cardH(_ jobs: [Job], _ g: Geo, replying: String? = nil) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : jobs.prefix(maxRows).reduce(0) { $0 + h($1, replying: replying) }
        return g.notchH + body + 10
    }

    /// Panel size + horizontal offset from screen centre. Collapsed = menu bar band only.
    static func rect(expanded: Bool, g: Geo, jobs: [Job], replying: String? = nil) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: cardW(g), height: cardH(jobs, g, replying: replying)), 0) }
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

struct ApprovalButtons: View {
    let job: Job
    let store: Store
    var body: some View {
        let p = job.perm
        HStack(spacing: 6) {
            Button { store.reply(job, p?.tool == "AskUserQuestion" ? "open" : "allow") } label: {
                Text(p?.allowLabel ?? "Allow").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(amber)).contentShape(Capsule())
            }.buttonStyle(.plain)
            Button { store.reply(job, "deny") } label: {
                Text(p?.denyLabel ?? "Deny").font(.system(size: 11)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 20).background(Capsule().fill(.white.opacity(0.2))).contentShape(Capsule())
            }.buttonStyle(.plain)
            if p?.allowAlways ?? true {
                Button { store.reply(job, "always") } label: {
                    Text("Always").font(.system(size: 11)).foregroundStyle(amber)
                        .padding(.horizontal, 4).frame(height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).help(p?.always ?? "")
            }
        }.fixedSize()
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
        if job.state == "approval", job.flash.isEmpty { approval(bar: bar, frac: frac) }
        else if job.state == "input", store.replying == job.id { replyRow(bar: bar, frac: frac) }
        else {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(job: job, alerting: alerting)
                Text(String(job.title.prefix(14))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).frame(width: 90, alignment: .leading)
                phrase.font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if job.state == "input" {
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
        .task(id: job.id + job.state) { if job.state == "input" { hasTab = await Focus.tab(job) != nil } }
    }

    @State private var hasTab = true
    @State private var text = ""
    @FocusState private var fieldFocus: Bool
    var panel: NSWindow? { NSApp.windows.first { $0 is NSPanel && $0.level == .statusBar } }

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
                Text(String(job.title.prefix(14))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
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
                Text(String(job.title.prefix(14))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                phrase.font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: 18)
            HStack(spacing: 8) {
                Text(p?.detail ?? "")
                    .font(.system(size: 11, design: (p?.mono ?? false) ? .monospaced : .default)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(p?.tall == true ? 2 : 1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                ApprovalButtons(job: job, store: store)
            }.frame(height: p?.tall == true ? 42 : 30)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) { Capsule().fill(bar).frame(width: g.size.width * frac) }
            }.frame(height: 2)
        }
        .padding(.horizontal, 14)
        .frame(height: p?.tall == true ? 64 : 52)
    }
}

/// 12pt two-frame glyph, 600 ms per frame.
struct Buddy: View {
    let kind: String
    let tint: Color?
    private static let frames: [String: (String, String)] = [
        "working": ("◐", "◑"), "needs": ("(!)", "( )"), "done": ("✓", "✓"),
        "compacting": ("◌", "◍"), "idle": ("·", "·"), "failed": ("✗", "✗")]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { c in
            let f = Buddy.frames[kind] ?? ("·", "·")
            let on = Int(c.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            Text(on ? f.0 : f.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(tint ?? .white.opacity(0.7))
        }
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
                if !store.jobs.isEmpty { Buddy(kind: store.buddy, tint: al.map { $0.kind == "needs" ? amber : $0.kind == "done" ? .green : .red }) }
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
                Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(height: Layout.emptyH)
            }
            ForEach(store.shown.prefix(Layout.maxRows)) { RowView(job: $0, alerting: $0.id == store.alertJobID, store: store) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: Layout.cardW(geo), height: Layout.cardH(store.shown, geo, replying: store.replying), alignment: .top)
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
            } else {
                collapsed.matchedGeometryEffect(id: 2, in: ns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { store.expanded = $0; store.syncOpen() }
        .animation(spring, value: store.open)
        .ignoresSafeArea()
    }

    private var collapsed: some View {
        Wings(store: store, geo: geo)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
    }
}
