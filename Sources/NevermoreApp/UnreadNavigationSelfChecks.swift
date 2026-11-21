import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of Go ▸ Next and Previous Unread Conversation: both
/// skip read conversations and wrap around the sidebar, so either reaches
/// every unread conversation. Disposable store, demo wire.
@MainActor enum UnreadNavigationSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreUnreadNavigationCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "unread-navigation-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        func channel(_ id: String) -> RavenChannel { RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)])) }
        let first = channel("a-unread"), read = channel("b-read"), middle = channel("c-unread"), current = channel("d-reading"), last = channel("e-unread")
        session.channels = [first, read, middle, current, last]
        session.unread = .array([first, middle, last].map { .object(["name": .string($0.id), "unread_count": .number(1)]) })
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func open(_ channel: RavenChannel) async { controller.select(channel); await controller.loadTask?.value; await controller.renderTask?.value }
        func go(_ action: (Any?) -> Void) async -> String? { action(nil); await controller.loadTask?.value; return controller.channel?.id }
        let previous = NSMenuItem(title: "Previous Unread Conversation", action: #selector(ConversationWindow.previousUnreadConversation(_:)), keyEquivalent: "")

        await open(current)
        check("Previous Unread Conversation is enabled with conversations in the sidebar", controller.validateMenuItem(previous))
        check("Previous Unread Conversation skips read conversations", await go(controller.previousUnreadConversation) == middle.id)
        check("Previous Unread Conversation reaches the first unread conversation", await go(controller.previousUnreadConversation) == first.id)
        check("Previous Unread Conversation wraps to the last one, as Next Unread wraps to the first", await go(controller.previousUnreadConversation) == last.id)
        check("Next Unread Conversation wraps to the first unread conversation", await go(controller.nextUnreadConversation) == first.id)
        check("Next Unread Conversation skips read conversations", await go(controller.nextUnreadConversation) == middle.id)
        await open(first)
        check("Previous Conversation still stops at the top of the sidebar", await go(controller.previousConversation) == first.id)
        let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.items.contains { $0.action == #selector(ConversationWindow.nextUnreadConversation(_:)) } }
        let item = menu?.items.first { $0.action == #selector(ConversationWindow.previousUnreadConversation(_:)) }
        check("the Go menu offers Previous Unread Conversation on Shift-Option-Command-Up", item?.keyEquivalentModifierMask == [.command, .option, .shift] && item?.keyEquivalent == String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        return checks
    }
}
