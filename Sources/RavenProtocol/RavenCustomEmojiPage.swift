import Foundation

/// One page of custom emoji from the generic Frappe list RPC.
///
/// The page advances by the raw row count the site sent, not by the number of
/// rows that parsed. A full page of 50 rows therefore always reports a next
/// offset, even when some rows were malformed or cross-origin, so a page full
/// of skipped rows can never be mistaken for the end of the sequence.
/// Oversized answers are rejected rather than truncated.
public struct RavenCustomEmojiPage: Sendable {
    /// Rows that satisfied the custom emoji contract, in server order.
    public let items: [RavenCustomEmoji]
    /// Raw rows that were malformed or pointed at another origin.
    public let skippedCount: Int
    /// Offset for the next `customEmojiPage` call, or nil when the site sent
    /// fewer rows than a full page.
    public let nextOffset: Int?

    /// Rows requested per page; the site is asked for exactly this many.
    public static let maximumRows = 50
    /// Maximum UTF-8 bytes accepted for a search query.
    fileprivate static let maximumQueryBytes = 256

    /// Parses the `message` array of `frappe.client.get_list`.
    ///
    /// `offset` must be a valid page start: non-negative and far enough below
    /// `Int.max` that advancing by one full page cannot overflow.
    public init(raw: JSONValue, origin: URL, offset: Int = 0) throws {
        guard offset >= 0, offset <= Int.max - Self.maximumRows else { throw RavenError.invalidResponse }
        guard case .array(let rows) = raw, rows.count <= Self.maximumRows else { throw RavenError.invalidResponse }

        var items: [RavenCustomEmoji] = []
        items.reserveCapacity(rows.count)
        var skippedCount = 0
        for row in rows {
            do {
                items.append(try RavenCustomEmoji(raw: row, origin: origin))
            } catch {
                skippedCount += 1
            }
        }

        self.items = items
        self.skippedCount = skippedCount
        self.nextOffset = rows.count == Self.maximumRows ? offset + rows.count : nil
    }
}

extension RavenClient {
    /// Fetches one page of custom emoji through `frappe.client.get_list`.
    ///
    /// The query is trimmed and matched with Frappe `like` wildcards against
    /// `emoji_name` and `keywords`; `%` and `_` in the query keep their Frappe
    /// wildcard meaning and are never re-escaped. Parsing stays on this actor.
    public func customEmojiPage(query: String = "", offset: Int = 0) async throws -> RavenCustomEmojiPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard offset >= 0, offset <= Int.max - RavenCustomEmojiPage.maximumRows,
              trimmedQuery.utf8.count <= RavenCustomEmojiPage.maximumQueryBytes else {
            throw RavenError.invalidResponse
        }

        var arguments: [String: JSONValue] = [
            "doctype": .string("Raven Custom Emoji"),
            "fields": .array(["name", "emoji_name", "image", "keywords"].map { JSONValue.string($0) }),
            "order_by": .string("emoji_name asc"),
            "limit_start": .string(String(offset)),
            "limit_page_length": .string(String(RavenCustomEmojiPage.maximumRows)),
        ]
        if !trimmedQuery.isEmpty {
            // Frappe LIKE wildcards in the query are deliberately preserved.
            let pattern = "%\(trimmedQuery)%"
            arguments["or_filters"] = .array([
                .array([.string("emoji_name"), .string("like"), .string(pattern)]),
                .array([.string("keywords"), .string("like"), .string(pattern)]),
            ])
        }

        let raw = try await rpc("frappe.client.get_list", arguments: arguments)
        return try RavenCustomEmojiPage(raw: raw, origin: origin, offset: offset)
    }
}
