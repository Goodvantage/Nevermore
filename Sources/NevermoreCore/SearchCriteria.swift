import Foundation
import RavenProtocol

/// Criteria that cannot be translated into verified server search keys.
public enum SearchCriteriaError: LocalizedError, Equatable {
    /// A scope identifier or author was empty or whitespace-only; `field`
    /// names the rejected search key.
    case emptyIdentifier(field: String)
    case unsupportedLinkWorkspace
    case linkEndpointRequired
    /// No locally known non-DM channel belongs to the workspace, so the
    /// workspace scope cannot be resolved to channel IDs. Falling back to
    /// account scope would silently broaden the search, so it is an error.
    case unresolvableWorkspace(String)
    public var errorDescription: String? {
        switch self {
        case .linkEndpointRequired: return "Links use the dedicated link-search endpoint."
        case .unsupportedLinkWorkspace: return "Links search supports This account or Conversation scope. Choose one before searching."
        case .emptyIdentifier(let field): return "Choose a valid value for \(field)."
        case .unresolvableWorkspace: return "No accessible channels are available in this workspace. Refresh the account before searching."
        }
    }
}

/// Search parameters for `raven.api.search.sqlite_search` and the cached
/// fallback that runs while (or instead of) a server request.
///
/// `filters(channels:)` emits only keys verified against the pinned contract
/// (`raven/api/search.py`, Raven `9b01029`): the indexed metadata fields
/// `channel_id`, `owner` and `message_type`, plus the
/// two special keys the endpoint accepts before filter validation, `saved`
/// and `mentions_me`. A scalar value means `field = value`, an array means
/// `field IN (...)`; the endpoint defines no other filter grammar and no
/// offset/cursor argument, so neither is expressed here. `query` is a
/// separate RPC argument, not a filter key.
public struct SearchCriteria: Codable, Sendable, Equatable {
    /// Message types plus the dedicated, independently paged Links search.
    public enum Kind: String, Codable, Sendable, Equatable {
        case all, text, files, images, polls, links
    }
    /// The set of messages a search runs over.
    public enum Scope: Codable, Sendable, Equatable {
        /// Every conversation the account can see. The server applies its
        /// own permission filter, so no filter key is emitted.
        case account
        /// One conversation, matched on the indexed `channel_id` exactly.
        /// Thread replies live in their own channels and are not included.
        case conversation(String)
        /// Messages in the workspace's non-DM channels. Thread replies remain
        /// available through account or explicit thread-conversation search.
        case workspace(String)
    }
    /// User text for the `query` argument; trimmed and bounded at
    /// `maxQueryLength` characters on init.
    public var query: String
    public var scope: Scope
    public var kind: Kind
    /// Restricts results to one author (`owner` exact match).
    public var author: String?
    /// Restricts results to messages the current user saved.
    public var savedOnly: Bool
    /// Restricts results to messages that mention the current user.
    public var mentionsMe: Bool

    /// Bound on `query`, in characters. Matches `Store.maxSearchQueryLength`.
    public static let maxQueryLength = 256

    public init(query: String = "", scope: Scope = .account, kind: Kind = .all, author: String? = nil, savedOnly: Bool = false, mentionsMe: Bool = false) {
        self.query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQueryLength))
        self.scope = scope
        self.kind = kind
        self.author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.savedOnly = savedOnly
        self.mentionsMe = mentionsMe
    }

    /// The `filters` argument for `sqlite_search`, as a JSON object.
    ///
    /// `channels` is the account's channel list, used to resolve a workspace
    /// scope to concrete `channel_id` values. Throws when a scope or
    /// author value is empty/whitespace-only, or when a workspace resolves
    /// to no non-DM channels — it never widens the scope to compensate.
    public func filters(channels: [RavenChannel]) throws -> [String: JSONValue] {
        var filters: [String: JSONValue] = [:]
        switch scope {
        case .account:
            break
        case .conversation(let id):
            filters["channel_id"] = .string(try Self.requiredText(id, field: "channel_id"))
        case .workspace(let id):
            let workspace = try Self.requiredText(id, field: "workspace")
            // This scope covers the workspace's ordinary channel IDs.
            // Thread replies remain searchable through account scope.
            let ids = Set(channels.filter { !$0.isDM && !$0.raw["is_thread"].bool && !$0.id.isEmpty && $0.workspace == workspace }.map(\.id)).sorted()
            guard !ids.isEmpty else { throw SearchCriteriaError.unresolvableWorkspace(workspace) }
            // Raven merges its account-wide parent-channel permission filter
            // over client filters. channel_id is independently intersected.
            filters["channel_id"] = .array(ids.map { .string($0) })
        }
        switch kind {
        case .links: throw SearchCriteriaError.linkEndpointRequired
        case .all: break
        case .text: filters["message_type"] = .string("Text")
        case .files: filters["message_type"] = .array([.string("File"), .string("Image")])
        case .images: filters["message_type"] = .string("Image")
        case .polls: filters["message_type"] = .string("Poll")
        }
        if let author {
            filters["owner"] = .string(try Self.requiredText(author, field: "owner"))
        }
        if savedOnly { filters["saved"] = .bool(true) }
        if mentionsMe { filters["mentions_me"] = .bool(true) }
        return filters
    }

    /// Whether a cached message satisfies the non-text criteria: scope,
    /// author, kind, and saved/mention membership.
    ///
    /// Only locally provable fields are claimed. `savedOnly`/`mentionsMe`
    /// require raw metadata that explicitly proves membership for
    /// `currentUser`; when it is absent the message is excluded rather than
    /// silently passed. Text matching is the caller's job (`Store.search`
    /// or equivalent), so `query` plays no part here.
    public func matches(_ message: RavenMessage, channels: [RavenChannel], currentUser: String) -> Bool {
        guard matchesScope(message, channels: channels), matchesKind(message) else { return false }
        if let author {
            let owner = author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty, message.owner == owner else { return false }
        }
        let user = currentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if savedOnly && !Self.provesSaved(message, user: user) { return false }
        if mentionsMe && !Self.provesMention(message, user: user) { return false }
        return true
    }

    private func matchesScope(_ message: RavenMessage, channels: [RavenChannel]) -> Bool {
        switch scope {
        case .account:
            return true
        case .conversation(let id):
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && message.channelID == id
        case .workspace(let id):
            let workspace = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspace.isEmpty else { return false }
            return channels.contains { !$0.isDM && !$0.raw["is_thread"].bool && $0.workspace == workspace && $0.id == message.channelID }
        }
    }

    private func matchesKind(_ message: RavenMessage) -> Bool {
        switch kind {
        case .links: return false // Link search has no complete cached-message equivalent.
        case .all: return true
        case .text: return message.messageType == "Text"
        case .files: return message.messageType == "File" || message.messageType == "Image"
        case .images: return message.messageType == "Image"
        case .polls: return message.messageType == "Poll"
        }
    }

    /// The personal-save field is `_liked_by` on the document and `liked_by`
    /// in the index; the server matches `liked_by LIKE '"<user>"'`, i.e. the
    /// quoted user inside a JSON array string.
    private static func provesSaved(_ message: RavenMessage, user: String) -> Bool {
        guard !user.isEmpty else { return false }
        for key in ["_liked_by", "liked_by"] {
            switch message.raw[key].nested {
            case .array(let users):
                if users.contains(where: { $0.string == user }) { return true }
            default: continue
            }
        }
        return false
    }

    /// Index rows carry `mentions` as a `|user|user|` string; document rows
    /// carry the Raven Mention child table as objects or a JSON string.
    private static func provesMention(_ message: RavenMessage, user: String) -> Bool {
        guard !user.isEmpty else { return false }
        switch message.raw["mentions"].nested {
        case .array(let rows):
            return rows.contains { $0["user"].string == user || $0.string == user }
        case .string(let text):
            return text.contains("|" + user + "|")
        default:
            return false
        }
    }

    private static func requiredText(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchCriteriaError.emptyIdentifier(field: field) }
        return trimmed
    }
}
