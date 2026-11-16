// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/ClaudePlanGauge.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation

public struct PlanWindow: Equatable, Sendable {
    public let usedPct: Double   // 0-100, clamped
    public let resetsAt: Date
}

public struct PlanUsage: Equatable, Sendable {
    public var fiveHour: PlanWindow?
    public var sevenDay: PlanWindow?
}

public enum Usage {
    /// `rate_limits` from a status file (or statusline payload). nil if absent or malformed.
    public static func parse(_ payload: [String: Any], now: Date = Date()) -> PlanUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let u = PlanUsage(fiveHour: window(limits["five_hour"], now), sevenDay: window(limits["seven_day"], now))
        return u.fiveHour == nil && u.sevenDay == nil ? nil : u
    }

    private static func window(_ raw: Any?, _ now: Date) -> PlanWindow? {
        guard let d = raw as? [String: Any],
              let pct = (d["used_percentage"] as? NSNumber)?.doubleValue, pct >= 0, pct <= 200,
              let epoch = (d["resets_at"] as? NSNumber)?.doubleValue, epoch > 0,
              epoch <= now.timeIntervalSince1970 + 400 * 86400 else { return nil }  // far future = milliseconds, not seconds
        return PlanWindow(usedPct: min(100, pct), resetsAt: Date(timeIntervalSince1970: epoch))
    }

    /// Every session relays its own copy of rate_limits, some older or partial. Merge per window so a stale
    /// session never moves the gauge back: a later reset wins, the same window keeps the higher %, a missing window is kept.
    public static func merge(_ current: PlanUsage?, with incoming: PlanUsage) -> PlanUsage {
        PlanUsage(fiveHour: latest(current?.fiveHour, incoming.fiveHour), sevenDay: latest(current?.sevenDay, incoming.sevenDay))
    }

    private static func latest(_ cur: PlanWindow?, _ inc: PlanWindow?) -> PlanWindow? {
        guard let cur else { return inc }
        guard let inc else { return cur }
        if inc.resetsAt != cur.resetsAt { return inc.resetsAt > cur.resetsAt ? inc : cur }
        return inc.usedPct >= cur.usedPct ? inc : cur
    }

    /// Freshest usage across all sessions, windows whose reset has passed dropped. nil when nothing is left.
    public static func freshest(_ all: [PlanUsage], now: Date = Date()) -> PlanUsage? {
        guard let first = all.first else { return nil }
        let m = all.dropFirst().reduce(first) { merge($0, with: $1) }
        let u = PlanUsage(fiveHour: m.fiveHour.flatMap { $0.resetsAt > now ? $0 : nil }, sevenDay: m.sevenDay.flatMap { $0.resetsAt > now ? $0 : nil })
        return u.fiveHour == nil && u.sevenDay == nil ? nil : u
    }

    /// "5h 42% · resets 3:10 pm" / "week 18% · resets Thu"
    public static func text(_ label: String, _ w: PlanWindow, weekday: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = weekday ? "EEE" : "h:mm a"
        return "\(label) \(Int(w.usedPct.rounded()))% · resets \(weekday ? f.string(from: w.resetsAt) : f.string(from: w.resetsAt).lowercased())"
    }
}
