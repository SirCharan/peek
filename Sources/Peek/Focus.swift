// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/ClaudeHost.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import AppKit
import PeekCore

/// Per-session terminal: Terminal.app and iTerm2 by tty/session (AppleScript), other known terminals by activation.
/// Sessions with no resolvable host fall back to a Terminal.app title lookup. osascript always runs off-main.
@MainActor enum Focus {
    private static var cache: [String: (Date, (window: Int, tab: Int)?)] = [:]

    nonisolated private static func osa(_ script: String, _ args: [String] = []) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static let findScript = """
    on run argv
      set needle to item 1 of argv
      set sid to item 2 of argv
      if application "Terminal" is not running then return ""
      tell application "Terminal"
        if sid is not "" then
          repeat with i from 1 to count of windows
            repeat with j from 1 to count of tabs of window i
              if (custom title of tab j of window i) contains sid then return (i as text) & " " & (j as text)
            end repeat
          end repeat
        end if
        if needle is not "" then
          repeat with i from 1 to count of windows
            repeat with j from 1 to count of tabs of window i
              if (custom title of tab j of window i) contains needle then return (i as text) & " " & (j as text)
            end repeat
          end repeat
        end if
      end tell
      return ""
    end run
    """

    nonisolated static func lookup(title: String, sid: String, tty: String = "") -> (window: Int, tab: Int)? {
        var out = Terminals.terminalFind(tty: tty).map { osa($0) } ?? ""
        if out.isEmpty { out = osa(findScript, [title, String(sid.prefix(8))]) }  // daemon-hosted: the tty is not the tab's
        let r = out.split(separator: " ")
        guard r.count == 2, let w = Int(r[0]), let t = Int(r[1]) else { return nil }
        return (w, t)
    }

    /// Blocking lookup by title (cached 5 s). Call off-main.
    nonisolated static func tab(for title: String) -> (window: Int, tab: Int)? { lookup(title: title, sid: "") }

    /// Cached async lookup for a job; strips leading glyphs from the title.
    static func tab(_ job: Job) async -> (window: Int, tab: Int)? {
        let key = job.id
        if let c = cache[key], c.0 > Date() { return c.1 }
        let title = job.title.trimmingCharacters(in: .whitespaces), sid = job.sid, tty = job.term.tty
        let r = await Task.detached { lookup(title: title, sid: sid, tty: tty) }.value
        cache[key] = (Date().addingTimeInterval(5), r)
        return r
    }

    /// The session's terminal app: env identity, else the first known terminal up its parent chain, else nil (Terminal.app title lookup).
    static func host(_ job: Job) -> String? {
        if let h = Terminals.host(termProgram: job.term.tp, bundleId: job.term.bid) { return h }
        var pid = Int32(job.term.pid)
        for _ in 0..<12 where pid > 1 {
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, Terminals.names[id] != nil { return id }
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// Reply field offered: Terminal.app / iTerm2 (or an unresolved host, which uses the Terminal.app title lookup).
    static func canType(_ job: Job) -> Bool { host(job).map { Terminals.scriptable($0) } ?? true }
    /// A scriptable tab/session exists to type into.
    static func hasTab(_ job: Job) async -> Bool {
        host(job) == Terminals.iterm ? true : await tab(job) != nil
    }

    /// Open through Launch Services: since macOS 14 NSRunningApplication.activate() is ignored from an app that is not active, and the notch never is.
    static func activate(_ id: String) {
        let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id })
        if let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    static func jump(_ job: Job, store: Store) {
        Task {
            let h = host(job)
            if h == Terminals.iterm {
                let script = Terminals.itermJump(guid: Terminals.itermGuid(job.term.itsid), tty: job.term.tty)
                if let script, await Task.detached(operation: { osa(script) }).value == "ok" { return }
                activate(Terminals.iterm); return
            }
            if let h, !Terminals.scriptable(h) { activate(h); return }
            guard let t = await tab(job) else {
                if job.sid.isEmpty { store.flash(job.id, "no terminal tab"); return }
                // `claude attach <id|name>` accepts a session id: open it in a new window
                let cmd = "claude attach \(job.sid)"
                Task.detached { _ = osa("tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate") }
                return
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: Terminals.terminal).first?.activate()
            Task.detached {
                _ = osa("tell application \"Terminal\"\nset selected tab of window \(t.window) to tab \(t.tab) of window \(t.window)\nset frontmost of window \(t.window) to true\nend tell")
            }
        }
    }

    static func send(_ job: Job, _ text: String) {
        Task {
            if host(job) == Terminals.iterm {
                if let s = Terminals.itermSend(guid: Terminals.itermGuid(job.term.itsid), tty: job.term.tty, text: text) { Task.detached { _ = osa(s) } }
                return
            }
            guard Terminals.scriptable(host(job)) || host(job) == nil, let t = await tab(job) else { return }
            let script = Terminals.terminalSend(window: t.window, tab: t.tab, text: text)
            Task.detached { _ = osa(script) }
        }
    }

    private static var frontCache: [String: (Date, Bool)] = [:]
    /// True when the session's terminal app is frontmost and (Terminal.app / iTerm2) its tab is the selected one. Cached 2 s.
    static func isFront(_ job: Job) async -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        let h = host(job) ?? Terminals.terminal
        guard front == h else { return false }
        if !Terminals.scriptable(h) { return true }
        if let c = frontCache[job.id], c.0 > Date() { return c.1 }
        let title = job.title.trimmingCharacters(in: .whitespaces), sid = String(job.sid.prefix(8))
        let tty = Terminals.device(job.term.tty) ?? "-", guid = Terminals.itermGuid(job.term.itsid)
        let r = await Task.detached { () -> Bool in
            if h == Terminals.iterm {
                let p = osa(Terminals.itermFront).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return p.count == 2 && ((!guid.isEmpty && p[0] == guid) || p[1] == tty)
            }
            let p = osa(Terminals.terminalFront).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 2 else { return false }
            return p[0] == tty || (!title.isEmpty && p[1].contains(title)) || (!sid.isEmpty && p[1].contains(sid))
        }.value
        frontCache[job.id] = (Date().addingTimeInterval(2), r)
        return r
    }
}
