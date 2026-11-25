import AppKit
import NevermoreCore

extension AppDelegate {
    var activeConversationWindow: ConversationWindow? {
        if let focused = NSApp.keyWindow?.windowController as? ConversationWindow, !focused.isClosed, focused.session?.stopped == false { return focused }
        return windows.last { !$0.isClosed && $0.session?.stopped == false }
    }
    @objc func newMessage(_ sender: Any?) {
        guard sessions.contains(where: { !$0.stopped }) else { addAccount(sender); return }
        var controller = activeConversationWindow
        if controller == nil { newWindow(sender); controller = windows.last }
        guard let controller else { return }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); controller.chooseConversation(sender)
    }
    // Responder-chain fallbacks: with Settings, a collection or another
    // auxiliary window in front, Go commands act on the most recent
    // conversation window, as Mail's mailbox shortcuts do.
    private func forward(_ body: (ConversationWindow) -> Void) {
        guard let controller = activeConversationWindow else { NSSound.beep(); return }
        controller.showWindow(nil)
        body(controller)
    }
    @objc func goHome(_ sender: Any?) { forward { $0.window?.makeKeyAndOrderFront(nil); $0.showHome() } }
    @objc func inbox() { forward { $0.inbox() } }
    @objc func threads() { forward { $0.threads() } }
    @objc func outbox() { forward { $0.outbox() } }
    @objc func showSavedMessages(_ sender: Any?) { forward { $0.showSavedMessages(sender) } }
    @objc func showReminders(_ sender: Any?) { forward { $0.showReminders(sender) } }
    @objc func showScheduledMessages(_ sender: Any?) { forward { $0.showScheduledMessages(sender) } }
    @objc func chooseConversation(_ sender: Any?) { forward { $0.window?.makeKeyAndOrderFront(nil); $0.chooseConversation(sender) } }
    @objc func newConversationTab(_ sender: Any?) { forward { $0.window?.makeKeyAndOrderFront(nil); $0.newConversationTab(sender) } }
    /// Marks every notification of one account read from any window. The
    /// mutation is account-wide and needs no collection window, so the
    /// Message menu item resolves through the app delegate in every window
    /// type; with several accounts and no conversation window key the item
    /// stays disabled instead of guessing an account. The Inbox window's own
    /// toolbar keeps its richer feedback.
    @objc func markAllNotificationsRead(_ sender: Any?) {
        let controller = NSApp.keyWindow?.windowController
        guard let session = notificationReadSession else { NSSound.beep(); return }
        let conversation = (controller as? ConversationWindow) ?? activeConversationWindow
        Task { @MainActor in
            let transport = CollectionBatchActions.transport(session: session)
            // Attempted once: an uncertain outcome is never replayed, the
            // canonical read below reports what the server applied.
            var acknowledged = false
            do { try await transport.markAllRead(); acknowledged = true } catch { }
            var reconciled = false
            do { session.unreadNotificationIDs = try await transport.unreadIDs(); reconciled = true } catch { }
            session.notify()
            for window in windows where window.session === session {
                for collection in window.collectionWindows where collection.kind == .inbox && collection.session === session { collection.refresh() }
            }
            if let conversation, conversation.session === session {
                conversation.status.stringValue = acknowledged
                    ? (reconciled ? "All notifications marked read." : "Notifications were marked read, but unread status could not be refreshed. Refresh this account to check.")
                    : "Could not confirm that all notifications were marked read. Refresh before trying again."
            }
        }
    }
    private var notificationReadSession: AccountSession? {
        let controller = NSApp.keyWindow?.windowController
        let focused = (controller as? CollectionWindow)?.session ?? (controller as? ConversationWindow)?.session ?? activeConversationWindow?.session
        func eligible(_ session: AccountSession) -> Bool { !session.stopped && !session.readOnly && !session.demo }
        if let focused { return eligible(focused) ? focused : nil }
        // No conversation or collection window is key, so the target account
        // is ambiguous: act only when exactly one account is eligible rather
        // than silently marking an arbitrary account's notifications read.
        let candidates = sessions.filter(eligible)
        return candidates.count == 1 ? candidates.first : nil
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let forwarded: [Selector] = [#selector(goHome(_:)), #selector(inbox), #selector(threads), #selector(outbox), #selector(showSavedMessages(_:)), #selector(showReminders(_:)), #selector(showScheduledMessages(_:)), #selector(chooseConversation(_:)), #selector(newConversationTab(_:))]
        if item.action == #selector(markAllNotificationsRead(_:)) {
            return notificationReadSession != nil
        }
        if let action = item.action, forwarded.contains(action) { return activeConversationWindow != nil }
        if item.action == #selector(showThemeEditor(_:)) { return !ThemeManager.shared.current.isClassic }
        return true
    }
    func updateMenuBarItem() {
        guard UserDefaults.standard.bool(forKey: "showMenuBarItem") else {
            if let menuBarItem { NSStatusBar.system.removeStatusItem(menuBarItem); self.menuBarItem = nil }
            return
        }
        // Also called when only the icon choice changed: an existing item
        // keeps its place in the menu bar and takes the new image.
        let icon = MenuBarIcon(storedValue: UserDefaults.standard.string(forKey: MenuBarIcon.defaultsKey))
        if let menuBarItem { menuBarItem.button?.image = MenuBarIconArt.image(for: icon); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIconArt.image(for: icon)
        item.button?.setAccessibilityLabel("Nevermore")
        item.button?.toolTip = "Nevermore"
        let menu = NSMenu()
        for (title, action) in [("New Message…", #selector(newMessage(_:))), ("New Window", #selector(newWindow(_:))), ("Settings…", #selector(showSettings(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: updates.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nevermore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        item.menu = menu; menuBarItem = item
    }
    /// Formats a menu item's key equivalent as symbols, e.g. "⇧⌘T".
    private static func shortcutSymbol(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var parts: [String] = []
        // HIG order: control, option, shift, command.
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        switch key {
        case "\r", "\u{3}": parts.append("Return")
        case "\u{1B}": parts.append("Escape")
        case "\t": parts.append("Tab")
        case " ": parts.append("Space")
        case "\u{F700}": parts.append("↑")
        case "\u{F701}": parts.append("↓")
        case "\u{F702}": parts.append("←")
        case "\u{F703}": parts.append("→")
        case "\u{F728}": parts.append("⌦")
        case "\u{F729}": parts.append("Home")
        case "\u{F72A}": parts.append("Begin")
        case "\u{F72B}": parts.append("End")
        case "\u{F72C}": parts.append("Page Up")
        case "\u{F72D}": parts.append("Page Down")
        case "\u{F727}": parts.append("Help")
        case "\u{7F}": parts.append("Delete")
        default:
            // Private-use function-key scalars 0xF704-0xF726 (AppKit's
            // NSF1...NSF35 range) label as F1-F35; the navigation scalars
            // above 0xF727 are already handled by the switch cases above.
            if let scalar = key.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) {
                parts.append("F\(scalar.value - 0xF704 + 1)")
            } else {
                parts.append(key.uppercased())
            }
        }
        return parts.joined()
    }
    @objc func keyboardShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Keyboard Shortcuts"; window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("NevermoreKeyboardShortcuts")
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 14); text.textContainerInset = NSSize(width: 20, height: 20)
            // Menu-backed shortcuts are generated from the main menu itself,
            // so this window cannot drift from the actual key equivalents.
            var sections: [(String, [(String, String)])] = []
            if let main = NSApp.mainMenu {
                for menu in main.items {
                    let title = menu.title
                    // Skip the system Apple menu (empty title) and the Services
                    // menu, identified by identity so localization cannot
                    // defeat the check. The app menu is included: Settings… ⌘,
                    // lives there.
                    guard !title.isEmpty, menu.submenu !== NSApp.servicesMenu else { continue }
                    let rows: [(String, String)] = menu.submenu?.items.compactMap { (item: NSMenuItem) -> (String, String)? in
                        guard !item.isSeparatorItem, !item.isHidden, !item.isAlternate, !item.title.isEmpty, item.action != nil, let keys = Self.shortcutSymbol(item) else { return nil }
                        return (item.title, keys)
                    } ?? []
                    if !rows.isEmpty { sections.append((title, rows)) }
                }
            }
            // Only behaviors that no menu item carries a key equivalent for;
            // rows whose title already appears above are dropped so nothing
            // renders twice.
            let menuTitles = Set(sections.flatMap { $0.1.map { $0.0.lowercased() } })
            let also = [("Send the message", "Return, or ⌘Return by preference"), ("Read on: page down, then the next unread conversation", "Space"), ("Start typing a message", "Type while reading"), ("Edit your last message", "↑ in an empty composer"), ("Cancel a reply or edit", "Escape")]
                .filter { !menuTitles.contains($0.0.lowercased()) }
            if !also.isEmpty { sections.append(("Also", also)) }
            let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 300)]; paragraph.paragraphSpacing = 3
            let output = NSMutableAttributedString()
            for (title, rows) in sections {
                output.append(NSAttributedString(string: "\(title)\n", attributes: [.font: NSFont.preferredFont(forTextStyle: .headline), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
                for (label, keys) in rows { output.append(NSAttributedString(string: "\(label)\t\(keys)\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])) }
                output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            }
            output.append(NSAttributedString(string: "Marked text is committed before sending. Escape cancels a chooser or sheet. Standard text selection, Undo, spelling, substitutions, dictation and Services use the macOS text system.", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            text.textStorage?.setAttributedString(output)
            text.setAccessibilityLabel("Keyboard shortcuts")
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
            window.contentView = scroll; shortcutsWindow = NSWindowController(window: window)
        }
        shortcutsWindow?.showWindow(sender)
    }
    @objc func copyDiagnostics(_ sender: Any?) {
        Task { @MainActor in
            let summary = await diagnosticsSummary()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary, forType: .string)
        }
    }
    func diagnosticsSummary() async -> String {
        let active = sessions.filter { !$0.stopped }
        var queued: Int? = 0
        for session in active {
            guard let count = try? await session.store.operations().count else { queued = nil; break }
            queued = (queued ?? 0) + count
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        Nevermore \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)
        Active accounts: \(active.count)
        Live realtime sessions: \(active.filter(\.realtimeLive).count)
        Read-only sessions: \(active.filter(\.readOnly).count)
        Queued sends: \(queued.map(String.init) ?? "unavailable")
        History retention: \(UserDefaults.standard.object(forKey: "retainHistory") as? Bool == false ? "off" : "on")
        Running-app notifications only; quit-time push is not configured.
        No account identifiers, site URLs, chat content, credentials or file paths are included.
        """
    }
}
