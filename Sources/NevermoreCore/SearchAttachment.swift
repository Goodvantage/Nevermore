import Foundation
import RavenProtocol

/// Search metadata is only a locator. The permission-filtered canonical message
/// supplies the attachment URL immediately before each user-requested download.
public struct SearchAttachment: Equatable, Sendable {
    public let messageID: String
    public let channelID: String
    public let parentChannelID: String?

    public init?(_ row: JSONValue) {
        let row = RavenSearchResult.normalize(row)
        guard ["File", "Image"].contains(row["message_type"].string ?? ""),
              let messageID = Self.identifier(row["name"]),
              let channelID = Self.identifier(row["channel_id"]) else { return nil }
        if row["parent_channel_id"] != .null, Self.identifier(row["parent_channel_id"]) == nil { return nil }
        self.messageID = messageID; self.channelID = channelID
        parentChannelID = Self.identifier(row["parent_channel_id"])
    }
    private static func identifier(_ value: JSONValue) -> String? {
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    public func canonicalURL(_ message: JSONValue, origin: URL) throws -> URL {
        guard message["name"].string == messageID, message["channel_id"].string == channelID,
              ["File", "Image"].contains(message["message_type"].string ?? ""),
              let file = message["file"].string else { throw RavenError.invalidResponse }
        return try RavenAttachmentURL.resolve(file, origin: origin)
    }
}
