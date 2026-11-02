import SwiftUI
import AppKit

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let cardW: CGFloat = 340
    static let emptyH: CGFloat = 30

    static let wing: CGFloat = 72

    static func bandW(_ g: Geo) -> CGFloat { g.notchW + 2 * wing }

    static func cardH(_ jobs: [Job], _ g: Geo) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : CGFloat(jobs.prefix(5).count) * 58
        return g.notchH + 6 + body + 10
    }

    /// Panel size + horizontal offset from screen centre. Collapsed = menu bar band only.
    static func rect(expanded: Bool, g: Geo, jobs: [Job]) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: max(cardW, bandW(g)), height: cardH(jobs, g)), 0) }
        return (CGSize(width: bandW(g), height: g.notchH), 0)
    }
}

func line2(_ j: Job) -> String {
    if j.state == "blocked" { return j.ask.isEmpty ? "needs you" : "needs you · \(j.ask)" }
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

struct Wings: View {
    let store: Store
    let geo: Geo
    @State private var pulse = false

    var body: some View {
        let al = store.alert
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if store.jobs.isEmpty {
                    Circle().fill(.gray).frame(width: 6, height: 6)
                } else {
                    ForEach(store.jobs.prefix(6)) { j in
                        let alerting = j.id == store.alertJobID
                        Circle().fill(itemColor(j)).frame(width: 6, height: 6)
                            .opacity(alerting && pulse ? 0.4 : 1)
                            .animation(alerting ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                    }
                }
            }
            .frame(width: Layout.wing, height: geo.notchH)
            Spacer(minLength: 0).frame(width: geo.notchW)
            Group {
                if let al {
                    let (label, col): (String, Color) = al.kind == "needs" ? ("NEEDS YOU", .orange) : al.kind == "done" ? ("DONE", .green) : ("FAILED", .red)
                    Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(col)
                } else if !store.jobs.isEmpty {
                    Text("\(store.jobs.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .lineLimit(1).fixedSize()
            .frame(width: Layout.wing, height: geo.notchH)
        }
        .frame(width: Layout.bandW(geo), height: geo.notchH)
        .onAppear { pulse = true }
    }
}

struct Card: View {
    let store: Store
    let geo: Geo
    var body: some View {
        VStack(spacing: 0) {
            Wings(store: store, geo: geo)
            Color.clear.frame(height: 6)
            if store.shown.isEmpty {
                Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(height: Layout.emptyH)
            }
            ForEach(store.shown.prefix(5)) { RowView(job: $0) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: max(Layout.cardW, Layout.bandW(geo)), height: Layout.cardH(store.shown, geo), alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20).fill(.black))
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
