import AppKit
import AuthenticationServices
// UNNotification* are non-Sendable on the CI runner's Xcode 26 SDK
// (newer SDKs mark them Sendable); results are only read for identifiers.
@preconcurrency import UserNotifications
import RavenProtocol
import NevermoreCore

@main struct NevermoreMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--performance-cleanup") {
            do {
                let id = try PerformanceMetrics.cleanupID(arguments: CommandLine.arguments)
                try PerformanceChecks.cleanupFixture(id)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Performance cleanup failed or arguments were invalid.\n".utf8)); exit(2)
            }
        }
        if CommandLine.arguments.contains("--performance-seed") {
            do {
                let id = try PerformanceMetrics.seedID(arguments: CommandLine.arguments)
                Task { @MainActor in
                    do { try await PerformanceChecks.seedFixture(id); exit(0) }
                    catch { FileHandle.standardError.write(Data("Performance seeding failed.\n".utf8)); exit(2) }
                }
                RunLoop.main.run()
                return
            } catch { FileHandle.standardError.write(Data("Invalid seed arguments.\n".utf8)); exit(2) }
        }
        PerformanceChecks.mainEnteredAt = ProcessInfo.processInfo.systemUptime
        if CommandLine.arguments.contains("--performance-check"), (try? PerformanceMetrics.Options(arguments: CommandLine.arguments)) == nil {
            FileHandle.standardError.write(Data("Performance mode requires --demo, idle seconds 0...600 and iterations 10 or 20.\n".utf8)); exit(2)
        }
        let checkingSoundSettings = CommandLine.arguments.contains("--check-ui-sound-settings")
        if CommandLine.arguments.contains("--check-ui-sounds") || checkingSoundSettings {
            var results = InterfaceSoundSelfChecks.run()
            if checkingSoundSettings {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                let delegate = AppDelegate()
                withExtendedLifetime(delegate) {
                    let settings = SettingsController(app: delegate)
                    results += InterfaceSoundSelfChecks.checkSettings(settings)
                    settings.close()
                }
            }
            for (label, passed) in results { print("\(passed ? "PASS" : "FAIL") \(label)") }
            exit(results.allSatisfy(\.1) ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-rich-text") {
            do {
                let results = try RichTextSelfChecks.run()
                for (label, passed) in results { print("\(passed ? "PASS" : "FAIL") \(label)") }
                exit(results.allSatisfy(\.1) ? 0 : 1)
            } catch { print("FAIL rich-text checks: \(error.localizedDescription)"); exit(1) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--theme-art-sheet") {
            let arguments = CommandLine.arguments
            guard arguments.indices.contains(flag + 1) else { print("FAIL --theme-art-sheet needs an output directory"); exit(2) }
            do { try ThemeArtSheet.run(directory: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)); exit(0) }
            catch { print("FAIL theme art sheet: \(error.localizedDescription)"); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var sessions: [AccountSession] = []
    var accountRecords: [Account] = []
    var windows: [ConversationWindow] = []
    var login: LoginController?
    var settings: SettingsController?
    var themeEditor: ThemeEditorController?
    var isPreparingToQuit = false
    var terminationTask: Task<Void, Never>?
    var accountPreferenceWindows: [UUID: AccountPreferencesController] = [:]
    lazy var updates = AppUpdateController()
    let interfaceSounds = InterfaceSounds()
    var activityMonitor: Any?
    var menuBarItem: NSStatusItem?
    var shortcutsWindow: NSWindowController?
    /// One loader for every window, so they share its cache of previews.
    let linkPreviews: any LinkPreviewLoading = LinkPreviewLoader()
    /// The conversation most recently shown in any window, so New Window and
    /// reopening from the Dock continue where the person left off.
    var lastConversation: (accountID: UUID, channelID: String)?
    var dataRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nevermore", isDirectory: true) }
    func updateDockBadge() {
        let mode = DockBadgeMode(rawValue: UserDefaults.standard.string(forKey: "dockBadgeMode") ?? "") ?? .attention
        let active = sessions.filter { !$0.stopped }
        let total = active.reduce(0) { min(9999, $0 + AttentionPolicy.unreadCount(channels: $1.channels, unread: $1.unread)) }
        let attention = active.contains { !$0.unreadNotificationIDs.isEmpty || AttentionPolicy.unreadCount(channels: $0.channels, unread: $0.unread, directMessagesOnly: true) > 0 }
        NSApp.dockTile.badgeLabel = AttentionPolicy.badge(mode: mode, unreadCount: total, hasAttention: attention)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--performance-check") {
            Task { await PerformanceChecks.run(self) }; return
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.appearance = nil
        observeThemeAccessibility()
        configureUpdater(); makeMenus(); updateMenuBarItem(); NSApp.servicesProvider = self
        interfaceSounds.configure()
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            let conversation = event.window?.windowController as? ConversationWindow
            let collection = event.window?.windowController as? CollectionWindow
            let parent = event.window?.sheetParent?.windowController as? ConversationWindow
            MainActor.assumeIsolated { (conversation?.session ?? collection?.session ?? parent?.session)?.recordInteraction() }
            return event
        }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        PromisedFileReceiver.cleanUpAbandonedReceives()
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if CommandLine.arguments.contains("--demo") { Task { await startDemo() }; return }
            let file = dataRoot.appendingPathComponent("accounts.json")
            if FileManager.default.fileExists(atPath: file.path) {
                accountRecords = try JSONDecoder().decode([Account].self, from: Data(contentsOf: file))
                for account in accountRecords {
                    do {
                        let session = try AccountSession(account: account, directory: dataRoot.appendingPathComponent(account.id.uuidString))
                        sessions.append(session); Task { await session.start() }
                    } catch { showError(error) }
                }
            }
            restoreWindows()
            if sessions.isEmpty { addAccount(nil) }
        } catch { showError(error); newWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in for session in self?.sessions ?? [] where !session.demo && !session.stopped { session.realtime?.disconnect(); session.realtimeLive = false; session.state = StatusLocalization.text(.realtimeUnavailable); session.notify() } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in for session in self?.sessions ?? [] { session.realtime?.connect(); session.requestReconciliation() } }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        settings?.loginItem.refreshStatus()
        for session in sessions where !session.interests.isEmpty { session.requestReconciliation() }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Message…", action: #selector(newMessage(_:)), keyEquivalent: "").target = self
        let item = menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: ""); item.target = self
        let account = menu.addItem(withTitle: "Add Account…", action: #selector(addAccount(_:)), keyEquivalent: ""); account.target = self
        return menu
    }
    @objc func composeSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= 1_000_000 else { error.pointee = "The selected text is empty or too large."; return }
        if windows.isEmpty { newWindow(nil) }
        guard let controller = (NSApp.keyWindow?.windowController as? ConversationWindow) ?? windows.last else { return }
        controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        guard controller.channel != nil else { error.pointee = "Choose a conversation in Nevermore, then invoke the service again."; return }
        controller.window?.makeFirstResponder(controller.composer)
        guard controller.composer.isEditable else { error.pointee = "Wait for the current message to finish saving."; return }
        controller.composer.insertText(text, replacementRange: controller.composer.selectedRange())
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow(nil) }; return true }
    func applicationWillTerminate(_ notification: Notification) { interfaceSounds.stop(); updates.stop(); for window in windows { window.cancelPromisedFiles(); window.cancelEmojiPicker(); window.closePollWindows(); window.closeCodeReaders(); window.clearPreview() }; PromisedFileReceiver.cleanUpActiveReceives(); if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }; persistWindows(); for session in sessions { session.stop() } }
    func persistWindows() {
        guard !CommandLine.arguments.contains("--demo") else { return }
        if UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool == false {
            UserDefaults.standard.removeObject(forKey: "savedWindowStates"); UserDefaults.standard.removeObject(forKey: "restoredWindows"); return
        }
        let states = windowsInRestorationOrder().prefix(12).compactMap { controller, group -> SavedWindowState? in
            guard let session = controller.session, !session.stopped, let location = controller.currentLocation(), let frame = controller.window?.frame else { return nil }
            return SavedWindowState(windowID: controller.windowID, accountID: session.account.id, location: location, workspaceID: controller.workspacePicker.titleOfSelectedItem, frame: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), threadRootID: controller.threadInspector?.rootMessage.id, tabGroupID: group)
        }
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: "savedWindowStates"); UserDefaults.standard.removeObject(forKey: "restoredWindows") }
    }
    /// Conversation windows with their tab group: tabs appear consecutively
    /// in tab-bar order, each naming its first tab, so restoration can
    /// regroup them; standalone windows have no group.
    func windowsInRestorationOrder() -> [(ConversationWindow, UUID?)] {
        var ordered: [(ConversationWindow, UUID?)] = []
        for controller in windows where !ordered.contains(where: { $0.0 === controller }) {
            let tabs = (controller.window?.tabbedWindows ?? []).compactMap { $0.windowController as? ConversationWindow }.filter { tab in windows.contains { $0 === tab } }
            guard tabs.count > 1, let leader = tabs.first else { ordered.append((controller, nil)); continue }
            for tab in tabs where !ordered.contains(where: { $0.0 === tab }) { ordered.append((tab, leader.windowID)) }
        }
        return ordered
    }
    func purgeRestoration(accountID: UUID) {
        if let data = UserDefaults.standard.data(forKey: "savedWindowStates") {
            let states = (try? JSONDecoder().decode([SavedWindowState].self, from: data)) ?? []
            for state in states where state.accountID == accountID { UserDefaults.standard.removeObject(forKey: "NSWindow Frame NevermoreWindow-\(state.windowID.uuidString)") }
            if let encoded = try? JSONEncoder().encode(states.filter { $0.accountID != accountID }) { UserDefaults.standard.set(encoded, forKey: "savedWindowStates") }
        }
        if let routes = UserDefaults.standard.array(forKey: "restoredWindows") as? [[String: String]] { UserDefaults.standard.set(routes.filter { $0["account"] != accountID.uuidString }, forKey: "restoredWindows") }
    }
    func restoreWindows() {
        guard UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool != false else { newWindow(nil); return }
        if let data = UserDefaults.standard.data(forKey: "savedWindowStates"), let states = try? JSONDecoder().decode([SavedWindowState].self, from: data) {
            for state in states.prefix(12) where state.version == 1 {
                guard let session = sessions.first(where: { $0.account.id == state.accountID && !$0.stopped }) else { continue }
                let controller = ConversationWindow(app: self, session: session, windowID: state.windowID)
                windows.append(controller); controller.pendingRestoration = state
                if let group = state.tabGroupID, group != state.windowID, let host = windows.first(where: { $0.windowID == group && $0 !== controller })?.window, let tab = controller.window {
                    host.addTabbedWindow(tab, ordered: .above)
                } else if let saved = state.frame, saved.isValid, let window = controller.window {
                    let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
                    let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
                    window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
                }
                controller.showWindow(nil); controller.navigation.visit(state.location); controller.restoreLocation(state.location)
            }
        } else {
            // Migrate route-only state written by the first development build.
            for route in (UserDefaults.standard.array(forKey: "restoredWindows") as? [[String: String]] ?? []).prefix(12) {
                guard let session = sessions.first(where: { $0.account.id.uuidString == route["account"] }), let id = route["channel"] else { continue }
                open(session: session, channel: RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)])), anchor: route["anchor"].flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        if windows.isEmpty { newWindow(nil) }
    }
    func persistAccounts() throws {
        try JSONEncoder().encode(accountRecords).write(to: dataRoot.appendingPathComponent("accounts.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func add(_ incoming: Account, tokens: OAuthTokens) async throws {
        if let existing = sessions.first(where: { $0.account.origin == incoming.origin && $0.account.user == incoming.user }) {
            guard !existing.stopped else { throw AppError.message("Account removal is still in progress. Wait for it to finish before signing in again.") }
            try await existing.reauthenticate(clientID: incoming.clientID, tokens: tokens)
            accountRecords = accountRecords.map { $0.id == existing.account.id ? existing.account : $0 }
            try persistAccounts(); settings?.reloadAccounts(); for window in windows { window.updateAccounts() }; return
        }
        // A temporarily unavailable Keychain/store at launch must not assign a
        // new identity and strand this user's existing durable work on re-login.
        let previous = accountRecords.first { $0.origin == incoming.origin && $0.user == incoming.user }
        let account = Account(id: previous?.id ?? incoming.id, origin: incoming.origin, user: incoming.user, siteName: incoming.siteName, clientID: incoming.clientID, displayName: incoming.displayName, timezone: incoming.timezone)
        try KeychainTokenStore.save(tokens, accountID: account.id)
        let session: AccountSession
        do { session = try AccountSession(account: account, directory: dataRoot.appendingPathComponent(account.id.uuidString)) }
        catch { if previous == nil { try? KeychainTokenStore.delete(accountID: account.id) }; throw error }
        let oldRecords = accountRecords
        sessions.append(session); accountRecords.removeAll { $0.id == account.id }; accountRecords.append(account)
        do { try persistAccounts() }
        catch { sessions.removeAll { $0 === session }; accountRecords = oldRecords; if previous == nil { try? KeychainTokenStore.delete(accountID: account.id) }; throw error }
        settings?.reloadAccounts(); for window in windows { window.updateAccounts() }
        windows.last?.use(session)
        Task { await session.start() }
    }
    @objc func newWindow(_ sender: Any?) {
        let session = activeConversationWindow?.session ?? lastConversation.flatMap { last in sessions.first { $0.account.id == last.accountID && !$0.stopped } } ?? sessions.first(where: { !$0.stopped })
        let window = ConversationWindow(app: self, session: session)
        windows.append(window); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        if let session, let last = lastConversation, last.accountID == session.account.id, let channel = session.channels.first(where: { $0.id == last.channelID }) { window.select(channel) }
    }
    func open(session: AccountSession, channel: RavenChannel, anchor: String? = nil) {
        guard !session.stopped else { return }
        let window = ConversationWindow(app: self, session: session)
        windows.append(window); window.showWindow(nil); window.select(channel, anchor: anchor)
    }
    /// Opens a conversation as a tab of an existing window (File ▸ New Tab,
    /// the tab bar's + button, and "Open in New Tab").
    @discardableResult func openTab(beside host: ConversationWindow, session: AccountSession?, channel: RavenChannel?) -> ConversationWindow? {
        guard session?.stopped != true else { return nil }
        let controller = ConversationWindow(app: self, session: session ?? host.session)
        windows.append(controller)
        if let hostWindow = host.window, let tab = controller.window, hostWindow.isVisible {
            hostWindow.addTabbedWindow(tab, ordered: .above)
            tab.makeKeyAndOrderFront(nil)
        } else { controller.showWindow(nil) }
        if let channel { controller.select(channel) }
        return controller
    }
    @objc func addAccount(_ sender: Any?) { login = LoginController(app: self); login?.showWindow(nil) }
    func showAccountPreferences(_ session: AccountSession) { guard !session.stopped else { return }; let controller = accountPreferenceWindows[session.account.id] ?? AccountPreferencesController(session: session); accountPreferenceWindows[session.account.id] = controller; controller.showWindow(nil) }
    func showSettingsPane(_ pane: SettingsPane) { showSettings(nil); settings?.gifSettings.reload(); settings?.select(pane) }
    @objc func showSettings(_ sender: Any?) { if settings == nil { settings = SettingsController(app: self) }; settings?.reloadAccounts(); settings?.reloadGeneralControls(); settings?.reloadReadingControls(); settings?.loginItem.refreshStatus(); settings?.showWindow(nil) }
    @objc func about(_ sender: Any?) { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Nevermore", .credits: NSAttributedString(string: "A native Mac client for Raven.\nIndependent client · running-app notifications only.")]) }
    /// App-modal by design: errors often arrive after the originating window
    /// closed or changed account. The first sentence becomes the alert title,
    /// the rest its explanation, per the HIG's alert guidance.
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning
        let text = StatusLocalization.errorDescription(error).trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = text.range(of: #"\. (?=\p{Lu})"#, options: .regularExpression), text.distance(from: text.startIndex, to: end.lowerBound) < 140 {
            alert.messageText = String(text[..<end.lowerBound]) + "."
            alert.informativeText = String(text[end.upperBound...])
        } else { alert.messageText = text.isEmpty ? "The action could not be completed." : text }
        alert.runModal()
    }
    func remove(_ session: AccountSession) async {
        let ops = (try? await session.store.operations()) ?? []
        let alert = NSAlert(); alert.messageText = "Remove \(session.account.user)?"
        alert.informativeText = "This removes this account’s credentials, cached history, drafts and \(ops.count) queued sends from this Mac. Export needed text or files first. Backups and exported files are outside this removal."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove Account")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        session.stop(); purgeRestoration(accountID: session.account.id)
        SavedSearchStore.clear(session.account.id)
        accountPreferenceWindows.removeValue(forKey: session.account.id)?.close()
        NotificationPreferenceStore.setQuietHours(nil, accountID: session.account.id)
        let replacement = sessions.first { $0 !== session && !$0.stopped }
        for window in windows where window.session === session { window.use(replacement) }
        await session.client.revoke()
        var failures: [String] = []
        var privateDownloadsCleared = false
        do {
            try DownloadedAttachment.purgeDownloads(accountID: session.account.id, in: FileManager.default.temporaryDirectory)
            privateDownloadsCleared = true
        } catch { failures.append("Private attachment files: \(error.localizedDescription)") }

        var credentialsDeleted = false
        do {
            try KeychainTokenStore.delete(accountID: session.account.id)
            credentialsDeleted = true
        } catch { failures.append("Keychain credentials: \(error.localizedDescription)") }

        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix(session.account.id.uuidString) }.map(\.identifier))
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.request.identifier.hasPrefix(session.account.id.uuidString) }.map { $0.request.identifier })
        var accountDataCleared = false
        do {
            try FileManager.default.removeItem(at: dataRoot.appendingPathComponent(session.account.id.uuidString))
            accountDataCleared = true
        } catch {
            let fileError = error as NSError
            if fileError.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(fileError.code) {
                accountDataCleared = true
            } else {
                failures.append("Cached history and drafts: \(error.localizedDescription)")
            }
        }

        // Keep the account identity until every private cleanup succeeds, so
        // permission failures cannot strand files without their account UUID.
        var accountForgotten = false
        if credentialsDeleted && privateDownloadsCleared && accountDataCleared {
            let previousRecords = accountRecords
            accountRecords.removeAll { $0.id == session.account.id }
            do {
                try persistAccounts()
                sessions.removeAll { $0 === session }
                accountForgotten = true
            } catch {
                accountRecords = previousRecords
                failures.append("Account registry: \(error.localizedDescription)")
            }
        }
        if !accountForgotten {
            failures.append("The account remains registered. Resolve the reported errors, including folder permissions if needed, then relaunch Nevermore and retry removal.")
        }
        settings?.reloadAccounts()
        for window in windows { window.updateAccounts() }
        if !failures.isEmpty { showError(AppError.message(failures.joined(separator: "\n\n"))) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.identifier == AppUpdateController.notificationID {
            await MainActor.run { updates.checkNow() }
            return
        }
        let info = response.notification.request.content.userInfo
        let accountID = info["account"] as? String, channelID = info["channel"] as? String, anchor = info["message"] as? String
        await MainActor.run {
            guard let session = sessions.first(where: { $0.account.id.uuidString == accountID }), let channel = session.channels.first(where: { $0.id == channelID }) else { return }
            open(session: session, channel: channel, anchor: anchor)
        }
    }
    func configureUpdater() {
        // Demos and automated fixtures remain local unless the user explicitly
        // invokes Check for Updates. Performance runs never reach this setup.
        guard !CommandLine.arguments.contains("--demo"), !CommandLine.arguments.contains("--self-check") else { return }
        updates.start()
    }
    @objc func checkForUpdates() { updates.checkNow() }
    @objc func helpPage() { NSWorkspace.shared.open(URL(string: "https://github.com/frappe/raven")!) }
    func startDemo() async {
        do {
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let account = Account(id: id, origin: URL(string: "https://demo.invalid")!, user: "you@example.com", siteName: "demo", clientID: "demo", displayName: "Nevermore Demo")
            let selfCheck = CommandLine.arguments.contains("--self-check")
            // The interactive demo seeds its own conversation and keeps what is
            // sent in it, so it has its own store, apart from the plain one
            // performance runs and earlier builds use.
            let demoDirectory = selfCheck ? FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSelfCheck-\(UUID())") : dataRoot.appendingPathComponent(DemoMenu.isAvailable ? "DemoWire" : "Demo")
            let session = try AccountSession(account: account, directory: demoDirectory, demo: true)
            if DemoMenu.isAvailable { session.demoWire = DemoWire(session: session) }
            let channel = RavenChannel(raw: .object(["name": .string("engineering"), "channel_name": .string("engineering"), "workspace": .string("Acme")]))
            try await session.store.cacheChannels([channel])
            let bodies = ["<p>Welcome to <strong>Nevermore</strong>. This is an explicitly local demo, with no server connection.</p>", "<p>Select text across these messages, use the keyboard, or open this conversation in a second window.</p><pre><code>let client = RavenClient(…)</code></pre>", "<p>Real accounts use your site’s dedicated OAuth client. Drafts and queued sends stay on this Mac.</p><blockquote>Quit stops running-app notifications.</blockquote>", "<p>Use File → Attach Files to stage a file. This demo never transmits messages.</p>"]
            for (i, body) in bodies.enumerated() {
                var fields: [String: JSONValue] = ["name": .string("demo-\(i)"), "channel_id": .string(channel.id), "owner": .string(i % 2 == 0 ? "alex@example.com" : "morgan@example.com"), "creation": .string("2026-11-07 10:4\(i):00.000000"), "text": .string(body), "message_type": .string("Text")]
                if i == 2 && !selfCheck { fields["is_thread"] = .bool(true) }
                if i == 0 && !selfCheck { fields["message_reactions"] = .string(#"{"👍": {"count": 2, "users": ["you@example.com", "morgan@example.com"], "reaction": "👍"}, "🎉": {"count": 1, "users": ["morgan@example.com"], "reaction": "🎉"}}"#) }
                try await session.store.cacheMessages([RavenMessage(raw: .object(fields))])
            }
            if !selfCheck {
                // A channel event, a day change and a run of messages from
                // one sender show the transcript's grouping.
                try await session.store.cacheMessages([
                    RavenMessage(raw: .object(["name": .string("demo-created"), "channel_id": .string(channel.id), "owner": .string("morgan@example.com"), "creation": .string("2026-11-06 16:02:00.000000"), "text": .string("Morgan Lee created engineering."), "message_type": .string("System")])),
                    RavenMessage(raw: .object(["name": .string("demo-4"), "channel_id": .string(channel.id), "owner": .string("morgan@example.com"), "creation": .string("2026-11-07 10:43:40.000000"), "text": .string("<p>Messages sent close together share one name and avatar.</p>"), "message_type": .string("Text")])),
                    RavenMessage(raw: .object(["name": .string("demo-5"), "channel_id": .string(channel.id), "owner": .string("alex@example.com"), "creation": .string("2026-11-07 10:52:00.000000"), "text": .string("<p>Replies quote the message they answer.</p>"), "message_type": .string("Text"), "is_reply": .bool(true), "linked_message": .string("demo-3")]))
                ])
            }
            // The interactive demo shows a local thread; the self-check
            // fixture keeps its own thread data.
            if !selfCheck {
                let replies = ["<p>Threads open in the inspector beside the conversation, or in their own window.</p>", "<p>Replies stay in the thread, so the channel stays readable.</p>"]
                for (i, body) in replies.enumerated() {
                    try await session.store.cacheMessages([RavenMessage(raw: .object(["name": .string("demo-thread-\(i)"), "channel_id": .string("demo-2"), "owner": .string(i == 0 ? "morgan@example.com" : "alex@example.com"), "creation": .string("2026-11-07 10:5\(i):00.000000"), "text": .string(body), "message_type": .string("Text")]))])
                }
            }
            if !selfCheck {
                // A private channel and a direct message with unread counts
                // show the sidebar's states; the self-check fixture stays minimal.
                let design = RavenChannel(raw: .object(["name": .string("design"), "channel_name": .string("design"), "workspace": .string("Acme"), "type": .string("Private")]))
                let direct = RavenChannel(raw: .object(["name": .string("dm-morgan"), "channel_name": .string("Morgan"), "is_direct_message": .bool(true), "peer_user_id": .string("morgan@example.com")]))
                try await session.store.cacheChannels([design, direct])
                // A week of your own messages gives Home's numbers something
                // to count. Times follow the clock, so the week stays full.
                let own: [(Double, String, String)] = [
                    (146, "dm-morgan", "Morning! Did the staging deploy finish?"), (122, "engineering", "Merged the audit log filter."),
                    (120, "dm-morgan", "Thanks, I will look after lunch."), (98, "dm-morgan", "Pushed the fix for the export timeout."),
                    (75, "engineering", "CI is green on my branch again."), (72, "dm-morgan", "Can you read the release notes draft?"),
                    (50, "dm-morgan", "Sounds good."), (47, "engineering", "Who has the staging credentials?"),
                    (26, "dm-morgan", "Shipping it tomorrow then."), (22, "engineering", "Tagged 2.4.0."), (3, "dm-morgan", "Lunch at the usual place?")
                ]
                try await session.store.cacheMessages(own.enumerated().map { index, line in
                    RavenMessage(raw: .object(["name": .string("demo-own-\(index)"), "channel_id": .string(line.1), "owner": .string(account.user), "creation": .string(session.serverTimestamp(Date().addingTimeInterval(-line.0 * 3600))), "text": .string("<p>\(line.2)</p>"), "message_type": .string("Text")]))
                })
                try await session.store.cacheMessages([RavenMessage(raw: .object(["name": .string("demo-design-0"), "channel_id": .string("design"), "owner": .string("morgan@example.com"), "creation": .string("2026-11-07 11:02:00.000000"), "text": .string("<p>The new sidebar marks unread conversations in bold with a count.</p>"), "message_type": .string("Text")])), RavenMessage(raw: .object(["name": .string("demo-dm-0"), "channel_id": .string("dm-morgan"), "owner": .string("morgan@example.com"), "creation": .string("2026-11-07 11:05:00.000000"), "text": .string("<p>Direct messages appear under their own heading.</p>"), "message_type": .string("Text")]))])
            }
            try await session.demoWire?.seed()
            sessions.append(session); await session.start()
            if !selfCheck {
                session.userNames = DemoWire.people.merging([account.user: "Sam Taylor"]) { _, own in own }
                session.unread = .array([.object(["name": .string("design"), "unread_count": .number(3)]), .object(["name": .string("dm-morgan"), "unread_count": .number(1)])])
                // The interactive demo counts what is unread since a visit,
                // so reading a conversation clears it.
                await session.demoWire?.settleUnread()
                session.notify()
            }
            // The interactive demo opens on the conversation that invites a reply.
            let opening = session.demoWire == nil ? nil : session.channels.first { $0.id == DemoWire.conversationID }
            newWindow(nil); windows.last?.select(opening ?? channel)
            session.demoWire?.updateState(); session.demoWire?.deliver()
            if selfCheck {
                let result = await SelfCheck.run(self)
                session.stop(); try? FileManager.default.removeItem(at: demoDirectory)
                exit(Int32(result))
            }
        } catch { showError(error) }
    }
}
