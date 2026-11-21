import Foundation

public struct MentionCandidate: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case person, channel }
    public var kind: Kind
    public var serverID: String
    public var title: String
    public var detail: String
    public var id: String { "\(kind.rawValue):\(serverID)" }
    public init(kind: Kind, serverID: String, title: String, detail: String = "") {
        self.kind = kind; self.serverID = serverID; self.title = title; self.detail = detail
    }
    public var node: RichNode {
        .element("span", ["data-type": kind == .person ? "userMention" : "channelMention", "data-id": serverID, "data-label": title], [.text((kind == .person ? "@" : "#") + title)])
    }
}
public struct MentionQuery: Sendable, Equatable {
    public var kind: MentionCandidate.Kind
    public var range: NSRange
    public var text: String
    public init(kind: MentionCandidate.Kind, range: NSRange, text: String) { self.kind = kind; self.range = range; self.text = text }
}
public enum MentionCompletion {
    /// Uses NSTextView's UTF-16 coordinates; IME marked text is never transformed.
    public static func query(in text: String, selection: NSRange, hasMarkedText: Bool = false) -> MentionQuery? {
        let value = text as NSString
        guard !hasMarkedText, selection.length == 0, selection.location != NSNotFound, selection.location > 0, selection.location <= value.length else { return nil }
        let line = value.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let start = max(line.location, selection.location - 128)
        let scan = NSRange(location: start, length: selection.location - start)
        let at = value.range(of: "@", options: .backwards, range: scan), hash = value.range(of: "#", options: .backwards, range: scan)
        let matches = [(at, MentionCandidate.Kind.person), (hash, .channel)].filter { $0.0.location != NSNotFound }
        guard let (trigger, kind) = matches.max(by: { $0.0.location < $1.0.location }) else { return nil }
        if trigger.location > 0 {
            let prefix = value.substring(with: NSRange(location: trigger.location - 1, length: 1))
            guard prefix.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || ["(","[","{",">"].contains(prefix) else { return nil }
        }
        let range = NSRange(location: trigger.location, length: selection.location - trigger.location)
        let query = value.substring(with: NSRange(location: trigger.location + 1, length: range.length - 1))
        guard query.count <= 64, !query.contains("  "), !query.hasPrefix(" "), query.unicodeScalars.allSatisfy({ CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters).union(CharacterSet(charactersIn: " ._-'’-")).contains($0) }) else { return nil }
        return MentionQuery(kind: kind, range: range, text: query)
    }
    /// True when the UTF-16 `location` in Markdown source lies in a fenced
    /// code block or after an unclosed backtick run on its line, where `@`
    /// and `#` are literal code rather than mentions. A tilde fence opened on
    /// the caret's own line (`~~~js @al`) suppresses the mention too.
    public static func isInsideMarkdownCode(_ source: String, at location: Int) -> Bool {
        guard location > 0, location <= source.utf16.count else { return false }
        var lines = String(decoding: source.utf16.prefix(location), as: UTF16.self).split(separator: "\n", omittingEmptySubsequences: false)
        let current = lines.removeLast()
        var fence: (marker: Character, length: Int)?
        for line in lines {
            let content = line.drop { $0 == " " }
            guard line.count - content.count <= 3, let marker = content.first, marker == "`" || marker == "~" else { continue }
            let length = content.prefix { $0 == marker }.count
            let rest = content.dropFirst(length)
            guard length >= 3 else { continue }
            if let open = fence {
                if marker == open.marker, length >= open.length, rest.allSatisfy(\.isWhitespace) { fence = nil }
            } else if marker == "~" || !rest.contains("`") {
                fence = (marker, length)
            }
        }
        if fence != nil { return true }
        // A tilde fence opened on the caret's own line suppresses the mention;
        // a backtick fence there is already caught by the unclosed-run scan.
        let content = current.drop { $0 == " " }
        if current.count - content.count <= 3, let marker = content.first, marker == "~", content.prefix { $0 == marker }.count >= 3 {
            return true
        }
        var open: Int?
        var index = current.startIndex
        while index < current.endIndex {
            let character = current[index]
            if character == "\\", open == nil {
                index = current.index(after: index)
                if index < current.endIndex { index = current.index(after: index) }
                continue
            }
            guard character == "`" else { index = current.index(after: index); continue }
            let run = current[index...].prefix { $0 == "`" }.count
            if let length = open { if length == run { open = nil } } else { open = run }
            index = current.index(index, offsetBy: run)
        }
        return open != nil
    }
    public static func matches(_ candidates: [MentionCandidate], query: MentionQuery, limit: Int = 50) -> [MentionCandidate] {
        matches(candidates, text: query.text, kind: query.kind, limit: limit)
    }

    /// The conversation chooser searches both kinds unless the reader types
    /// a prefix. Rank the whole directory before taking the displayed rows.
    public static func matches(_ candidates: [MentionCandidate], text: String, kind: MentionCandidate.Kind?, limit: Int = 100) -> [MentionCandidate] {
        let locale = Locale(identifier: "en_US_POSIX")
        func fold(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
        }
        let needle = fold(text).trimmingCharacters(in: .whitespaces)
        let words = needle.split(separator: " ")
        var seen = Set<String>()
        var ranked: [(candidate: MentionCandidate, rank: Int, title: String)] = []
        for candidate in candidates {
            guard kind == nil || candidate.kind == kind, seen.insert(candidate.id).inserted else { continue }
            let title = fold(candidate.title)
            let rank: Int
            if needle.isEmpty {
                // Preserve channel-first browsing for an empty chooser.
                rank = candidate.kind == .channel ? 0 : 1
            } else {
                let haystack = title + " " + fold(candidate.serverID + " " + candidate.detail)
                guard words.allSatisfy(haystack.contains) else { continue }
                if title.hasPrefix(needle) { rank = 0 }
                else if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { rank = 1 }
                else { rank = 2 }
            }
            ranked.append((candidate, rank, title))
        }
        ranked.sort { ($0.rank, $0.title, $0.candidate.id) < ($1.rank, $1.title, $1.candidate.id) }
        return ranked.prefix(max(0, min(limit, 100))).map(\.candidate)
    }
}
