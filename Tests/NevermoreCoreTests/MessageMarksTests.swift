import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct MessageMarksTests {
    private func message(_ likedBy: JSONValue?) -> RavenMessage {
        var raw: [String: JSONValue] = ["name": .string("m1")]
        if let likedBy { raw["_liked_by"] = likedBy }
        return RavenMessage(raw: .object(raw))
    }

    @Test func savedReadsTheSerializedLikedByArray() {
        #expect(MessageMarks.isSaved(message(.string(#"["me@example.com","you@example.com"]"#)), by: "me@example.com"))
        #expect(MessageMarks.isSaved(message(.array([.string("me@example.com")])), by: "me@example.com"))
    }

    @Test func savedNeedsTheExactUser() {
        #expect(!MessageMarks.isSaved(message(.string(#"["you@example.com"]"#)), by: "me@example.com"))
        #expect(!MessageMarks.isSaved(message(.string("me@example.com")), by: "me@example.com"))
        #expect(!MessageMarks.isSaved(message(nil), by: "me@example.com"))
        #expect(!MessageMarks.isSaved(message(.null), by: "me@example.com"))
        #expect(!MessageMarks.isSaved(message(.string(#"[""]"#)), by: ""))
    }

    @Test func pinnedIDsSplitRavensNewlineList() {
        let channel = RavenChannel(raw: .object(["name": .string("c"), "pinned_messages_string": .string("a1\nb2\r\n c3 \n\n")]))
        #expect(MessageMarks.pinnedMessageIDs(in: channel) == ["a1", "b2", "c3"])
        #expect(MessageMarks.pinnedMessageIDs(in: RavenChannel(raw: .object(["name": .string("c")]))).isEmpty)
        #expect(MessageMarks.pinnedMessageIDs(in: RavenChannel(raw: .object(["name": .string("c"), "pinned_messages_string": .null]))).isEmpty)
    }
}
