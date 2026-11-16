// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/ClaudeHost.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation

/// Which terminal app hosts a session, and the AppleScript for the two that can be scripted per tab (Terminal.app, iTerm2).
public enum Terminals {
    public static let terminal = "com.apple.Terminal", iterm = "com.googlecode.iterm2"

    /// Bundle id -> display name. Everything except Terminal and iTerm2 is activate-only.
    public static let names: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
        "dev.warp.Warp-Stable": "Warp", "dev.warp.Warp-Preview": "Warp",
        "com.mitchellh.ghostty": "Ghostty", "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty",
        "com.github.wez.wezterm": "WezTerm", "co.zeit.hyper": "Hyper", "dev.zed.Zed": "Zed",
        "com.cmuxterm.app": "cmux", "com.stablyai.orca": "Orca", "com.conductor.app": "Conductor", "com.t3tools.t3code": "T3 Code",
        "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor",
    ]
    static let programs: [String: String] = [
        "warpterminal": "dev.warp.Warp-Stable", "apple_terminal": terminal, "iterm.app": iterm, "ghostty": "com.mitchellh.ghostty",
        "kitty": "net.kovidgoyal.kitty", "alacritty": "org.alacritty", "wezterm": "com.github.wez.wezterm", "hyper": "co.zeit.hyper",
        "zed": "dev.zed.Zed", "vscode": "com.microsoft.VSCode",
    ]

    /// Host app from the hook's environment: `__CFBundleIdentifier` wins (cmux and Cursor set a borrowed TERM_PROGRAM), else TERM_PROGRAM.
    public static func host(termProgram: String, bundleId: String) -> String? {
        if names[bundleId] != nil { return bundleId }
        return programs[termProgram.lowercased()]
    }

    public static func scriptable(_ id: String?) -> Bool { id == terminal || id == iterm }

    /// AppleScript string literal: backslashes and quotes escaped, CR/LF kept as AppleScript escapes.
    public static func quote(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(e)\""
    }

    /// "ttys003" -> "/dev/ttys003"; nil for anything else (daemon-hosted sessions can report no tty).
    public static func device(_ tty: String) -> String? {
        tty.hasPrefix("ttys") && tty.count > 4 && tty.dropFirst(4).allSatisfy(\.isNumber) ? "/dev/" + tty : nil
    }

    /// `ITERM_SESSION_ID` is "w0t0p0:<guid>"; the guid is the session's `unique id`.
    public static func itermGuid(_ envId: String) -> String {
        let g = envId.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        return g.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") } ? g : ""
    }

    /// Terminal.app: prints "window tab" of the tab on this tty, else "".
    public static func terminalFind(tty: String) -> String? {
        guard let d = device(tty) else { return nil }
        return """
        if application "Terminal" is not running then return ""
        tell application "Terminal"
          repeat with i from 1 to count of windows
            repeat with j from 1 to count of tabs of window i
              if (tty of tab j of window i) is \(quote(d)) then return (i as text) & " " & (j as text)
            end repeat
          end repeat
        end tell
        return ""
        """
    }

    /// Terminal.app: "<tty>|<custom title>" of the selected tab of the front window.
    public static let terminalFront = "tell application \"Terminal\" to get (tty of selected tab of front window) & \"|\" & (custom title of selected tab of front window)"

    public static func terminalSend(window: Int, tab: Int, text: String) -> String {
        "tell application \"Terminal\" to do script \(quote(text)) in tab \(tab) of window \(window)"
    }

    private static func itermEach(guid: String, tty: String, _ body: String) -> String? {
        let d = device(tty)
        guard !guid.isEmpty || d != nil else { return nil }
        let test = [guid.isEmpty ? nil : "(unique id of s) is \(quote(guid))", d.map { "(tty of s) is \(quote($0))" }].compactMap { $0 }.joined(separator: " or ")
        return """
        if application "iTerm2" is not running then return ""
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if \(test) then
                  \(body)
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return ""
        """
    }

    /// iTerm2: select the session (by guid or tty), its tab and window, and activate. Prints "ok" on a match.
    public static func itermJump(guid: String, tty: String) -> String? {
        itermEach(guid: guid, tty: tty, "tell w to select\n tell t to select\n tell s to select\n activate")
    }
    public static func itermSend(guid: String, tty: String, text: String) -> String? {
        itermEach(guid: guid, tty: tty, "tell s to write text \(quote(text))")
    }
    /// iTerm2: "<guid>|<tty>" of the current session of the current window.
    public static let itermFront = "tell application \"iTerm2\" to get (unique id of current session of current window) & \"|\" & (tty of current session of current window)"
}
