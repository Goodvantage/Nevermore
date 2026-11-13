import Foundation
import Synchronization
import Testing
@testable import RavenProtocol

struct CustomEmojiPageTests {
    private let origin = URL(string: "https://site.test")!
    private func row(_ id: String = "party") -> JSONValue { .object(["name": .string(id), "emoji_name": .string(id), "image": .string("/files/party.png")]) }
    @Test func pageOffsetsAdvancePastUnavailableRows() throws {
        var rows = (0..<50).map { row("emoji-\($0)") }; rows[20] = .object(["name": .string("bad")])
        let page = try RavenCustomEmojiPage(raw: .array(rows), origin: origin, offset: 50)
        #expect(page.items.count == 49 && page.skippedCount == 1 && page.nextOffset == 100)
        let unavailable = try RavenCustomEmojiPage(raw: .array(Array(repeating: .null, count: 50)), origin: origin)
        #expect(unavailable.items.isEmpty && unavailable.skippedCount == 50 && unavailable.nextOffset == 50)
    }
    @Test func shortAndEmptyPagesEndWithoutClaimingMalformedAnswersAreEmpty() throws {
        #expect(try RavenCustomEmojiPage(raw: .array([row()]), origin: origin).nextOffset == nil)
        #expect(try RavenCustomEmojiPage(raw: .array([]), origin: origin).items.isEmpty)
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmojiPage(raw: .object([:]), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmojiPage(raw: .array(Array(repeating: row(), count: 51)), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmojiPage(raw: .array([]), origin: origin, offset: Int.max) }
    }
}

extension TransportSuite {
    @Test func customEmojiCatalogUsesPermissionFilteredListPaging() async throws {
        let session = StubURLProtocol.install { request in
            #expect(request.httpMethod == "GET" && request.url?.path == "/api/method/frappe.client.get_list")
            let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(fields["doctype"] == "Raven Custom Emoji" && fields["limit_start"] == "50" && fields["limit_page_length"] == "50")
            #expect(fields["order_by"] == "emoji_name asc")
            let requestedFields = try JSONDecoder().decode([String].self, from: Data((fields["fields"] ?? "").utf8))
            #expect(requestedFields == ["name", "emoji_name", "image", "keywords"])
            let filters = try JSONDecoder().decode([[String]].self, from: Data((fields["or_filters"] ?? "").utf8))
            #expect(filters == [["emoji_name", "like", "%party_%%"], ["keywords", "like", "%party_%%"]])
            return stubResponse(request, 200, #"{"message":[]}"#)
        }
        let page = try await client(session).customEmojiPage(query: " party_% ", offset: 50)
        #expect(page.items.isEmpty && page.nextOffset == nil)
    }
    @Test func invalidCatalogParametersFailBeforeAnyRequest() async throws {
        let requests = Mutex(0)
        let session = StubURLProtocol.install { request in requests.withLock { $0 += 1 }; return stubResponse(request, 200, #"{"message":[]}"#) }
        let raven = client(session)
        await #expect(throws: RavenError.invalidResponse) { try await raven.customEmojiPage(offset: -1) }
        await #expect(throws: RavenError.invalidResponse) { try await raven.customEmojiPage(offset: Int.max) }
        await #expect(throws: RavenError.invalidResponse) { try await raven.customEmojiPage(query: String(repeating: "🙂", count: 65)) }
        #expect(requests.withLock { $0 } == 0)
    }
}
