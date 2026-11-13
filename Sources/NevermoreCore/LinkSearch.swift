import Foundation
import RavenProtocol

/// The pinned `search_links` RPC searches registered message links, including
/// links without previews. Its offset counts links, not unique messages.
public enum LinkSearch {
    public static let method = "raven.api.search.search_links"

    public static func source(_ criteria: SearchCriteria) throws -> CollectionSource {
        var arguments: [String: JSONValue] = [:]
        switch criteria.scope {
        case .account: break
        case .conversation(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SearchCriteriaError.emptyIdentifier(field: "channel_id") }
            arguments["channel_id"] = .string(id)
        case .workspace:
            throw SearchCriteriaError.unsupportedLinkWorkspace
        }
        if !criteria.query.isEmpty { arguments["search_text"] = .string(criteria.query) }
        if let author = criteria.author {
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SearchCriteriaError.emptyIdentifier(field: "owner") }
            arguments["owner"] = .string(author)
        }
        if criteria.savedOnly { arguments["saved"] = .number(1) }
        if criteria.mentionsMe { arguments["mentions_me"] = .number(1) }
        return CollectionSource(method: method, arguments: arguments, strategy: .offset(parameter: "start_after"), pageSize: 50)
    }

    /// Never fetch preview images or navigate returned URLs. Open routes to
    /// the source message; the composite key preserves its distinct links.
    public static func normalize(_ row: JSONValue) -> JSONValue {
        var fields = row.object
        if let id = row["id"].string {
            fields["message_id"] = .string(id)
            let key = JSONValue.array([.string(id), row["url"]])
            if let data = try? JSONEncoder().encode(key) { fields["Nevermore.LinkKey"] = .string(String(decoding: data, as: UTF8.self)) }
        }
        return .object(fields)
    }

    public static func preview(_ row: JSONValue) -> String {
        // The endpoint returns derived plain content, not message HTML.
        // Re-parsing would eat literal tags and decode literal entity names.
        let content = row["content"].string ?? ""
        let preview = String(content.prefix(4096))
        // Raven extracts links before masking spoilers in derived content.
        // This projection cannot classify which URL/title was inside a spoiler.
        if content.contains("▒▒▒▒▒▒") || content.contains("[Spoiler]") { return preview }
        return [String((row["title"].string ?? "").prefix(1024)), String((row["url"].string ?? "").prefix(8192)), preview].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
