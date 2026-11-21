import AppKit
import NevermoreCore
import RavenProtocol

/// Checks that the realtime rooms an account asks for follow conversation
/// access in both directions. The socket is created but never connected,
/// so only the desired room set is observed; nothing reaches a server.
@MainActor enum RealtimeRoomSelfChecks {
    static func run() async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreRoomCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "room-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
        let socket = RavenRealtime(account: account, accessToken: "unused") { _, _ in }
        session.realtime = socket
        let window = UUID()
        session.attach(window: window, channelID: "room-private")
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        check("an open conversation's room is requested", socket.desiredChannels == ["room-private"])
        // A refresh that withdraws access changes only the revoked set.
        session.revokedChannels.formUnion(["room-private"])
        check("a refresh that withdraws access to an open conversation leaves its room", socket.desiredChannels.isEmpty)
        session.revokedChannels.subtract(["room-private"])
        check("a refresh that restores access to an open conversation joins its room again", socket.desiredChannels == ["room-private"])
        // A denied load leaves the room itself, then a later refresh restores access.
        session.revokedChannels.insert("room-private"); session.updateRooms()
        session.revokedChannels.subtract(["room-private"])
        check("access restored after a denied load joins the room again", socket.desiredChannels == ["room-private"])
        session.attach(window: window, channelID: nil)
        check("closing the conversation leaves its room", socket.desiredChannels.isEmpty)
        return checks
    }
}
