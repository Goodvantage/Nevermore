import AppKit
import RavenProtocol

/// Profile photo loading against the loopback fixture started by
/// `scripts/check-native-attachments.py --avatars`: what a session keeps
/// when the user directory changes while a photo is still downloading.
@MainActor enum AvatarSelfChecks {
    private static let newPhoto = "/files/avatar-new.png"

    static func runNetwork(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Avatar checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreAvatarNetworkCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try AccountSession(account: Account(origin: origin, user: "avatar-fixture-user", siteName: "Local fixture", clientID: "local-fixture"), directory: root)
        defer { session.stop() }

        func wait(_ condition: () async throws -> Bool) async throws -> Bool {
            for _ in 0..<300 { if try await condition() { return true }; try await Task.sleep(for: .milliseconds(10)) }
            return try await condition()
        }
        func entry(_ id: String, photo: String?) -> JSONValue {
            .object(["name": .string(id), "full_name": .string(id), "user_image": photo.map(JSONValue.string) ?? .null])
        }
        /// The fixture's new photo is wide and its old one tall, so the two
        /// stay distinguishable at any thumbnail size.
        func showsNewPhoto(_ id: String) -> Bool { session.avatars[id].map { $0.size.width > $0.size.height } == true }
        /// Starts `id`'s download from a slow path, changes the directory
        /// while it is in flight and waits for the queue to drain.
        func interrupt(_ id: String, slow: String, then photo: String?) async throws -> Bool {
            session.directory[id] = entry(id, photo: slow)
            session.loadAvatars([id])
            guard try await wait({ try await session.client.rpc("nevermore_fixture.avatar_stats")[slow] == .number(1) }) else { return false }
            // Any Raven User change empties the directory; the reload that
            // follows brings the entry as it is now.
            session.event("list_update", .object(["doctype": .string("Raven User")]))
            session.directory[id] = entry(id, photo: photo)
            // The fixture holds a slow photo until told to let go, so the
            // change above lands mid-download however slow the machine is.
            _ = try await session.client.rpc("nevermore_fixture.avatar_release")
            return try await wait { session.avatarRequests.isEmpty }
        }

        var results: [(String, Bool)] = []
        session.directory["steady"] = entry("steady", photo: newPhoto)
        session.directory["broken"] = entry("broken", photo: "/files/avatar-missing.png")
        let pendingPortrait = session.avatarImage(for: "steady")
        let brokenPortrait = session.avatarImage(for: "broken")
        session.loadAvatars(["steady", "broken"])
        let settled = try await wait { session.avatarRequests.isEmpty }
        results.append(("profile photos load from the site and a broken one stops retrying", settled && showsNewPhoto("steady") && session.avatars["broken"] == nil && session.avatarFailures.contains("broken")))

        results.append(("a generated raven never suppresses a real photo download", pendingPortrait != nil && session.avatarImage(for: "steady") === session.avatars["steady"] && session.avatarImage(for: "steady") !== pendingPortrait))
        results.append(("a failed photo keeps its user's stable generated raven", brokenPortrait != nil && session.avatarImage(for: "broken") === brokenPortrait))

        let replaced = try await interrupt("replaced", slow: "/files/avatar-slow-old-replaced.png", then: newPhoto)
        results.append(("a photo replaced while the old one downloads ends up as the new photo", replaced && showsNewPhoto("replaced")))

        let removed = try await interrupt("removed", slow: "/files/avatar-slow-old-removed.png", then: nil)
        results.append(("a photo removed while it downloads is not shown afterwards", removed && session.avatars["removed"] == nil && !session.avatarFailures.contains("removed")))

        let moved = try await interrupt("moved", slow: "/files/avatar-slow-gone.png", then: newPhoto)
        results.append(("an old file failing after a photo change does not block the new photo", moved && showsNewPhoto("moved") && !session.avatarFailures.contains("moved")))
        // This peer never appears in an open transcript: the sidebar itself
        // must request its photo, then update the already-visible cell.
        let sidebarSession = try AccountSession(account: session.account, directory: root.appendingPathComponent("sidebar"))
        defer { sidebarSession.stop() }
        sidebarSession.directory["sidebar-only"] = entry("sidebar-only", photo: newPhoto)
        sidebarSession.channels = [RavenChannel(raw: .object(["name": .string("sidebar-dm"), "channel_name": .string("Sidebar peer"), "is_direct_message": .bool(true), "peer_user_id": .string("sidebar-only")]))]
        let controller = ConversationWindow(app: app, session: sidebarSession)
        defer { controller.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == "sidebar-dm" }),
           let cell = controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell {
            let loaded = try await wait { sidebarSession.avatars["sidebar-only"] != nil && sidebarSession.avatarRequests.isEmpty }
            results.append(("a visible DM loads and displays its peer photo without opening a conversation", loaded && controller.channel == nil && cell.imageView?.image === sidebarSession.avatars["sidebar-only"]))
        } else { results.append(("the network avatar fixture creates a sidebar DM", false)) }
        return results
    }
}
