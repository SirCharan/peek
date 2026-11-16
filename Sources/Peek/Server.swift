// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/HookServer.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation
import PeekCore

/// One PermissionRequest held open on the socket. The held connection is the key: answering writes one line to it,
/// giving up (or the hook process dying) closes it and the hook prints nothing.
final class PermRequest: @unchecked Sendable {
    let id = UUID().uuidString
    let sid: String, tool: String, cwd: String, input: [String: Any]
    /// The hook's own timestamp (ms); a later event of the session means the terminal prompt was answered.
    var t = 0.0
    /// Tooltip for the Always button ("" = the request carried no permission suggestion, so no Always).
    var always = ""
    /// Set for an AskUserQuestion; the answer is the answers dict as one JSON line.
    var ask: AskQuestion?
    private let lock = NSLock()
    private var verb: String?
    init(sid: String, tool: String, cwd: String, input: [String: Any]) { self.sid = sid; self.tool = tool; self.cwd = cwd; self.input = input }
    /// `allow` | `always` | `deny:<reason>` | answers JSON (ask); "" = give up without answering.
    func answer(_ v: String) { lock.lock(); if verb == nil { verb = v }; lock.unlock() }
    fileprivate var answered: String? { lock.lock(); defer { lock.unlock() }; return verb }
}

/// Unix-domain socket listener at ~/.peek/peek.sock. A nudge triggers a refresh; a PermissionRequest is held until answered in Peek, answered in the terminal, or timed out.
final class Server: @unchecked Sendable {
    static let maxConnections = 32, maxPayload = 1 << 20, holdSeconds = 110.0
    private let onNudge: @Sendable () -> Void
    private let onPermission: @Sendable (PermRequest) -> Void
    private let onGone: @Sendable (String) -> Void
    private let lock = NSLock()
    private var connections = 0

    init(onNudge: @escaping @Sendable () -> Void, onPermission: @escaping @Sendable (PermRequest) -> Void, onGone: @escaping @Sendable (String) -> Void) {
        self.onNudge = onNudge; self.onPermission = onPermission; self.onGone = onGone
    }

    func start() { Thread.detachNewThread { self.serve() } }

    private func serve() {
        let path = PeekPaths.sock
        // sun_path on macOS is 104 bytes including the NUL terminator
        let maxPath = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxPath else { NSLog("peek: socket path too long (\(path.utf8.count) > \(maxPath)): \(path)"); return }
        try? FileManager.default.createDirectory(atPath: PeekPaths.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)  // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let c = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in c.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { NSLog("peek: bind failed errno=\(errno)"); close(fd); return }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { close(fd); return }

        while true {
            let cfd = Darwin.accept(fd, nil, nil)
            guard cfd >= 0 else {
                let e = errno
                if e == EBADF || e == EINVAL || e == ENOTSOCK { break }
                if e != EINTR && e != ECONNABORTED { usleep(100_000) }
                continue
            }
            var euid: uid_t = 0, egid: gid_t = 0  // same-user connections only
            guard getpeereid(cfd, &euid, &egid) == 0, euid == getuid() else { close(cfd); continue }
            lock.lock(); let n = connections; if n < Self.maxConnections { connections += 1 }; lock.unlock()
            guard n < Self.maxConnections else { close(cfd); continue }
            Thread.detachNewThread { self.handle(cfd) }
        }
    }

    private func handle(_ fd: Int32) {
        defer { lock.lock(); connections -= 1; lock.unlock() }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)  // an unresponsive client must not hold the thread
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var raw = Data(), buf = [UInt8](repeating: 0, count: 4096)
        read: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            if let i = buf[0..<n].firstIndex(of: UInt8(ascii: "\n")) { raw.append(contentsOf: buf[0..<i]); break read }
            raw.append(contentsOf: buf[0..<n])
            if raw.count > Self.maxPayload { break }
        }
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let ev = o["ev"] as? String, ev == "PermissionRequest", let sid = Hook.safeSid(o["sid"]) else {
            onNudge(); close(fd); return
        }
        let input = o["tool_input"] as? [String: Any] ?? [:]
        let req = PermRequest(sid: sid, tool: o["tool_name"] as? String ?? "tool", cwd: o["cwd"] as? String ?? "", input: input)
        req.always = o["always"] as? String ?? ""
        req.t = (o["t"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        if req.tool == "AskUserQuestion" {
            guard let q = AskQuestion.parse(toolInput: input) else { close(fd); return }  // malformed: hang up, the terminal prompt stays the only one
            req.ask = q
        }
        onPermission(req)
        let deadline = Date().addingTimeInterval(Self.holdSeconds)
        while Date() < deadline {
            if let v = req.answered {
                if !v.isEmpty { _ = PeekSocket.send(fd, v) }
                break
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 50) > 0 {  // client hung up (hook killed)
                var b: UInt8 = 0
                if recv(fd, &b, 1, 0) <= 0 { break }
            }
        }
        close(fd)
        onGone(req.id)
    }
}
