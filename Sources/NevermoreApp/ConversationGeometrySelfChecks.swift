import AppKit

@MainActor enum ConversationGeometrySelfChecks {
    static func run() -> [(String, Bool)] {
        let app = AppDelegate()
        let fresh = ConversationWindow(app: app, session: nil, lastFrameAutosaveName: nil)
        defer { fresh.close() }
        fresh.showWindow(nil)
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        let sidebar = fresh.sidebarSplitItem.viewController.view
        let split = fresh.splitController.splitView
        // setPosition specifies a divider coordinate. AppKit can inset the
        // controller's content inside its arranged pane, so measure the pane.
        func dividerPosition() -> CGFloat { split.arrangedSubviews.first?.frame.maxX ?? .nan }
        var results = [("a fresh conversation window places its sidebar divider at 300 points", abs(dividerPosition() - 300) <= 1)]
        print("MEASURE sidebar divider: \(dividerPosition()) pt; pane: \(String(describing: split.arrangedSubviews.first?.frame)); content: \(sidebar.frame)")
        fresh.splitController.splitView.setPosition(340, ofDividerAt: 0)
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        results.append(("the wider default does not prevent manually resizing the sidebar", abs(dividerPosition() - 340) <= 1))
        fresh.toggleSidebar(nil)
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        fresh.toggleSidebar(nil)
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        results.append(("hiding and showing the sidebar retains its manually adjusted width", abs(dividerPosition() - 340) <= 1))
        fresh.window?.setContentSize(NSSize(width: 650, height: 500))
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        results.append(("a narrow window still leaves room for the conversation", sidebar.frame.width >= 200 && fresh.contentController.view.frame.width >= 380))
        let name = "NevermoreGeometryCheck-\(UUID())"
        let key = "NSWindow Frame \(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let first = ConversationWindow(app: app, session: nil, lastFrameAutosaveName: name)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        first.showWindow(nil)
        first.window?.setFrame(NSRect(x: screen.minX + 35, y: screen.minY + 45, width: 780, height: 540), display: true)
        let moved = first.window?.frame
        first.close()
        let saved = UserDefaults.standard.string(forKey: key)
        let reopened = ConversationWindow(app: app, session: nil, lastFrameAutosaveName: name)
        defer { reopened.close() }
        results.append(("a new conversation window restores the previous location and size without an account or the previous window UUID", saved != nil && first.windowID != reopened.windowID && reopened.window?.frame == moved))

        let transient = ConversationWindow(app: app, session: nil, lastFrameAutosaveName: nil)
        transient.showWindow(nil)
        transient.window?.setFrameOrigin(NSPoint(x: screen.minX + 90, y: screen.minY + 80))
        transient.close()
        results.append(("transient self-check windows do not overwrite remembered geometry", UserDefaults.standard.string(forKey: key) == saved))

        UserDefaults.standard.set("100000 100000 780 540 0 0 1440 900 ", forKey: key)
        let offscreen = ConversationWindow(app: app, session: nil, lastFrameAutosaveName: name)
        defer { offscreen.close() }
        results.append(("remembered geometry from a removed display remains on an available screen", offscreen.window.map { window in NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) } } == true))
        return results
    }
}
