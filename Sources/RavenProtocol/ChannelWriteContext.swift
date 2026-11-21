import Foundation

public struct RavenChannelWriteContext: Sendable, Equatable {
    public let channelID: String
    public let parentChannelIDs: [String]
    public let archivedChannelID: String?
    public var isArchived: Bool { archivedChannelID != nil }
}

extension RavenClient {
    /// Read canonical archive state for a channel and its thread ancestors.
    /// Raven's send endpoint does not itself enforce the archive flag.
    /// Each resource read retains the server's ordinary permission checks.
    public func channelWriteContext(_ channelID: String) async throws -> RavenChannelWriteContext {
        try await channelContext(channelID, purpose: .write)
    }

    /// Reading archived attachments still checks canonical thread ancestors.
    /// It uses the same permission-filtered resource traversal as writes, but
    /// does not stop at an archived child before checking its parent.
    public func channelReadContext(_ channelID: String) async throws -> RavenChannelWriteContext {
        try await channelContext(channelID, purpose: .read)
    }
    private enum ContextPurpose { case read, write }
    private func channelContext(_ channelID: String, purpose: ContextPurpose) async throws -> RavenChannelWriteContext {
        guard !channelID.isEmpty else { throw RavenError.invalidResponse }
        var firstArchived: String?
        var id = channelID, parents: [String] = [], visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(id).inserted else { throw RavenError.invalidResponse }
            let channel = try await resource("Raven Channel", name: id, values: nil)
            guard channel["name"].string == id else { throw RavenError.invalidResponse }
            if try Self.channelFlag(channel["is_archived"]) {
                firstArchived = firstArchived ?? id
                if purpose == .write { return RavenChannelWriteContext(channelID: channelID, parentChannelIDs: parents, archivedChannelID: firstArchived) }
            }
            guard try Self.channelFlag(channel["is_thread"]) else {
                return RavenChannelWriteContext(channelID: channelID, parentChannelIDs: parents, archivedChannelID: firstArchived)
            }
            guard let rootID = channel["channel_name"].string, !rootID.isEmpty else { throw RavenError.invalidResponse }
            let root = try await resource("Raven Message", name: rootID, values: nil)
            guard root["name"].string == rootID, let parent = root["channel_id"].string, !parent.isEmpty else { throw RavenError.invalidResponse }
            parents.append(parent); id = parent
        }
        // A cycle is refused above; reaching this point means the ancestry is
        // deeper than the contract can validate, which is a malformed
        // response rather than a size budget.
        throw RavenError.invalidResponse
    }

    private static func channelFlag(_ value: JSONValue) throws -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .number(0), .string("0"), .string("false"): return false
        case .number(1), .string("1"), .string("true"): return true
        default: throw RavenError.invalidResponse
        }
    }
}
