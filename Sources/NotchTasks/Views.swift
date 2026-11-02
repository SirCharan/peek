import SwiftUI
import AppKit

struct Geo: Equatable, Sendable { var notchW: CGFloat; var notchH: CGFloat }

enum Layout {
    static let rowH: CGFloat = 30
    static let maxRows = 6
    static let emptyH: CGFloat = 30
    static let wing: CGFloat = 72

    static func bandW(_ g: Geo) -> CGFloat { g.notchW + 2 * wing }
    static func cardW(_ g: Geo) -> CGFloat { max(380, g.notchW + 144) }

    static func cardH(_ jobs: [Job], _ g: Geo) -> CGFloat {
        let body = jobs.isEmpty ? emptyH : CGFloat(jobs.prefix(maxRows).count) * rowH
        return g.notchH + body + 10
    }

    /// Panel size + horizontal offset from screen centre. Collapsed = menu bar band only.
    static func rect(expanded: Bool, g: Geo, jobs: [Job]) -> (size: CGSize, dx: CGFloat) {
        if expanded { return (CGSize(width: cardW(g), height: cardH(jobs, g)), 0) }
        return (CGSize(width: bandW(g), height: g.notchH), 0)
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

struct RowView: View {
    let job: Job
    let alerting: Bool
    @State private var pulse = false

    private var phrase: Text {
        let amber = Color.orange, dim = Color.white.opacity(0.6)
        if job.state == "done" || job.state == "failed" { return Text(job.state).foregroundStyle(dim) }
        if job.state == "blocked" {
            return Text(job.ask.isEmpty ? "needs you" : "needs you · \(job.ask)").foregroundStyle(amber)
        }
        var s = job.doing.isEmpty ? job.phase : "\(job.phase) · \(job.doing)"
        if job.agents > 0 { s += " · \(job.agents) agent\(job.agents == 1 ? "" : "s")" }
        return Text(s).foregroundStyle(dim) + Text(job.stuck ? " · stuck" : "").foregroundStyle(amber)
    }

    var body: some View {
        let bar: Color = job.state == "done" ? .green : job.state == "failed" ? .red : (job.state == "blocked" || job.stuck) ? .orange : .white.opacity(0.45)
        let frac = job.state == "done" || job.state == "failed" ? 1 : CGFloat(min(max(job.pct, 0), 100)) / 100
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(itemColor(job)).frame(width: 6, height: 6)
                    .opacity(alerting && pulse ? 0.4 : 1)
                    .animation(alerting ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                Text(String(job.title.prefix(14))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).frame(width: 96, alignment: .leading)
                phrase.font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear { pulse = true }
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
            if store.shown.isEmpty {
                Text("No Claude tasks running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(height: Layout.emptyH)
            }
            ForEach(store.shown.prefix(Layout.maxRows)) { RowView(job: $0, alerting: $0.id == store.alertJobID) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: Layout.cardW(geo), height: Layout.cardH(store.shown, geo), alignment: .top)
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
