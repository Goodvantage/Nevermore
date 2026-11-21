import Foundation

/// How much of a message its notification shows. `generic` is the private
/// default the app always had; the others are opt-in in Settings ▸
/// Notifications. Notification Center keeps what it shows, so a lower level
/// protects messages from people who can see the screen.
public enum NotificationPreview: String, CaseIterable, Sendable {
    case generic, sender, message

    public static let defaultsKey = "notificationPreview"

    public static func current(_ defaults: UserDefaults = .standard) -> NotificationPreview {
        level(stored: defaults.string(forKey: defaultsKey))
    }

    /// An unset or unknown stored value means the private default.
    public static func level(stored: String?) -> NotificationPreview {
        stored.flatMap(NotificationPreview.init(rawValue:)) ?? .generic
    }

    /// The Settings menu title.
    public var title: String {
        switch self {
        case .generic: "Nothing about the message"
        case .sender: "Sender and conversation"
        case .message: "Sender, conversation and message"
        }
    }
}

/// The visible text of one message notification, built without AppKit so
/// every level can be tested.
public struct NotificationText: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    /// The longest message excerpt a notification carries.
    public static let excerptLimit = 240

    /// - Parameters:
    ///   - account: the account's display name; generic notifications are
    ///     titled with it, the others name it in the subtitle only when
    ///     `multipleAccounts` is set.
    ///   - conversation: the channel name without its `#`; ignored for a
    ///     direct message, whose title is the sender.
    ///   - text: the message as plain text with spoilers already masked, or
    ///     nil when it has none (a file, say).
    ///   - file: the attached file's name, if any.
    public static func make(level: NotificationPreview, account: String, multipleAccounts: Bool, conversation: String, isDirect: Bool, sender: String, text: String?, file: String?) -> NotificationText {
        let subtitle = multipleAccounts ? account : ""
        let title = isDirect ? sender : "#" + conversation
        switch level {
        case .generic:
            return NotificationText(title: account, subtitle: "", body: "New activity in Raven")
        case .sender:
            return NotificationText(title: title, subtitle: subtitle, body: isDirect ? "New message" : "New message from \(sender)")
        case .message:
            let content = excerpt(text) ?? file.map { "Sent \($0)" } ?? "New message"
            return NotificationText(title: title, subtitle: subtitle, body: isDirect ? content : "\(sender): \(content)")
        }
    }

    /// The derived caption or question on a structured message with no HTML body.
    public static func structuredTeaser(_ content: String?) -> String? {
        guard let content, content.contains("<") else { return content }
        guard let document = try? RichTextCodec.parse(content) else { return nil }
        return RichTextCodec.plainText(document)
    }

    /// One line of at most `excerptLimit` characters, cut at a word where
    /// possible. Nil for text that is empty once whitespace is folded.
    static func excerpt(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        guard folded.count > excerptLimit else { return folded }
        let cut = folded.prefix(excerptLimit)
        // A cut far back (one very long word) would lose too much; cut mid-word then.
        let word = cut.lastIndex(of: " ").map { cut[..<$0] }.flatMap { $0.count >= excerptLimit / 2 ? $0 : nil } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }
}
