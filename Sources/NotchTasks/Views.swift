import SwiftUI
import AppKit

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let cardW: CGFloat = 340
    static let emptyH: CGFloat = 30

    static func cardH(_ jobs: [Job], _ g: Geo) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : CGFloat(jobs.prefix(5).count) * 58
        return g.notchH + 6 + body + 10
    }

    /// Panel size + horizontal offset from screen centre. Panel always matches content so it never blocks clicks.
    static func collapsedW(_ alert: String?, jobs: Int, _ g: Geo) -> CGFloat {
        guard let a = alert else {
            let n = min(jobs, 3)
            let content: CGFloat = n == 0 ? 50 : CGFloat(n) * 170 + CGFloat(n - 1) * 14 + (jobs > 3 ? 26 : 0)
            return max(g.notchW + 80, content + 32)
        }
        return min(g.notchW + 220, max(g.notchW + 80, CGFloat(a.count) * 7.5 + 40))
    }

    static func rect(expanded: Bool, g: Geo, jobs: [Job], alert: String?) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: cardW, height: cardH(jobs, g)), 0) }
        return (CGSize(width: collapsedW(alert, jobs: jobs.count, g), height: g.notchH + 24), 0)
    }
}

func dotColor(_ kind: String) -> Color {
    switch kind {
    case "working": .green
    case "blocked": .orange
    case "failed": .red
    default: .gray
    }
}

func line2(_ j: Job) -> String {
    if j.state == "blocked" { return "needs you · \(j.ask)" }
    if j.state == "done" || j.state == "failed" { return j.state }
    var s = j.doing.isEmpty ? j.phase : "\(j.phase) · \(j.doing)"
    if j.agents > 0 { s += " · \(j.agents) agent\(j.agents == 1 ? "" : "s")" }
    return s
}

struct RowView: View {
    let job: Job
    var body: some View {
        let blocked = job.state == "blocked", done = job.state == "done", failed = job.state == "failed"
        let fill: Color = blocked ? .orange : done ? .green : failed ? .red : .white.opacity(0.8)
        let frac = done || failed ? 1 : CGFloat(job.pct) / 100
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(String(job.title.prefix(28))).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                let proj = (job.project == "~" || job.project.isEmpty) ? "" : job.project
                Group {
                    Text(proj).foregroundStyle(.white.opacity(0.5))
                    + Text(job.stuck ? " stuck" : "").foregroundStyle(.orange)
                }.font(.system(size: 11)).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.white.opacity(0.15)).frame(width: 110, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(fill).frame(width: 110 * frac, height: 6) }
                    .padding(.top, 3)
                Text(line2(job)).font(.system(size: 11))
                    .foregroundStyle(blocked ? .orange : .white.opacity(0.6)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58, alignment: .center)
    }
}

func itemColor(_ j: Job) -> Color {
    if j.state == "blocked" || j.stuck { return .orange }
    switch j.state {
    case "working", "done": return .green
    case "failed": return .red
    default: return .gray
    }
}

struct PillItem: View {
    let job: Job
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(itemColor(job)).frame(width: 6, height: 6)
            Text(String(job.title.prefix(12))).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            Text(job.state == "blocked" ? job.ask : job.doing).font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 170, alignment: .leading)
    }
}

struct Card: View {
    let store: Store
    let geo: Geo
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geo.notchH + 6)
            if store.shown.isEmpty {
                Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(height: Layout.emptyH)
            }
            ForEach(store.shown.prefix(5)) { RowView(job: $0) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: Layout.cardW, height: Layout.cardH(store.shown, geo), alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20).fill(.black))
    }
}

struct Root: View {
    let store: Store
    let geo: Geo
    @Namespace private var ns
    @State private var pulse = false
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
        let al = store.alert
        let bg: Color = al.map { $0.kind == "needs" ? .orange : $0.kind == "done" ? .green : .red } ?? .black
        return VStack(spacing: 0) {
            Color.clear.frame(height: geo.notchH)
            HStack(spacing: 6) {
                if let al {
                    Text(al.text).font(.system(size: 11, weight: .bold)).lineLimit(1)
                } else if store.jobs.isEmpty {
                    Circle().fill(dotColor(store.dotKind)).frame(width: 7, height: 7)
                    Text("idle").font(.system(size: 11, weight: .medium))
                } else {
                    HStack(spacing: 14) {
                        ForEach(store.jobs.prefix(3)) { PillItem(job: $0) }
                        if store.jobs.count > 3 {
                            Text("+\(store.jobs.count - 3)").font(.system(size: 10)).foregroundStyle(.gray)
                        }
                    }
                }
            }
            .foregroundStyle(al == nil || al?.kind == "failed" ? .white : .black).frame(height: 24)
        }
        .frame(width: Layout.collapsedW(al?.text, jobs: store.jobs.count, geo), height: geo.notchH + 24)
        .background {
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
            ZStack {
                shape.fill(bg)
                    .opacity(al?.kind == "needs" && pulse ? 0.75 : 1)
                    .animation(.easeInOut(duration: 1.2).repeatForever(), value: pulse)
            }.clipShape(shape)
        }
        .onAppear { pulse = true }
    }
}
