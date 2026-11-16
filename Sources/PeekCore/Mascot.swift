import Foundation
import CoreGraphics

public enum MascotState: Sendable, CaseIterable {
    case idle, working, needs, done, failed
    public init(buddy: String) {
        switch buddy {
        case "needs": self = .needs
        case "done": self = .done
        case "failed": self = .failed
        case "working", "compacting": self = .working
        default: self = .idle
        }
    }
}

/// Everything the drawing needs for one frame. `sweep` nil means the pupil follows the cursor.
public struct MascotPose: Equatable, Sendable {
    public var lift = 1.0, open = 1.0, happy = 0.0, tilt = 0.0, hop = 0.0
    /// Ears: -1 drooped, 0 relaxed, 1 lifted. `wink` 1 closes the second eye in a wink arc, 0 opens it.
    public var ear = 0.0, wink = 1.0
    public var sweep: Double?
}

public enum MascotMath {
    static func ease(_ x: Double) -> Double { let u = min(max(x, 0), 1); return u * u * (3 - 2 * u) }

    /// Unit-disk gaze toward `p` from `c` (screen coords, y up). Full deflection from 80pt away, zero on top of it.
    public static func gaze(from c: CGPoint, to p: CGPoint) -> CGVector {
        let dx = Double(p.x - c.x), dy = Double(p.y - c.y), d = (dx * dx + dy * dy).squareRoot()
        guard d > 0.001 else { return .zero }
        let m = min(1, d / 80)
        return CGVector(dx: dx / d * m, dy: dy / d * m)
    }

    /// `t` = seconds since the state began. Reduce motion: no hop, sweep or blink; only the one-shot happy eye remains.
    public static func pose(_ s: MascotState, t: Double, reduceMotion: Bool) -> MascotPose {
        var p = MascotPose()
        let rise = reduceMotion ? 1 : ease(t / 0.35)
        switch s {
        case .idle:
            p.lift = reduceMotion ? 0.55 : 1 - 0.45 * rise; p.open = 0.7  // heavy-lidded
            p.ear = -0.15
            if !reduceMotion, (t + 3).truncatingRemainder(dividingBy: 5) < 0.4 {
                p.open = 0.7 * (1 - sin(Double.pi * (t + 3).truncatingRemainder(dividingBy: 5) / 0.4))
            }
        case .working:
            p.lift = 0.55 + 0.45 * rise; p.ear = 1.0 * rise
            if !reduceMotion { p.sweep = 0.9 * sin(2 * Double.pi * t / 4) }
        case .needs:
            p.lift = 0.55 + 0.45 * rise; p.open = 1.2; p.wink = 0; p.ear = 0.45 * rise
            if !reduceMotion, t < 1.6 { p.hop = 2.5 * abs(sin(Double.pi * t / 0.8)) }
        case .done:
            p.lift = 0.55 + 0.45 * rise
            p.happy = 1 - ease((t - 2) / 0.3); p.open = 1 - p.happy; p.ear = 0.2
            if !reduceMotion, t < 0.5 { p.hop = 2 * sin(Double.pi * t / 0.5) }
        case .failed:
            p.lift = 0.55 + 0.45 * rise; p.open = 0; p.tilt = 2.5; p.ear = -0.9
        }
        return p
    }
}
