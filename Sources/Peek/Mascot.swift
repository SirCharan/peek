import SwiftUI
import AppKit
import PeekCore

let mascotBody = Color(white: 0.92)

/// One frame of the winking pup in a 22x16 pt box; `scale` enlarges it. Pure drawing, no time or pointer.
/// Shapes are the 512-unit mark scaled down (0.05 wide, 0.062 tall) with the face simplified for size.
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
            ctx.translateBy(x: 0, y: -pose.hop)
            let baseY = 15 + (1 - pose.lift) * 7
            // Mark coordinates (x 256 = centre, y 364 = ledge) to points; `flip` mirrors for the right side.
            func m(_ x: Double, _ y: Double, _ flip: Bool = false) -> CGPoint {
                CGPoint(x: 11 + (flip ? -1 : 1) * (x - 256) * 0.05, y: baseY + (y - 364) * 0.062)
            }
            var head = ctx
            head.translateBy(x: 11, y: baseY); head.rotate(by: .degrees(pose.tilt)); head.translateBy(x: -11, y: -baseY)
            let earFill = Color(white: 0.2), earLine = Color(white: 0.92)
            for flip in [false, true] {
                var ear = Path()
                ear.move(to: m(178, 194, flip))
                ear.addCurve(to: m(82, 262, flip), control1: m(140, 174, flip), control2: m(94, 206, flip))
                ear.addCurve(to: m(104, 342, flip), control1: m(74, 302, flip), control2: m(80, 340, flip))
                ear.addCurve(to: m(168, 262, flip), control1: m(130, 344, flip), control2: m(150, 302, flip))
                ear.closeSubpath()
                let pv = m(176, 200, flip), a = Angle.degrees(pose.ear * (pose.ear < 0 ? 14 : 15) * (flip ? -1 : 1)).radians
                let t = CGAffineTransform(translationX: pv.x, y: pv.y + max(0, -pose.ear) * 1.4).rotated(by: a).translatedBy(x: -pv.x, y: -pv.y)
                head.fill(ear.applying(t), with: .color(earFill))
                head.stroke(ear.applying(t), with: .color(earLine), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            }
            var dome = Path()
            dome.move(to: m(122, 364))
            dome.addCurve(to: m(256, 176), control1: m(112, 262), control2: m(156, 178))
            dome.addCurve(to: m(390, 364), control1: m(356, 176), control2: m(400, 262))
            dome.closeSubpath()
            head.fill(dome, with: .color(mascotBody))
            let cheek = Color(red: 0.93, green: 0.75, blue: 0.71)
            for x in [6.6, 15.4] { head.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: baseY - 2.5, width: 2.4, height: 1.4)), with: .color(cheek)) }
            let ey = baseY - 4.9, ex = [8.4, 13.6]
            let g = pose.sweep.map { CGVector(dx: $0, dy: 0) } ?? gaze
            let ink = Color.black, line = StrokeStyle(lineWidth: 1.2, lineCap: .round)
            func arc(_ x: Double, _ lift: Double) {
                var a = Path(); a.move(to: CGPoint(x: x - 1.8, y: ey + 0.7))
                a.addQuadCurve(to: CGPoint(x: x + 1.8, y: ey + 0.7), control: CGPoint(x: x, y: ey + 0.7 - lift))
                head.stroke(a, with: .color(ink), style: line)
            }
            func flat(_ x: Double, _ dir: Double) {
                var l = Path(); l.move(to: CGPoint(x: x - 1.8, y: ey + 0.4 * dir)); l.addLine(to: CGPoint(x: x + 1.8, y: ey - 0.4 * dir))
                head.stroke(l, with: .color(ink), style: line)
            }
            func eye(_ x: Double) {
                let wide = pose.open > 1, rx = wide ? 2.3 : 1.9, ry = 2.4 * pose.open
                let c = CGPoint(x: x + g.dx * 0.7, y: ey + (1 - min(pose.open, 1)) * 0.9 - g.dy * 0.5)
                let shape = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
                head.fill(shape, with: .color(ink))
                if wide { head.fill(Path(ellipseIn: CGRect(x: c.x + g.dx * 0.4 - 1.4, y: c.y - g.dy * 0.5 - 1.4, width: 2.8, height: 2.8)), with: .color(accent ?? mascotBody)) }
                else { head.fill(Path(ellipseIn: CGRect(x: c.x - 0.7 - rx * 0.25, y: c.y - ry * 0.3 - 0.8, width: 1.6, height: 1.6)), with: .color(accent ?? mascotBody)) }
            }
            if pose.happy > 0.5 { arc(ex[0], 2.8); arc(ex[1], 2.8) }
            else if 2.4 * pose.open < 0.7 { flat(ex[0], 1); flat(ex[1], -1) }
            else {
                eye(ex[0])
                if pose.wink < 0.5 { eye(ex[1]) } else { arc(ex[1], pose.open < 0.9 ? 1.0 : 2.8) }
            }
            head.fill(Path(ellipseIn: CGRect(x: 11 - 1.4, y: baseY - 3.1, width: 2.8, height: 2)), with: .color(ink))
            if pose.happy > 0.5 { head.fill(Path(roundedRect: CGRect(x: 10.1, y: baseY - 1.2, width: 1.8, height: 1.6), cornerRadius: 0.8), with: .color(Color(red: 0.93, green: 0.45, blue: 0.5))) }
            for x in [1.5, 17.2] { let paw = Path(roundedRect: CGRect(x: x, y: 11.6, width: 3.4, height: 3.6), cornerRadius: 1.6)
                ctx.fill(paw, with: .color(mascotBody)); ctx.stroke(paw, with: .color(.black), lineWidth: 0.5) }
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
