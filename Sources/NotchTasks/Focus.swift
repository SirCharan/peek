import AppKit

/// Terminal.app tab lookup, jump and text injection. osascript always runs off-main.
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

    nonisolated static func lookup(title: String, sid: String) -> (window: Int, tab: Int)? {
        let r = osa(findScript, [title, String(sid.prefix(8))]).split(separator: " ")
        guard r.count == 2, let w = Int(r[0]), let t = Int(r[1]) else { return nil }
        return (w, t)
    }

    /// Blocking lookup by title (cached 5 s). Call off-main.
    nonisolated static func tab(for title: String) -> (window: Int, tab: Int)? { lookup(title: title, sid: "") }

    /// Cached async lookup for a job; strips leading glyphs from the title.
    static func tab(_ job: Job) async -> (window: Int, tab: Int)? {
        let key = job.id
        if let c = cache[key], c.0 > Date() { return c.1 }
        let title = job.title.trimmingCharacters(in: .whitespaces), sid = job.sid
        let r = await Task.detached { lookup(title: title, sid: sid) }.value
        cache[key] = (Date().addingTimeInterval(5), r)
        return r
    }

    static func jump(_ job: Job, store: Store) {
        Task {
            guard let t = await tab(job) else {
                if job.sid.isEmpty { store.flash(job.id, "no terminal tab"); return }
                // `claude attach <id|name>` accepts a session id: open it in a new window
                let cmd = "claude attach \(job.sid)"
                Task.detached { _ = osa("tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate") }
                return
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.activate()
            Task.detached {
                _ = osa("tell application \"Terminal\"\nset selected tab of window \(t.window) to tab \(t.tab) of window \(t.window)\nset frontmost of window \(t.window) to true\nend tell")
            }
        }
    }

    static func send(_ job: Job, _ text: String) {
        Task {
            guard let t = await tab(job) else { return }
            let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            Task.detached { _ = osa("tell application \"Terminal\" to do script \"\(esc)\" in tab \(t.tab) of window \(t.window)") }
        }
    }

    private static var frontCache: [String: (Date, Bool)] = [:]
    /// True when Terminal is frontmost and its selected tab's title contains the job title. Cached 2 s.
    static func isFront(_ job: Job) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return false }
        if let c = frontCache[job.id], c.0 > Date() { return c.1 }
        let title = job.title.trimmingCharacters(in: .whitespaces), sid = String(job.sid.prefix(8))
        let t = await Task.detached { osa("tell application \"Terminal\" to get custom title of selected tab of front window") }.value
        let r = !t.isEmpty && ((!title.isEmpty && t.contains(title)) || (!sid.isEmpty && t.contains(sid)))
        frontCache[job.id] = (Date().addingTimeInterval(2), r)
        return r
    }
}
