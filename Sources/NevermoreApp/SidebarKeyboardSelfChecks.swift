import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of moving through the sidebar with the keyboard.
/// They use a disposable demo store; nothing reaches a server.
@MainActor enum SidebarKeyboardSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSidebarKeyboardCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "sidebar-keys@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let first = RavenChannel(raw: .object(["name": .string("keys-a"), "channel_name": .string("keys-a")]))
        let second = RavenChannel(raw: .object(["name": .string("keys-b"), "channel_name": .string("keys-b")]))
        let third = RavenChannel(raw: .object(["name": .string("keys-c"), "channel_name": .string("keys-c")]))
        session.channels = [first, second, third]
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(first)
        await controller.loadTask?.value; await controller.renderTask?.value
        // The delayed open acts only while the sidebar has focus, as it does
        // for a reader arrowing through a visible list.
        controller.window?.makeFirstResponder(controller.sidebar)

        var results: [(String, Bool)] = []
        func press(_ keyCode: UInt16, _ character: Int) {
            let characters = String(UnicodeScalar(UInt16(character)).map(Character.init) ?? " ")
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
            controller.sidebar.keyDown(with: event)
        }
        func highlighted() -> String? {
            controller.sidebarItems.indices.contains(controller.sidebar.selectedRow) ? controller.sidebarItems[controller.sidebar.selectedRow].channel?.id : nil
        }
        /// Waits for the conversation to open, with room for a busy main
        /// thread; the checks read "not yet" before calling this.
        func settle(opening channelID: String) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while controller.channel?.id != channelID, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            await controller.loadTask?.value; await controller.renderTask?.value
        }
        /// Waits out the delayed-open pause without asking anything to open.
        func awaitPause() async {
            try? await Task.sleep(for: .milliseconds(600))
        }

        // Down arrow: the conversation the selection rests on opens after a
        // short pause, not at once.
        press(125, NSDownArrowFunctionKey)
        let movedTo = highlighted()
        let stayedAtFirst = controller.channel?.id == first.id
        await settle(opening: second.id)
        results.append(("an arrow key in the sidebar opens the conversation it lands on after a pause", movedTo == second.id && stayedAtFirst && controller.channel?.id == second.id))

        // A held key passes over conversations: only the last one opens.
        press(126, NSUpArrowFunctionKey)
        press(125, NSDownArrowFunctionKey)
        press(125, NSDownArrowFunctionKey)
        let passedOver = controller.channel?.id == second.id
        await settle(opening: third.id)
        results.append(("arrowing past conversations opens only the one the selection rests on", passedOver && highlighted() == third.id && controller.channel?.id == third.id))

        // Return opens the highlighted conversation at once and moves focus
        // into its composer, instead of the composer of the one still shown.
        controller.window?.makeFirstResponder(controller.sidebar)
        press(126, NSUpArrowFunctionKey)
        press(36, 13)
        let openedAtOnce = controller.channel?.id == second.id
        await settle(opening: second.id)
        let composerFocused = controller.window?.firstResponder === controller.composer
        results.append(("Return opens the highlighted conversation at once and focuses its composer", openedAtOnce && controller.channel?.id == second.id && composerFocused))

        // New activity reloads the sidebar and can move rows. A reload during
        // the pause keeps the selection where the keyboard left it, and that
        // conversation still opens.
        controller.window?.makeFirstResponder(controller.sidebar)
        press(125, NSDownArrowFunctionKey)
        session.channels = [third, first, second]
        controller.refreshSidebar()
        let keptThroughReload = highlighted() == third.id
        await settle(opening: third.id)
        results.append(("a sidebar reload during the pause keeps the arrowed selection, which then opens", keptThroughReload && controller.channel?.id == third.id))

        // Opening a conversation another way during the pause, such as from
        // a notification, wins over the row the keyboard left.
        press(125, NSDownArrowFunctionKey)
        controller.select(second)
        let deadline = ContinuousClock.now + .seconds(1)
        while controller.channel?.id == second.id, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        results.append(("opening a conversation during the pause cancels the keyboard's pending open", controller.channel?.id == second.id && highlighted() == second.id))

        session.channels = [first, second, third]
        func startPendingOpen() async -> Bool {
            controller.select(first)
            await controller.loadTask?.value
            await controller.renderTask?.value
            controller.window?.makeFirstResponder(controller.sidebar)
            press(125, NSDownArrowFunctionKey)
            return highlighted() == second.id && controller.channel?.id == first.id
        }
        let pendingClick = await startPendingOpen()
        if let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == third.id }) {
            controller.sidebar.onMouseSelection?(row)
            // Incoming activity reorders the list between mouse-down and
            // the table action. AppKit's click must keep its original row.
            session.channels = [third, first, second]
            controller.refreshSidebar()
            let keptClickedRow = highlighted() == third.id
            controller.selectedSidebar()
            controller.sidebar.onMouseSelection?(nil)
            await awaitPause()
            results.append(("a sidebar click takes precedence over an arrow key through a reload",
                            pendingClick && keptClickedRow && controller.channel?.id == third.id))
            session.channels = [first, second, third]
        } else { results.append(("the sidebar click fixture has a destination", false)) }
        let pendingComposer = await startPendingOpen()
        controller.window?.makeFirstResponder(controller.composer)
        await awaitPause()
        results.append(("leaving the sidebar for the composer cancels the pending open", pendingComposer && controller.channel?.id == first.id))

        for inTab in [false, true] {
            let pending = await startPendingOpen()
            let item = NSMenuItem()
            item.representedObject = second
            let count = app.windows.count
            if inTab { controller.openSidebarRowInNewTab(item) } else { controller.openSidebarRowInNewWindow(item) }
            await awaitPause()
            let opened = app.windows.count == count + 1 ? app.windows.last : nil
            results.append(("opening a new \(inTab ? "tab" : "window") cancels the source window's pending open",
                            pending && controller.channel?.id == first.id && opened?.channel?.id == second.id))
            opened?.close()
        }
        // Two Raven sites may use the same channel IDs. An arrow in the
        // first account must never select that channel in the second one.
        let replacement = Account(origin: URL(string: "https://other.invalid")!, user: account.user, siteName: "Other", clientID: "fixture")
        let other = try AccountSession(account: replacement, directory: directory.appendingPathComponent("other"), demo: true)
        defer { other.stop() }
        other.channels = [first, second, third]
        let pendingSwitch = await startPendingOpen()
        controller.use(other)
        await awaitPause()
        results.append(("switching accounts clears the pending sidebar selection",
                        pendingSwitch && controller.channel == nil && highlighted() == nil))
        return results
    }
}
