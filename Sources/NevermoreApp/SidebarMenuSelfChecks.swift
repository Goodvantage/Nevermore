import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks that every place in the sidebar has a context
/// menu with something in it. Uses a disposable store and the demo wire.
@MainActor enum SidebarMenuSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSidebarMenuCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "sidebar-menu-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        session.channels = [RavenChannel(raw: .object(["name": .string("menu-channel"), "channel_name": .string("menu-channel"), "workspace": .string("Fixture")]))]
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.refreshSidebar()
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func titles(row: Int) -> [String] {
            let menu = NSMenu()
            controller.populateSidebarMenu(menu, row: row)
            return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        }
        let home = controller.sidebarItems.firstIndex { $0.isHome }
        let header = controller.sidebarItems.firstIndex { $0.isHeader }
        let conversation = controller.sidebarItems.firstIndex { $0.channel != nil }
        check("the Home row's context menu offers Customize Home", home.map { titles(row: $0) == ["Customize Home…"] } == true)
        check("a sidebar heading's context menu offers new conversations and archived ones", header.map { titles(row: $0) == ["New Message…", "New Channel…", "Show Archived Conversations"] } == true)
        check("empty sidebar space has the same context menu as a heading", titles(row: -1) == ["New Message…", "New Channel…", "Show Archived Conversations"])
        check("a conversation row keeps its own context menu", conversation.map { titles(row: $0).first == "Open in New Window" } == true)
        return checks
    }
}
