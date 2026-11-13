import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Test func quickReactionsDefaultToRavenWebsQuickEmoji() {
    #expect(QuickReactions.slots(mostUsed: []) == ["👍", "✅", "👀", "🎉", "🔥", "🤔", "❤️", "😂"])
    #expect(QuickReactions.slots(mostUsed: []).count == QuickReactions.slotCount)
}

@Test func quickReactionsPutMostUsedFirstWithoutDuplicates() {
    let response: JSONValue = .array([
        .object(["reaction": .string("🚀"), "is_custom": .number(0), "uses": .number(5)]),
        .object(["reaction": .string("👍"), "is_custom": .number(0), "uses": .number(3)]),
        .object(["reaction": .string("/files/party.png"), "is_custom": .number(1), "reaction_escaped": .string("party"), "uses": .number(2)]),
        // A custom row whose reaction is a single emoji grapheme would slip
        // through if the numeric flag were not honored.
        .object(["reaction": .string("🎯"), "is_custom": .number(1), "uses": .number(9)]),
        .object(["reaction": .string("not an emoji"), "is_custom": .number(0), "uses": .number(2)]),
        .object(["reaction": .number(42), "uses": .number(1)]),
        .object(["reaction": .string("🚀"), "is_custom": .number(0), "uses": .number(1)])
    ])
    let used = QuickReactions.mostUsed(from: response)
    #expect(used == ["🚀", "👍"])
    #expect(QuickReactions.slots(mostUsed: used) == ["🚀", "👍", "✅", "👀", "🎉", "🔥", "🤔", "❤️"])
}

@Test func quickReactionsBoundServerRowsAndSlots() {
    let many = ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😊", "😇", "🙂"]
    let response = JSONValue.array(many.map { .object(["reaction": .string($0), "is_custom": .bool(false)]) })
    #expect(QuickReactions.mostUsed(from: response) == Array(many.prefix(QuickReactions.usageLimit)))
    #expect(QuickReactions.slots(mostUsed: many) == Array(many.prefix(QuickReactions.slotCount)))
    #expect(QuickReactions.mostUsed(from: .object([:])).isEmpty)
    #expect(QuickReactions.mostUsed(from: .null).isEmpty)
}

@Test func quickReactionsKeepTheAccountsPresentationForm() {
    // ❤ without VS16 is a distinct Raven reaction; show it once, as used.
    let slots = QuickReactions.slots(mostUsed: ["❤"])
    #expect(slots.first == "❤")
    #expect(!slots.contains("❤️"))
    #expect(slots.count == QuickReactions.slotCount)
}

@Test func unicodeReactionsAcceptOneJoinedGrapheme() {
    for value in ["👍", "👍🏽", "👩🏽‍💻", "❤️", "🏳️‍🌈", "1️⃣", "#️⃣"] { #expect(QuickReactions.isUnicodeReaction(value)) }
    for value in ["", "👍👍", "ab", "3", "#", "*", "\u{7}", String(repeating: "👍", count: 20)] { #expect(!QuickReactions.isUnicodeReaction(value)) }
}

@Test func unicodeReactionsRejectGraphemesThatOnlyBorrowEmojiParts() {
    // Each is one grapheme carrying a selector, modifier or mark that used
    // to pass for an emoji: a bare selector, a letter or digit with one, a
    // letter with a skin tone, and an emoji with a stray combining mark.
    let junk = ["\u{FE0F}", "a\u{FE0F}", "3\u{FE0F}", "e\u{301}\u{FE0F}", "a\u{1F3FB}", "👍\u{301}", "👍\u{20E3}", "\u{200D}", "\u{E0067}"]
    for value in junk {
        #expect(value.count == 1)
        #expect(!QuickReactions.isUnicodeReaction(value), "\(value.unicodeScalars.map { String($0.value, radix: 16) })")
    }
    // A server row of this kind never reaches the row or the reacted marks.
    #expect(QuickReactions.mostUsed(from: .array([.object(["reaction": .string("a\u{FE0F}"), "is_custom": .number(0)])])).isEmpty)
    #expect(QuickReactions.reacted(by: "you@example.com", in: .object(["\u{FE0F}": .object(["users": .array([.string("you@example.com")]), "reaction": .string("\u{FE0F}")])])).isEmpty)
}

@Test func unicodeReactionsAcceptEveryEmojiSequenceKind() {
    let kinds = [
        "😀", "❤", "❤️", "❤\u{FE0E}", "©️",          // basic, with and without a presentation selector
        "1️⃣", "#\u{20E3}", "*️⃣",                  // keycaps, fully qualified or not
        "🇨🇭", "👍🏽", "🏻",                        // flag, modifier sequence, bare modifier
        "👩🏽‍💻", "🏳️‍🌈", "❤️‍🔥", "🧑‍🦰",          // joined sequences
        "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}" // tag sequence (England)
    ]
    for value in kinds { #expect(QuickReactions.isUnicodeReaction(value), "\(value)") }
    for value in QuickReactions.defaults { #expect(QuickReactions.isUnicodeReaction(value), "\(value)") }
}

@Test func reactedFindsOnlyTheUsersUnicodeReactions() {
    let reactions: JSONValue = .string(#"""
    {"👍": {"count": 2, "users": ["you@example.com", "alex@example.com"], "reaction": "👍", "is_custom": 0},
     "🎉": {"count": 1, "users": ["alex@example.com"], "reaction": "🎉", "is_custom": 0},
     "party": {"count": 1, "users": ["you@example.com"], "reaction": "/files/party.png", "is_custom": 1},
     "✅": {"count": 1, "users": ["you@example.com"], "is_custom": false}}
    """#)
    #expect(QuickReactions.reacted(by: "you@example.com", in: reactions) == ["👍", "✅"])
    #expect(QuickReactions.reacted(by: "alex@example.com", in: reactions) == ["👍", "🎉"])
    #expect(QuickReactions.reacted(by: "nobody@example.com", in: reactions).isEmpty)
    // Older aggregate shapes carry counts only, so nothing is marked as yours.
    #expect(QuickReactions.reacted(by: "you@example.com", in: .string(#"{"👍": 2}"#)).isEmpty)
    #expect(QuickReactions.reacted(by: "you@example.com", in: .null).isEmpty)
}
