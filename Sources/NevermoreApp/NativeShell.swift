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
    /// type; the Inbox window's own toolbar keeps its richer feedback.
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
        return sessions.first(where: { eligible($0) })
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
    @objc func keyboardShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Keyboard Shortcuts"; window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("NevermoreKeyboardShortcuts")
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 14); text.textContainerInset = NSSize(width: 20, height: 20)
            let sections: [(String, [(String, String)])] = [
                ("Windows and conversations", [("New message", "⌘N"), ("New window", "⇧⌘N"), ("New tab", "⌘T"), ("Open conversation", "⌘O"), ("Back / forward", "⌘[ / ⌘]"), ("Next / previous conversation", "⌥⌘↓ / ⌥⌘↑"), ("Next / previous unread conversation", "⇧⌥⌘↓ / ⇧⌥⌘↑"), ("Inbox … Outbox (Go menu)", "⌘1 – ⌘6"), ("Show or hide the sidebar", "⌃⌘S"), ("Show or hide the thread inspector", "⌥⌘I"), ("Settings", "⌘,")]),
                ("Reading", [("Find in the transcript", "⌘F"), ("Next / previous match", "⌘G / ⇧⌘G"), ("Search messages", "⌥⌘F"), ("Search this account", "⇧⌘F"), ("Next / previous message", "⌃⌘] / ⌃⌘["), ("Quick Look attachment", "Space or ⌘Y"), ("Read on: page down, then the next unread conversation", "Space"), ("Start typing a message", "Type while reading"), ("Make text bigger / smaller / normal", "⌘+ / ⌘- / ⌘0"), ("Print the conversation", "⌘P")]),
                ("Messages", [("Reply", "⌘R"), ("Reply in thread", "⇧⌘T"), ("Edit your last message", "↑ in an empty composer"), ("Mark conversation as unread", "⇧⌘U"), ("Attach files", "⇧⌘A")]),
                ("Writing", [("Send", "Return, or ⌘Return by preference"), ("Insert a line break", "⇧Return or ⌥Return"), ("Move focus out of the composer", "Tab / ⇧Tab"), ("Bold / italic / underline", "⌘B / ⌘I / ⌘U"), ("Strikethrough", "⇧⌘X"), ("Code", "⇧⌘K"), ("Insert link", "⌘K"), ("Bulleted / numbered list", "⇧⌘7 / ⇧⌘9"), ("Block quote", "⌘'"), ("Mention a person", "⇧⌘2 or @"), ("Mention a channel", "#"), ("Emoji & Symbols", "⌃⌘Space"), ("Cancel a reply or edit", "Escape")])
            ]
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
