import Foundation
import Testing
@testable import RavenProtocol

@Test func nestedServerJSONRemainsDistinctFromRichHTML() throws {
    let wire = #"{"name":"opaque/ID","channel_id":"one","creation":"2026-11-07 10:22:33.123456","text":"<p>Hello</p>","message_type":"Future Type","message_reactions":"{\"👍\":2}","is_reply":"1","unknown":{"enabled":true}}"#
    let raw = try JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))
    let message = RavenMessage(raw: raw)
    #expect(message.id == "opaque/ID")
    #expect(message.creation.hasSuffix("123456"))
    #expect(message.html == "<p>Hello</p>")
    #expect(message.messageType == "Future Type")
    #expect(raw["message_reactions"].nested["👍"] == .number(2))
    #expect(raw["is_reply"].bool)
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(raw)) == raw)
}
@Test func accountIdentityIsNotWorkspaceOrServerMessageID() throws {
    let origin = URL(string: "https://same.example")!
    let one = Account(origin: origin, user: "one", siteName: "internal", clientID: "client")
    let two = Account(origin: origin, user: "two", siteName: "internal", clientID: "client")
    #expect(one.id != two.id)
    #expect(one.origin == two.origin)
    #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(one)) == one)
}
@Test func unknownAndNullFieldsArePreserved() throws {
    let raw = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","content":null,"future":[1,true,"🦅"]}"#.utf8))
    #expect(raw["missing"] == .null)
    #expect(raw["future"].array.count == 3)
    #expect(RavenMessage(raw: raw).messageType == "Unknown")
    #expect(!JSONValue.null.bool)
    #expect(JSONValue.number(1).bool)
    #expect(!JSONValue.string("false").bool)
}

@Test func sqliteSearchIdentityUsesTheFrappeDocumentPrefix() {
    let raw = JSONValue.object(["id": .string("Raven Message:opaque:ID"), "channel_id": .string("channel"), "author": .string("alex"), "content": .string("Preview")])
    let normalized = RavenMessage(raw: RavenSearchResult.normalize(raw))
    #expect(normalized.id == "opaque:ID")
    #expect(normalized.owner == "alex")
    #expect(normalized.channelID == "channel")
}

@Test func directMessageUsesAccountSpecificDisplayName() {
    let channel = RavenChannel(raw: .object(["name": .string("opaque-dm"), "channel_name": .string("internal-name"), "channel_name_for_current_user": .string("Morgan"), "is_direct_message": .number(1)]))
    #expect(channel.title == "Morgan")
    #expect(channel.id == "opaque-dm")
    #expect(channel.isDM)
}
