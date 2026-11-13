import Foundation
import RavenProtocol

/// The one-click reaction row offered before the full emoji picker, like the
/// quick emoji in Raven web's message toolbar.
///
/// The row starts with the account's most-used Unicode reactions, which Raven
/// counts server-side across devices (`reactions.most_used_reactions`), and
/// fills the remaining slots from Raven web's default quick emoji. Custom
/// emoji stay in the full picker: drawing them here would need automatic
/// image downloads, which Nevermore avoids.
public enum QuickReactions {
    /// Raven web's default quick emoji, then two common additions so an
    /// account without reaction history still sees a full row.
    public static let defaults = ["👍", "✅", "👀", "🎉", "🔥", "🤔", "❤️", "😂"]
    public static let slotCount = 8
    /// Raven clamps `most_used_reactions` to at most six rows.
    public static let usageLimit = 6

    /// One emoji grapheme, as Raven's `react` accepts with `is_custom = false`.
    /// Joined sequences and skin-tone modifiers count as one grapheme.
    ///
    /// The grapheme must start with an emoji and continue only with what
    /// emoji sequences are built from. One grapheme alone is not enough: a
    /// bare selector, "a" with a selector or a skin tone, and an emoji with
    /// a stray accent are each one grapheme too. The order of the parts is
    /// not checked, so a doubled modifier still passes; it draws as emoji.
    public static func isUnicodeReaction(_ value: String) -> Bool {
        guard value.count == 1, value.utf8.count <= 64, let base = value.unicodeScalars.first, base.properties.isEmoji else { return false }
        let rest = value.unicodeScalars.dropFirst()
        // "0"-"9", "#" and "*" carry the Unicode Emoji property only as
        // keycap bases: 1️⃣ is a reaction, "3" and "3" with a selector are not.
        if base.isASCII { return rest.contains(keycap) && rest.allSatisfy { $0 == keycap || $0 == emojiPresentation } }
        return rest.allSatisfy { scalar in
            (scalar.properties.isEmoji && !scalar.isASCII) || scalar == emojiPresentation || scalar == textPresentation
                || scalar == joiner || tags.contains(scalar)
        }
    }

    private static let emojiPresentation: Unicode.Scalar = "\u{FE0F}"
    private static let textPresentation: Unicode.Scalar = "\u{FE0E}"
    private static let joiner: Unicode.Scalar = "\u{200D}"
    private static let keycap: Unicode.Scalar = "\u{20E3}"
    /// Tag characters spell subdivision flags such as England's.
    private static let tags: ClosedRange<Unicode.Scalar> = "\u{E0020}"..."\u{E007F}"

    /// Unicode reactions from a `most_used_reactions` response, most used
    /// first. Custom, malformed and repeated rows are skipped.
    public static func mostUsed(from response: JSONValue) -> [String] {
        var result: [String] = []
        for row in response.array.prefix(64) where !row["is_custom"].bool {
            guard let reaction = row["reaction"].string, isUnicodeReaction(reaction), !result.contains(reaction) else { continue }
            result.append(reaction)
            if result.count == usageLimit { break }
        }
        return result
    }

    /// The emoji shown in the row: most-used first, then the defaults.
    /// Emoji that differ only by a presentation selector (❤ and ❤️) appear
    /// once, in the form the account actually used.
    public static func slots(mostUsed: [String], count: Int = slotCount) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for emoji in mostUsed + defaults where result.count < count && isUnicodeReaction(emoji) {
            guard seen.insert(presentationNeutral(emoji)).inserted else { continue }
            result.append(emoji)
        }
        return result
    }

    /// The Unicode reactions `user` has already added to a message. Raven's
    /// `message_reactions` maps each reaction to the users who added it, and
    /// reacting again with one of these removes it. Matching is exact,
    /// because Raven keys reactions by their exact characters.
    public static func reacted(by user: String, in reactions: JSONValue) -> Set<String> {
        var result = Set<String>()
        for (key, value) in reactions.nested.object.prefix(500) where !value["is_custom"].bool {
            guard value["users"].array.contains(where: { $0.string == user }) else { continue }
            let reaction = value["reaction"].string ?? key
            if isUnicodeReaction(reaction) { result.insert(reaction) }
        }
        return result
    }

    private static func presentationNeutral(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0 != textPresentation && $0 != emojiPresentation }))
    }
}
