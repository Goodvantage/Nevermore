import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct LinkSearchTests {
    @Test func verifiedRequestAndOffset() throws {
        let criteria = SearchCriteria(query: "meeting", scope: .conversation("room"), kind: .links, author: "person", savedOnly: true, mentionsMe: true)
        let source = try LinkSearch.source(criteria)
        #expect(source.method == "raven.api.search.search_links")
        // Thread replies are included by default: the server resolves them
        // to their parent conversation.
        #expect(source.arguments == ["search_text": .string("meeting"), "parent_channel_id": .string("room"), "owner": .string("person"), "saved": .number(1), "mentions_me": .number(1)])
        var withoutThreads = criteria; withoutThreads.includeThreads = false; withoutThreads.attribute = .reactions
        #expect(try LinkSearch.source(withoutThreads).arguments == ["search_text": .string("meeting"), "channel_id": .string("room"), "owner": .string("person"), "saved": .number(1), "mentions_me": .number(1), "has_reactions": .number(1)])
        let arguments = CollectionPaging.pageArguments(source, offset: 50)
        #expect(arguments["start_after"] == .number(50))
        #expect(arguments["limit"] == .number(50))
        #expect(try LinkSearch.source(SearchCriteria(kind: .links)).arguments["channel_id"] == nil)
        #expect(throws: SearchCriteriaError.unsupportedLinkWorkspace) { try LinkSearch.source(SearchCriteria(scope: .workspace("w"), kind: .links)) }
    }
    @Test func distinctLinksRetainMessageAnchorAndPagingCount() throws {
        let first = LinkSearch.normalize(.object(["id": .string("message"), "url": .string("https://one.example")] ))
        let second = LinkSearch.normalize(.object(["id": .string("message"), "url": .string("https://two.example")] ))
        #expect(first["message_id"] == .string("message"))
        #expect(CollectionPaging.recordKey(first) != CollectionPaging.recordKey(second))
        var pager = CollectionPager(pageSize: 2)
        let generation = pager.beginRefresh()
        let refreshed = pager.applyRefresh([first, second], generation: generation)
        #expect(refreshed)
        #expect(pager.records.count == 2 && pager.nextOffset == 2 && pager.hasMore)
        let appended = pager.applyAppend([second], generation: generation)
        #expect(appended)
        #expect(pager.records.count == 2 && pager.nextOffset == 3 && !pager.hasMore)
    }
    @Test func scopeAndPreviewDoNotBroadenOrRevealSpoilers() throws {
        let source = try LinkSearch.source(SearchCriteria(scope: .conversation("room"), kind: .links, includeThreads: false))
        let rows: [JSONValue] = [.object(["channel_id": .string("room")]), .object(["channel_id": .string("other")]), .object(["channel_id": .string("thread"), "parent_channel_id": .string("room")])]
        #expect(CollectionPaging.scopedSearchRows(rows, source: source) == [rows[0]])
        // With threads, a reply in the conversation's thread stays and a
        // row from elsewhere is still dropped.
        let threaded = try LinkSearch.source(SearchCriteria(scope: .conversation("room"), kind: .links))
        #expect(CollectionPaging.scopedSearchRows(rows + [.object(["channel_id": .string("thread2"), "parent_channel_id": .string("other")])], source: threaded) == [rows[0], rows[2]])
        let preview = LinkSearch.preview(.object(["title": .string("Title"), "content": .string("public content"), "url": .string("javascript:alert(1)")]))
        #expect(preview.contains("public content"))
        // URLs remain inert text. No URL request or browser action belongs to this helper.
        #expect(preview.contains("javascript:"))
        #expect(LinkSearch.preview(.object(["url": .string("https://example.test/?x=1&copy=2")])) == "https://example.test/?x=1&copy=2")
        let decoded = try JSONDecoder().decode(SearchCriteria.self, from: JSONEncoder().encode(SearchCriteria(kind: .files)))
        #expect(decoded.kind == .files)
    }
    @Test func canonicalPlainPreviewPreservesLiterals() {
        let preview = LinkSearch.preview(.object(["title": .string("Use <T> &copy; literally"), "content": .string("a < b and <T> &copy;"), "url": .string("https://example.test/?x=1&copy=2")]))
        #expect(preview.contains("Use <T> &copy; literally"))
        #expect(preview.contains("a < b and <T> &copy;"))
        #expect(preview.contains("https://example.test/?x=1&copy=2"))
    }
    @Test func maskedCanonicalContentHidesUnclassifiedLinkMetadata() {
        let preview = LinkSearch.preview(.object(["title": .string("SECRET_TITLE"), "content": .string("public ▒▒▒▒▒▒"), "url": .string("https://secret.invalid/SECRET_URL")]))
        #expect(preview == "public ▒▒▒▒▒▒")
        #expect(!preview.contains("SECRET"))
    }
}
