import Foundation

/// Row text helpers: where a session's title comes from, and how a long message becomes a short phrase.
public enum SessionTitle {
    /// Better sources have a higher rank. A title never moves to a lower rank.
    public enum Source: Int, Comparable, Sendable {
        case cwd = 1, placeholder, prompt, name
        public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    /// Generated names such as `pasted-7595`, a bare 8-digit hex id, a long hex hash or a UUID are not titles.
    public static func isPlaceholder(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.isEmpty { return true }
        if n.wholeMatch(of: /pasted[-_ ]?[0-9a-f]{3,}/) != nil { return true }
        if n.wholeMatch(of: /[0-9a-f]{8}/) != nil || n.wholeMatch(of: /[0-9a-f]{12,}/) != nil { return true }
        return n.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
    }

    private static let injected = ["<system-reminder", "<command-name", "<command-message", "<command-args", "<local-command", "<agent-message",
                                   "<task-notification", "<user-prompt-submit-hook", "caveat:"]

    /// The human words of a prompt, or nil when it is system-injected, a slash command, or only a pasted block.
    public static func prompt(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = t.lowercased()
        if injected.contains(where: { low.hasPrefix($0) }) { return nil }
        t = t.replacing(/(?s)<pasted_content.*?<\/pasted_content>/, with: " ")
            .replacing(/(?s)<pasted_content.*$/, with: " ")
            .replacing(/\[(?:Pasted text|Image|Pasted image)[^\]]*\]/, with: " ")
            .replacing(/<[^>]*>/, with: " ")
            .replacing(/<[^>]*$/, with: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.firstMatch(of: /^\/[A-Za-z][\w:.\-]*(\s|$)/) != nil { return nil }
        t = t.replacing(/^[#>*\-\s`]+/, with: "")
        let w = t.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        return w.isEmpty ? nil : w
    }

    /// Cut at a word boundary with an ellipsis.
    public static func short(_ s: String, _ n: Int) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > n, n > 1 else { return t }
        let head = String(t.prefix(n))
        let atWord = t[t.index(t.startIndex, offsetBy: n)] == " "
        var cut = head
        if !atWord, let sp = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: sp) >= n / 3 { cut = String(head[..<sp]) }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\u{2013}\u{2014}("))
        return cut + "\u{2026}"
    }

    /// Picks the title. `previous` keeps a good title from sliding back to a worse source.
    public static func pick(name: String, prompt: String, cwdBase: String,
                            previous: (title: String, source: Source)?) -> (title: String, source: Source) {
        var c: (title: String, source: Source)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, !isPlaceholder(n) { c = (n, .name) }
        else if !prompt.isEmpty { c = (short(prompt, 40), .prompt) }
        else if !n.isEmpty { c = (n, .placeholder) }
        else { c = (cwdBase, .cwd) }
        if let p = previous, !p.title.isEmpty, p.source > c.source { return p }
        return c
    }

    private static func isMarker(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isEmojiPresentation { return true }
        switch s.properties.generalCategory { case .otherSymbol, .mathSymbol, .modifierSymbol: return true; default: return false }
    }

    /// First real sentence of a message. Skips empty lines, HTML comments, status lines that start with an emoji or symbol,
    /// rules, headings, code fences and table rows. Cut at a word boundary with an ellipsis.
    public static func sentence(_ text: String, _ n: Int = 60) -> String {
        let body = text.replacing(/(?s)<!--.*?-->/, with: "\n").replacing(/(?s)<!--.*$/, with: "")
        for var line in body.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let f = line.unicodeScalars.first else { continue }
            if isMarker(f) || "#|<".unicodeScalars.contains(f) || line.hasPrefix("```") { continue }
            if line.allSatisfy({ "-*_=~ \u{2500}\u{2501}".contains($0) }) { continue }
            line = line.replacing(/^(?:[-*>]|\d+[.)])\s+/, with: "").replacing(/[*_`]+/, with: "")
            if let m = line.firstMatch(of: /[.!?](?:\s|$)/) { line = String(line[..<m.range.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return short(line, n)
        }
        return ""
    }
}
