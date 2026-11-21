import Foundation
import Testing
@testable import NevermoreCore

@Test func mentionDetectionUsesNativeUTF16Offsets() throws {
    let text = "👩🏽‍💻 مرحبا @Al"
    let query = try #require(MentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
    #expect(query.kind == .person)
    #expect(query.text == "Al")
    #expect((text as NSString).substring(with: query.range) == "@Al")
}
@Test func completionAvoidsEmailIMEAndSelectedText() {
    for value in ["person@example.com", "word#channel", "@two  spaces", "@line\nnext", "@bad/url"] {
        #expect(MentionCompletion.query(in: value, selection: NSRange(location: value.utf16.count, length: 0)) == nil)
    }
    #expect(MentionCompletion.query(in: "@Alex", selection: NSRange(location: 5, length: 0), hasMarkedText: true) == nil)
    #expect(MentionCompletion.query(in: "@Alex", selection: NSRange(location: 1, length: 2)) == nil)
    #expect(MentionCompletion.query(in: "", selection: NSRange(location: NSNotFound, length: 0)) == nil)
}
@Test func peopleAndChannelsMatchDiacriticsWithStableIdentity() throws {
    let people = [MentionCandidate(kind: .person, serverID: "b", title: "José Smith"), MentionCandidate(kind: .person, serverID: "a", title: "José Adams"), MentionCandidate(kind: .channel, serverID: "a", title: "José Adams")]
    let query = MentionQuery(kind: .person, range: NSRange(location: 0, length: 5), text: "jose")
    #expect(MentionCompletion.matches(people + [people[0]], query: query).map(\.serverID) == ["a","b"])
    #expect(MentionCompletion.matches(people, query: query, limit: 1).count == 1)
    let html = RichTextCodec.html(RichDocument(nodes: [people[0].node]))
    #expect(html.contains("data-id=\"b\""))
    #expect(html.contains("userMention"))
    #expect(RichTextCodec.html(RichDocument(nodes: [people[2].node])).contains("channelMention"))
}
@Test func triggerBoundariesAndMultiwordQueries() throws {
    for text in ["(@Alex S", "Hello #dev", "@", "\n#engineering"] {
        #expect(MentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0)) != nil)
    }
    let text = "@Alex S"
    #expect(try #require(MentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0))).text == "Alex S")
}
@Test func markdownCodeIsRecognizedBeforeTheCaret() {
    func inside(_ source: String) -> Bool { MentionCompletion.isInsideMarkdownCode(source, at: source.utf16.count) }
    #expect(!inside("plain @al"))
    #expect(inside("see `code @al"))
    #expect(!inside("see `code` @al"))
    #expect(inside("``a ` @al"))
    #expect(!inside("``a ` b`` @al"))
    #expect(!inside(#"\`not code @al"#))
    #expect(inside("```\nlet x = @al"))
    #expect(inside("```swift\nlet x = 1\n@al"))
    #expect(!inside("```\ncode\n```\n@al"))
    #expect(inside("~~~\n@al"))
    #expect(inside("~~~js @al"))
    #expect(!inside("see ~~~js @al"))
    #expect(!inside("    ~~~js @al"))
    // A closing backtick after the caret does not count, so the caret stays
    // inside the unclosed code span.
    #expect(MentionCompletion.isInsideMarkdownCode("see `code @al`", at: 13))
    #expect(inside("````\n```\n@al"))
    #expect(!inside("    ```\n@al"))
    #expect(!inside("``` not `a fence\n@al"))
    #expect(!MentionCompletion.isInsideMarkdownCode("", at: 0))
}

@Test func matchesRankFoldedTitlesDeterministically() throws {
    let people = [
        MentionCandidate(kind: .person, serverID: "1", title: "Alex Rivera"),
        MentionCandidate(kind: .person, serverID: "2", title: "alexandra fox"),
        MentionCandidate(kind: .person, serverID: "3", title: "Rafael Alex"),
        MentionCandidate(kind: .person, serverID: "4", title: "Álex García"),
        MentionCandidate(kind: .person, serverID: "0", title: "Alex García")
    ]
    let query = MentionQuery(kind: .person, range: NSRange(location: 0, length: 4), text: "alex")
    // Diacritics fold, exact titles outrank word-prefix matches, a
    // folded-title tie breaks on the stable server ID, and the duplicate
    // "Alex Rivera" entry is dropped by candidate-ID dedup.
    #expect(MentionCompletion.matches(people, query: query).map(\.serverID) == ["0", "4", "1", "2", "3"])
    #expect(MentionCompletion.matches(people + [people[0]], query: query).map(\.serverID) == ["0", "4", "1", "2", "3"])
}

@Test func destinationSearchRanksBeforeApplyingItsSharedLimit() {
    let person = MentionCandidate(kind: .person, serverID: "alex", title: "Álex")
    let channels = (1...101).map { MentionCandidate(kind: .channel, serverID: "c-\($0)", title: "Alex project \($0)") }
    let candidates = channels + [person, person]
    let mixed = MentionCompletion.matches(candidates, text: "alex", kind: nil)
    #expect(mixed.count == 100)
    #expect(mixed.first == person)
    #expect(mixed.filter { $0 == person }.count == 1)
    #expect(MentionCompletion.matches(candidates, text: "alex", kind: .person) == [person])
    #expect(MentionCompletion.matches(candidates, text: "alex", kind: .channel).allSatisfy { $0.kind == .channel })
    #expect(MentionCompletion.matches(candidates, text: "", kind: nil).allSatisfy { $0.kind == .channel })
}
