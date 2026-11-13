import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Test func broaderServerSearchCandidatesAreNarrowedOnEveryCollectionLoad() throws {
    let filters = String(decoding: try JSONEncoder().encode(JSONValue.object(["channel_id": .array([.string("workspace-channel")])])), as: UTF8.self)
    let source = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["filters": .string(filters)])
    let rows: [JSONValue] = [
        .object(["name": .string("allowed"), "channel_id": .string("workspace-channel")]),
        .object(["name": .string("other-workspace"), "channel_id": .string("other")]),
        .object(["name": .string("dm"), "channel_id": .string("dm-channel")])
    ]
    #expect(CollectionPaging.scopedSearchRows(rows, source: source) == [rows[0]])
    let account = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["filters": .string("{}")])
    #expect(CollectionPaging.scopedSearchRows(rows, source: account) == rows)
}

@Test func invalidOrEmptySearchChannelFiltersNeverBroadenResults() {
    let rows: [JSONValue] = [.object(["channel_id": .string("private")])]
    for filters in [#"{"channel_id":[]}"#, #"{"channel_id":""}"#, #"{"channel_id":true}"#] {
        let source = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["filters": .string(filters)])
        #expect(CollectionPaging.scopedSearchRows(rows, source: source).isEmpty)
    }
}
