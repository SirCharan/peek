import Foundation
import CoreGraphics

// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/IslandStateMachine.swift@0d7fe58, NotchBuddy/Sources/App/IslandDisplayChoice.swift@0d7fe58, NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.

/// What Peek shows: nothing, the collapsed band, or the card.
public enum Presence: Equatable, Sendable { case hidden, small, home }

public enum PresenceMachine {
    /// Next hover-driven state. Pointer in the hit area climbs one step (hidden, small, home);
    /// out of it, the state falls to small while sessions exist and to hidden otherwise.
    /// `demo` pins home. Alert pops are layered on top by the store.
    public static func next(_ s: Presence, hasSessions: Bool, inside: Bool, demo: Bool = false) -> Presence {
        if demo { return .home }
        if inside { return s == .hidden ? .small : .home }
        return hasSessions ? .small : .hidden
    }
}

/// Where the bar sits and how big it rests, from the real screen.
public struct BarGeometry: Equatable, Sendable {
    public static let fallbackNotchWidth: CGFloat = 184
    public static let noNotchWidth: CGFloat = 80
    public let hasNotch: Bool
    public let width: CGFloat
    public let height: CGFloat

    /// `menuBarHeight` is `frame.maxY - visibleFrame.maxY`; 0 (auto-hidden bar) falls back to 24.
    public init(screenWidth: CGFloat, safeAreaTop: CGFloat, auxLeft: CGFloat?, auxRight: CGFloat?, menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let l = auxLeft, let r = auxRight, screenWidth - l - r > 0, screenWidth - l - r < screenWidth { width = screenWidth - l - r }
            else { width = Self.fallbackNotchWidth }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = menuBarHeight > 0 ? menuBarHeight : 24
        }
    }
}

/// Which screen hosts Peek. Stored in UserDefaults key `screen`: "notch", "main", "mouse" or a display UUID.
public enum ScreenChoice: Equatable, Sendable {
    case notch, main, mouse
    case display(String)

    public init(_ stored: String?) {
        switch stored {
        case nil, "", "notch": self = .notch
        case "main": self = .main
        case "mouse": self = .mouse
        case let u?: self = .display(u)
        }
    }
    public var stored: String {
        switch self {
        case .notch: return "notch"
        case .main: return "main"
        case .mouse: return "mouse"
        case .display(let u): return u
        }
    }
}

public struct ScreenCandidate: Equatable, Sendable {
    public var uuid: String?, hasNotch: Bool, containsMouse: Bool
    public init(uuid: String?, hasNotch: Bool, containsMouse: Bool) { self.uuid = uuid; self.hasNotch = hasNotch; self.containsMouse = containsMouse }
}

public enum ScreenResolver {
    /// Index (in `NSScreen.screens` order, menu-bar screen first) of the screen to use. A missing display or
    /// no notch falls back to the notch screen, then the main screen; the saved choice is never rewritten here.
    public static func index(_ c: ScreenChoice, in s: [ScreenCandidate]) -> Int? {
        guard !s.isEmpty else { return nil }
        let notch = s.firstIndex { $0.hasNotch } ?? 0
        switch c {
        case .notch: return notch
        case .main: return 0
        case .mouse: return s.firstIndex { $0.containsMouse } ?? notch
        case .display(let u): return s.firstIndex { $0.uuid == u } ?? notch
        }
    }
}
