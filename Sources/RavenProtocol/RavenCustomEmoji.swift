import Foundation

/// A custom emoji registered on the site.
///
/// The Frappe document `name` is the stable opaque identity and is preserved
/// verbatim; `emoji_name` is the display shortcode. The image URL is resolved
/// against the account origin and stored origin-relative. User information
/// and references to another site are rejected.
public struct RavenCustomEmoji: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let imagePath: String
    public let keywords: String

    /// Maximum UTF-8 byte length accepted for the opaque ID and shortcode.
    private static let identifierLimit = 512
    /// Maximum UTF-8 byte length accepted for the keyword blob.
    private static let keywordLimit = 4096

    public init(raw: JSONValue, origin: URL) throws {
        id = try Self.requiredText(raw["name"])
        name = try Self.requiredText(raw["emoji_name"])

        guard let image = raw["image"].string else { throw RavenError.invalidResponse }
        let resolved = try RavenAttachmentURL.resolve(image, origin: origin)
        guard let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { throw RavenError.invalidResponse }
        var normalized = components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            normalized += "?" + query
        }
        guard normalized.utf8.count <= 8192 else { throw RavenError.invalidResponse }
        imagePath = normalized

        switch raw["keywords"] {
        case .null:
            keywords = ""
        case .string(let text):
            guard text.utf8.count <= Self.keywordLimit else { throw RavenError.invalidResponse }
            keywords = text
        default:
            throw RavenError.invalidResponse
        }
    }

    /// Reads a required text field, rejecting missing values, wrong types,
    /// empty/oversized values, and control characters. The value is kept
    /// verbatim so opaque IDs are never rewritten.
    private static func requiredText(_ value: JSONValue) throws -> String {
        guard let text = value.string else { throw RavenError.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= identifierLimit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RavenError.invalidResponse
        }
        return text
    }
}
