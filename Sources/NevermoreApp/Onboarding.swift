import AppKit
import AuthenticationServices
import RavenProtocol
import NevermoreCore
import UserNotifications

/// A borderless button drawn as a link, with the pointing-hand cursor.
@MainActor private final class LinkButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class LoginController: NSWindowController, ASWebAuthenticationPresentationContextProviding, NSWindowDelegate, NSTextFieldDelegate {
    /// The OAuth Client ID a new account starts with. Frappe generates the ID
    /// per registration, so it fits only the site it was created on: the
    /// field stays editable, and the link below it opens the list where
    /// another site's ID is found.
    static let presetClientID = "r80b0u70c0"
    private static let clientIDHintWithoutSite = "Enter your site address to get a link to its OAuth Client list."
    private static let clientIDHintWithSite = "Look up this site’s client ID:"
    private static let clientIDRowFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    unowned let app: AppDelegate
    let siteLabel = NSTextField(labelWithString: "Raven Site URL")
    let site = NSTextField(string: "https://")
    let clientIDLabel = NSTextField(labelWithString: "OAuth Client ID")
    let clientID = NSTextField(string: LoginController.presetClientID)
    let clientIDNote = NSTextField(wrappingLabelWithString: "The prefilled client ID belongs to one site. A different site needs its own client ID.")
    let clientIDHint = NSTextField(labelWithString: LoginController.clientIDHintWithoutSite)
    let clientIDLink: NSButton = LinkButton(title: "", target: nil, action: nil)
    /// The page `clientIDLink` opens: the OAuth Client list of the site in
    /// the site field, or nil while that field holds no acceptable origin.
    private(set) var clientListURL: URL?
    /// Hands the OAuth Client list to the default browser. Self-checks
    /// replace it so that no browser opens.
    var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    let status = NSTextField(wrappingLabelWithString: "Use a dedicated Nevermore OAuth Client created by your site administrator. Nevermore never asks for your password.")
    let button = NSButton(title: "Continue in Browser", target: nil, action: nil)
    var webSession: ASWebAuthenticationSession?
    private var authorizationID: UUID?
    let expectedAccount: Account?
    let redirect = URL(string: "ch.goodvantage.Nevermore://oauth")!
    init(app: AppDelegate, account: Account? = nil) {
        self.app = app; expectedAccount = account
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 450), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Add Raven Account"; window.center(); window.delegate = self
        let title = NSTextField(labelWithString: "Welcome to Nevermore"); title.font = .systemFont(ofSize: 23, weight: .semibold)
        siteLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        clientIDLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        // The fields already carry these names for VoiceOver; the visible
        // labels are for sighted readers, so they add no second AX element.
        siteLabel.setAccessibilityElement(false)
        clientIDLabel.setAccessibilityElement(false)
        site.placeholderString = "https://chat.example.com"; site.setAccessibilityLabel("Raven site URL")
        clientID.placeholderString = "Dedicated OAuth Client ID"; clientID.setAccessibilityLabel("OAuth Client ID")
        clientIDNote.font = Self.clientIDRowFont; clientIDNote.textColor = .secondaryLabelColor
        clientIDNote.maximumNumberOfLines = 0
        let note = NSTextField(wrappingLabelWithString: "Register this exact redirect URI for a public client, with authorization-code flow and S256 PKCE:\nch.goodvantage.Nevermore://oauth\nConsent requests the server’s all openid scopes."); note.textColor = .secondaryLabelColor; note.isSelectable = true
        clientIDHint.font = Self.clientIDRowFont; clientIDHint.textColor = .secondaryLabelColor
        clientIDHint.setContentCompressionResistancePriority(.required, for: .horizontal)
        clientIDLink.isBordered = false; clientIDLink.isHidden = true; clientIDLink.setAccessibilityRole(.link)
        clientIDLink.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clientIDRow = NSStackView(views: [clientIDHint, clientIDLink]); clientIDRow.orientation = .horizontal; clientIDRow.spacing = 4
        let stack = NSStackView(views: [title, siteLabel, site, clientIDLabel, clientID, clientIDNote, clientIDRow, note, status, button]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: siteLabel)
        stack.setCustomSpacing(16, after: site)
        stack.setCustomSpacing(6, after: clientIDLabel)
        stack.setCustomSpacing(4, after: clientID)
        stack.setCustomSpacing(12, after: clientIDNote)
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), site.widthAnchor.constraint(equalTo: stack.widthAnchor), clientID.widthAnchor.constraint(equalTo: stack.widthAnchor), clientIDNote.widthAnchor.constraint(equalTo: stack.widthAnchor), clientIDRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        if let account { site.stringValue = account.origin.absoluteString; clientID.stringValue = account.clientID; window.title = "Sign In Again · \(account.user)" }
        button.target = self; button.action = #selector(begin)
        site.delegate = self
        clientIDLink.target = self; clientIDLink.action = #selector(openClientList)
        updateClientIDLink()
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === site else { return }
        updateClientIDLink()
    }

    /// Points the link at the OAuth Client list of the site in the site
    /// field. The link exists only for an origin Continue would accept; until
    /// then the row says how to get it.
    private func updateClientIDLink() {
        let origin = try? SiteOrigin.normalize(site.stringValue)
        clientListURL = origin.flatMap(RavenEndpoints.oauthClientListURL(origin:))
        guard let url = clientListURL, let host = origin?.host else {
            clientIDHint.stringValue = Self.clientIDHintWithoutSite
            clientIDLink.isHidden = true
            return
        }

        // A long address is cut in its middle so the path's end stays
        // readable; the tooltip carries it whole.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle
        // The scheme is always https here, so the title leaves it out.
        let title = url.absoluteString.replacingOccurrences(of: "https://", with: "", options: .anchored)
        clientIDLink.attributedTitle = NSAttributedString(string: title, attributes: [.font: Self.clientIDRowFont, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: truncating])
        clientIDLink.toolTip = url.absoluteString
        clientIDLink.setAccessibilityLabel("Open the OAuth Client list on \(host) in your browser")
        clientIDHint.stringValue = Self.clientIDHintWithSite
        clientIDLink.isHidden = false
    }

    @objc private func openClientList() {
        guard let clientListURL else { return }
        openInBrowser(clientListURL)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window! }
    func windowWillClose(_ notification: Notification) { cancelAuthorization() }
    func cancelAuthorization() {
        authorizationID = nil
        let session = webSession; webSession = nil; session?.cancel()
    }
    @objc func begin() {
        cancelAuthorization()
        let attempt = UUID(); authorizationID = attempt
        button.isEnabled = false; status.stringValue = "Checking Raven site…"
        Task { [self] in
            do {
                let origin = try SiteOrigin.normalize(site.stringValue)
                let id = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { throw AppError.message("Enter the dedicated Nevermore OAuth Client ID supplied by your administrator.") }
                let discovery = RavenClient(origin: origin, tokens: nil, clientID: id, accountID: UUID())
                let metadata = try await discovery.rpc("raven.api.raven_mobile.get_client_id")
                guard authorizationID == attempt else { return }
                guard metadata["raven_version"].string != nil else { throw AppError.message("This site did not return Raven metadata.") }
                let transaction = PKCETransaction()
                let url = try transaction.authorizationURL(origin: origin, clientID: id, redirectURI: redirect)
                status.stringValue = "Complete sign-in in your browser. Verify the requested site and scopes."
                let completion = BrowserAuthenticationCallback.makeHandler { [weak self] callback, error in
                    guard let self, self.authorizationID == attempt else { return }
                    do {
                        if let error { throw error }
                        guard let callback else { throw AppError.message("No authorization callback was returned.") }
                        let code = try transaction.validateCallback(callback, redirectURI: self.redirect)
                        let tokens = try await RavenClient.exchange(origin: origin, clientID: id, redirectURI: self.redirect, code: code, verifier: transaction.verifier)
                        guard self.authorizationID == attempt else { return }
                        let accountID = UUID()
                        let client = RavenClient(origin: origin, tokens: tokens, clientID: id, accountID: accountID)
                        let boot = try await client.rpc("raven.api.native.boot")
                        let user = try await client.rpc("raven.api.raven_users.get_current_raven_user")
                        guard self.authorizationID == attempt else { return }
                        guard let userID = user["user"].string ?? user["name"].string, userID != "Guest" else { throw AppError.message("The site did not identify an authenticated Raven user.") }
                        let account = Account(id: accountID, origin: origin, user: userID, siteName: boot["sitename"].string ?? metadata["sitename"].string ?? origin.host!, clientID: id, displayName: user["full_name"].string ?? userID, timezone: metadata["system_timezone"].string ?? "UTC")
                        if let expected = self.expectedAccount, expected.origin != origin || expected.user != userID { throw AppError.message("The browser signed in as a different user. Sign in as \(self.expectedAccount!.user) to reconnect this account without losing its drafts.") }
                        try await self.app.add(account, tokens: tokens)
                        self.close(); self.webSession = nil
                    } catch {
                        guard self.authorizationID == attempt else { return }
                        self.status.stringValue = error.localizedDescription; self.button.isEnabled = true; self.webSession = nil; self.authorizationID = nil
                    }
                }
                webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: redirect.scheme, completionHandler: completion)
                webSession?.presentationContextProvider = self
                webSession?.prefersEphemeralWebBrowserSession = true
                guard webSession?.start() == true else { throw AppError.message("The system browser could not start authentication.") }
            } catch { guard authorizationID == attempt else { return }; status.stringValue = error.localizedDescription; button.isEnabled = true; authorizationID = nil }
        }
    }
}

@MainActor final class SettingsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppDelegate
    let notifications = NSButton(checkboxWithTitle: "Show notifications while Nevermore is running", target: nil, action: nil)
    let sendKey = NSPopUpButton()
    let notificationPreview = NSPopUpButton()
    let markdownShortcuts = NSButton(checkboxWithTitle: "Format Markdown shortcuts as you type", target: nil, action: nil)
    let linkPreviews = NSButton(checkboxWithTitle: "Preview links while you write", target: nil, action: nil)
    let inkSounds = NSButton(checkboxWithTitle: "Play sounds for sending, delivery and reactions", target: nil, action: nil)
    let interfaceSounds = NSButton(checkboxWithTitle: "Play menu, window and navigation sounds", target: nil, action: nil)
    let interfaceSoundVolume = NSSlider(value: InterfaceSoundPreferences.defaultVolume, minValue: 0, maxValue: 1, target: nil, action: nil)
    let interfaceSoundVolumeLabel = NSTextField(labelWithString: "35%")
    let interfaceSoundPreview = NSButton(title: "Preview", target: nil, action: nil)
    let badgeMode = NSPopUpButton()
    let retention = NSButton(checkboxWithTitle: "Keep received history on this Mac", target: nil, action: nil)
    let loginItem = LoginItemPreferences(frame: .zero)
    let menuBar = NSButton(checkboxWithTitle: "Show Nevermore in the menu bar", target: nil, action: nil)
    let menuBarIcon = NSPopUpButton()
    let automaticUpdates = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    let updateCheck = NSButton(title: "Check for Updates…", target: nil, action: nil)
    let compact = NSButton(checkboxWithTitle: "Compact message spacing", target: nil, action: nil)
    let fontSize = NSSlider(value: 14, minValue: 11, maxValue: 30, target: nil, action: nil)
    let fontLabel = NSTextField(labelWithString: "14 pt")
    private(set) var themeSettings: ThemeSettingsView!
    let gifSettings = GIFSettings()
    private var tabs: NSTabViewController?
    private var gifPane: NSViewController?
    private let accountTable = NSTableView()
    private let accountSegments = NSSegmentedControl()
    private let accountPreferencesButton = NSButton(title: "Account Preferences…", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "Sign In Again…", target: nil, action: nil)
    private let clearHistoryButton = NSButton(title: "Clear Received History…", target: nil, action: nil)
    private var accountIDs: [UUID] = []
    private static let accountColumnID = NSUserInterfaceItemIdentifier("account")
    private static let serverColumnID = NSUserInterfaceItemIdentifier("server")
    private static let noteMaximumWidth: CGFloat = 360
    private static let accountTableWidth: CGFloat = 440
    private static let accountTableHeight: CGFloat = 160
    private static let textSizeSliderWidth: CGFloat = 200
    private static let accountColumnWidth: CGFloat = 220

    private var selectedSession: AccountSession? {
        let row = accountTable.selectedRow
        guard accountIDs.indices.contains(row) else { return nil }
        let id = accountIDs[row]
        return app.sessions.first { $0.account.id == id && !$0.stopped }
    }

    init(app: AppDelegate) {
        self.app = app
        notifications.state = UserDefaults.standard.bool(forKey: "notifications") ? .on : .off
        markdownShortcuts.state = ComposerPreferences.formatsMarkdownShortcuts ? .on : .off
        linkPreviews.state = ComposerPreferences.showsLinkPreviews ? .on : .off
        inkSounds.state = InkSounds.isEnabled ? .on : .off
        interfaceSoundVolume.isContinuous = false
        interfaceSoundVolume.widthAnchor.constraint(equalToConstant: Self.textSizeSliderWidth).isActive = true
        interfaceSoundVolume.setAccessibilityLabel("Interface sound volume")
        interfaceSoundPreview.setAccessibilityLabel("Preview interface sound")
        interfaceSoundVolumeLabel.textColor = .secondaryLabelColor
        for icon in MenuBarIcon.allCases {
            menuBarIcon.addItem(withTitle: MenuBarIconArt.title(for: icon))
            menuBarIcon.lastItem?.image = MenuBarIconArt.image(for: icon, size: MenuBarIconArt.menuItemSize)
        }
        menuBarIcon.setAccessibilityLabel("Menu bar icon")
        notificationPreview.addItems(withTitles: NotificationPreview.allCases.map(\.title))
        notificationPreview.selectItem(at: NotificationPreview.allCases.firstIndex(of: .current()) ?? 0)
        notificationPreview.setAccessibilityLabel("What notifications show")
        sendKey.addItems(withTitles: ComposerSendKey.allCases.map(Self.title(for:)))
        sendKey.setAccessibilityLabel("Key that sends a message")
        retention.state = UserDefaults.standard.object(forKey: "retainHistory") as? Bool == false ? .off : .on
        compact.state = UserDefaults.standard.bool(forKey: "compactMessages") ? .on : .off
        badgeMode.addItems(withTitles: ["Inbox activity and DMs (dot)", "All unread logical sends", "No Dock badge"])
        let currentBadge = DockBadgeMode(rawValue: UserDefaults.standard.string(forKey: "dockBadgeMode") ?? "") ?? .attention
        badgeMode.selectItem(at: DockBadgeMode.allCases.firstIndex(of: currentBadge) ?? 0)
        badgeMode.setAccessibilityLabel("Dock badge policy")
        fontSize.isContinuous = false
        fontSize.numberOfTickMarks = 20
        fontSize.allowsTickMarkValuesOnly = true
        fontSize.widthAnchor.constraint(equalToConstant: Self.textSizeSliderWidth).isActive = true
        fontSize.setAccessibilityLabel("Message text size")
        fontLabel.textColor = .secondaryLabelColor
        fontLabel.font = .systemFont(ofSize: 11)
        Self.reloadReadingControls(slider: fontSize, label: fontLabel)
        Self.configureAccountColumns(accountTable)
        accountTable.style = .inset
        accountTable.usesAlternatingRowBackgroundColors = false
        accountTable.setAccessibilityLabel("Accounts")
        Self.configureSegments(accountSegments)
        let interfaceSoundControls = NSStackView(views: [interfaceSoundVolume, interfaceSoundVolumeLabel, interfaceSoundPreview])
        interfaceSoundControls.orientation = .horizontal
        interfaceSoundControls.spacing = 8
        let general = SettingsPaneController(title: "General", symbol: "gearshape", grid: Self.makeGrid([
            [Self.label("Menu bar:"), menuBar],
            [Self.label("Menu bar icon:"), menuBarIcon],
            [Self.label("Login:"), loginItem],
            [Self.label("Sending:"), sendKey],
            [NSGridCell.emptyContentView, inkSounds],
            [Self.label("Interface:"), interfaceSounds],
            [NSGridCell.emptyContentView, interfaceSoundControls],
            [Self.label("Writing:"), markdownShortcuts],
            [Self.label(""), Self.note("Start a line with > for a quote, - or 1. for a list, or ``` for code. Wrap text in **bold**, *italic*, `code`, ~~strikethrough~~ or ||spoiler||. Undo brings back what you typed.")],
            [Self.label(""), linkPreviews],
            [Self.label(""), Self.note("For a preview, Nevermore loads the linked page itself, over HTTPS and without cookies. That site sees your network address, as it would in a browser.")],
            [Self.label("Dock badge:"), badgeMode],
            [Self.label("Updates:"), automaticUpdates],
            [Self.label(""), updateCheck],
            [Self.label(""), Self.note("Checks apps.goodvantage.cloud after launch and daily, without Raven account data. Downloads open in your browser; you install updates yourself.")],
        ]))
        let notificationsPane = SettingsPaneController(title: "Notifications", symbol: "bell.badge", grid: Self.makeGrid([
            [Self.label("Notifications:"), notifications],
            [Self.label("Show:"), notificationPreview],
            [Self.label(""), Self.note("Notification Center keeps what a notification shows until you clear it, and anyone who can see your screen can read it. Spoilers stay hidden. Notifications arrive only while Nevermore is open; Sleep and Quit pause them.")],
        ]))
        let reading = SettingsPaneController(title: "Reading", symbol: "textformat.size", grid: Self.makeGrid([
            [Self.label("Message text:"), Self.makeSizeStack(slider: fontSize)],
            [Self.label(""), fontLabel],
            [Self.label("Spacing:"), compact],
        ]))
        let themeSettings = ThemeSettingsView(actions: ThemeSettingsView.Actions(
            select: { [weak app] id in app?.selectTheme(id) },
            customize: { [weak app] in app?.showThemeEditor(nil) },
            setBackdropOpacity: { [weak app] opacity in app?.setThemeBackdropOpacity(opacity) },
            preferencesChanged: { [weak app] in app?.applyThemeEverywhere() }))
        let appearance = SettingsPaneController(title: "Appearance", symbol: "paintpalette", grid: Self.makeGrid([
            [Self.label("Theme:"), themeSettings],
        ]))
        let accounts = SettingsPaneController(title: "Accounts", symbol: "person.crop.circle", grid: Self.makeGrid([
            [Self.label(""), Self.makeAccountScrollView(table: accountTable)],
            [Self.label(""), Self.makeAccountControls(segments: accountSegments, preferences: accountPreferencesButton, reconnect: reconnectButton)],
        ]))
        let gifs = SettingsPaneController(title: "GIFs", symbol: "photo.stack", grid: Self.makeGrid(gifSettings.rows(label: Self.label, note: Self.note)))
        let privacy = SettingsPaneController(title: "Privacy", symbol: "hand.raised", grid: Self.makeGrid([
            [Self.label("History:"), retention],
            [Self.label(""), clearHistoryButton],
            [Self.label(""), Self.note("Quit and sleep stop socket-based notifications. Message databases are protected by the sandbox and your Mac’s permissions/FileVault, not application encryption. Drafts and queued files remain until sent or explicitly discarded. No telemetry or Spotlight indexing.")],
        ]))
        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar
        for pane in [general, notificationsPane, reading, gifs, appearance, accounts, privacy] {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            tabController.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "General"
        window.center()
        super.init(window: window)
        self.themeSettings = themeSettings
        self.tabs = tabController; self.gifPane = gifs
        gifSettings.onChange = { [weak app] in
            for window in app?.windows ?? [] { window.render(); window.threadInspector?.render() }
        }
        menuBar.target = self
        menuBar.action = #selector(changeMenuBar)
        menuBarIcon.target = self
        menuBarIcon.action = #selector(changeMenuBarIcon)
        sendKey.target = self
        sendKey.action = #selector(changeSendKey)
        notificationPreview.target = self
        notificationPreview.action = #selector(changeNotificationPreview)
        interfaceSounds.target = self; interfaceSounds.action = #selector(changeInterfaceSounds)
        interfaceSoundVolume.target = self; interfaceSoundVolume.action = #selector(changeInterfaceSounds)
        interfaceSoundPreview.target = self; interfaceSoundPreview.action = #selector(previewInterfaceSound)
        automaticUpdates.target = self; automaticUpdates.action = #selector(changeAutomaticUpdates)
        updateCheck.target = app; updateCheck.action = #selector(AppDelegate.checkForUpdates)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadUpdateControls), name: .appUpdateChanged, object: app.updates)
        reloadGeneralControls()
        for control in [notifications, markdownShortcuts, linkPreviews, inkSounds, retention] {
            control.target = self
            control.action = #selector(change)
        }
        compact.target = self
        compact.action = #selector(changeReading)
        badgeMode.target = self
        badgeMode.action = #selector(changeBadge)
        fontSize.target = self
        fontSize.action = #selector(changeReading)
        accountTable.dataSource = self
        accountTable.delegate = self
        accountTable.doubleAction = #selector(showAccountPreferences)
        accountTable.target = self
        accountSegments.target = self
        accountSegments.action = #selector(accountSegmentChanged(_:))
        accountPreferencesButton.target = self
        accountPreferencesButton.action = #selector(showAccountPreferences)
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect)
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(promptClearHistory)
        reloadAccounts()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings a pane to the front, as its toolbar item would.
    func select(_ pane: SettingsPane) {
        guard let tabs, let target = gifPane, let index = tabs.tabViewItems.firstIndex(where: { $0.viewController === target }) else { return }
        switch pane { case .gifs: tabs.selectedTabViewItemIndex = index }
        window?.title = target.title ?? ""
    }

    @objc func changeMenuBar() {
        UserDefaults.standard.set(menuBar.state == .on, forKey: "showMenuBarItem")
        menuBarIcon.isEnabled = menuBar.state == .on
        app.updateMenuBarItem()
    }

    @objc func changeMenuBarIcon() {
        guard MenuBarIcon.allCases.indices.contains(menuBarIcon.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(MenuBarIcon.allCases[menuBarIcon.indexOfSelectedItem].rawValue, forKey: MenuBarIcon.defaultsKey)
        app.updateMenuBarItem()
    }

    @objc func changeSendKey() {
        guard ComposerSendKey.allCases.indices.contains(sendKey.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(ComposerSendKey.allCases[sendKey.indexOfSelectedItem].returnInsertsNewline, forKey: ComposerSendKey.defaultsKey)
    }

    /// Shows the stored menu bar and send key choices. The icon popup is
    /// enabled only while the menu bar item is shown.
    func reloadGeneralControls() {
        reloadUpdateControls()
        let defaults = UserDefaults.standard
        menuBar.state = defaults.bool(forKey: "showMenuBarItem") ? .on : .off
        let icon = MenuBarIcon(storedValue: defaults.string(forKey: MenuBarIcon.defaultsKey))
        menuBarIcon.selectItem(at: MenuBarIcon.allCases.firstIndex(of: icon) ?? 0)
        menuBarIcon.isEnabled = menuBar.state == .on
        let key = ComposerSendKey(returnInsertsNewline: defaults.bool(forKey: ComposerSendKey.defaultsKey))
        sendKey.selectItem(at: ComposerSendKey.allCases.firstIndex(of: key) ?? 0)
        let sounds = app.interfaceSounds.preferences
        interfaceSounds.state = sounds.isEnabled ? .on : .off
        interfaceSoundVolume.doubleValue = sounds.volume
        interfaceSoundVolumeLabel.stringValue = "\(Int((sounds.volume * 100).rounded()))%"
        interfaceSoundPreview.isEnabled = sounds.volume > 0
    }

    @objc func changeInterfaceSounds() {
        let sounds = InterfaceSoundPreferences(enabled: interfaceSounds.state == .on, volume: interfaceSoundVolume.doubleValue)
        UserDefaults.standard.set(sounds.isEnabled, forKey: InterfaceSoundPreferences.enabledKey)
        UserDefaults.standard.set(sounds.volume, forKey: InterfaceSoundPreferences.volumeKey)
        app.interfaceSounds.configure()
        reloadGeneralControls()
    }

    @objc private func previewInterfaceSound() { app.interfaceSounds.preview() }

    @objc private func reloadUpdateControls() {
        automaticUpdates.state = app.updates.checksAutomatically ? .on : .off
        updateCheck.title = app.updates.menuTitle
    }

    @objc private func changeAutomaticUpdates() {
        app.updates.setChecksAutomatically(automaticUpdates.state == .on)
    }

    /// Each title names both keys, so the closed popup already says what
    /// Return does and how to get the other behavior.
    private static func title(for key: ComposerSendKey) -> String {
        switch key {
        case .returnKey: "Return sends, Shift-Return inserts a new line"
        case .commandReturn: "Command-Return sends, Return inserts a new line"
        }
    }

    @objc func changeNotificationPreview() {
        guard NotificationPreview.allCases.indices.contains(notificationPreview.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(NotificationPreview.allCases[notificationPreview.indexOfSelectedItem].rawValue, forKey: NotificationPreview.defaultsKey)
    }

    @objc func changeBadge() {
        guard DockBadgeMode.allCases.indices.contains(badgeMode.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(DockBadgeMode.allCases[badgeMode.indexOfSelectedItem].rawValue, forKey: "dockBadgeMode")
        app.updateDockBadge()
    }

    @objc func change() {
        UserDefaults.standard.set(notifications.state == .on, forKey: "notifications")
        UserDefaults.standard.set(markdownShortcuts.state == .on, forKey: ComposerPreferences.markdownShortcutsKey)
        UserDefaults.standard.set(linkPreviews.state == .on, forKey: ComposerPreferences.linkPreviewsKey)
        UserDefaults.standard.set(inkSounds.state == .on, forKey: InkSounds.preferenceKey)
        for window in app.windows { window.updateLinkPreview() }
        let wasRetaining = UserDefaults.standard.object(forKey: "retainHistory") as? Bool != false
        if notifications.state == .on {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
        }
        if retention.state == .on { UserDefaults.standard.set(true, forKey: "retainHistory") }
        else if wasRetaining { confirmStopRetaining() }
    }

    /// Turning retention off deletes the cache, so it asks first; Cancel
    /// restores the checkbox and keeps the history.
    private func confirmStopRetaining() {
        // Without a window to ask in, keep the history (as Cancel would).
        guard let window else { retention.state = .on; return }
        let alert = SheetPrompt.confirmationAlert("Stop keeping received history?", message: "Received messages are no longer stored on this Mac, and the existing cache and downloaded previews are removed now. Drafts and queued sends are kept.", confirm: "Stop Keeping History", destructive: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertSecondButtonReturn { self.stopRetaining() } else { self.retention.state = .on }
            }
        }
    }

    private func stopRetaining() {
        UserDefaults.standard.set(false, forKey: "retainHistory")
        clearHistory()
    }

    func reloadAccounts() {
        let selectedID = selectedSession?.account.id
        let sessions = app.sessions.filter { !$0.stopped }
        accountIDs = sessions.map { $0.account.id }
        accountTable.reloadData()
        if let selectedID, let index = accountIDs.firstIndex(of: selectedID) {
            accountTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if accountIDs.indices.contains(0) {
            accountTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateAccountSelectionControls()
    }

    func reloadReadingControls() {
        Self.reloadReadingControls(slider: fontSize, label: fontLabel)
    }

    func reloadThemeControls() {
        themeSettings.reload()
    }

    private static func reloadReadingControls(slider: NSSlider, label: NSTextField) {
        let stored = UserDefaults.standard.double(forKey: "fontSize")
        let size = stored.isFinite && stored > 0 ? min(30, max(11, stored)) : 14
        slider.doubleValue = size
        label.stringValue = "\(Int(size)) pt"
    }

    @objc func changeReading() {
        UserDefaults.standard.set(compact.state == .on, forKey: "compactMessages")
        UserDefaults.standard.set(fontSize.doubleValue.rounded(), forKey: "fontSize")
        reloadReadingControls()
        for window in app.windows {
            window.render()
            window.threadInspector?.render()
        }
    }

    @objc func clearHistory() {
        Task {
            for session in app.sessions {
                do {
                    try await session.store.clearHistory()
                    session.clearMessageDocuments()
                    session.memoryMessages.removeAll()
                    session.thumbnails.removeAll()
                    session.forgetAnimatedImages()
                    session.sentLinkPreviews.reset()
                    for window in app.windows where window.session === session {
                        window.clearPreview()
                    }
                    session.notify()
                    try DownloadedAttachment.purgeDownloads(accountID: session.account.id, in: FileManager.default.temporaryDirectory)
                } catch { app.showError(error) }
            }
        }
    }

    @objc private func promptClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear received history for all accounts?"
        alert.informativeText = "Cached messages and downloaded previews are removed from this Mac. Drafts and queued sends are kept."
        let clearButton = alert.addButton(withTitle: "Clear History")
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.clearHistory()
        }
    }

    @objc func showAccountPreferences() {
        guard let session = selectedSession else { return }
        app.showAccountPreferences(session)
    }

    @objc func reconnect() {
        guard let session = selectedSession else { return }
        app.login = LoginController(app: app, account: session.account)
        app.login?.showWindow(nil)
    }

    @objc func remove() {
        guard let session = selectedSession else { return }
        Task { await app.remove(session); reloadAccounts() }
    }

    @objc private func accountSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            app.addAccount(nil)
        case 1:
            remove()
        default:
            break
        }
    }

    private func updateAccountSelectionControls() {
        let hasSelection = accountTable.selectedRow >= 0
        accountSegments.setEnabled(hasSelection, forSegment: 1)
        accountPreferencesButton.isEnabled = hasSelection
        reconnectButton.isEnabled = hasSelection
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        accountIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard accountIDs.indices.contains(row) else { return nil }
        let id = accountIDs[row]
        guard let session = app.sessions.first(where: { $0.account.id == id && !$0.stopped }) else { return nil }
        let value: String
        if tableColumn?.identifier == Self.accountColumnID {
            value = session.account.displayName.isEmpty ? session.account.user : session.account.displayName
        } else {
            value = session.account.origin.host ?? ""
        }
        return Self.makeAccountCell(value)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateAccountSelectionControls()
    }

    private static func configureAccountColumns(_ table: NSTableView) {
        let accountColumn = NSTableColumn(identifier: accountColumnID)
        accountColumn.title = "Account"
        accountColumn.width = accountColumnWidth
        table.addTableColumn(accountColumn)
        let serverColumn = NSTableColumn(identifier: serverColumnID)
        serverColumn.title = "Server"
        serverColumn.width = accountColumnWidth
        table.addTableColumn(serverColumn)
    }

    private static func configureSegments(_ segments: NSSegmentedControl) {
        segments.segmentStyle = .smallSquare
        segments.trackingMode = .momentary
        segments.segmentCount = 2
        segments.setImage(makeTemplateImage(NSImage.addTemplateName, accessibility: "Add Account"), forSegment: 0)
        segments.setImage(makeTemplateImage(NSImage.removeTemplateName, accessibility: "Remove Account"), forSegment: 1)
        segments.setToolTip("Add Account…", forSegment: 0)
        segments.setToolTip("Remove Account…", forSegment: 1)
    }

    private static func makeTemplateImage(_ name: NSImage.Name, accessibility label: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        let copy = image.copy() as? NSImage
        copy?.accessibilityDescription = label
        return copy
    }

    private static func makeGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = noteMaximumWidth
        field.widthAnchor.constraint(lessThanOrEqualToConstant: noteMaximumWidth).isActive = true
        return field
    }

    private static func makeSizeStack(slider: NSSlider) -> NSStackView {
        let smaller = NSImageView()
        smaller.image = NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: nil)
        let larger = NSImageView()
        larger.image = NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: nil)
        let stack = NSStackView(views: [smaller, slider, larger])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private static func makeAccountScrollView(table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.widthAnchor.constraint(equalToConstant: accountTableWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: accountTableHeight).isActive = true
        return scroll
    }

    private static func makeAccountControls(segments: NSSegmentedControl, preferences: NSButton, reconnect: NSButton) -> NSView {
        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [segments, flexibleSpace, preferences, reconnect])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private static func makeAccountCell(_ value: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: value)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

@MainActor private final class SettingsPaneController: NSViewController {
    let symbol: String
    private let grid: NSGridView
    private static let margin: CGFloat = 20
    private static let minimumWidth: CGFloat = 480

    init(title: String, symbol: String, grid: NSGridView) {
        self.symbol = symbol
        self.grid = grid
        super.init(nibName: nil, bundle: nil)
        self.title = title
        let fitting = grid.fittingSize
        preferredContentSize = NSSize(width: max(Self.minimumWidth, fitting.width + Self.margin * 2), height: fitting.height + Self.margin * 2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        view.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.margin),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.margin),
        ])
        self.view = view
    }
}
