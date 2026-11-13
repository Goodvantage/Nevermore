import Foundation
import Synchronization
import Testing
@testable import NevermoreCore

@Suite struct MessageDocumentCacheTests {
    @Test func sharesParsingButReturnsValueDocumentsAndReplacesExactHTMLEdits() throws {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(parse: { html in
            calls.withLock { $0 += 1 }; return try RichTextCodec.parse(html)
        })
        guard case .parsed(var first) = cache.document(channelID: "c", messageID: "m", html: "<p>old</p>") else { Issue.record("Missing document"); return }
        first.nodes = [.text("local presentation change")]
        #expect(RichTextCodec.plainText(first) == "local presentation change")
        #expect(cache.document(channelID: "c", messageID: "m", html: "<p>old</p>") == .parsed(try RichTextCodec.parse("<p>old</p>")))
        #expect(calls.withLock { $0 } == 1)
        #expect(cache.document(channelID: "c", messageID: "m", html: "<p>new</p>") == .parsed(try RichTextCodec.parse("<p>new</p>")))
        let composed = "<p>é</p>", decomposed = "<p>e\u{301}</p>"
        _ = cache.document(channelID: "c", messageID: "m", html: composed)
        guard case .parsed(let exact) = cache.document(channelID: "c", messageID: "m", html: decomposed) else { Issue.record("Missing edited document"); return }
        #expect(exact.rawHTML.utf8.elementsEqual(decomposed.utf8))
        #expect(calls.withLock { $0 } == 4)
    }

    @Test func channelMessageAndAccountCachesKeepOpaqueIdentitiesSeparate() {
        let calls = Mutex(0)
        let parse: @Sendable (String) throws -> RichDocument = { html in calls.withLock { $0 += 1 }; return try RichTextCodec.parse(html) }
        var first = MessageDocumentCache(parse: parse), second = MessageDocumentCache(parse: parse)
        for (channel, id) in [("a", "m"), ("b", "m"), ("a", "other"), ("a", "é"), ("a", "e\u{301}")] {
            _ = first.document(channelID: channel, messageID: id, html: "same")
            _ = first.document(channelID: channel, messageID: id, html: "same")
        }
        _ = second.document(channelID: "a", messageID: "m", html: "same")
        #expect(calls.withLock { $0 } == 6)
    }

    @Test func recentReadsKeepEntriesWarmWhenEntryLimitEvicts() {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(maximumEntries: 2, parse: { html in calls.withLock { $0 += 1 }; return try RichTextCodec.parse(html) })
        for id in ["a", "b", "a", "c", "a", "b"] { _ = cache.document(channelID: "c", messageID: id, html: id) }
        #expect(calls.withLock { $0 } == 4)
    }

    @Test func byteBudgetIncludesKeysAndRejectsOversizedEditsWithoutRetainingOldSource() {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(maximumBytes: 64, parse: { html in calls.withLock { $0 += 1 }; return try RichTextCodec.parse(html) })
        _ = cache.document(channelID: "c", messageID: "m", html: "small")
        let oversized = String(repeating: "x", count: 65)
        _ = cache.document(channelID: "c", messageID: "m", html: oversized)
        _ = cache.document(channelID: "c", messageID: "m", html: oversized)
        _ = cache.document(channelID: "c", messageID: "m", html: "small")
        let oversizedKey = String(repeating: "k", count: 100)
        _ = cache.document(channelID: "c", messageID: oversizedKey, html: "x")
        _ = cache.document(channelID: "c", messageID: oversizedKey, html: "x")
        let unboundedKey = String(repeating: "k", count: 100_000)
        _ = cache.document(channelID: unboundedKey, messageID: "m", html: "x")
        _ = cache.document(channelID: unboundedKey, messageID: "m", html: "x")
        #expect(calls.withLock { $0 } == 8)
    }

    @Test func nodeBudgetEvictsOldDocumentsAndBypassesIndividuallyOversizedTrees() {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(maximumNodes: 2, parse: { html in
            calls.withLock { $0 += 1 }
            return RichDocument(nodes: html == "large" ? [.text("a"), .text("b"), .text("c")] : [.text(html)])
        })
        for id in ["a", "b", "a", "c", "a", "b"] { _ = cache.document(channelID: "c", messageID: id, html: id) }
        #expect(calls.withLock { $0 } == 4)
        _ = cache.document(channelID: "c", messageID: "large", html: "large")
        _ = cache.document(channelID: "c", messageID: "large", html: "large")
        #expect(calls.withLock { $0 } == 6)
    }

    @Test func failedParsesAreBoundedCachedAndClearedWithPrivateDocuments() {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(maximumEntries: 2, parse: { html in
            calls.withLock { $0 += 1 }
            if html == "bad" { throw RichTextError.tooDeep }
            return try RichTextCodec.parse(html)
        })
        #expect(cache.document(channelID: "c", messageID: "bad", html: "bad") == .failed)
        #expect(cache.document(channelID: "c", messageID: "bad", html: "bad") == .failed)
        _ = cache.document(channelID: "c", messageID: "good", html: "private body")
        #expect(calls.withLock { $0 } == 2)
        cache.removeAll()
        #expect(cache.document(channelID: "c", messageID: "bad", html: "bad") == .failed)
        _ = cache.document(channelID: "c", messageID: "good", html: "private body")
        #expect(calls.withLock { $0 } == 4)
        _ = cache.document(channelID: "c", messageID: "third", html: "third")
        #expect(cache.document(channelID: "c", messageID: "bad", html: "bad") == .failed)
        #expect(calls.withLock { $0 } == 6)
    }

    @Test func defaultBudgetsKeepTheVisibleAndWarmConversationWorkingSet() {
        let calls = Mutex(0)
        var cache = MessageDocumentCache(parse: { html in calls.withLock { $0 += 1 }; return try RichTextCodec.parse(html) })
        for _ in 0..<2 {
            for index in 0..<700 {
                _ = cache.document(channelID: index < 500 ? "visible" : "warm", messageID: "m\(index)", html: "<p>message \(index)</p>")
            }
        }
        #expect(calls.withLock { $0 } == 700)
    }
}
