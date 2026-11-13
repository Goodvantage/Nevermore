import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct PollDraftTests {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var kolkata: TimeZone { TimeZone(identifier: "Asia/Kolkata")! }

    private var past: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private var deadline: Date { Date(timeIntervalSince1970: 1_893_456_000) } // 2030-01-01 00:00:00 UTC
    private var later: Date { Date(timeIntervalSince1970: 2_000_000_000) }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    // MARK: - Wire shape

    @Test func singleNamedPollWithoutDeadlineUsesExactWireShape() throws {
        let draft = try PollDraft(question: "  Favorite color?  ", options: ["  Red  ", "\nBlue\t"], now: past)
        #expect(draft.question == "Favorite color?")
        #expect(draft.options == ["Red", "Blue"])

        let arguments = try draft.arguments(channelID: "general", siteTimeZone: utc, now: past)
        let expected: [String: JSONValue] = [
            "channel_id": .string("general"),
            "question": .string("Favorite color?"),
            "options": .array([
                .object(["option": .string("Red")]),
                .object(["option": .string("Blue")]),
            ]),
            "is_multi_choice": .bool(false),
            "is_anonymous": .bool(false),
            "max_choices": .number(0),
        ]
        #expect(arguments == expected)
        #expect(!arguments.keys.contains("end_date"))
    }

    @Test func multipleAnonymousPollEncodesLimitAndDeadline() throws {
        let draft = try PollDraft(
            question: "Q",
            options: ["A", "B", "C"],
            choiceMode: .multiple(limit: 2),
            privacy: .anonymous,
            deadline: deadline,
            now: past
        )
        let arguments = try draft.arguments(channelID: "chan", siteTimeZone: kolkata, now: past)
        let expected: [String: JSONValue] = [
            "channel_id": .string("chan"),
            "question": .string("Q"),
            "options": .array([
                .object(["option": .string("A")]),
                .object(["option": .string("B")]),
                .object(["option": .string("C")]),
            ]),
            "is_multi_choice": .bool(true),
            "is_anonymous": .bool(true),
            "max_choices": .number(2),
            "end_date": .string("2030-01-01 05:30:00"),
        ]
        #expect(arguments == expected)
    }

    @Test func unlimitedMultipleEncodesZeroAndPreservesOptionOrder() throws {
        let draft = try PollDraft(
            question: "Q",
            options: ["First", "Second", "Third"],
            choiceMode: .multiple(limit: nil),
            now: past
        )
        #expect(draft.choiceMode == .multiple(limit: nil))
        let arguments = try draft.arguments(channelID: "general", siteTimeZone: utc, now: past)
        #expect(arguments["is_multi_choice"] == .bool(true))
        #expect(arguments["max_choices"] == .number(0))
        #expect(arguments["options"] == .array([
            .object(["option": .string("First")]),
            .object(["option": .string("Second")]),
            .object(["option": .string("Third")]),
        ]))
    }

    @Test func questionBoundsUseTrimmedUTF8Bytes() throws {
        let maxQuestion = String(repeating: "a", count: 4096)
        let draft = try PollDraft(question: "  \(maxQuestion)  ", options: ["A", "B"], now: past)
        #expect(draft.question == maxQuestion)

        #expect(throws: PollDraft.ValidationError.questionTooLong) {
            try PollDraft(question: maxQuestion + "a", options: ["A", "B"], now: past)
        }

        let maxMultibyte = String(repeating: "é", count: 2048)
        #expect(maxMultibyte.utf8.count == 4096)
        _ = try PollDraft(question: maxMultibyte, options: ["A", "B"], now: past)
        #expect(throws: PollDraft.ValidationError.questionTooLong) {
            try PollDraft(question: maxMultibyte + "é", options: ["A", "B"], now: past)
        }

        #expect(throws: PollDraft.ValidationError.emptyQuestion) {
            try PollDraft(question: " \n\t ", options: ["A", "B"], now: past)
        }
        #expect(throws: PollDraft.ValidationError.emptyQuestion) {
            try PollDraft(question: "", options: ["A", "B"], now: past)
        }
    }

    @Test func optionBoundsCountsAndTrimming() throws {
        let maxOption = String(repeating: "b", count: 1024)
        let draft = try PollDraft(question: "Q", options: [" \(maxOption) ", "Other"], now: past)
        #expect(draft.options.first == maxOption)

        #expect(throws: PollDraft.ValidationError.optionTooLong) {
            try PollDraft(question: "Q", options: [maxOption + "b", "Other"], now: past)
        }

        let maxMultibyte = String(repeating: "é", count: 512)
        #expect(maxMultibyte.utf8.count == 1024)
        _ = try PollDraft(question: "Q", options: [maxMultibyte, "Other"], now: past)
        #expect(throws: PollDraft.ValidationError.optionTooLong) {
            try PollDraft(question: "Q", options: [maxMultibyte + "é", "Other"], now: past)
        }

        #expect(throws: PollDraft.ValidationError.emptyOption) {
            try PollDraft(question: "Q", options: ["   ", "Other"], now: past)
        }
        #expect(throws: PollDraft.ValidationError.emptyOption) {
            try PollDraft(question: "Q", options: ["First", "\n\t"], now: past)
        }

        #expect(throws: PollDraft.ValidationError.tooFewOptions) {
            try PollDraft(question: "Q", options: ["Only"], now: past)
        }
        #expect(throws: PollDraft.ValidationError.tooFewOptions) {
            try PollDraft(question: "Q", options: [], now: past)
        }
        #expect(throws: PollDraft.ValidationError.tooManyOptions) {
            try PollDraft(question: "Q", options: (1...21).map { "Option \($0)" }, now: past)
        }

        _ = try PollDraft(question: "Q", options: (1...20).map { "Option \($0)" }, now: past)
        _ = try PollDraft(question: "Q", options: ["A", "B"], now: past)
    }

    @Test func duplicateOptionsAreRejectedAfterTrimmingButCaseIsExact() throws {
        #expect(throws: PollDraft.ValidationError.duplicateOption) {
            try PollDraft(question: "Q", options: ["Same", "Same"], now: past)
        }
        #expect(throws: PollDraft.ValidationError.duplicateOption) {
            try PollDraft(question: "Q", options: ["Same", "  Same \n"], now: past)
        }

        let distinctCase = try PollDraft(question: "Q", options: ["Yes", "yes"], now: past)
        #expect(distinctCase.options == ["Yes", "yes"])
    }

    // MARK: - Multi-choice limits

    @Test func multiChoiceLimitFollowsPinnedControllerBounds() throws {
        let threeOptions = ["A", "B", "C"]

        // nil is unlimited and legal for any option count.
        _ = try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: nil), now: past)
        _ = try PollDraft(question: "Q", options: ["A", "B"], choiceMode: .multiple(limit: nil), now: past)

        // The smallest legal finite limit is 2.
        _ = try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: 2), now: past)

        // The pinned controller rejects a limit of 1 and limits at or above
        // the option count.
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: 1), now: past)
        }
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: 0), now: past)
        }
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: -3), now: past)
        }
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: threeOptions, choiceMode: .multiple(limit: 3), now: past)
        }

        // With 2 options there is no legal finite limit.
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: ["A", "B"], choiceMode: .multiple(limit: 2), now: past)
        }

        // At 20 options the largest legal limit is 19.
        let twentyOptions = (1...20).map { "Option \($0)" }
        _ = try PollDraft(question: "Q", options: twentyOptions, choiceMode: .multiple(limit: 19), now: past)
        #expect(throws: PollDraft.ValidationError.invalidLimit) {
            try PollDraft(question: "Q", options: twentyOptions, choiceMode: .multiple(limit: 20), now: past)
        }
    }

    // MARK: - Deadline

    @Test func deadlineMustBeStrictlyAfterInitNow() throws {
        _ = try PollDraft(question: "Q", options: ["A", "B"], deadline: deadline, now: past)
        _ = try PollDraft(question: "Q", options: ["A", "B"], deadline: nil, now: past)

        #expect(throws: PollDraft.ValidationError.deadlineNotFuture) {
            try PollDraft(question: "Q", options: ["A", "B"], deadline: past, now: past)
        }
        #expect(throws: PollDraft.ValidationError.deadlineNotFuture) {
            try PollDraft(question: "Q", options: ["A", "B"], deadline: Date(timeIntervalSince1970: 1_799_999_999), now: past)
        }
    }

    @Test func deadlineCanExpireBetweenInitAndArguments() throws {
        let draft = try PollDraft(question: "Q", options: ["A", "B"], deadline: deadline, now: past)

        // Still future at preflight time.
        let arguments = try draft.arguments(
            channelID: "general",
            siteTimeZone: utc,
            now: Date(timeIntervalSince1970: 1_850_000_000)
        )
        #expect(arguments["end_date"] == .string("2030-01-01 00:00:00"))

        // Expired by send time.
        #expect(throws: PollDraft.ValidationError.deadlineNotFuture) {
            try draft.arguments(channelID: "general", siteTimeZone: utc, now: later)
        }
        // Exactly equal to now is not strictly after.
        #expect(throws: PollDraft.ValidationError.deadlineNotFuture) {
            try draft.arguments(channelID: "general", siteTimeZone: utc, now: deadline)
        }
    }

    // MARK: - Site timezone rendering

    @Test func endDateUsesSiteTimeZoneAndPOSIXFormat() throws {
        let draft = try PollDraft(question: "Q", options: ["A", "B"], deadline: deadline, now: past)

        let utcArguments = try draft.arguments(channelID: "general", siteTimeZone: utc, now: past)
        let kolkataArguments = try draft.arguments(channelID: "general", siteTimeZone: kolkata, now: past)
        #expect(utcArguments["end_date"] == .string("2030-01-01 00:00:00"))
        #expect(kolkataArguments["end_date"] == .string("2030-01-01 05:30:00"))
        #expect(utcArguments["end_date"] != kolkataArguments["end_date"])

        // Zero-padded, locale-independent fields.
        let siteDate = date(2030, 2, 3, 4, 5, 6, timeZone: utc)
        let paddedDraft = try PollDraft(question: "Q", options: ["A", "B"], deadline: siteDate, now: past)
        let paddedUTC = try paddedDraft.arguments(channelID: "general", siteTimeZone: utc, now: past)
        let paddedKolkata = try paddedDraft.arguments(channelID: "general", siteTimeZone: kolkata, now: past)
        #expect(paddedUTC["end_date"] == .string("2030-02-03 04:05:06"))
        #expect(paddedKolkata["end_date"] == .string("2030-02-03 09:35:06"))
    }

    // MARK: - Channel ID

    @Test func malformedChannelIDsAreRejected() throws {
        let draft = try PollDraft(question: "Q", options: ["A", "B"], now: past)

        #expect(throws: PollDraft.ValidationError.emptyChannelID) {
            try draft.arguments(channelID: "", siteTimeZone: utc, now: past)
        }
        #expect(throws: PollDraft.ValidationError.emptyChannelID) {
            try draft.arguments(channelID: " \n\t ", siteTimeZone: utc, now: past)
        }

        let maxChannel = String(repeating: "c", count: 512)
        _ = try draft.arguments(channelID: maxChannel, siteTimeZone: utc, now: past)
        #expect(throws: PollDraft.ValidationError.channelIDTooLong) {
            try draft.arguments(channelID: maxChannel + "c", siteTimeZone: utc, now: past)
        }

        #expect(throws: PollDraft.ValidationError.channelIDControlCharacters) {
            try draft.arguments(channelID: "general\u{1}", siteTimeZone: utc, now: past)
        }
        #expect(throws: PollDraft.ValidationError.channelIDControlCharacters) {
            try draft.arguments(channelID: "general\n", siteTimeZone: utc, now: past)
        }
        #expect(throws: PollDraft.ValidationError.channelIDControlCharacters) {
            try draft.arguments(channelID: "general\t", siteTimeZone: utc, now: past)
        }
        #expect(throws: PollDraft.ValidationError.channelIDControlCharacters) {
            try draft.arguments(channelID: "general\u{7f}", siteTimeZone: utc, now: past)
        }
    }

    // MARK: - Error text

    @Test func errorsAreActionableAndNeverEchoPrivateInput() {
        let privateQuestion = String(repeating: "q", count: 5_000)
        let privateOption = String(repeating: "o", count: 1_100)
        let privateChannel = String(repeating: "z", count: 600)

        var messages: [String] = []
        do {
            _ = try PollDraft(question: privateQuestion, options: ["A", "B"], now: past)
        } catch let error as LocalizedError {
            messages.append(error.errorDescription ?? "")
        } catch {
            messages.append(String(describing: error))
        }
        do {
            _ = try PollDraft(question: "Q", options: [privateOption, "B"], now: past)
        } catch let error as LocalizedError {
            messages.append(error.errorDescription ?? "")
        } catch {
            messages.append(String(describing: error))
        }
        do {
            let draft = try PollDraft(question: "Q", options: ["A", "B"], now: past)
            _ = try draft.arguments(channelID: privateChannel, siteTimeZone: utc, now: past)
        } catch let error as LocalizedError {
            messages.append(error.errorDescription ?? "")
        } catch {
            messages.append(String(describing: error))
        }

        #expect(messages.count == 3)
        for message in messages {
            #expect(!message.isEmpty)
            #expect(!message.contains(privateQuestion))
            #expect(!message.contains(privateOption))
            #expect(!message.contains(privateChannel))
        }
    }
}
