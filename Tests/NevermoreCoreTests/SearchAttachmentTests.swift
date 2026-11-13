import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct SearchAttachmentTests {
    private let origin = URL(string: "https://chat.example")!
    private let row: JSONValue = .object(["id": .string("Raven Message:opaque/id"), "channel_id": .string("room"), "message_type": .string("File"), "internal_link": .string("https://evil.example/index-url")])
    @Test func searchRowsOnlyLocateCanonicalAttachments() throws {
        let identity = try #require(SearchAttachment(row))
        #expect(identity.messageID == "opaque/id")
        let canonical: JSONValue = .object(["name": .string("opaque/id"), "channel_id": .string("room"), "message_type": .string("File"), "file": .string("/private/files/canonical.pdf")])
        #expect(try identity.canonicalURL(canonical, origin: origin).absoluteString == "https://chat.example/private/files/canonical.pdf")
        for (key, value) in [("name", "different"), ("channel_id", "other"), ("message_type", "Text"), ("file", "https://evil.example/file"), ("file", "https://user@chat.example/file"), ("file", "/")] {
            var fields = canonical.object; fields[key] = .string(value)
            #expect(throws: RavenError.self) { try identity.canonicalURL(.object(fields), origin: origin) }
        }
    }
    @Test func invalidOrNonFileRowsHaveNoAttachmentAction() {
        for (key, value) in [("id", .string("")), ("channel_id", .string("\nroom")), ("message_type", .string("Text")), ("parent_channel_id", .string(""))] as [(String, JSONValue)] {
            var fields = row.object; fields[key] = value
            #expect(SearchAttachment(.object(fields)) == nil)
        }
    }
}
