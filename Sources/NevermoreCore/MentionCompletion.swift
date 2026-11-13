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
    public static func matches(_ candidates: [MentionCandidate], query: MentionQuery, limit: Int = 50) -> [MentionCandidate] {
        func fold(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let text = fold(query.text).trimmingCharacters(in: .whitespaces), words = text.split(separator: " ").map(String.init)
        var seen = Set<String>()
        return Array(candidates.filter { candidate in
            guard candidate.kind == query.kind, seen.insert(candidate.id).inserted else { return false }
            let haystack = fold(candidate.title + " " + candidate.serverID + " " + candidate.detail)
            return words.allSatisfy(haystack.contains)
        }.sorted { left, right in
            func rank(_ candidate: MentionCandidate) -> Int { let title = fold(candidate.title); return title.hasPrefix(text) ? 0 : title.split(separator: " ").contains(where: { $0.hasPrefix(text) }) ? 1 : 2 }
            let a = rank(left), b = rank(right)
            if a != b { return a < b }
            let titleA = fold(left.title), titleB = fold(right.title)
            if titleA != titleB { return titleA < titleB }
            return left.id < right.id
        }.prefix(max(0, min(limit, 100))))
    }
}
