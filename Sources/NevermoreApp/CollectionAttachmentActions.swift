import AppKit
import NevermoreCore
import RavenProtocol

/// How file results reach a permission-checked download. Self-checks
/// inject a fixture in place of the server.
@MainActor enum CollectionAttachmentActions {
    struct Transport {
        let message: @MainActor (String) async throws -> JSONValue
        let channelContext: @MainActor (String) async throws -> RavenChannelWriteContext
        let download: @MainActor (URL) async throws -> DownloadedAttachment
    }
    static func transport(_ session: AccountSession) -> Transport {
        Transport(message: { try await session.client.resource("Raven Message", name: $0, values: nil) }, channelContext: {
            // Reuse canonical channel/ancestor resource permission checks.
            // Archived conversations remain readable, so ignore isArchived.
            try await session.client.channelReadContext($0)
        }, download: {
            try await session.client.download($0, to: FileManager.default.temporaryDirectory)
        })
    }
}
