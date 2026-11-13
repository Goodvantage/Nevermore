import Foundation
import Testing
@testable import RavenProtocol

struct RavenCustomEmojiTests {
    let origin = URL(string: "https://site.test")!

    private func payload(name: JSONValue = .string("opaque/ID:with:colons"),
                         emoji: JSONValue = .string(":party_raven:"),
                         image: JSONValue = .string("/private/files/emoji.png"),
                         keywords: JSONValue = .null) -> JSONValue {
        .object(["name": name, "emoji_name": emoji, "image": image, "keywords": keywords])
    }

    @Test func canonicalFieldsExposeOpaqueIdentityAndAbsentKeywordsBecomeEmpty() throws {
        let emoji = try RavenCustomEmoji(raw: payload(), origin: origin)
        #expect(emoji.id == "opaque/ID:with:colons")
        #expect(emoji.name == ":party_raven:")
        #expect(emoji.imagePath == "/private/files/emoji.png")
        #expect(emoji.keywords == "")

        let withoutKeywordsKey = try RavenCustomEmoji(
            raw: .object(["name": .string("opaque/ID"), "emoji_name": .string(":raven:"), "image": .string("/private/files/emoji.png")]),
            origin: origin
        )
        #expect(withoutKeywordsKey.keywords == "")
        #expect(try RavenCustomEmoji(raw: payload(keywords: .string("party,raven")), origin: origin).keywords == "party,raven")

        let preserved = try RavenCustomEmoji(raw: payload(name: .string("  Raven Custom Emoji:abc  ")), origin: origin)
        #expect(preserved.id == "  Raven Custom Emoji:abc  ")
    }

    @Test func imageURLsKeepPercentEncodingAndQueries() throws {
        let relative = try RavenCustomEmoji(
            raw: payload(image: .string("/private/files/my%20emoji.png?download=1&size=%2B2")),
            origin: origin
        )
        #expect(relative.imagePath == "/private/files/my%20emoji.png?download=1&size=%2B2")
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(image: .string("/files/" + String(repeating: "🙂", count: 1024))), origin: origin) }
        #expect(try RavenCustomEmoji(raw: payload(image: .string("a name.png?")), origin: origin).imagePath == "/a%20name.png?")

        let absolute = try RavenCustomEmoji(
            raw: payload(image: .string("https://site.test/private/files/a%2Fb.png?tag=%E2%9C%85")),
            origin: origin
        )
        #expect(absolute.imagePath == "/private/files/a%2Fb.png?tag=%E2%9C%85")
    }

    @Test func sameOriginAbsoluteImageURLsBecomeOriginRelative() throws {
        let defaultPort = try RavenCustomEmoji(
            raw: payload(image: .string("https://SITE.test:443/private/files/emoji.png?download=1")),
            origin: origin
        )
        #expect(defaultPort.imagePath == "/private/files/emoji.png?download=1")

        let explicitPort = try RavenCustomEmoji(
            raw: payload(image: .string("https://site.test:8443/files/emoji.png")),
            origin: URL(string: "https://site.test:8443")!
        )
        #expect(explicitPort.imagePath == "/files/emoji.png")
    }

    @Test func hostileImageLocationsAreRejected() {
        for value in ["https://other.test/files/a.png", "//other.test/files/a.png",
                      "https://user:password@site.test/files/a.png", "http://site.test/files/a.png",
                      "file:///private/files/a.png"] {
            #expect(throws: RavenError.crossOrigin) {
                try RavenCustomEmoji(raw: payload(image: .string(value)), origin: origin)
            }
        }
        for value in ["/", "https://site.test", "https://site.test/", "https://site.test/files/a.png#frag", "?download=1", "", "/files/.."] {
            #expect(throws: RavenError.invalidResponse) {
                try RavenCustomEmoji(raw: payload(image: .string(value)), origin: origin)
            }
        }
    }

    @Test func malformedRequiredFieldsAreRejected() {
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .number(7)), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(emoji: .bool(true)), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .string("")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(emoji: .string("")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .string(" ")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .string("bad\nid")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(emoji: .string("bad\u{7}name")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: .object([:]), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: .string("not an object"), origin: origin) }
    }

    @Test func identifierAndKeywordByteBoundsAreEnforced() throws {
        let maxIdentifier = String(repeating: "a", count: 512)
        let maxEmojiName = String(repeating: ":", count: 512)
        let accepted = try RavenCustomEmoji(raw: payload(name: .string(maxIdentifier), emoji: .string(maxEmojiName)), origin: origin)
        #expect(accepted.id == maxIdentifier)
        #expect(accepted.name == maxEmojiName)
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .string(maxIdentifier + "a")), origin: origin) }
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(emoji: .string(maxEmojiName + ":")), origin: origin) }

        #expect(try RavenCustomEmoji(raw: payload(name: .string(String(repeating: "🦅", count: 128))), origin: origin).id.count == 128)
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(name: .string(String(repeating: "🦅", count: 129))), origin: origin) }

        let maxKeywords = String(repeating: "k", count: 4096)
        #expect(try RavenCustomEmoji(raw: payload(keywords: .string(maxKeywords)), origin: origin).keywords == maxKeywords)
        #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(keywords: .string(maxKeywords + "k")), origin: origin) }
        for typed in [JSONValue.bool(true), .number(3), .array([.string("a")]), .object(["k": .string("v")])] {
            #expect(throws: RavenError.invalidResponse) { try RavenCustomEmoji(raw: payload(keywords: typed), origin: origin) }
        }
    }
}
