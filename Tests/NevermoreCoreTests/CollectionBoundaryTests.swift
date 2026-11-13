import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Test func collectionCacheIsBoundToQueryAndChannelScope() {
    let first = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["query": .string("private"), "filters": .string("channel-a")])
    let second = CollectionSource(method: first.method, arguments: ["query": .string("private"), "filters": .string("channel-b")])
    #expect(first.cacheKey != second.cacheKey)
    #expect(first.cacheKey == CollectionSource(method: first.method, arguments: ["filters": .string("channel-a"), "query": .string("private")]).cacheKey)
    #expect(!first.cacheKey.contains("private"))
}
@Test func nonPagedMethodsDoNotInventUnsupportedLimitArguments() {
    let reminders = CollectionSource(method: "raven.api.reminders.get_reminders")
    #expect(CollectionPaging.pageArguments(reminders).isEmpty)
    let search = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["query": .string("x")])
    #expect(CollectionPaging.pageArguments(search)["limit"] == .number(50))
    #expect(CollectionPaging.pageArguments(search)["start"] == nil)
}
@Test func malformedCollectionResponsesAreVisibleFailures() {
    #expect(throws: RavenError.invalidResponse) { try CollectionPaging.decodeRows(.object(["unexpected": .array([])])) }
    #expect(throws: RavenError.invalidResponse) { try CollectionPaging.decodeRows(.null) }
}
@Test func notificationIdentityIncludesItsNotificationType() {
    let rows: [JSONValue] = [.object(["name":.string("same"),"message_id":.string("message"),"notification_type":.string("mention")]), .object(["name":.string("same"),"message_id":.string("message"),"notification_type":.string("reaction")])]
    #expect(CollectionPaging.deduplicate(rows).count == 2)
}
