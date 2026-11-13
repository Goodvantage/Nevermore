import Testing
import Foundation
import RavenProtocol
@testable import NevermoreCore

private let me = "me@example.com"

private func channel(_ id: String, workspace: String? = nil, dm: Bool = false, extra: [String: JSONValue] = [:]) -> RavenChannel {
    var object: [String: JSONValue] = ["name": .string(id)]
    if let workspace { object["workspace"] = .string(workspace) }
    if dm { object["is_direct_message"] = .bool(true) }
    for (key, value) in extra { object[key] = value }
    return RavenChannel(raw: .object(object))
}

private func message(_ id: String, channel: String, owner: String = "other@example.com", type: String = "Text", extra: [String: JSONValue] = [:]) -> RavenMessage {
    var object: [String: JSONValue] = [
        "name": .string(id),
        "channel_id": .string(channel),
        "owner": .string(owner),
        "message_type": .string(type),
    ]
    for (key, value) in extra { object[key] = value }
    return RavenMessage(raw: .object(object))
}

/// One workspace with two channels, a second workspace, a DM that claims the
/// first workspace (servers must not put it there, but DMs are excluded by
/// flag, not by workspace value), and a thread channel under `general`.
private let channels = [
    channel("general", workspace: "engineering"),
    channel("design", workspace: "engineering"),
    channel("random", workspace: "ops"),
    channel("dm-alice", workspace: "engineering", dm: true),
    channel("thread-1", extra: ["is_thread": .bool(true), "parent_channel_id": .string("general")]),
]

// MARK: - Query normalization

@Test func queryIsTrimmedAndBoundedAt256Characters() {
    #expect(SearchCriteria(query: "  hello world  ").query == "hello world")
    let overLimit = SearchCriteria(query: String(repeating: "é", count: 300))
    #expect(overLimit.query.count == SearchCriteria.maxQueryLength)
    let atLimit = SearchCriteria(query: String(repeating: "q", count: SearchCriteria.maxQueryLength))
    #expect(atLimit.query.count == SearchCriteria.maxQueryLength)
}

// MARK: - Filter shapes

@Test func accountScopeEmitsNoChannelFilter() throws {
    #expect(try SearchCriteria().filters(channels: channels).isEmpty)
    #expect(try SearchCriteria(savedOnly: true).filters(channels: channels) == ["saved": .bool(true)])
}

@Test func conversationScopeIsAnExactChannelIDFilter() throws {
    let filters = try SearchCriteria(scope: .conversation("general")).filters(channels: channels)
    #expect(filters == ["channel_id": .string("general")])
}

@Test func workspaceScopeFiltersOnIndependentChannelIDs() throws {
    let filters = try SearchCriteria(scope: .workspace("engineering")).filters(channels: channels)
    // Only non-DM channels in the workspace; the DM claiming it and the
    // thread channel (no workspace of its own) are excluded.
    #expect(filters == ["channel_id": .array([.string("design"), .string("general")])])
}

@Test func workspaceScopeMatchesTheRequestedWorkspaceOnly() throws {
    let filters = try SearchCriteria(scope: .workspace("ops")).filters(channels: channels)
    #expect(filters == ["channel_id": .array([.string("random")])])
}

@Test func workspaceFilterSurvivesTheServersPermissionFilterMerge() throws {
    var serverFilters = try SearchCriteria(scope: .workspace("engineering")).filters(channels: channels)
    // Pinned Raven get_list combines {**filters, **permission_filters}.
    // Permission parent IDs are account-wide and overwrite that client key.
    serverFilters["parent_channel_id"] = .array([.string("general"), .string("design"), .string("random"), .string("dm-alice")])
    #expect(serverFilters["channel_id"] == .array([.string("design"), .string("general")]))
}

@Test func unresolvedWorkspaceThrowsRatherThanBroadening() {
    #expect(throws: SearchCriteriaError.unresolvableWorkspace("missing")) {
        try SearchCriteria(scope: .workspace("missing")).filters(channels: channels)
    }
    // A workspace only a DM claims is still unresolvable.
    #expect(throws: SearchCriteriaError.unresolvableWorkspace("engineering")) {
        try SearchCriteria(scope: .workspace("engineering")).filters(channels: [channel("dm-bob", workspace: "engineering", dm: true)])
    }
}

@Test func emptyAndWhitespaceIDsAreRejected() {
    #expect(throws: SearchCriteriaError.emptyIdentifier(field: "workspace")) {
        try SearchCriteria(scope: .workspace("   ")).filters(channels: channels)
    }
    #expect(throws: SearchCriteriaError.emptyIdentifier(field: "channel_id")) {
        try SearchCriteria(scope: .conversation("")).filters(channels: channels)
    }
    #expect(throws: SearchCriteriaError.emptyIdentifier(field: "owner")) {
        try SearchCriteria(author: " ").filters(channels: channels)
    }
}

@Test func kindsMapToVerifiedMessageTypes() throws {
    #expect(try SearchCriteria(kind: .text).filters(channels: channels) == ["message_type": .string("Text")])
    #expect(try SearchCriteria(kind: .files).filters(channels: channels) == ["message_type": .array([.string("File"), .string("Image")])])
    #expect(try SearchCriteria(kind: .images).filters(channels: channels) == ["message_type": .string("Image")])
    #expect(try SearchCriteria(kind: .polls).filters(channels: channels) == ["message_type": .string("Poll")])
    #expect(try SearchCriteria(kind: .all).filters(channels: channels).isEmpty)
}

@Test func authorAndMembershipFlagsUseVerifiedKeysOnly() throws {
    let filters = try SearchCriteria(
        scope: .conversation("general"), kind: .images, author: " alice@example.com ",
        savedOnly: true, mentionsMe: true
    ).filters(channels: channels)
    #expect(filters == [
        "channel_id": .string("general"),
        "message_type": .string("Image"),
        "owner": .string("alice@example.com"),
        "saved": .bool(true),
        "mentions_me": .bool(true),
    ])
    let allowed: Set<String> = ["channel_id", "parent_channel_id", "owner", "message_type", "saved", "mentions_me"]
    #expect(Set(filters.keys).isSubset(of: allowed))
    // `query` is an RPC argument, never a filter key.
    let queried = try SearchCriteria(query: "deploy").filters(channels: channels)
    #expect(!queried.keys.contains("query"))
}

@Test func filtersSurviveJSONEncodingAsAnObject() throws {
    let filters = try SearchCriteria(scope: .workspace("engineering"), kind: .files).filters(channels: channels)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(JSONValue.object(filters)))
    #expect(decoded == .object(filters))
}

// MARK: - Codable

@Test func criteriaRoundTripThroughCodable() throws {
    let criteria = SearchCriteria(
        query: "launch plan", scope: .workspace("engineering"), kind: .files,
        author: "alice@example.com", savedOnly: true, mentionsMe: true
    )
    #expect(try JSONDecoder().decode(SearchCriteria.self, from: JSONEncoder().encode(criteria)) == criteria)
    #expect(try JSONDecoder().decode(SearchCriteria.self, from: JSONEncoder().encode(SearchCriteria())) == SearchCriteria())
}

// MARK: - Cached predicate

@Test func matchesAppliesScopeAuthorAndKind() {
    let criteria = SearchCriteria(scope: .conversation("general"), kind: .images, author: "alice@example.com")
    let hit = message("m1", channel: "general", owner: "alice@example.com", type: "Image")
    #expect(criteria.matches(hit, channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m2", channel: "random", owner: "alice@example.com", type: "Image"), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m3", channel: "general", owner: "alice@example.com", type: "Text"), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m4", channel: "general", owner: "bob@example.com", type: "Image"), channels: channels, currentUser: me))
}

@Test func conversationMatchIsExactAndExcludesThreadReplies() {
    let criteria = SearchCriteria(scope: .conversation("general"))
    #expect(criteria.matches(message("m1", channel: "general"), channels: channels, currentUser: me))
    // The server's channel_id match is exact: a thread reply indexed under
    // its own channel is not part of the parent conversation's results.
    #expect(!criteria.matches(message("m2", channel: "thread-1", extra: ["parent_channel_id": .string("general")]), channels: channels, currentUser: me))
}

@Test func workspaceCacheMatchesTheServersChannelScopeAndAccountSearchIncludesThreads() {
    let criteria = SearchCriteria(scope: .workspace("engineering"))
    #expect(criteria.matches(message("m1", channel: "general"), channels: channels, currentUser: me))
    // Index-shaped row: raw parent_channel_id carries the attribution.
    #expect(!criteria.matches(message("m2", channel: "thread-1", extra: ["parent_channel_id": .string("general")]), channels: channels, currentUser: me))
    // Stream-shaped row: attribution resolves through the channel list.
    #expect(!criteria.matches(message("m3", channel: "thread-1"), channels: channels, currentUser: me))
    #expect(SearchCriteria().matches(message("m3", channel: "thread-1"), channels: channels, currentUser: me))
    // Other workspace, DM, and unattributable rows are excluded.
    #expect(!criteria.matches(message("m4", channel: "random"), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m5", channel: "dm-alice"), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m6", channel: "thread-dm", extra: ["parent_channel_id": .string("dm-alice")]), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m7", channel: "ghost"), channels: channels, currentUser: me))
}

@Test func unresolvableOrEmptyScopesMatchNothingLocally() {
    let hit = message("m1", channel: "general")
    #expect(!SearchCriteria(scope: .workspace("missing")).matches(hit, channels: channels, currentUser: me))
    #expect(!SearchCriteria(scope: .workspace("  ")).matches(hit, channels: channels, currentUser: me))
    #expect(!SearchCriteria(scope: .conversation("")).matches(hit, channels: channels, currentUser: me))
    #expect(!SearchCriteria(author: " ").matches(hit, channels: channels, currentUser: me))
}

@Test func savedOnlyRequiresProofForCurrentUser() {
    let criteria = SearchCriteria(savedOnly: true)
    // No metadata at all: excluded rather than assumed.
    #expect(!criteria.matches(message("m1", channel: "general"), channels: channels, currentUser: me))
    // Document rows: _liked_by is a JSON array string.
    let savedRow = message("m2", channel: "general", extra: ["_liked_by": .string(#"["me@example.com","other@example.com"]"#)])
    #expect(criteria.matches(savedRow, channels: channels, currentUser: me))
    #expect(!criteria.matches(savedRow, channels: channels, currentUser: "third@example.com"))
    // Index rows carry liked_by instead.
    #expect(criteria.matches(message("m3", channel: "general", extra: ["liked_by": .string(#"["me@example.com"]"#)]), channels: channels, currentUser: me))
    // An unquoted name is not proof: the server LIKEs the quoted user.
    #expect(!criteria.matches(message("m4", channel: "general", extra: ["_liked_by": .string("me@example.com")]), channels: channels, currentUser: me))
    // An empty current user can never prove membership.
    #expect(!criteria.matches(savedRow, channels: channels, currentUser: ""))
}

@Test func mentionsMeRequiresProofForCurrentUser() {
    let criteria = SearchCriteria(mentionsMe: true)
    #expect(!criteria.matches(message("m1", channel: "general"), channels: channels, currentUser: me))
    // Index rows carry |user|user|.
    #expect(criteria.matches(message("m2", channel: "general", extra: ["mentions": .string("|me@example.com|other@example.com|")]), channels: channels, currentUser: me))
    #expect(!criteria.matches(message("m3", channel: "general", extra: ["mentions": .string("|other@example.com|")]), channels: channels, currentUser: me))
    // Document rows carry the Raven Mention child table as objects.
    #expect(criteria.matches(message("m4", channel: "general", extra: ["mentions": .array([.object(["user": .string(me)])])]), channels: channels, currentUser: me))
    // Pipe boundaries prevent prefix matches on a longer user id.
    #expect(!criteria.matches(message("m5", channel: "general", extra: ["mentions": .string("|me@example.com|")]), channels: channels, currentUser: "me@example.co"))
    #expect(!criteria.matches(message("m6", channel: "general", extra: ["mentions": .string("|me@example.com|")]), channels: channels, currentUser: ""))
}
