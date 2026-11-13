import Foundation

/// Parsed `raven.api.raven_poll.get_poll` response.
///
/// Bounds are enforced to keep hostile or malformed payloads from consuming
/// unbounded memory or producing ambiguous identities. The limits are generous
/// for real Raven polls and intentionally documented:
/// - up to 100 options
/// - up to 10,000 current-user selections
/// - up to 100,000 voter identifiers in total across all options
/// - question text up to 10,000 UTF-8 bytes, option/user identifiers up to 512
public struct RavenPollSnapshot: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        /// Stable Raven Poll Option child document name. The server also refers
        /// to selections by this identifier; option text is display-only.
        public let id: String
        public let text: String
        public let voteCount: Int

        fileprivate init(id: String, text: String, voteCount: Int) {
            self.id = id
            self.text = text
            self.voteCount = voteCount
        }
    }

    public let id: String
    public let owner: String
    public let question: String
    public let multiChoice: Bool
    public let anonymous: Bool
    public let closed: Bool
    /// Server date text as returned by Raven (no locale parsing is invented).
    public let endDate: String?
    /// Raven's configured maximum selection count. For multi-choice polls a
    /// value of 0 means unlimited selections.
    public let maxChoices: Int
    public let totalVotes: Int
    public let options: [Option]
    /// Option child names selected by the current user.
    public let selectedOptionIDs: Set<String>
    /// Option child name -> Raven user identifiers who voted for it.
    /// Anonymous snapshots never contain voter identities, even if the server
    /// payload includes them.
    public let votersByOption: [String: [String]]

    private init(
        id: String,
        owner: String,
        question: String,
        multiChoice: Bool,
        anonymous: Bool,
        closed: Bool,
        endDate: String?,
        maxChoices: Int,
        totalVotes: Int,
        options: [Option],
        selectedOptionIDs: Set<String>,
        votersByOption: [String: [String]]
    ) {
        self.id = id
        self.owner = owner
        self.question = question
        self.multiChoice = multiChoice
        self.anonymous = anonymous
        self.closed = closed
        self.endDate = endDate
        self.maxChoices = maxChoices
        self.totalVotes = totalVotes
        self.options = options
        self.selectedOptionIDs = selectedOptionIDs
        self.votersByOption = votersByOption
    }

    /// Parses the top-level `get_poll` message payload.
    public init(getPoll response: JSONValue) throws {
        guard case .object(let root) = response else { throw RavenError.invalidResponse }
        guard case .object(let pollFields) = root["poll"] else { throw RavenError.invalidResponse }

        let id = try Self.requiredID(pollFields["name"] ?? .null)
        let owner = try Self.requiredID(pollFields["owner"] ?? .null)
        let question = try Self.requiredText(pollFields["question"] ?? .null, maxUTF8: 10_000)
        let multiChoice = try Self.requiredBool(pollFields["is_multi_choice"] ?? .null)
        let anonymous = try Self.requiredBool(pollFields["is_anonymous"] ?? .null)
        let closed = try Self.requiredBool(pollFields["is_disabled"] ?? .null)
        let maxChoices = try Self.requiredInt(pollFields["max_choices"] ?? .null)
        let totalVotes = try Self.requiredInt(pollFields["total_votes"] ?? .null)
        guard maxChoices >= 0, totalVotes >= 0 else { throw RavenError.invalidResponse }
        let endDate = try Self.optionalText(pollFields["end_date"] ?? .null, maxUTF8: 128)

        guard case .array(let optionValues) = pollFields["options"] ?? .null else { throw RavenError.invalidResponse }
        guard optionValues.count <= 100 else { throw RavenError.invalidResponse }

        var options: [Option] = []
        options.reserveCapacity(optionValues.count)
        var optionIDs = Set<String>()
        for value in optionValues {
            guard case .object(let fields) = value else { throw RavenError.invalidResponse }
            let optionID = try Self.requiredID(fields["name"] ?? .null)
            guard optionIDs.insert(optionID).inserted else { throw RavenError.invalidResponse }
            let text = try Self.requiredText(fields["option"] ?? .null, maxUTF8: 10_000)
            let voteCount = try Self.requiredInt(fields["votes"] ?? .null)
            guard voteCount >= 0 else { throw RavenError.invalidResponse }
            options.append(Option(id: optionID, text: text, voteCount: voteCount))
        }

        let rawCurrentVotes = root["current_user_votes"]
        let currentVotes: [JSONValue]
        switch rawCurrentVotes {
        case .null:
            currentVotes = []
        case .array(let values):
            currentVotes = values
        default:
            throw RavenError.invalidResponse
        }
        guard currentVotes.count <= 10_000 else { throw RavenError.invalidResponse }
        var selectedOptionIDs = Set<String>()
        for value in currentVotes {
            guard case .object(let fields) = value else { throw RavenError.invalidResponse }
            let optionID = try Self.requiredID(fields["option"] ?? .null)
            guard optionIDs.contains(optionID) else { throw RavenError.invalidResponse }
            selectedOptionIDs.insert(optionID)
        }

        var votersByOption: [String: [String]] = [:]
        if !anonymous {
            let voteFields: [String: JSONValue]
            switch root["votes"] ?? .null {
            case .null:
                voteFields = [:]
            case .object(let object):
                voteFields = object
            default:
                throw RavenError.invalidResponse
            }
            var totalVoterIDs = 0
            for (optionID, value) in voteFields {
                guard Self.validID(optionID), optionIDs.contains(optionID) else { throw RavenError.invalidResponse }
                guard case .array(let users) = value else { throw RavenError.invalidResponse }
                totalVoterIDs += users.count
                guard totalVoterIDs <= 100_000 else { throw RavenError.invalidResponse }
                var voterIDs: [String] = []
                voterIDs.reserveCapacity(users.count)
                for user in users {
                    guard let id = try Self.string(user), Self.validID(id) else { throw RavenError.invalidResponse }
                    voterIDs.append(id)
                }
                votersByOption[optionID] = voterIDs
            }
        }

        self.init(
            id: id,
            owner: owner,
            question: question,
            multiChoice: multiChoice,
            anonymous: anonymous,
            closed: closed,
            endDate: endDate,
            maxChoices: maxChoices,
            totalVotes: totalVotes,
            options: options,
            selectedOptionIDs: selectedOptionIDs,
            votersByOption: votersByOption
        )
    }

    public enum SelectionError: LocalizedError, Sendable, Equatable {
        case empty
        case duplicate
        case unknown
        case excessive
        case closed
        case alreadyVoted
        public var errorDescription: String? {
            switch self {
            case .empty: return "Choose at least one option."
            case .duplicate: return "Choose each option only once."
            case .unknown: return "This poll changed. Refresh it before voting."
            case .excessive: return "Choose fewer options for this poll."
            case .closed: return "This poll is closed."
            case .alreadyVoted: return "You have already voted. Retract your vote before choosing again."
            }
        }
    }

    /// Validates a client selection before calling `add_vote`.
    ///
    /// - Closed polls reject any selection.
    /// - Duplicate option IDs are rejected.
    /// - Option IDs must refer to known option child names.
    /// - Single-choice polls require exactly one option.
    /// - Multi-choice polls require at least one option. `maxChoices == 0`
    ///   means unlimited; any positive value is an inclusive upper bound.
    public func validateSelection(_ optionIDs: [String]) throws {
        if closed { throw SelectionError.closed }
        guard selectedOptionIDs.isEmpty else { throw SelectionError.alreadyVoted }
        guard !optionIDs.isEmpty else { throw SelectionError.empty }
        var seen = Set<String>()
        let known = Set(options.map(\.id))
        for optionID in optionIDs {
            guard seen.insert(optionID).inserted else { throw SelectionError.duplicate }
            guard known.contains(optionID) else { throw SelectionError.unknown }
        }
        if multiChoice {
            if maxChoices > 0, optionIDs.count > maxChoices { throw SelectionError.excessive }
        } else {
            guard optionIDs.count == 1 else { throw SelectionError.excessive }
        }
    }

    private static func requiredID(_ value: JSONValue) throws -> String {
        guard let text = try string(value), Self.validID(text) else { throw RavenError.invalidResponse }
        return text
    }

    private static func validID(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 512 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func requiredText(_ value: JSONValue, maxUTF8: Int) throws -> String {
        guard let text = try string(value), !text.isEmpty, text.utf8.count <= maxUTF8 else { throw RavenError.invalidResponse }
        return text
    }

    private static func optionalText(_ value: JSONValue, maxUTF8: Int) throws -> String? {
        guard let text = try string(value) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.utf8.count <= maxUTF8 else { throw RavenError.invalidResponse }
        return trimmed
    }

    private static func string(_ value: JSONValue) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let text): return text
        default: return nil
        }
    }

    private static func requiredInt(_ value: JSONValue) throws -> Int {
        guard let number = try int(value) else { throw RavenError.invalidResponse }
        return number
    }

    private static func int(_ value: JSONValue) throws -> Int? {
        switch value {
        case .null: return nil
        case .number(let number):
            guard let integer = Int(exactly: number) else { throw RavenError.invalidResponse }
            return integer
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let number = Int(trimmed) else { throw RavenError.invalidResponse }
            return number
        case .bool, .array, .object:
            throw RavenError.invalidResponse
        }
    }

    private static func requiredBool(_ value: JSONValue) throws -> Bool {
        guard let flag = try bool(value) else { throw RavenError.invalidResponse }
        return flag
    }

    private static func bool(_ value: JSONValue) throws -> Bool? {
        switch value {
        case .null: return nil
        case .bool(let flag): return flag
        case .number(let number):
            if number == 0 { return false }
            if number == 1 { return true }
            throw RavenError.invalidResponse
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            case "": return nil
            default: throw RavenError.invalidResponse
            }
        case .array, .object:
            throw RavenError.invalidResponse
        }
    }
}
