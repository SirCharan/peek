// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/CoucouKit/DiffEngine.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
}

public struct DiffHunk: Equatable, Sendable {
    public var lines: [DiffLine]
}

/// Line counts and hunks for one Edit / MultiEdit / Write. `capped`: the hook cut the input at 20 KB, so counts would be wrong and are left at 0.
public struct FileDiff: Equatable, Sendable {
    public var path: String
    public var added = 0
    public var removed = 0
    public var hunks: [DiffHunk] = []
    public var capped = false
    public var isNew = false
    public var name: String { (path as NSString).lastPathComponent }
}

public enum DiffEngine {
    /// Diff for a hook `tool_input`. nil when the tool is not an edit or nothing changed.
    public static func forTool(_ tool: String, _ input: [String: Any]) -> FileDiff? {
        guard let path = input["file_path"] as? String else { return nil }
        var d = FileDiff(path: path)
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            d = fromEdit(old: old, new: new, path: path)
            d.capped = isCapped(old) || isCapped(new)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            for e in edits {
                guard let old = e["old_string"] as? String, let new = e["new_string"] as? String else { continue }
                let x = fromEdit(old: old, new: new, path: path)
                d.added += x.added; d.removed += x.removed; d.hunks += x.hunks
                if isCapped(old) || isCapped(new) { d.capped = true }
            }
            if ((input["edits_dropped"] as? NSNumber)?.intValue ?? 0) > 0 { d.capped = true }
        case "Write":
            guard let content = input["content"] as? String, !content.isEmpty else { return nil }
            d = fromNew(content: content, path: path)
            d.capped = isCapped(content)
        default: return nil
        }
        if d.capped { d.added = 0; d.removed = 0; d.hunks = []; return d }
        return d.added > 0 || d.removed > 0 ? d : nil
    }

    private static func isCapped(_ s: String) -> Bool { s.utf8.count >= Hook.bigCap }

    static func fromEdit(old: String, new: String, path: String) -> FileDiff {
        let oldLines = splitLines(old), newLines = splitLines(new)
        // LCS is O(m*n): bail out to plain counts before the quadratic blowup
        if oldLines.count * newLines.count > 1_000_000 { return countFallback(oldLines, newLines, path) }
        let flat = buildDiffLines(oldLines, newLines)
        return FileDiff(path: path, added: flat.filter { $0.kind == .added }.count, removed: flat.filter { $0.kind == .removed }.count,
                        hunks: buildHunks(flat, context: 3))
    }

    static func fromNew(content: String, path: String) -> FileDiff {
        let lines = splitLines(content).map { DiffLine(kind: .added, text: $0) }
        return FileDiff(path: path, added: lines.count, hunks: lines.isEmpty ? [] : [DiffHunk(lines: lines)], isNew: true)
    }

    private static func splitLines(_ text: String) -> [String] {
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }  // trailing newline
        return parts
    }

    private static func buildDiffLines(_ a: [String], _ b: [String]) -> [DiffLine] {
        let m = a.count, n = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in 1...m { for j in 1...n {
                dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            } }
        }
        var matches: [(Int, Int)] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] { matches.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 }
            else { j -= 1 }
        }
        matches.reverse()
        var out: [DiffLine] = []
        var po = -1, pn = -1
        for (oi, ni) in matches + [(m, n)] {
            for k in (po + 1)..<oi { out.append(DiffLine(kind: .removed, text: a[k])) }
            for k in (pn + 1)..<ni { out.append(DiffLine(kind: .added, text: b[k])) }
            if oi < m { out.append(DiffLine(kind: .context, text: a[oi])) }
            po = oi; pn = ni
        }
        return out
    }

    private static func buildHunks(_ lines: [DiffLine], context: Int) -> [DiffHunk] {
        var merged: [(Int, Int)] = []
        for (i, l) in lines.enumerated() where l.kind != .context {
            let r = (max(0, i - context), min(lines.count - 1, i + context))
            if let last = merged.last, r.0 <= last.1 + 1 { merged[merged.count - 1].1 = max(last.1, r.1) } else { merged.append(r) }
        }
        return merged.map { DiffHunk(lines: Array(lines[$0.0...$0.1])) }
    }

    private static func countFallback(_ a: [String], _ b: [String], _ path: String) -> FileDiff {
        let sa = Set(a), sb = Set(b)
        return FileDiff(path: path, added: b.filter { !$0.isEmpty && !sa.contains($0) }.count, removed: a.filter { !$0.isEmpty && !sb.contains($0) }.count)
    }
}
