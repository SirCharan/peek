import Foundation
import PeekCore

signal(SIGPIPE, SIG_IGN)
let input = FileHandle.standardInput.readDataToEndOfFile()
let raw = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]

func writeAtomic(_ path: String, _ data: Data) {
    let tmp = path + ".tmp\(getpid())"
    if FileManager.default.createFile(atPath: tmp, contents: data) { rename(tmp, path) }
}

/// Controlling tty of a process, e.g. "ttys003"; "" when it has none.
func tty(of pid: Int32) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, info.kp_eproc.e_tdev != -1 else { return "" }
    var buf = [CChar](repeating: 0, count: 64)
    guard devname_r(info.kp_eproc.e_tdev, S_IFCHR, &buf, 64) != nil else { return "" }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// MARK: --statusline: record context % / rate limits, then hand the same stdin to the user's previous command.
if CommandLine.arguments.contains("--statusline") {
    if let s = Hook.status(raw) {
        try? FileManager.default.createDirectory(atPath: PeekPaths.status, withIntermediateDirectories: true)
        writeAtomic("\(PeekPaths.status)/\(s.sid).json", s.json)
    }
    let prev = ((try? String(contentsOfFile: PeekPaths.prevStatusline, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prev.isEmpty else { exit(0) }
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", prev]
    p.standardInput = pipe
    guard (try? p.run()) != nil else { exit(0) }
    try? pipe.fileHandleForWriting.write(contentsOf: input)
    try? pipe.fileHandleForWriting.close()
    p.waitUntilExit()
    exit(p.terminationStatus)
}

let ppid = getppid()
guard var ev = Hook.event(raw, pid: ppid, tty: "") else { exit(0) }

// MARK: --ask (PreToolUse on AskUserQuestion): the app shows the questions; on any failure print nothing so the terminal asks.
if CommandLine.arguments.contains("--ask") {
    guard raw["tool_name"] as? String == "AskUserQuestion", let qs = (raw["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]],
          let fd = PeekSocket.connect(PeekPaths.sock, timeout: 0.3) else { exit(0) }
    ev["ev"] = "AskUserQuestion"; ev["tty"] = tty(of: ppid)
    guard let l = Hook.line(ev), PeekSocket.send(fd, l), let reply = PeekSocket.readLine(fd, timeout: 125),
          let out = Hook.askOutput(questions: qs, reply: reply) else { exit(0) }
    print(out)
    exit(0)
}

// MARK: PermissionRequest: ask the app over the socket; on any failure print nothing so Claude Code asks itself.
if ev["ev"] as? String == "PermissionRequest" {
    guard let fd = PeekSocket.connect(PeekPaths.sock, timeout: 0.3) else { exit(0) }
    let always = Hook.always(raw["permission_suggestions"] as? [[String: Any]] ?? [])
    if let always { ev["always"] = always.label }
    ev["tty"] = tty(of: ppid)
    guard let l = Hook.line(ev), PeekSocket.send(fd, l), let reply = PeekSocket.readLine(fd, timeout: 115),
          let out = Hook.decision(reply, tool: ev["tool_name"] as? String ?? "", rawInput: raw["tool_input"] as? [String: Any] ?? [:], always: always?.update) else { exit(0) }
    print(out)
    exit(0)
}

// MARK: everything else: append to the session's events file, then nudge the app.
ev["tty"] = tty(of: ppid)
guard let l = Hook.line(ev), let sid = ev["sid"] as? String else { exit(0) }
try? FileManager.default.createDirectory(atPath: PeekPaths.events, withIntermediateDirectories: true)
let path = "\(PeekPaths.events)/\(sid).jsonl"
if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
if let fh = FileHandle(forWritingAtPath: path) {
    _ = try? fh.seekToEnd()
    try? fh.write(contentsOf: Data((l + "\n").utf8))
    try? fh.close()
}
// keep the file small: past 400 lines keep the last 200 (only look once it is big enough to matter)
if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 64_000, let d = FileManager.default.contents(atPath: path) {
    let lines = d.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    if lines.count > 400 {
        var out = Data()
        for x in lines.suffix(200) { out.append(contentsOf: x); out.append(UInt8(ascii: "\n")) }
        writeAtomic(path, out)
    }
}
if let fd = PeekSocket.connect(PeekPaths.sock, timeout: 0.3) { _ = PeekSocket.send(fd, #"{"nudge":1}"#); close(fd) }
exit(0)
