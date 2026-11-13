import Foundation

/// How a sent message travels from the composer to the transcript.
///
/// The composer and the transcript lay the same message out at different
/// widths and sometimes in different fonts. When both contain the same
/// words in the same order, each word can fly from where it was typed to
/// where it will be read. Otherwise the message moves as one block.
public enum InkFlightPlan: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public let source: NSRange
        public let destination: NSRange
        public init(source: NSRange, destination: NSRange) { self.source = source; self.destination = destination }
    }
    case words([Pair])
    case block

    /// More layers than this cost more than the flight is worth.
    public static let wordLimit = 160

    /// UTF-16 ranges of the whitespace-separated words in `text`.
    public static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        var offset = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if scalar.properties.isWhitespace {
                if let begin = start { ranges.append(NSRange(location: begin, length: offset - begin)); start = nil }
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let begin = start { ranges.append(NSRange(location: begin, length: offset - begin)) }
        return ranges
    }

    /// Pairs each word of `source` with the same word of `destination`.
    /// Any difference in the words, their order or their count yields
    /// `.block`: a flight that lands on the wrong word is worse than none.
    public static func plan(source: String, destination: String, limit: Int = wordLimit) -> InkFlightPlan {
        let from = wordRanges(in: source), to = wordRanges(in: destination)
        guard !from.isEmpty, from.count == to.count, from.count <= limit else { return .block }
        let sourceText = source as NSString, destinationText = destination as NSString
        var pairs: [Pair] = []
        pairs.reserveCapacity(from.count)
        for (a, b) in zip(from, to) {
            guard sourceText.substring(with: a) == destinationText.substring(with: b) else { return .block }
            pairs.append(Pair(source: a, destination: b))
        }
        return .words(pairs)
    }
}

/// What an accepted, unacknowledged send looks like in the transcript.
public enum InkWetness: Equatable, Sendable {
    /// The outbox is working on it; nothing is asked of the reader.
    case flowing
    /// It will be retried without help, but has failed at least once.
    case stalled
    /// It will not leave until someone looks at it.
    case blocked

    public init?(_ state: SendState) {
        switch state {
        case .queued, .uploading, .sending: self = .flowing
        case .retryable: self = .stalled
        case .needsReview, .rejected: self = .blocked
        case .acknowledged, .cancelled: return nil
        }
    }
}

public enum InkRules {
    /// A message can return to the composer only while no request for it
    /// can have reached the server: after a first attempt, a lost
    /// acknowledgement could mean it was delivered. The outbox's Cancel
    /// Send applies the same rule.
    public static func canTakeBack(_ operation: SendOperation) -> Bool {
        operation.state == .queued && operation.attempts == 0
    }

    /// A reply target, staged file or unreadable draft is work too, even
    /// when the composer has no visible characters.
    public static func canRestoreDraft(_ draft: Draft?) -> Bool {
        guard let draft else { return true }
        guard draft.attachments.isEmpty, draft.replyTo == nil else { return false }
        if let editor = draft.editorState, editor.mode == .markdown { return editor.source.isEmpty }
        guard let document = try? RichTextCodec.parse(draft.html), document.canEdit else { return false }
        return RichTextCodec.plainText(document, revealSpoilers: true).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
