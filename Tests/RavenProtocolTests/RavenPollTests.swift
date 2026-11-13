import Foundation
import Testing
@testable import RavenProtocol

struct RavenPollTests {
    private func payload(
        poll: [String: JSONValue],
        currentVotes: JSONValue = .array([]),
        votes: JSONValue = .object([:])
    ) -> JSONValue {
        .object([
            "poll": .object(poll),
            "current_user_votes": currentVotes,
            "votes": votes,
        ])
    }

    private func basePoll(_ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var poll: [String: JSONValue] = [
            "name": .string("POLL-1"),
            "channel_id": .string("CHAN-1"),
            "owner": .string("alex@example.com"),
            "question": .string("Lunch?"),
            "is_multi_choice": .number(0),
            "is_anonymous": .number(0),
            "is_disabled": .number(0),
            "max_choices": .number(1),
            "total_votes": .number(2),
            "options": .array([
                .object(["name": .string("OPT-A"), "option": .string("Pizza"), "votes": .number(1)]),
                .object(["name": .string("OPT-B"), "option": .string("Salad"), "votes": .number(1)]),
            ]),
            "end_date": .string("2026-11-08 12:00:00"),
        ]
        for (key, value) in overrides { poll[key] = value }
        return poll
    }

    @Test func canonicalPollDocumentsDoNotContainAChannelField() throws {
        var poll = basePoll(); poll.removeValue(forKey: "channel_id")
        let snapshot = try RavenPollSnapshot(getPoll: payload(poll: poll))
        #expect(snapshot.id == "POLL-1" && snapshot.options.count == 2)
    }

    @Test func parsesGetPollWithNumericAndBoolFlags() throws {
        let snapshot = try RavenPollSnapshot(getPoll: payload(
            poll: basePoll([
                "is_multi_choice": .bool(true),
                "is_anonymous": .bool(false),
                "is_disabled": .bool(true),
                "max_choices": .string("3"),
                "total_votes": .string("5"),
            ]),
            currentVotes: .array([.object(["option": .string("OPT-A"), "name": .string("SEL-1")])]),
            votes: .object(["OPT-A": .array([.string("alex@example.com"), .string("sam@example.com")])])
        ))

        #expect(snapshot.id == "POLL-1")
        #expect(snapshot.owner == "alex@example.com")
        #expect(snapshot.question == "Lunch?")
        #expect(snapshot.multiChoice)
        #expect(!snapshot.anonymous)
        #expect(snapshot.closed)
        #expect(snapshot.maxChoices == 3)
        #expect(snapshot.totalVotes == 5)
        #expect(snapshot.endDate == "2026-11-08 12:00:00")
        #expect(snapshot.options.map(\.id) == ["OPT-A", "OPT-B"])
        #expect(snapshot.options.map(\.text) == ["Pizza", "Salad"])
        #expect(snapshot.options.map(\.voteCount) == [1, 1])
        #expect(snapshot.selectedOptionIDs == ["OPT-A"])
        #expect(snapshot.votersByOption["OPT-A"] == ["alex@example.com", "sam@example.com"])
    }

    @Test func anonymousPollDiscardsHostileVoterIdentitiesButKeepsSelection() throws {
        let snapshot = try RavenPollSnapshot(getPoll: payload(
            poll: basePoll(["is_anonymous": .number(1)]),
            currentVotes: .array([.object(["option": .string("OPT-B")])]),
            votes: .object([
                "OPT-A": .array([.string("leak@example.com")]),
                "OPT-B": .array([.string("leak@example.com")]),
            ])
        ))

        #expect(snapshot.anonymous)
        #expect(snapshot.selectedOptionIDs == ["OPT-B"])
        #expect(snapshot.votersByOption.isEmpty)
    }

    @Test func existingVotesRequireExplicitRetractionAndOlderServersMayOmitVoterDetails() throws {
        let snapshot = try RavenPollSnapshot(getPoll: payload(poll: basePoll(), currentVotes: .array([.object(["option": .string("OPT-A")])])))
        #expect(throws: RavenPollSnapshot.SelectionError.alreadyVoted) { try snapshot.validateSelection(["OPT-B"]) }
        var older = payload(poll: basePoll()).object; older.removeValue(forKey: "votes")
        #expect(try RavenPollSnapshot(getPoll: .object(older)).votersByOption.isEmpty)
    }

    @Test func multiChoiceMaxZeroMeansUnlimited() throws {
        let snapshot = try RavenPollSnapshot(getPoll: payload(
            poll: basePoll([
                "is_multi_choice": .number(1),
                "max_choices": .number(0),
                "options": .array([
                    .object(["name": .string("OPT-A"), "option": .string("A"), "votes": .number(0)]),
                    .object(["name": .string("OPT-B"), "option": .string("B"), "votes": .number(0)]),
                    .object(["name": .string("OPT-C"), "option": .string("C"), "votes": .number(0)]),
                    .object(["name": .string("OPT-D"), "option": .string("D"), "votes": .number(0)]),
                ]),
            ])
        ))

        try snapshot.validateSelection(["OPT-A", "OPT-B", "OPT-C", "OPT-D"])
    }

    @Test func selectionValidationRejectsInvalidStates() throws {
        let single = try RavenPollSnapshot(getPoll: payload(poll: basePoll()))
        #expect(throws: RavenPollSnapshot.SelectionError.empty) { try single.validateSelection([]) }
        #expect(throws: RavenPollSnapshot.SelectionError.duplicate) { try single.validateSelection(["OPT-A", "OPT-A"]) }
        #expect(throws: RavenPollSnapshot.SelectionError.unknown) { try single.validateSelection(["OPT-MISSING"]) }
        #expect(throws: RavenPollSnapshot.SelectionError.excessive) { try single.validateSelection(["OPT-A", "OPT-B"]) }
        try single.validateSelection(["OPT-A"])

        let limited = try RavenPollSnapshot(getPoll: payload(poll: basePoll([
            "is_multi_choice": .number(1),
            "max_choices": .number(2),
            "options": .array([
                .object(["name": .string("OPT-A"), "option": .string("A"), "votes": .number(0)]),
                .object(["name": .string("OPT-B"), "option": .string("B"), "votes": .number(0)]),
                .object(["name": .string("OPT-C"), "option": .string("C"), "votes": .number(0)]),
            ]),
        ])))
        #expect(throws: RavenPollSnapshot.SelectionError.excessive) { try limited.validateSelection(["OPT-A", "OPT-B", "OPT-C"]) }

        let closed = try RavenPollSnapshot(getPoll: payload(poll: basePoll(["is_disabled": .number(1)])))
        #expect(throws: RavenPollSnapshot.SelectionError.closed) { try closed.validateSelection(["OPT-A"]) }
    }

    @Test func rejectsDuplicateUnknownAndUnsafeOptionIdentities() async {
        let duplicate = basePoll([
            "options": .array([
                .object(["name": .string("OPT-A"), "option": .string("A"), "votes": .number(0)]),
                .object(["name": .string("OPT-A"), "option": .string("B"), "votes": .number(0)]),
            ]),
        ])
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: duplicate)) }

        let unknownSelection = payload(
            poll: basePoll(),
            currentVotes: .array([.object(["option": .string("OPT-MISSING")])])
        )
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: unknownSelection) }

        let hostileVoteKey = payload(
            poll: basePoll(),
            votes: .object(["OPT-MISSING": .array([.string("alex@example.com")])])
        )
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: hostileVoteKey) }

        let unsafeID = basePoll(["name": .string("")])
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: unsafeID)) }
    }

    @Test func rejectsUnrepresentableCountersAndUnknownClosedState() {
        for value in [Double(Int.max), .infinity, .nan, -1, 1.5] {
            #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: basePoll(["total_votes": .number(value)]))) }
        }
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: basePoll(["is_disabled": .null]))) }
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: basePoll(["name": .string("invalid\nidentity")]))) }
    }

    @Test func rejectsMalformedAndOutOfBoundsPayloads() async {
        var missingIdentity = basePoll(); missingIdentity.removeValue(forKey: "name")
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: missingIdentity)) }

        let malformedOptions = basePoll(["options": .string("bad")])
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: malformedOptions)) }

        let tooManyOptions = basePoll(["options": .array((0..<101).map {
            .object(["name": .string("OPT-\($0)"), "option": .string("O"), "votes": .number(0)])
        })])
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: tooManyOptions)) }

        let badFlag = basePoll(["is_multi_choice": .number(2)])
        #expect(throws: RavenError.invalidResponse) { try RavenPollSnapshot(getPoll: payload(poll: badFlag)) }
    }
}
