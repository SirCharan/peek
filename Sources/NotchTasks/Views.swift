import SwiftUI
import AppKit

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let cardW: CGFloat = 340
    static let emptyH: CGFloat = 30

    static func cardH(_ jobs: [Job], _ g: Geo) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : CGFloat(jobs.prefix(5).count) * 44
        return g.notchH + 6 + body + 10
    }

    /// Panel size + horizontal offset from screen centre. Panel always matches content so it never blocks clicks.
    static func rect(expanded: Bool, g: Geo, jobs: [Job]) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: cardW, height: cardH(jobs, g)), 0) }
        return (CGSize(width: g.notchW + 80, height: g.notchH + 24), 0)
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
                Group {
                    Text("\(job.project) · \(Eta.fmt(job.elapsed))").foregroundStyle(.white.opacity(0.5))
                    + Text(job.stuck.map { " stuck \($0)m" } ?? "").foregroundStyle(.orange)
                }.font(.system(size: 11)).lineLimit(1)
            }
            HStack(spacing: 8) {
                Capsule().fill(.white.opacity(0.15)).frame(width: 110, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(fill).frame(width: 110 * frac, height: 6) }
                Text(line2(job)).font(.system(size: 11))
                    .foregroundStyle(blocked ? .orange : .white.opacity(0.6)).lineLimit(1)
                if let e = job.eta, !blocked {
                    Spacer(minLength: 4)
                    Text("maybe \(Eta.fmt(e))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44, alignment: .center)
    }
}

struct Card: View {
    let store: Store
    let geo: Geo
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geo.notchH + 6)
            if store.jobs.isEmpty {
                Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(height: Layout.emptyH)
            }
            ForEach(store.jobs.prefix(5)) { RowView(job: $0) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: Layout.cardW, height: Layout.cardH(store.jobs, geo), alignment: .top)
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
            if store.expanded {
                Card(store: store, geo: geo)
                    .matchedGeometryEffect(id: 1, in: ns)
            } else {
                collapsed.matchedGeometryEffect(id: 2, in: ns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { store.expanded = $0 }
        .animation(spring, value: store.expanded)
        .ignoresSafeArea()
    }

    private var collapsed: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geo.notchH)
            HStack(spacing: 6) {
                Circle().fill(dotColor(store.dotKind)).frame(width: 7, height: 7)
                Text(store.summary).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.white).frame(height: 24)
        }
        .frame(width: geo.notchW + 80, height: geo.notchH + 24)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black))
    }
}
