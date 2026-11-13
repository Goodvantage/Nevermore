import Testing
import RavenProtocol
@testable import NevermoreCore

private func record(_ name: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = ["name": .string(name)]
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

// MARK: - CollectionSource

@Test func pageSizeDefaultsTo50AndIsClampedToServerCap() {
    #expect(CollectionSource(method: "m").pageSize == 50)
    #expect(CollectionSource(method: "m", pageSize: 0).pageSize == 1)
    #expect(CollectionSource(method: "m", pageSize: 500).pageSize == 100)
}

@Test func onlyVerifiedOffsetStrategiesSupportPaging() {
    #expect(CollectionSource(method: "m", strategy: .offset(parameter: "start")).supportsPaging)
    #expect(!CollectionSource(method: "m", strategy: .none).supportsPaging)
    #expect(!CollectionSource(method: "m").supportsPaging)
}

// MARK: - Page arguments

@Test func pageArgumentsInjectOffsetParameterAndLimitOverBaseArguments() {
    let source = CollectionSource(
        method: "raven.api.notifications.get_notifications",
        arguments: ["unread_only": .bool(true)],
        strategy: .offset(parameter: "start"),
        pageSize: 50
    )
    let arguments = CollectionPaging.pageArguments(source, offset: 100)
    #expect(arguments["start"] == .number(100))
    #expect(arguments["limit"] == .number(50))
    #expect(arguments["unread_only"] == .bool(true))
}

@Test func sqliteSearchStyleSourceNeverReceivesAnOffset() {
    // sqlite_search(query, filters, limit) has no paging argument in the pinned contract.
    let source = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["query": .string("hi")], strategy: .none)
    let arguments = CollectionPaging.pageArguments(source, offset: 200)
    #expect(arguments["limit"] == .number(50))
    #expect(arguments["query"] == .string("hi"))
    #expect(arguments.keys.allSatisfy { !["start", "start_after", "offset"].contains($0) })
}

@Test func negativeOffsetsAreClampedToZero() {
    let source = CollectionSource(method: "m", strategy: .offset(parameter: "start_after"))
    #expect(CollectionPaging.pageArguments(source, offset: -5)["start_after"] == .number(0))
}

// MARK: - Page end detection

@Test func hasMoreOnlyWhenThePageIsFull() {
    #expect(CollectionPaging.hasMore(received: 50, pageSize: 50))
    #expect(!CollectionPaging.hasMore(received: 49, pageSize: 50))
    #expect(!CollectionPaging.hasMore(received: 0, pageSize: 50))
}

// MARK: - Deduplication

@Test func dedupKeepsFirstOccurrenceOfOpaqueIDs() {
    let input = [record("a"), record("b"), record("a", ["text": .string("updated")]), record("c")]
    #expect(CollectionPaging.deduplicate(input) == [record("a"), record("b"), record("c")])
}

@Test func notificationRowsAreDedupedByNotificationIDNotByMessage() {
    // A mention and a reaction about the same message are distinct
    // notifications; only a repeated notification id is a duplicate.
    let mention = record("mention-1", ["message_id": .string("msg-1"), "notification_type": .string("mention")])
    let reaction = record("msg-1", ["message_id": .string("msg-1"), "notification_type": .string("reaction")])
    let repeated = record("mention-1", ["message_id": .string("msg-1"), "notification_type": .string("mention")])
    let output = CollectionPaging.deduplicate([mention, reaction, repeated])
    #expect(output.count == 2)
    #expect(output[0]["name"] == .string("mention-1"))
    #expect(output[1]["name"] == .string("msg-1"))
}

@Test func dedupFallsBackToIDThenMessageIDAndKeepsKeylessRows() {
    let search = JSONValue.object(["id": .string("Raven Message:xyz"), "channel_id": .string("c")])
    let sameSearch = JSONValue.object(["id": .string("Raven Message:xyz")])
    let messageOnly = JSONValue.object(["message_id": .string("m-9")])
    let messageOnlyDupe = JSONValue.object(["message_id": .string("m-9"), "text": .string("again")])
    let keyless = JSONValue.object(["text": .string("no id at all")])
    let output = CollectionPaging.deduplicate([search, sameSearch, messageOnly, messageOnlyDupe, keyless, keyless])
    #expect(output == [search, messageOnly, keyless, keyless])
}

// MARK: - Response extraction

@Test func extractRowsHandlesBareArraysAndMessagesEnvelope() {
    #expect(CollectionPaging.extractRows(.array([record("a")])) == [record("a")])
    #expect(CollectionPaging.extractRows(.object(["messages": .array([record("b")])])) == [record("b")])
    #expect(CollectionPaging.extractRows(.object(["messages": .array([])])) == [])
    #expect(CollectionPaging.extractRows(.array([])) == [])
    #expect(CollectionPaging.extractRows(.null) == [])
}

// MARK: - Pager state machine

@Test func initDeduplicatesSeedRecords() {
    let pager = CollectionPager(records: [record("a"), record("a"), record("b")])
    #expect(pager.records == [record("a"), record("b")])
    #expect(pager.nextOffset == 3) // server offsets count the duplicate wire row too
    #expect(pager.hasMore)
}

@Test func appendDeduplicatesAcrossPageBoundariesAndAdvancesServerOffset() {
    var pager = CollectionPager(pageSize: 2)
    let generation = pager.beginRefresh()
    let refreshed = pager.applyRefresh([record("a"), record("b")], generation: generation)
    #expect(refreshed)
    #expect(pager.hasMore && pager.nextOffset == 2)
    // Overlapping page (offset windows can repeat rows): deduped locally,
    // but the server offset still advances by the received row count.
    let appended = pager.applyAppend([record("b"), record("c")], generation: generation)
    #expect(appended)
    #expect(pager.records == [record("a"), record("b"), record("c")])
    #expect(pager.nextOffset == 4)
}

@Test func shortPageEndsPagingAndFurtherAppendsAreRejected() {
    var pager = CollectionPager(pageSize: 2)
    let generation = pager.beginRefresh()
    let refreshed = pager.applyRefresh([record("a"), record("b")], generation: generation)
    #expect(refreshed)
    let appended = pager.applyAppend([record("c")], generation: generation)
    #expect(appended)
    #expect(!pager.hasMore)
    #expect(pager.nextOffset == 3)
    let rejected = pager.applyAppend([record("d")], generation: generation)
    #expect(!rejected)
    #expect(pager.records == [record("a"), record("b"), record("c")])
}

@Test func staleGenerationPagesAreRejected() {
    var pager = CollectionPager(pageSize: 10)
    let first = pager.beginRefresh()
    let second = pager.beginRefresh() // a newer refresh supersedes the first
    let staleRefresh = pager.applyRefresh([record("x")], generation: first)
    #expect(!staleRefresh)
    #expect(pager.records.isEmpty)
    let freshRefresh = pager.applyRefresh([record("y")], generation: second)
    #expect(freshRefresh)
    #expect(pager.records == [record("y")])
    let staleAppend = pager.applyAppend([record("z")], generation: first)
    #expect(!staleAppend)
    #expect(pager.records == [record("y")])
}

@Test func invalidateDropsDelayedResultsFromClosedOrSwitchedCollections() {
    var pager = CollectionPager(pageSize: 10)
    let generation = pager.beginRefresh()
    pager.invalidate() // window closed / account switched / access revoked
    let staleRefresh = pager.applyRefresh([record("late")], generation: generation)
    let staleAppend = pager.applyAppend([record("late")], generation: generation)
    #expect(!staleRefresh && !staleAppend)
    #expect(pager.records.isEmpty)
    #expect(!pager.hasMore)
}

@Test func refreshReplacesRecordsAndResetsPaging() {
    var pager = CollectionPager(records: [record("old")], pageSize: 2)
    let generation = pager.beginRefresh()
    let applied = pager.applyRefresh([record("new-1"), record("new-2")], generation: generation)
    #expect(applied)
    #expect(pager.records == [record("new-1"), record("new-2")])
    #expect(pager.nextOffset == 2 && pager.hasMore)
}
