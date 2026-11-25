import Foundation
import NevermoreCore
import RavenProtocol

/// Verifies notification targets through the same permission-filtered
/// resource reads as a signed-in account.
@MainActor enum NotificationNetworkSelfChecks {
    static func run(origin input: String) async throws -> [(String, Bool)] {
        let origin = try PerformanceMetrics.loopbackOrigin(input)
        let account = Account(origin: origin, user: "performance-fixture@example.invalid",
                              siteName: "Notification fixture", clientID: "performance-loopback")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreNotification-\(UUID())")
        let session = try AccountSession(account: account, directory: directory, authentication: .loopbackFixture)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }

        let thread = "notification-fixture-root"
        let parent = "notification-fixture-parent"
        session.channels = [RavenChannel(raw: .object(["name": .string(parent), "channel_name": .string("Fixture parent")]))]
        let reply = try await session.notificationThreadTarget(channelID: thread, anchor: "notification-fixture-reply")
        let root = try await session.notificationThreadTarget(channelID: thread, anchor: thread)
        let elsewhere = try await session.notificationThreadTarget(channelID: thread, anchor: "notification-fixture-other")

        let denied: Bool
        do {
            _ = try await session.notificationThreadTarget(channelID: "notification-fixture-denied", anchor: thread)
            denied = false
        } catch let error as RavenError where error.isPermissionDenied {
            denied = true
        }

        await session.client.invalidate()
        return [
            ("a verified notification reply targets its unlisted Raven thread room",
             reply?.id == thread && reply?.raw["parent_channel_id"].string == parent && session.threadParents[thread] == parent),
            ("a verified root notification targets the canonical parent", root?.id == parent),
            ("notification routing rejects a Raven message from another conversation", elsewhere == nil),
            ("notification routing honors Raven resource permissions", denied),
        ]
    }
}
