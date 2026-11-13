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
