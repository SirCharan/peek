// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/ShortcutLogic.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation

/// A virtual key code plus modifier bits (NSEvent.ModifierFlags raw values, masked to ⌃⌥⇧⌘).
public struct Shortcut: Equatable, Hashable, Sendable {
    public static let cmd: UInt = 1 << 20, shift: UInt = 1 << 17, opt: UInt = 1 << 19, ctrl: UInt = 1 << 18
    public static let mask: UInt = cmd | shift | opt | ctrl

    public let keyCode: UInt16
    public let flags: UInt
    public init(keyCode: UInt16, flags: UInt) { self.keyCode = keyCode; self.flags = flags & Self.mask }

    /// Stored form in UserDefaults: "<keyCode>:<flags>".
    public var stored: String { "\(keyCode):\(flags)" }
    public init?(stored: String) {
        let p = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, let k = UInt16(p[0]), let f = UInt(p[1]), f & Self.mask != 0 else { return nil }
        self.init(keyCode: k, flags: f)
    }

    /// Carbon modifier mask for `RegisterEventHotKey` (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    public var carbonModifiers: UInt32 {
        var c: UInt32 = 0
        if flags & Self.cmd != 0 { c |= 1 << 8 }
        if flags & Self.shift != 0 { c |= 1 << 9 }
        if flags & Self.opt != 0 { c |= 1 << 11 }
        if flags & Self.ctrl != 0 { c |= 1 << 12 }
        return c
    }

    /// "⌃⌥J": modifiers in system order, then the key.
    public var display: String {
        var s = ""
        if flags & Self.ctrl != 0 { s += "\u{2303}" }
        if flags & Self.opt != 0 { s += "\u{2325}" }
        if flags & Self.shift != 0 { s += "\u{21E7}" }
        if flags & Self.cmd != 0 { s += "\u{2318}" }
        return s + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }

    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`", 36: "\u{21A9}", 48: "\u{21E5}", 49: "Space", 51: "\u{232B}", 53: "\u{238B}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// The global actions. UserDefaults key `hotkey.<name>`: absent = default, "" = cleared, else `Shortcut.stored`.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case jump, allow, deny, toggle, mute

    public var title: String {
        switch self {
        case .jump: return "Jump to waiting session"
        case .allow: return "Allow first request"
        case .deny: return "Deny first request"
        case .toggle: return "Open or close card"
        case .mute: return "Mute or unmute sounds"
        }
    }
    public var defaultsKey: String { "hotkey." + rawValue }
    public var defaultShortcut: Shortcut {
        let co = Shortcut.ctrl | Shortcut.opt
        switch self {
        case .jump: return Shortcut(keyCode: 38, flags: co)
        case .allow: return Shortcut(keyCode: 0, flags: co)
        case .deny: return Shortcut(keyCode: 2, flags: co)
        case .toggle: return Shortcut(keyCode: 35, flags: co)
        case .mute: return Shortcut(keyCode: 46, flags: co)
        }
    }
    /// nil = cleared; an unreadable stored value falls back to the default.
    public func resolve(_ stored: String?) -> Shortcut? {
        guard let stored else { return defaultShortcut }
        return stored.isEmpty ? nil : (Shortcut(stored: stored) ?? defaultShortcut)
    }
}
