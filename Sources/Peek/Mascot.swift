import SwiftUI
import AppKit
import PeekCore

let mascotBody = Color(white: 0.92)

/// One frame of the peeking dome in a 22x16 pt box; `scale` enlarges it. Pure drawing, no time or pointer.
struct MascotArt: View {
    let pose: MascotPose
    let gaze: CGVector      // unit disk, y up
    let accent: Color?
    var scale: CGFloat = 1

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            let ledge = accent ?? Color.white.opacity(0.25)
            ctx.fill(Path(CGRect(x: 0, y: 15, width: 22, height: 1)), with: .color(ledge))
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: 22, height: 15)))
            let baseY = 15 + (1 - pose.lift) * 7
            ctx.translateBy(x: 0, y: -pose.hop)
            ctx.translateBy(x: 11, y: baseY); ctx.rotate(by: .degrees(pose.tilt)); ctx.translateBy(x: -11, y: -baseY)
            var dome = Path()
            dome.move(to: CGPoint(x: 2, y: baseY))
            dome.addArc(center: CGPoint(x: 11, y: baseY), radius: 9, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            dome.addLine(to: CGPoint(x: 2, y: baseY))
            ctx.fill(dome.applying(CGAffineTransform(translationX: 0, y: baseY).scaledBy(x: 1, y: 11.0 / 9).translatedBy(x: 0, y: -baseY)), with: .color(mascotBody))
            let cx = 11.0, cy = baseY - 5.2, rx = 5.2, ry = 3.4 * max(pose.open, 0)
            if pose.happy > 0.5 {
                var arc = Path(); arc.move(to: CGPoint(x: cx - 4, y: cy + 1.4))
                arc.addQuadCurve(to: CGPoint(x: cx + 4, y: cy + 1.4), control: CGPoint(x: cx, y: cy - 3.6))
                ctx.stroke(arc, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            } else if ry < 0.7 {
                var l = Path(); l.move(to: CGPoint(x: cx - 4.2, y: cy)); l.addLine(to: CGPoint(x: cx + 4.2, y: cy))
                ctx.stroke(l, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            } else {
                let eye = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
                ctx.fill(eye, with: .color(.black))
                ctx.clip(to: eye)
                let g = pose.sweep.map { CGVector(dx: $0, dy: 0) } ?? gaze
                let pr = 1.9
                let px = cx + g.dx * (rx - pr - 0.2), py = cy - g.dy * max(0, ry - pr + 0.6)
                ctx.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: 2 * pr, height: 2 * pr)), with: .color(accent ?? mascotBody))
            }
        }
        .frame(width: 22 * scale, height: 16 * scale)
    }
}

/// Live character: reads the pointer, tracks its own screen position, animates at 30 fps.
struct Mascot: View {
    let state: MascotState
    let accent: Color?
    let pointer: Pointer
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var since = Date()
    @State private var center = CGPoint.zero

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let pose = MascotMath.pose(state, t: tl.date.timeIntervalSince(since), reduceMotion: reduce)
            let lazy: CGFloat = state == .idle ? 0.6 : 1
            let g = MascotMath.gaze(from: center, to: pointer.location)
            MascotArt(pose: pose, gaze: CGVector(dx: g.dx * lazy, dy: g.dy * lazy), accent: accent, scale: scale)
        }
        .onChange(of: state) { since = Date() }
        .onGeometryChange(for: CGPoint.self) { CGPoint(x: $0.frame(in: .global).midX, y: $0.frame(in: .global).midY) } action: { c in
            if let w = notchPanel { center = CGPoint(x: w.frame.minX + c.x, y: w.frame.maxY - c.y) }
        }
    }
}

/// `PEEK_RENDER_MASCOT=<dir>`: one 8x PNG per state plus a labelled sheet with a true-size wing mock, then exit.
@MainActor func renderMascot(to dir: String) {
    let states: [(String, MascotState, Double, Color?, String)] = [
        ("idle", .idle, 1, nil, "2"), ("working", .working, 3, nil, "2"),
        ("needs", .needs, 2, amber, "NEEDS"), ("done", .done, 0.9, .green, "DONE"), ("failed", .failed, 3, .red, "FAILED")]
    func art(_ s: MascotState, _ t: Double, _ c: Color?, _ k: CGFloat) -> MascotArt {
        MascotArt(pose: MascotMath.pose(s, t: t, reduceMotion: false), gaze: CGVector(dx: -0.7, dy: 0.7), accent: c, scale: k)
    }
    func write<V: View>(_ v: V, _ name: String, _ scale: CGFloat) {
        let r = ImageRenderer(content: v); r.scale = scale
        guard let img = r.cgImage, let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
    for (n, s, t, c, _) in states { write(art(s, t, c, 1).padding(1).background(.black), n, 8) }
    let sheet = VStack(spacing: 14) {
        HStack(spacing: 16) {
            ForEach(states, id: \.0) { n, s, t, c, _ in
                VStack(spacing: 6) { art(s, t, c, 6); Text(n).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
            }
        }
        HStack(spacing: 8) {
            ForEach(states, id: \.0) { _, s, t, c, w in
                HStack(spacing: 4) {
                    art(s, t, c, 1)
                    Text(w).font(.system(size: w.count > 1 ? 10 : 11, weight: w.count > 1 ? .bold : .semibold)).foregroundStyle(w.count > 1 ? (c ?? .white) : .white)
                }.fixedSize().frame(width: Layout.wing, height: 24).background(.black)
            }
        }
    }.padding(20).background(.black)
    write(sheet, "sheet", 2)
    write(sheet, "sheet-1x", 1)
}
