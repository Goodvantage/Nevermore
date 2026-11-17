import AppKit
import RavenProtocol

@MainActor enum ChannelAvatarSelfChecks {
    static func run(app: AppDelegate) throws -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreChannelAvatarCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "self", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: root, demo: true)
        defer { session.stop() }
        func channel(_ id: String, name: String = "general", workspace: String = "Engineering", extra: [String: JSONValue] = [:]) -> RavenChannel {
            let fields: [String: JSONValue] = ["name": .string(id), "channel_name": .string(name), "workspace": .string(workspace), "type": .string("Open")]
            return RavenChannel(raw: .object(fields.merging(extra) { _, new in new }))
        }
        let general = channel("one")
        let privateRoom = channel("two", extra: ["type": .string("Private"), "muted": .bool(true)])
        let otherWorkspace = channel("three", workspace: "Operations")
        let archived = channel("four", extra: ["is_archived": .bool(true)])
        let thread = channel("five", extra: ["is_thread": .bool(true)])
        session.channels = [general, privateRoom, otherWorkspace, archived, thread]
        // A same-named user photo must never become a channel's identity.
        let userPhoto = RavenPortrait.image(named: "somebody else")
        session.avatars["general"] = userPhoto
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func cell(_ channel: RavenChannel) -> SidebarConversationCell? {
            guard let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == channel.id }) else { return nil }
            return controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell
        }
        guard let generalCell = cell(general), let image = generalCell.imageView?.image,
              let privateCell = cell(privateRoom), let privateImage = privateCell.imageView?.image else {
            return [("channel rows receive generated tiles", false)]
        }
        var results = [("ordinary channels show non-template tiles without using user photos", !image.isTemplate && image !== userPhoto && image === session.channelAvatarImage(for: general))]
        results.append(("private channels have their own lock tile and explicit accessibility/tooltip labels", !privateImage.isTemplate && privateImage !== image && privateCell.accessibilityLabel()?.contains("private channel") == true && privateCell.toolTip?.contains("Private channel") == true))
        results.append(("equal channel names in different workspaces get distinct tiles", cell(otherWorkspace)?.imageView?.image !== image && cell(otherWorkspace)?.imageView?.image != nil))
        results.append(("channel membership and unread counts do not reshuffle tiles", controller.sidebarModel(for: channel("one", extra: ["members": .array([.string("new member")])]), unread: 5).photo === image))
        results.append(("view-specific channel labels do not replace the canonical seed", controller.sidebarModel(for: channel("one", extra: ["channel_name_for_current_user": .string("Different label")]), unread: 0).photo === image))
        for (item, symbol) in [(archived, "archivebox"), (thread, "bubble.left.and.text.bubble.right")] {
            let model = controller.sidebarModel(for: item, unread: 0)
            results.append(("\(symbol) takes precedence over generated channel art", model.photo == nil && model.symbolName == symbol))
        }
        generalCell.configure(controller.sidebarModel(for: privateRoom, unread: 3), fontSize: controller.sidebarFontSize)
        results.append(("reused private rows keep privacy, unread and muted labels", generalCell.imageView?.image === privateImage && generalCell.accessibilityLabel()?.contains("private channel, 3 unread, muted") == true))
        generalCell.configure(controller.sidebarModel(for: general, unread: 0), fontSize: controller.sidebarFontSize)
        results.append(("reusing a private row for an ordinary channel clears its privacy marker", generalCell.imageView?.image === image && generalCell.accessibilityLabel()?.contains("private channel") == false))

        let renamed = channel("one", name: "announcements")
        session.channels = [renamed, privateRoom]
        session.notify()
        results.append(("renaming a channel updates its tile in the sidebar", cell(renamed)?.imageView?.image === session.channelAvatarImage(for: renamed) && cell(renamed)?.imageView?.image !== image))
        results.append(("channel generation never creates photo requests or overwrites user photos", session.avatarRequests.isEmpty && session.avatars.count == 1 && session.avatarImage(for: "general") === userPhoto))
        results.append(("unnamed channels keep a generic type icon instead of an invented identity", session.channelAvatarImage(for: RavenChannel(raw: .object([:]))) == nil))
        session.stop()
        results.append(("stopped accounts do not regenerate channel tiles", session.channelAvatarImage(for: general) == nil))
        return results
    }
}
