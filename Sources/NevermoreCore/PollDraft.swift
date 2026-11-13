import Foundation
import RavenProtocol

/// An immutable poll composition, validated before submission.
///
/// Nevermore applies the bounds below to its composition form. The finite
/// choice-limit rule comes from the pinned Raven Poll controller; wire keys
/// follow `raven.api.raven_poll.create_poll`.
/// - a question of at most 4096 UTF-8 bytes;
/// - 2 through 20 options, each at most 1024 UTF-8 bytes and unique after
///   trimming;
/// - single-choice polls send `max_choices = 0`;
/// - multi-choice polls send `max_choices = 0` for unlimited, otherwise a
///   limit of at least 2 and strictly below the option count (the controller
///   rejects a limit of 1 and any limit greater than or equal to the option
///   count);
/// - an optional deadline rendered in the site timezone as
///   `yyyy-MM-dd HH:mm:ss` (POSIX locale, never the device locale).
///
/// Validation runs at initialization and again when arguments are produced,
/// because a deadline can pass while the form or a preflight is waiting.
public struct PollDraft: Sendable, Equatable {
    /// How many options a voter may choose.
    public enum ChoiceMode: Sendable, Equatable {
        /// Exactly one option. Encoded as `max_choices = 0`.
        case single
        /// One or more options. A finite `limit` must be at least 2 and
        /// strictly below the option count; `nil` means unlimited, encoded
        /// as `max_choices = 0`.
        case multiple(limit: Int?)
    }

    /// Whether voters are attributed by name.
    public enum Privacy: Sendable, Equatable {
        case named
        case anonymous
    }

    /// Validation failures with actionable, input-free descriptions. Private
    /// question, option, or channel text is never included in the messages.
    public enum ValidationError: LocalizedError, Sendable, Equatable {
        case emptyQuestion
        case questionTooLong
        case tooFewOptions
        case tooManyOptions
        case emptyOption
        case optionTooLong
        case duplicateOption
        case invalidLimit
        case deadlineNotFuture
        case emptyChannelID
        case channelIDTooLong
        case channelIDControlCharacters

        public var errorDescription: String? {
            switch self {
            case .emptyQuestion:
                return "Enter a poll question."
            case .questionTooLong:
                return "Shorten the poll question to 4096 bytes or fewer."
            case .tooFewOptions:
                return "Add at least 2 poll options."
            case .tooManyOptions:
                return "Use at most 20 poll options."
            case .emptyOption:
                return "Enter text for every poll option."
            case .optionTooLong:
                return "Shorten each poll option to 1024 bytes or fewer."
            case .duplicateOption:
                return "Give each poll option different text."
            case .invalidLimit:
                return "Set the multi-choice limit between 2 and one fewer than the option count."
            case .deadlineNotFuture:
                return "Choose an end date and time in the future."
            case .emptyChannelID:
                return "Enter a channel ID."
            case .channelIDTooLong:
                return "Shorten the channel ID to 512 bytes or fewer."
            case .channelIDControlCharacters:
                return "Remove control characters from the channel ID."
            }
        }
    }

    public let question: String
    public let options: [String]
    public let choiceMode: ChoiceMode
    public let privacy: Privacy
    public let deadline: Date?

    /// Creates a validated, trimmed draft. `now` is the reference instant for
    /// the deadline check; a deadline must be strictly after it.
    public init(
        question: String,
        options: [String],
        choiceMode: ChoiceMode = .single,
        privacy: Privacy = .named,
        deadline: Date? = nil,
        now: Date = Date()
    ) throws {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw ValidationError.emptyQuestion }
        guard trimmedQuestion.utf8.count <= 4096 else { throw ValidationError.questionTooLong }

        guard options.count >= 2, options.count <= 20 else {
            throw options.count < 2 ? ValidationError.tooFewOptions : ValidationError.tooManyOptions
        }

        var trimmedOptions: [String] = []
        trimmedOptions.reserveCapacity(options.count)
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError.emptyOption }
            guard trimmed.utf8.count <= 1024 else { throw ValidationError.optionTooLong }
            trimmedOptions.append(trimmed)
        }
        guard Set(trimmedOptions).count == trimmedOptions.count else {
            throw ValidationError.duplicateOption
        }

        if case .multiple(let limit) = choiceMode, let limit {
            guard limit >= 2, limit < options.count else { throw ValidationError.invalidLimit }
        }

        if let deadline {
            guard deadline > now else { throw ValidationError.deadlineNotFuture }
        }

        self.question = trimmedQuestion
        self.options = trimmedOptions
        self.choiceMode = choiceMode
        self.privacy = privacy
        self.deadline = deadline
    }

    /// Produces the `raven.api.raven_poll.create_poll` argument dictionary.
    /// `end_date` is omitted entirely when there is no deadline; otherwise it
    /// is rendered in `siteTimeZone` with a POSIX locale. `now` re-checks the
    /// deadline, which may have expired since initialization.
    public func arguments(channelID: String, siteTimeZone: TimeZone, now: Date = Date()) throws -> [String: JSONValue] {
        guard !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyChannelID
        }
        guard channelID.utf8.count <= 512 else { throw ValidationError.channelIDTooLong }
        guard !channelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.channelIDControlCharacters
        }

        if let deadline {
            guard deadline > now else { throw ValidationError.deadlineNotFuture }
        }

        let isMultiple: Bool
        let maxChoices: Int
        switch choiceMode {
        case .single:
            isMultiple = false
            maxChoices = 0
        case .multiple(let limit):
            isMultiple = true
            maxChoices = limit ?? 0
        }

        var arguments: [String: JSONValue] = [
            "channel_id": .string(channelID),
            "question": .string(question),
            "options": .array(options.map { .object(["option": .string($0)]) }),
            "is_multi_choice": .bool(isMultiple),
            "is_anonymous": .bool(privacy == .anonymous),
            "max_choices": .number(Double(maxChoices)),
        ]
        if let deadline {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = siteTimeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = siteTimeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            arguments["end_date"] = .string(formatter.string(from: deadline))
        }
        return arguments
    }
}
