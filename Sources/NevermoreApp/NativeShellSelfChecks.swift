import AppKit
import ServiceManagement
import RavenProtocol
import NevermoreCore

@MainActor enum NativeShellSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
        let compose = file?.items.first { $0.title == "New Message…" }
        results.append(("New Message has an application target independent of open windows", compose?.target as AnyObject? === app && compose?.action == #selector(AppDelegate.newMessage(_:))))
        let dock = app.applicationDockMenu(NSApp)
        results.append(("the Dock exposes New Message and New Window commands", dock?.items.contains { $0.action == #selector(AppDelegate.newMessage(_:)) && $0.target as AnyObject? === app } == true && dock?.items.contains { $0.action == #selector(AppDelegate.newWindow(_:)) } == true))
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        func actions(_ menu: NSMenu?) -> Set<Selector> { Set(menu?.items.compactMap(\.action) ?? []) }
        let spelling = actions(edit?.items.first { $0.title == "Spelling and Grammar" }?.submenu)
        let substitutions = actions(edit?.items.first { $0.title == "Substitutions" }?.submenu)
        results.append(("the text system exposes spelling and substitutions menus", spelling.isSuperset(of: [#selector(NSTextView.showGuessPanel(_:)), #selector(NSTextView.checkSpelling(_:)), #selector(NSTextView.toggleContinuousSpellChecking(_:)), #selector(NSTextView.toggleGrammarChecking(_:)), #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))]) && substitutions.isSuperset(of: [#selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), #selector(NSTextView.toggleAutomaticTextReplacement(_:)), #selector(NSTextView.toggleAutomaticDataDetection(_:))])))
        let titles = NSApp.mainMenu?.items.compactMap { $0.submenu?.title } ?? []
        results.append(("the menu bar follows Mail's File, Edit, View, Go, Conversation, Message, Format, Window, Help order", titles == ["Nevermore", "File", "Edit", "View", "Go", "Conversation", "Message", "Format", "Window", "Help"]))
        let messageMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Message" }?.submenu
        let markAll = messageMenu?.items.first { $0.title == "Mark All Notifications Read" }
        let markSelected = messageMenu?.items.first { $0.title == "Mark Selected Notifications Read" }
        results.append(("Mark All Notifications Read resolves through the app delegate from any window", markAll?.action == #selector(AppDelegate.markAllNotificationsRead(_:)) && markAll?.target == nil))
        results.append(("Mark Selected Notifications Read stays an Inbox-window command", markSelected?.action == #selector(CollectionWindow.markSelectedRead) && markSelected?.target == nil))
        if let first = app.windows.first, let markSelected {
            results.append(("a conversation window disables Mark Selected Notifications Read", !first.validateMenuItem(markSelected)))
        }
        let go = NSApp.mainMenu?.items.first { $0.submenu?.title == "Go" }?.submenu
        let back = go?.items.first { $0.action == #selector(ConversationWindow.goBack) }, forward = go?.items.first { $0.action == #selector(ConversationWindow.goForward) }
        // AppKit localizes bracket key equivalents for the active keyboard
        // layout, so compare the shortcut's presence and modifiers.
        results.append(("Back and Forward have Command shortcuts in the Go menu", back?.keyEquivalent.isEmpty == false && forward?.keyEquivalent.isEmpty == false && back?.keyEquivalent != forward?.keyEquivalent && back?.keyEquivalentModifierMask == .command && forward?.keyEquivalentModifierMask == .command))
        let duplicates = duplicateKeyEquivalents(in: NSApp.mainMenu, services: NSApp.servicesMenu)
        for titles in duplicates { print("DIAG duplicate menu key equivalent: \(titles.joined(separator: " | "))") }
        results.append(("menu key equivalents are unique", duplicates.isEmpty))
        let fixtureServices = NSMenu(title: "Services")
        fixtureServices.addItem(NSMenuItem(title: "Make New Sticky Note", action: nil, keyEquivalent: "q"))
        let fixtureApp = NSMenu(title: "Nevermore")
        fixtureApp.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = fixtureServices
        fixtureApp.addItem(withTitle: "Quit Nevermore", action: nil, keyEquivalent: "q")
        let fixtureBar = NSMenu()
        fixtureBar.addItem(withTitle: "Nevermore", action: nil, keyEquivalent: "").submenu = fixtureApp
        results.append(("system services' shortcuts do not count as duplicate menu keys", duplicateKeyEquivalents(in: fixtureBar, services: fixtureServices).isEmpty))
        // The exemption must not hide a real clash between the app's menus.
        let clashBar = NSMenu()
        for (menu, title) in [("File", "Quick Look Attachment"), ("Edit", "Paste and Match Style")] {
            let submenu = NSMenu(title: menu)
            submenu.addItem(withTitle: title, action: nil, keyEquivalent: "y")
            clashBar.addItem(withTitle: menu, action: nil, keyEquivalent: "").submenu = submenu
        }
        results.append(("two app menu items sharing a shortcut count as a duplicate", duplicateKeyEquivalents(in: clashBar, services: fixtureServices) == [["File > Quick Look Attachment", "Edit > Paste and Match Style"]]))
        let destructive = SheetPrompt.confirmationAlert("Delete?", message: "", confirm: "Delete", destructive: true)
        let ordinary = SheetPrompt.confirmationAlert("Archive?", message: "", confirm: "Archive", destructive: false)
        // NSAlert gives a leading Cancel button Escape and no button Return,
        // so Return can never perform the destructive action.
        let destructiveButton = destructive.buttons.first { $0.hasDestructiveAction }
        results.append(("Return never performs destructive confirmations but confirms ordinary ones", destructiveButton?.title == "Delete" && destructiveButton?.keyEquivalent != "\r" && destructive.buttons.first?.title == "Cancel" && destructive.buttons.first?.keyEquivalent == "\u{1b}" && ordinary.buttons.first { $0.keyEquivalent == "\r" }?.title == "Archive"))
        app.newMessage(nil)
        let choosing = app.windows.first { $0.conversationChooser != nil }
        results.append(("New Message opens the native recipient and conversation chooser", choosing?.conversationChooser != nil && choosing?.window?.attachedSheet != nil))
        if let chooser = choosing?.conversationChooser, let user = choosing?.session?.account.user {
            results.append(("the open-conversation chooser never lists the account user as a person", !chooser.candidates.contains { $0.kind == .person && $0.serverID == user }))
        }
        choosing?.conversationChooser?.cancel()
        if let host = app.windows.first(where: { $0.session?.stopped == false && $0.window?.isVisible == true }), let session = host.session {
            let tab = app.openTab(beside: host, session: session, channel: host.channel)
            let order = app.windowsInRestorationOrder()
            let hostGroup = order.first { $0.0 === host }?.1
            let tabGroup = tab.flatMap { tab in order.first { $0.0 === tab }?.1 }
            let hostIndex = order.firstIndex { $0.0 === host }, tabIndex = tab.flatMap { tab in order.firstIndex { $0.0 === tab } }
            results.append(("tabbed windows restore as one tab group led by the first tab", hostGroup != nil && hostGroup == tabGroup && hostGroup == host.windowID && (hostIndex ?? .max) < (tabIndex ?? .min)))
            tab?.close()
        } else { results.append(("tabbed windows restore as one tab group led by the first tab", false)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreStoppedWindow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(origin: URL(string: "https://fixture.invalid")!, user: "stopped@example.invalid", siteName: "fixture", clientID: "fixture")
        let stopped = try AccountSession(account: account, directory: directory, demo: true)
        app.sessions.append(stopped)
        let stoppedWindow = ConversationWindow(app: app, session: stopped)
        app.windows.append(stoppedWindow); stoppedWindow.showWindow(nil); stoppedWindow.window?.makeKeyAndOrderFront(nil)
        for _ in 0..<100 { if stoppedWindow.window?.isKeyWindow == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        let writableAccount = Account(origin: URL(string: "http://127.0.0.1:12345")!, user: "performance-fixture@example.invalid", siteName: "Fixture", clientID: "performance-loopback")
        let writable = try AccountSession(account: writableAccount, directory: directory.appendingPathComponent("writable"), authentication: .loopbackFixture)
        app.sessions.append(writable)
        if let markAll {
            results.append(("Mark All Read stays disabled in the focused demo even with another writable account", !app.validateMenuItem(markAll)))
        }
        app.sessions.removeAll { $0 === writable }
        writable.stop()
        stopped.stop(); app.newWindow(nil)
        let opened = app.windows.last
        results.append(("New Window replaces a stopped focused account with an active session", opened !== stoppedWindow && opened?.session?.stopped == false))
        opened?.close(); stoppedWindow.close(); app.sessions.removeAll { $0 === stopped }
        let originalLoginStatus = SMAppService.mainApp.status
        app.showSettings(nil)
        let tabController = app.settings?.window?.contentViewController as? NSTabViewController
        let presentsTabbedPanes: Bool
        if let tabController, tabController.tabStyle == .toolbar, tabController.tabViewItems.count >= 5 {
            presentsTabbedPanes = tabController.tabViewItems.allSatisfy { item in
                let fitting = item.viewController?.view.fittingSize ?? .zero
                return fitting.width > 0 && fitting.height > 0
            }
        } else {
            presentsTabbedPanes = false
        }
        results.append(("Settings presents grouped panes in a native tabbed window", presentsTabbedPanes))
        results.append(("opening login preferences does not change login registration", SMAppService.mainApp.status == originalLoginStatus))
        app.settings?.close()
        let previousMenuBar = UserDefaults.standard.object(forKey: "showMenuBarItem")
        defer {
            if let previousMenuBar { UserDefaults.standard.set(previousMenuBar, forKey: "showMenuBarItem") } else { UserDefaults.standard.removeObject(forKey: "showMenuBarItem") }
            app.updateMenuBarItem()
        }
        UserDefaults.standard.set(true, forKey: "showMenuBarItem"); app.updateMenuBarItem()
        let added = app.menuBarItem?.menu?.items.contains { $0.action == #selector(AppDelegate.newMessage(_:)) } == true
        UserDefaults.standard.set(false, forKey: "showMenuBarItem"); app.updateMenuBarItem()
        results.append(("the optional menu bar item can be added and removed", added && app.menuBarItem == nil))
        results += checkGeneralPreferences(app)
        let diagnostic = await app.diagnosticsSummary()
        results.append(("diagnostics contain aggregate state without account or site identifiers", diagnostic.contains("Active accounts:") && app.sessions.allSatisfy { !diagnostic.contains($0.account.user) && !diagnostic.contains($0.account.origin.absoluteString) } && !diagnostic.contains(app.dataRoot.path)))
        app.keyboardShortcuts(nil)
        results.append(("keyboard shortcut help uses a native selectable text view", app.shortcutsWindow?.window?.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSTextView.self).first }.map { !$0.isEditable && $0.isSelectable && $0.string.contains("⌘Return") } == true))
        app.shortcutsWindow?.close()
        return results
    }

    /// The menu bar icon choice and the send key popup. Restores the three
    /// preferences it changes.
    private static func checkGeneralPreferences(_ app: AppDelegate) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let defaults = UserDefaults.standard
        let keys = ["showMenuBarItem", MenuBarIcon.defaultsKey, ComposerSendKey.defaultsKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            app.updateMenuBarItem()
        }

        let renderings = MenuBarIcon.allCases.map { rendering(MenuBarIconArt.image(for: $0)) }
        results.append(("every menu bar icon is a template image that draws something", MenuBarIcon.allCases.allSatisfy { MenuBarIconArt.image(for: $0).isTemplate } && renderings.allSatisfy { $0.hasInk }))
        results.append(("the menu bar icons are distinct", Set(renderings.map(\.pixels)).count == MenuBarIcon.allCases.count))

        defaults.removeObject(forKey: MenuBarIcon.defaultsKey)
        defaults.set(true, forKey: "showMenuBarItem"); app.updateMenuBarItem()
        let item = app.menuBarItem
        let shown = { item?.button?.image.map { rendering($0).pixels } }
        results.append(("the menu bar item shows a raven unless another icon is chosen", shown() == rendering(MenuBarIconArt.image(for: .raven)).pixels))

        app.showSettings(nil)
        guard let settings = app.settings else { return results + [("Settings offers the menu bar icons and send keys", false)] }
        defer { settings.close() }
        results.append(("Settings lists every menu bar icon with its image and selects the raven", settings.menuBarIcon.itemTitles == MenuBarIcon.allCases.map(MenuBarIconArt.title(for:)) && settings.menuBarIcon.itemArray.allSatisfy { $0.image != nil } && settings.menuBarIcon.titleOfSelectedItem == "Raven" && settings.menuBarIcon.isEnabled))
        if let feather = MenuBarIcon.allCases.firstIndex(of: .feather) {
            settings.menuBarIcon.selectItem(at: feather); settings.changeMenuBarIcon()
        }
        results.append(("choosing an icon redraws the existing menu bar item", app.menuBarItem === item && defaults.string(forKey: MenuBarIcon.defaultsKey) == MenuBarIcon.feather.rawValue && shown() == rendering(MenuBarIconArt.image(for: .feather)).pixels))
        settings.menuBar.state = .off; settings.changeMenuBar()
        results.append(("the icon popup is disabled while the menu bar item is hidden", !settings.menuBarIcon.isEnabled && app.menuBarItem == nil))

        defaults.removeObject(forKey: ComposerSendKey.defaultsKey)
        settings.reloadGeneralControls()
        let listsBothKeys = settings.sendKey.itemTitles == ["Return sends, Shift-Return inserts a new line", "Command-Return sends, Return inserts a new line"] && settings.sendKey.indexOfSelectedItem == 0
        settings.sendKey.selectItem(at: 1); settings.changeSendKey()
        let storesCommandReturn = defaults.bool(forKey: ComposerSendKey.defaultsKey)
        settings.sendKey.selectItem(at: 0); settings.changeSendKey()
        results.append(("the send key popup names both choices and stores the chosen one", listsBothKeys && storesCommandReturn && !defaults.bool(forKey: ComposerSendKey.defaultsKey)))

        results += InterfaceSoundSelfChecks.checkSettings(settings)
        return results
    }

    /// The titles sharing each shortcut used more than once in the menu bar,
    /// one level of submenus deep. The Services menu is skipped: macOS fills
    /// it with other apps' services, whose shortcuts the user assigns in
    /// Keyboard settings and the app's own items take precedence over.
    private static func duplicateKeyEquivalents(in menuBar: NSMenu?, services: NSMenu?) -> [[String]] {
        var menuKeys: [String: [String]] = [:]
        for top in menuBar?.items ?? [] {
            for entry in top.submenu?.items ?? [] {
                let submenu = entry.submenu === services ? [] : entry.submenu?.items ?? []
                let candidates: [NSMenuItem] = [entry] + submenu
                for item in candidates where !item.keyEquivalent.isEmpty && !item.isHidden && !item.isAlternate {
                    menuKeys["\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent.lowercased())", default: []].append("\(top.submenu?.title ?? "") > \(item.title)")
                }
            }
        }
        // Sorted so the diagnostics read the same from run to run.
        return menuKeys.values.filter { $0.count > 1 }.sorted { $0.joined() < $1.joined() }
    }

    /// `image` drawn at 2x into a bitmap, to compare icons by what they show.
    private static func rendering(_ image: NSImage) -> (pixels: Data, hasInk: Bool) {
        let side = Int(MenuBarIconArt.menuBarSize * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData else { return (Data(), false) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = Data(bytes: data, count: bitmap.bytesPerRow * side)
        return (pixels, pixels.contains { $0 != 0 })
    }
}
