import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

/// Pins the roster rules against the inspected Raven contract:
/// `get_channel_members` returns an object keyed by user ID whose values
/// carry `is_admin` (an IntField, so JSON 0/1) and `channel_member_name`.
@Suite struct MemberRosterTests {
    private func response(_ entries: [String: [String: JSONValue]]) -> JSONValue {
        .object(entries.mapValues(JSONValue.object))
    }

    @Test func pinnedResponseParsesUserIDsAndMembershipRecords() {
        let value = response([
            "alex@example.com": ["is_admin": .number(1), "channel_member_name": .string("RCM-0001")],
            "morgan@example.com": ["is_admin": .number(0), "channel_member_name": .string("RCM-0002")],
        ])
        let entries = MemberRoster.entries(from: value, names: [
            "alex@example.com": "Alex Morgan",
            "morgan@example.com": "Morgan Lee",
        ])
        #expect(entries.map(\.userID) == ["alex@example.com", "morgan@example.com"])
        #expect(entries.first?.displayName == "Alex Morgan")
        #expect(entries.first?.isAdmin == true)
        #expect(entries.first?.memberID == "RCM-0001")
        #expect(entries.last?.isAdmin == false)
        #expect(entries.last?.memberID == "RCM-0002")
    }

    @Test func pinnedResponseAlsoAcceptsBooleanAdminFlags() {
        let value = response(["alex@example.com": ["is_admin": .bool(true)]])
        #expect(MemberRoster.entries(from: value, names: [:]).first?.isAdmin == true)
    }

    @Test func everyReturnedMemberIsKeptBeyondTwoHundred() {
        let names = (0..<247).reduce(into: [String: String]()) { result, index in
            result[String(format: "user-%03d@example.com", index)] = String(format: "Member %03d", index)
        }
        let value = response(names.mapValues { _ in ["is_admin": .number(0)] })
        #expect(MemberRoster.entries(from: value, names: names).count == 247)
    }

    @Test func unexpectedResponseShapeIsNotASilentPartialRoster() {
        #expect(MemberRoster.entries(from: .array([.object(["full_name": .string("Alex")])]), names: [:]).isEmpty)
        #expect(MemberRoster.entries(from: .null, names: [:]).isEmpty)
    }

    @Test func duplicateDisplayNamesSortDeterministicallyByID() {
        let value = response([
            "zoe@example.com": ["is_admin": .number(0)],
            "alex@example.com": ["is_admin": .number(0)],
        ])
        let entries = MemberRoster.entries(from: value, names: [
            "zoe@example.com": "Alex",
            "alex@example.com": "Alex",
        ])
        #expect(entries.map(\.userID) == ["alex@example.com", "zoe@example.com"])
    }

    @Test func sortingUsesFoldedDisplayNameThenStableIdentity() {
        let value = response([
            "zoe@example.com": ["is_admin": .number(0)],
            "amy@example.com": ["is_admin": .number(0)],
            "ben@example.com": ["is_admin": .number(0)],
            "cat@example.com": ["is_admin": .number(0)],
        ])
        let entries = MemberRoster.entries(from: value, names: [
            "zoe@example.com": "Zoe",
            "amy@example.com": "Émile",
            "ben@example.com": "émile",
            "cat@example.com": "apple",
        ])
        #expect(entries.map(\.userID) == ["cat@example.com", "amy@example.com", "ben@example.com", "zoe@example.com"])
    }

    @Test func searchMatchesNamesAndUserIDsCaseAndDiacriticInsensitively() {
        let value = response([
            "emile@example.com": ["is_admin": .number(1), "channel_member_name": .string("RCM-0001")],
            "ana@example.com": ["is_admin": .number(0), "channel_member_name": .string("RCM-0002")],
        ])
        let entries = MemberRoster.entries(from: value, names: [
            "emile@example.com": "Émile Rowe",
            "ana@example.com": "Ana Silva",
        ])
        #expect(MemberRoster.filtered(entries, query: "emile").map(\.userID) == ["emile@example.com"])
        #expect(MemberRoster.filtered(entries, query: "émile rowe").map(\.userID) == ["emile@example.com"])
        #expect(MemberRoster.filtered(entries, query: "EMILE@EXAMPLE").map(\.userID) == ["emile@example.com"])
        #expect(MemberRoster.filtered(entries, query: "RCM-0002").map(\.userID) == ["ana@example.com"])
        #expect(MemberRoster.filtered(entries, query: "nobody").isEmpty)
        #expect(MemberRoster.filtered(entries, query: "  ").count == 2)
    }

    @Test func searchIndexMatchesIndependentReferenceAndKeepsOrder() {
        let entries = [
            MemberRosterEntry(userID: "zoe@example.com", displayName: "Zoë Lane", isAdmin: false, memberID: "RCM-0009"),
            MemberRosterEntry(userID: "ana@example.com", displayName: "Ana Silva", isAdmin: true, memberID: "RCM-0002"),
            MemberRosterEntry(userID: "emile@example.com", displayName: "Émile Rowe", isAdmin: false, memberID: "RCM-0001"),
        ]
        // Reference implementation written against the documented contract
        // (fold case/diacritics, split the query into words, every word must
        // appear in the folded "name id memberID" haystack, order preserved)
        // rather than against MemberRoster.filtered, which SearchIndex
        // delegates to — a parity check against it would be circular.
        func fold(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        func reference(_ query: String) -> [String] {
            let text = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return entries.map(\.userID) }
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            return entries.compactMap { entry in
                let haystack = fold([entry.displayName, entry.userID, entry.memberID ?? ""].joined(separator: " "))
                return words.allSatisfy(haystack.contains) ? entry.userID : nil
            }
        }
        let index = MemberRoster.SearchIndex(entries: entries)
        #expect(index.all.map(\.userID) == entries.map(\.userID))
        // "SILVA" pins the en_US_POSIX locale: its uppercase I folds to "i"
        // here, but to a dotless ı under a Turkish locale, where it would not
        // match the haystack.
        for query in ["", "  ", "ana", "ZOE", "SILVA", "émile", "ÉMILE", "RCM-0009", "example.com", "nobody", "ana example", "lane zoe"] {
            #expect(index.filtered(query: query).map(\.userID) == reference(query))
        }
        #expect(index.filtered(query: "example.com").count == 3)
        #expect(index.filtered(query: "  ").count == 3)
    }

    @Test func countLabelShowsTotalAndFilteredCount() {
        #expect(MemberRoster.countLabel(total: 0, shown: 0) == "No members")
        #expect(MemberRoster.countLabel(total: 1, shown: 1) == "1 member")
        #expect(MemberRoster.countLabel(total: 247, shown: 247) == "247 members")
        #expect(MemberRoster.countLabel(total: 247, shown: 3) == "3 of 247 members")
    }

    @Test func onlyAnotherNonEmptyUserCanOpenADirectMessage() {
        let entry = MemberRosterEntry(userID: "alex@example.com", displayName: "Alex", isAdmin: false, memberID: "RCM-0001")
        #expect(MemberRoster.canMessage(entry, accountUser: "me@example.com"))
        #expect(!MemberRoster.canMessage(entry, accountUser: "alex@example.com"))
        #expect(!MemberRoster.canMessage(MemberRosterEntry(userID: "", displayName: "", isAdmin: false, memberID: nil), accountUser: "me@example.com"))
    }
}
