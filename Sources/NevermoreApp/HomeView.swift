import AppKit
import OSLog
import UniformTypeIdentifiers
import NevermoreCore
import RavenProtocol

extension Notification.Name {
    /// Posted when the reader shows, hides or reorders Home modules.
    static let homeLayoutChanged = Notification.Name("NevermoreHomeLayoutChanged")
}

/// The stored Home layout, shared by every window and account.
@MainActor enum HomePreferences {
    static var layout: HomeLayout {
        get { HomeLayout.decode(UserDefaults.standard.data(forKey: HomeLayout.defaultsKey)) }
        set {
            UserDefaults.standard.set(newValue.encoded(), forKey: HomeLayout.defaultsKey)
            NotificationCenter.default.post(name: .homeLayoutChanged, object: nil)
        }
    }
}

/// Home: what an account has for the reader while no conversation is open.
/// Favorites as tiles, then modules the reader can show, hide and reorder
/// (see `docs/design/home/HOME-SCREEN.md`, design B).
///
/// Showing Home never marks anything read. Unread previews come from the
/// channel list the session already holds; the other modules come from
/// `HomeFeed`. Personal numbers describe only the reader.
@MainActor final class HomeView: NSView, NSMenuDelegate {
    private weak var owner: ConversationWindow?
    private let scroll = NSScrollView()
    private let document = HomeColumnDocumentView()
    private let content = NSStackView()
    private let customizeButton = NSButton()
    private var customizePopover: NSPopover?
    private var reloadScheduled = false
    private var needsReload = true
    private var columns = 0
    private var expandedUnread = false
    private var observers: [NSObjectProtocol] = []

    static let wideLayoutWidth: CGFloat = 820
    static let maximumContentWidth: CGFloat = 1120
    static let unreadRows = 5

    init(owner: ConversationWindow) {
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Home")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        customizeButton.bezelStyle = .glass
        customizeButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Customize Home")
        customizeButton.title = "Customize Home…"
        customizeButton.imagePosition = .imageLeading
        customizeButton.controlSize = .small
        customizeButton.toolTip = "Show, hide and reorder what Home shows"
        customizeButton.target = self
        customizeButton.action = #selector(customize(_:))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip = scroll.contentView
        // The column fills the pane up to a maximum width. As a constraint
        // on the pane's width, that wish took part in sizing the pane, even
        // with Home hidden: it held the sidebar at its maximum width, made
        // showing the sidebar jump instead of slide, and once capped the
        // window in full screen. The document sets a plain width instead.
        let columnWidth = content.widthAnchor.constraint(equalToConstant: Self.maximumContentWidth)
        // Above the modules' own size wishes, which would shrink the column,
        // and above their default compression resistance: in a narrow pane
        // they truncate instead of pushing the column past its margins.
        columnWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue + 1)
        document.column = columnWidth
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnWidth
        ])
        let menu = NSMenu(title: "Home")
        menu.delegate = self
        self.menu = menu
        let center = NotificationCenter.default
        for name in [Notification.Name.sessionChanged, .homeFeedChanged, .sessionAvatarsChanged, .sessionPresenceChanged, .draftChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? AccountSession
                MainActor.assumeIsolated { guard let self, source === self.owner?.session else { return }; self.setNeedsReload() }
            })
        }
        observers.append(center.addObserver(forName: .homeLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }

    override var isHidden: Bool {
        didSet {
            guard oldValue, !isHidden else { return }
            expandedUnread = false
            reloadNow()
            owner?.session?.home.refresh()
        }
    }

    /// Rebuilds once the current burst of session changes is over. Hidden,
    /// Home only remembers that it is out of date.
    func setNeedsReload() {
        needsReload = true
        guard !isHidden, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            if self.needsReload && !self.isHidden { self.reloadNow() }
        }
    }

    /// Asks the feed for fresh server modules when they have gone stale,
    /// for example when the window becomes key again.
    func refreshIfShown() {
        guard !isHidden else { return }
        owner?.session?.home.refresh()
    }

    override func layout() {
        super.layout()
        // Rebuild after this layout pass, not inside it.
        let wanted = bounds.width >= Self.wideLayoutWidth ? 2 : 1
        if wanted != columns, !isHidden { columns = wanted; setNeedsReload() }
    }

    // MARK: Building

    func reloadNow() {
        needsReload = false
        guard let owner, let session = owner.session else { content.setViews([], in: .top); return }
        columns = bounds.width >= Self.wideLayoutWidth || bounds.width == 0 ? 2 : 1
        let builder = HomeBuilder(owner: owner, session: session, home: self)
        var rows: [NSView] = []
        var pending: [NSView] = []
        func flush() {
            guard !pending.isEmpty else { return }
            if columns == 2, pending.count == 1 { pending.append(NSView()) }
            let row = NSStackView(views: pending)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 16
            for card in pending where card is HomeCard { card.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true }
            rows.append(row)
            pending.removeAll()
        }
        for module in HomePreferences.layout.visible {
            guard let card = builder.card(for: module) else { continue }
            if module == .favorites { flush(); rows.append(card); continue }
            pending.append(card)
            if pending.count == columns { flush() }
        }
        flush()
        if rows.isEmpty { rows.append(builder.nothingShown()) }
        // Customize sits after the last module, where it covers nothing.
        let footer = NSStackView(views: [NSView(), customizeButton])
        footer.orientation = .horizontal
        rows.append(footer)
        content.setViews(rows, in: .top)
        for row in rows { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        applyTheme()
    }

    func applyTheme() {
        let theme = ThemeManager.shared.current
        let tint = theme.palette.map { NSColor(theme: $0.composerTint, alpha: 0.22) }
        for card in content.descendants(of: HomeCard.self) { card.glass.tintColor = tint }
        markThemeSubtreeNeedsDisplay()
    }

    func toggleUnreadExpansion() { expandedUnread.toggle(); reloadNow() }
    var showsAllUnread: Bool { expandedUnread }

    /// What Later says with no rows to show. A part that failed already has
    /// its own note, so a failure never reads as nothing saved.
    static func emptyLaterNote(_ feed: HomeFeed.Snapshot) -> String? {
        if feed.reminders.isLoading || feed.saved.isLoading || feed.draftRead.isLoading || feed.outboxRead.isLoading {
            return "Loading…"
        }
        guard feed.reminders.value != nil, feed.saved.value != nil,
              feed.draftRead.value != nil, feed.outboxRead.value != nil else { return nil }
        return "Nothing saved for later. Save a message or set a reminder from its menu."
    }

    // MARK: Customize

    @objc func customize(_ sender: Any?) {
        if let customizePopover, customizePopover.isShown { customizePopover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = HomeCustomizeController()
        customizePopover = popover
        popover.show(relativeTo: customizeButton.bounds, of: customizeButton, preferredEdge: .maxY)
    }

    @objc func refreshHome(_ sender: Any?) { owner?.session?.home.refresh(force: true) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Customize Home…", action: #selector(customize(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Home", action: #selector(refreshHome(_:)), keyEquivalent: "").target = self
    }
}

/// Flipped, so Home's content starts at the top of its scroll view.
@MainActor final class HomeDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Home's scrolling document. It sets the column's width from its own,
/// so no constraint ties the column to the pane (see `HomeView.init`).
@MainActor private final class HomeColumnDocumentView: NSView {
    var column: NSLayoutConstraint?
    private static let margin: CGFloat = 24

    override var isFlipped: Bool { true }

    /// Sizes the column before placing it, so the width applies to this pass.
    override func layout() {
        if let column {
            let width = max(0, min(bounds.width - 2 * Self.margin, HomeView.maximumContentWidth))
            if column.constant != width { column.constant = width }
        }
        super.layout()
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.descendants(of: type)
        }
    }
}

// MARK: - Modules

/// Builds one module's card from the session and its Home feed.
@MainActor private struct HomeBuilder {
    let owner: ConversationWindow
    let session: AccountSession
    let home: HomeView
    var feed: HomeFeed.Snapshot { session.home.snapshot }

    func card(for module: HomeModule) -> NSView? {
        switch module {
        case .favorites: return favorites()
        case .unread: return unread()
        case .later: return later()
        case .people: return people()
        case .week: return week()
        case .threads: return threads()
        case .files: return files()
        }
    }

    func nothingShown() -> NSView {
        let card = HomeCard(title: "Home")
        card.add(HomeText.note("Every module is hidden. Choose Customize Home to show some again."))
        return card
    }

    // MARK: Favorites

    private func favorites() -> NSView? {
        let ids = session.favoriteIDs
        let channels = session.channels.filter { ids.contains($0.id) && !$0.raw["is_archived"].bool }
        let card = HomeCard(title: HomeModule.favorites.title)
        guard !channels.isEmpty else {
            card.add(HomeText.note("Add conversations to Favorites from the sidebar or the Conversation menu, and they appear here."))
            return card
        }
        let flow = HomeFlowView()
        for channel in channels {
            let unread = owner.unreadCount(channel.id)
            let tile = HomeTile(avatar: avatar(for: channel, size: 52, badge: channel.raw["muted"].bool ? 0 : unread), name: shortName(channel))
            var label = channel.title
            if unread > 0 { label += ", \(unread) unread" }
            tile.setAccessibilityLabel(label)
            tile.toolTip = channel.title
            tile.onPress = { [weak owner] in owner?.select(channel) }
            flow.addTile(tile)
        }
        card.add(flow, fill: true)
        return card
    }

    // MARK: Unread

    private func unread() -> NSView? {
        let digest = HomeUnreadDigest.make(channels: session.channels, unread: session.unread, mentioned: session.mentionedChannels, fallback: feed.cachedLatest)
        session.home.loadCachedLatest(for: digest.entries)
        let card = HomeCard(title: HomeModule.unread.title)
        if !digest.entries.isEmpty, !session.readOnly {
            card.setAction("Mark All Read") { [weak owner] in owner?.markAllRead(digest) }
        }
        if digest.entries.isEmpty {
            card.add(HomeRestingRavens(), fill: false)
            card.add(HomeText.note("Nothing unread. The ravens are resting."))
        }
        let limit = home.showsAllUnread ? digest.entries.count : HomeView.unreadRows
        for entry in digest.entries.prefix(limit) {
            let channel = entry.channel
            let title = NSMutableAttributedString(string: channel.isDM ? channel.title : "# \(channel.title)", attributes: HomeText.titleAttributes)
            title.append(NSAttributedString(string: "  \(entry.count) new", attributes: HomeText.accentAttributes))
            if entry.mentioned { title.append(NSAttributedString(string: " · @you", attributes: HomeText.accentAttributes)) }
            let detail = preview(entry.latest)
            let row = HomeRow(icon: avatar(for: channel, size: 28), title: title, detail: detail, trailing: time(entry.latest?.timestamp))
            row.setAccessibilityLabel([channel.title, "\(entry.count) unread", entry.mentioned ? "mentions you" : nil, detail?.string].compactMap { $0 }.joined(separator: ", "))
            row.onPress = { [weak owner] in owner?.select(channel) }
            card.add(row)
        }
        if digest.entries.count > HomeView.unreadRows {
            let more = home.showsAllUnread ? "Show fewer" : "Show \(digest.entries.count - HomeView.unreadRows) more"
            card.add(HomeLinkButton(more) { [weak home] in home?.toggleUnreadExpansion() })
        }
        if digest.mutedConversations > 0 {
            let line = "\(digest.mutedMessages) new in \(digest.mutedConversations) muted conversation\(digest.mutedConversations == 1 ? "" : "s")"
            card.add(HomeText.quietLine(symbol: "bell.slash", line))
        }
        return card
    }

    private func preview(_ latest: HomeLatestMessage?) -> NSAttributedString? {
        guard let latest else { return nil }
        let text: String = switch latest.kind {
        case .image: latest.text.isEmpty ? "Image" : latest.text
        case .file: latest.text.isEmpty ? "File" : latest.text
        case .poll: latest.text.isEmpty ? "Poll" : "Poll: \(latest.text)"
        case .text, .system: latest.text
        }
        let result = NSMutableAttributedString()
        if latest.kind != .system, !latest.authorID.isEmpty {
            let name = latest.authorID == session.account.user ? "You" : firstName(latest.authorID)
            result.append(NSAttributedString(string: "\(name): ", attributes: HomeText.detailStrongAttributes))
        }
        result.append(NSAttributedString(string: text, attributes: HomeText.detailAttributes))
        return result
    }

    // MARK: Later

    private func later() -> NSView? {
        let card = HomeCard(title: HomeModule.later.title)
        var rows = 0
        switch feed.reminders {
        case .loaded(let reminders):
            for reminder in reminders.filter({ !$0["is_read"].bool }).prefix(3) {
                let text = reminder["description"].string.flatMap { $0.isEmpty ? nil : $0 } ?? messageText(reminder["message_content"].string)
                let due = reminder["remind_at"].string.map { dayAndTime($0) } ?? ""
                let detail = [due, origin(owner: reminder["message_owner"].string, channelID: reminder["channel_id"].string)].filter { !$0.isEmpty }.joined(separator: " · ")
                let row = HomeRow(icon: HomeSymbol("alarm"), title: HomeText.title(text), detail: HomeText.detail(detail), trailing: nil)
                row.setAccessibilityLabel("Reminder: \(text), \(detail)")
                row.onPress = { [weak owner] in owner?.openMessage(channelID: reminder["channel_id"].string, messageID: reminder["message"].string, parentID: nil) }
                card.add(row); rows += 1
            }
        case .failed: card.add(HomeText.note("Reminders could not be loaded."))
        case .loading: break
        }
        if case .loaded(let saved) = feed.saved {
            for message in saved.prefix(rows >= 2 ? 1 : 2) {
                let text = messageText(message["content"].string ?? message["text"].string)
                let detail = ["Saved", origin(owner: message["owner"].string, channelID: message["channel_id"].string)].filter { !$0.isEmpty }.joined(separator: " · ")
                let row = HomeRow(icon: HomeSymbol("bookmark"), title: HomeText.title(text), detail: HomeText.detail(detail), trailing: nil)
                row.setAccessibilityLabel("Saved message: \(text), \(detail)")
                row.onPress = { [weak owner] in owner?.openMessage(channelID: message["channel_id"].string, messageID: message["name"].string, parentID: message["parent_channel_id"].string) }
                card.add(row); rows += 1
            }
        } else if case .failed = feed.saved {
            card.add(HomeText.note("Saved messages could not be loaded."))
        }
        let drafts = homeDraftDestinations(for: session)
        if !drafts.isEmpty {
            let names = drafts.prefix(3).map { label($0.channel) }.joined(separator: " · ")
            let title = drafts.count == 1 ? "1 draft" : "\(drafts.count) drafts"
            let row = HomeRow(icon: HomeSymbol("square.and.pencil"), title: HomeText.title(title), detail: HomeText.detail(names), trailing: nil)
            row.setAccessibilityLabel("\(title): \(names)")
            row.onPress = { [weak owner] in owner?.openHomeDrafts() }
            card.add(row); rows += 1
        }
        if !feed.unsent.isEmpty {
            let title = feed.unsent.count == 1 ? "1 message not sent" : "\(feed.unsent.count) messages not sent"
            let row = HomeRow(icon: HomeSymbol("exclamationmark.circle", tint: .themeAlert), title: HomeText.title(title), detail: HomeText.detail("Outbox · open it to retry or edit"), trailing: nil)
            row.setAccessibilityLabel("\(title). Opens the Outbox.")
            row.onPress = { [weak owner] in owner?.outbox() }
            card.add(row); rows += 1
        }
        if case .failed = feed.draftRead { card.add(HomeText.note("Drafts could not be loaded.")) }
        if case .failed = feed.outboxRead { card.add(HomeText.note("The outbox could not be loaded.")) }
        if rows == 0, let note = HomeView.emptyLaterNote(feed) { card.add(HomeText.note(note)) }
        return card
    }

    // MARK: People

    private func people() -> NSView? {
        let card = HomeCard(title: HomeModule.people.title)
        card.setCaption("From your own messages")
        let ranked = HomePeople.rank(sent: feed.sent.value ?? [], channels: session.channels, me: session.account.user, now: Date())
        if ranked.isEmpty {
            if case .loading = feed.sent { card.add(HomeText.note("Loading…")) }
            else if case .failed = feed.sent { card.add(HomeText.note("Your sent messages could not be loaded.")) }
            else { card.add(HomeText.note("Write to someone directly and they appear here.")) }
            return card
        }
        session.loadAvatars(Set(ranked))
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.distribution = .fill
        strip.alignment = .top
        strip.spacing = 4
        for user in ranked {
            let name = firstName(user)
            let status = statusLine(user)
            let person = HomePerson(avatar: personAvatar(user, size: 44), name: name, status: status)
            person.setAccessibilityLabel([session.userNames[user] ?? user, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            person.toolTip = session.userNames[user] ?? user
            if let dm = session.channels.first(where: { $0.isDM && $0.raw["peer_user_id"].string == user }) {
                person.onPress = { [weak owner] in owner?.select(dm) }
            }
            person.widthAnchor.constraint(equalToConstant: HomePerson.width).isActive = true
            strip.addArrangedSubview(person)
        }
        let rest = NSView()
        rest.setContentHuggingPriority(.defaultLow, for: .horizontal)
        strip.addArrangedSubview(rest)
        card.add(strip, fill: true)
        return card
    }

    private func statusLine(_ user: String) -> String {
        let entry = session.directory[user]
        if let custom = entry?["custom_status"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        if let presence = session.presenceDescription(for: user) { return presence }
        return session.presenceUnavailable || session.demo ? "" : "Offline"
    }

    // MARK: Your week

    private func week() -> NSView? {
        let card = HomeCard(title: HomeModule.week.title)
        card.setCaption("Only you see this", symbol: "lock.fill")
        guard let sent = feed.sent.value else {
            if case .failed = feed.sent { card.add(HomeText.note("Your numbers could not be loaded from the server.")) }
            else { card.add(HomeText.note("Loading…")) }
            return card
        }
        let calendar = session.displayCalendar
        let now = Date()
        let summary = HomeWeekSummary.make(sent: sent.map(\.date), now: now, calendar: calendar)
        let sentStat = HomeStat(label: "Messages sent", value: String(summary.thisWeek), detail: summary.comparison)
        let hour: HomeStat
        if let busiest = summary.busiestHour {
            hour = HomeStat(label: "Busiest hour", value: hourRange(busiest, calendar: calendar), detail: summary.busiestHourCount == 1 ? "1 message" : "\(summary.busiestHourCount) messages")
        } else {
            hour = HomeStat(label: "Busiest hour", value: "–", detail: "No messages yet")
        }
        let emoji = Array(session.quickReactionUsage.mostUsed.prefix(3))
        let reactions = HomeStat(label: "Your reactions", value: emoji.isEmpty ? "–" : emoji.joined(), detail: emoji.isEmpty ? "None in 3 months" : "Most used, 3 months")
        let stats = NSStackView(views: [sentStat, hour, reactions])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.alignment = .top
        card.add(stats, fill: true)
        card.add(HomeBars(days: summary.days, today: now, calendar: calendar), fill: true)
        if feed.sentTruncated { card.add(HomeText.note("Counted from your newest \(HomeFeed.sentPageLimit) messages.")) }
        return card
    }

    private func hourRange(_ hour: Int, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        guard let start = calendar.date(from: components), let end = calendar.date(byAdding: .hour, value: 1, to: start) else { return "\(hour)" }
        // "10–11" in 24-hour locales, "10 AM–11 AM" in others.
        return "\(formatter.string(from: start).trimmingCharacters(in: .whitespaces))–\(formatter.string(from: end).trimmingCharacters(in: .whitespaces))"
    }

    // MARK: Threads

    private func threads() -> NSView? {
        let card = HomeCard(title: HomeModule.threads.title)
        card.setAction("Open Threads") { [weak owner] in owner?.threads() }
        switch feed.threads {
        case .loading: card.add(HomeText.note("Loading…"))
        case .failed: card.add(HomeText.note("Threads could not be loaded."))
        case .loaded(let threads):
            if threads.isEmpty { card.add(HomeText.note("Threads you reply in appear here.")) }
            let authors = Set(threads.compactMap { $0["owner"].string })
            session.loadAvatars(authors)
            for thread in threads {
                guard let id = thread["name"].string, let parent = thread["channel_id"].string else { continue }
                let unread = feed.unreadThreads[id] ?? 0
                let title = NSMutableAttributedString(attributedString: HomeText.title(messageText(thread["content"].string ?? thread["text"].string)))
                if unread > 0 { title.append(NSAttributedString(string: "  \(unread) new", attributes: HomeText.accentAttributes)) }
                let replies = thread["reply_count"].nonnegativeCount.map { $0 == 1 ? "1 reply" : "\($0) replies" }
                let place = session.channels.first { $0.id == parent }.map(label) ?? (thread["is_dm_thread"].bool ? "Direct message" : "")
                let detail = [place, replies].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let icon = thread["owner"].string.map { personAvatar($0, size: 28) } ?? HomeSymbol("bubble.left.and.text.bubble.right")
                let row = HomeRow(icon: icon, title: title, detail: HomeText.detail(detail), trailing: time(thread["last_message_timestamp"].string))
                row.setAccessibilityLabel([title.string, detail].joined(separator: ", "))
                row.onPress = { [weak owner] in owner?.openThread(id: id, parentID: parent) }
                card.add(row)
            }
        }
        return card
    }

    // MARK: Files

    private func files() -> NSView? {
        let card = HomeCard(title: HomeModule.files.title)
        switch feed.files {
        case .loading: card.add(HomeText.note("Loading…"))
        case .failed: card.add(HomeText.note("Recent files could not be loaded."))
        case .loaded(let files):
            if files.isEmpty { card.add(HomeText.note("Files and images shared with you appear here.")) }
            for file in files {
                let name = fileName(file)
                let size = file["file_size"].nonnegativeCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                let detail = [origin(owner: file["owner"].string, channelID: file["channel_id"].string), size].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let row = HomeRow(icon: HomeFileIcon(filename: name), title: HomeText.title(name), detail: HomeText.detail(detail), trailing: time(file["creation"].string))
                row.setAccessibilityLabel("\(name), \(detail)")
                row.onPress = { [weak owner] in owner?.openMessage(channelID: file["channel_id"].string, messageID: file["name"].string, parentID: file["parent_channel_id"].string) }
                card.add(row)
            }
            card.add(HomeText.note("New files can take a few minutes to appear."))
        }
        return card
    }

    private func fileName(_ row: JSONValue) -> String {
        for key in ["file", "internal_link", "content", "title"] {
            guard let value = row[key].string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            let last = value.split(separator: "/").last.map(String.init) ?? value
            let name = last.removingPercentEncoding ?? last
            if !name.isEmpty { return name }
        }
        return "File"
    }

    // MARK: Shared pieces

    private func avatar(for channel: RavenChannel, size: CGFloat, badge: Int = 0) -> HomeAvatar {
        let peer = owner.sidebarAvatarUserID(for: channel)
        if let peer { session.loadAvatars([peer]) }
        let image = peer.flatMap { session.avatarImage(for: $0) } ?? session.channelAvatarImage(for: channel)
        let view = HomeAvatar(size: size, shape: channel.isDM ? .circle : .tile)
        view.image = image
        view.symbol = channel.isDM ? "person.crop.circle" : channel.raw["type"].string == "Private" ? "lock" : "number"
        view.presence = peer.flatMap { session.presenceDescription(for: $0) }
        view.badge = badge
        return view
    }

    private func personAvatar(_ user: String, size: CGFloat) -> HomeAvatar {
        let view = HomeAvatar(size: size, shape: .circle)
        view.image = session.avatarImage(for: user)
        view.symbol = "person.crop.circle"
        view.presence = session.presenceDescription(for: user)
        return view
    }

    private func shortName(_ channel: RavenChannel) -> String {
        guard channel.isDM, let peer = channel.raw["peer_user_id"].string else { return channel.title }
        return firstName(peer)
    }

    private func firstName(_ user: String) -> String {
        let full = session.userNames[user] ?? user
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private func label(_ channel: RavenChannel) -> String { homeChannelLabel(channel) }

    /// "Mara in # design": who wrote a message and where.
    private func origin(owner user: String?, channelID: String?) -> String {
        let place = channelID.flatMap { id in session.channels.first { $0.id == id } }
        let name = user.map { $0 == session.account.user ? "You" : firstName($0) }
        switch (name, place) {
        case let (name?, place?) where place.isDM: return name == place.title || place.raw["peer_user_id"].string == user ? name : "\(name) with \(place.title)"
        case let (name?, place?): return "\(name) in # \(place.title)"
        case let (name?, nil): return name
        case let (nil, place?): return label(place)
        case (nil, nil): return ""
        }
    }

    private func messageText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Message" }
        let plain = raw.contains("<") ? ((try? RichTextCodec.parse(raw)).map { RichTextCodec.plainText($0) } ?? raw) : raw
        let line = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? "Message" : String(line.prefix(200))
    }

    /// Row-date formatter cache key: template, time zone and calendar system,
    /// so a calendar preference change does not reuse a stale formatter.
    private struct FormatterKey: Hashable {
        let template: String
        let timeZone: String
        let calendar: Calendar.Identifier
    }
    /// Row-date formatters cached per key, so a long Home list does not build a
    /// DateFormatter per row. Static because the builder is a struct;
    /// @MainActor-isolated, so access stays on the main thread.
    private static var rowDateFormatters: [FormatterKey: DateFormatter] = [:]
    private func rowDate(_ template: String, calendar: Calendar, date: Date) -> String {
        let key = FormatterKey(template: template, timeZone: calendar.timeZone.identifier, calendar: calendar.identifier)
        if let cached = Self.rowDateFormatters[key] { return cached.string(from: date) }
        let new = DateFormatter()
        new.calendar = calendar
        new.timeZone = calendar.timeZone
        new.setLocalizedDateFormatFromTemplate(template)
        Self.rowDateFormatters[key] = new
        return new.string(from: date)
    }

    /// "13:32" today, "Fri" this week, "12 Nov 2025" before — older dates keep
    /// the year so rows from a previous year are not ambiguous.
    private func time(_ raw: String?) -> String? {
        guard let raw, let date = session.messageDate(raw) else { return nil }
        let calendar = session.displayCalendar
        if calendar.isDateInToday(date) { return session.displayTime(raw) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        return rowDate(days < 7 && days > 0 ? "EEE" : "d MMM y", calendar: calendar, date: date)
    }

    /// "Today 15:00", "Thursday 09:30".
    private func dayAndTime(_ raw: String) -> String {
        guard let date = session.messageDate(raw) else { return "" }
        return "\(session.dayLabel(for: date)) \(session.displayTime(raw))"
    }
}

/// Later's draft destinations: a stored draft paired with the channel it
/// belongs to. A draft whose channel is gone or no longer accessible is not
/// a destination, so Home cannot offer it.
@MainActor private func homeDraftDestinations(for session: AccountSession) -> [(draft: Draft, channel: RavenChannel)] {
    session.home.snapshot.drafts.compactMap { draft in
        guard let channel = session.channels.first(where: { $0.id == draft.channelID }),
              !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents) else { return nil }
        return (draft: draft, channel: channel)
    }
}

/// How a channel is named in Home rows: "# design", or the peer for a DM.
@MainActor private func homeChannelLabel(_ channel: RavenChannel) -> String { channel.isDM ? channel.title : "# \(channel.title)" }

/// The draft preview shown beside a destination in the chooser.
@MainActor private func homeDraftDetail(_ draft: Draft) -> String {
    let plain = (try? RichTextCodec.parse(draft.html)).map { RichTextCodec.plainText($0) } ?? ""
    let text = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if draft.attachments.isEmpty { return text.isEmpty ? "Draft" : String(text.prefix(60)) }
    return text.isEmpty ? "Draft with attachments" : "\(String(text.prefix(60))) · attachments"
}

// MARK: - Actions

extension ConversationWindow {
    fileprivate static let logger = Logger(subsystem: "ch.goodvantage.Nevermore", category: "Home")
    /// Opens the draft row in Home's Later card. One destination opens
    /// directly; several offer the native choice sheet.
    fileprivate func openHomeDrafts() {
        guard let session, let window else { return }
        let destinations = homeDraftDestinations(for: session)
        guard !destinations.isEmpty else { return }
        if destinations.count == 1 {
            openHomeDraft(destinations[0].channel.id, session: session)
            return
        }
        let choices = destinations.map { destination in
            ChoiceSheet.Choice(id: destination.channel.id, title: homeChannelLabel(destination.channel), detail: homeDraftDetail(destination.draft))
        }
        Task { [weak self] in
            guard let picked = try? await ChoiceSheet.choose(title: "Open Draft", prompt: "Choose the conversation whose draft you want to continue.", choices: choices, allowsMultiple: false, on: window), let id = picked.first else { return }
            self?.openHomeDraft(id, session: session)
        }
    }

    /// Opens one draft destination after rechecking the original session,
    /// Home's current state and the destination's eligibility.
    fileprivate func openHomeDraft(_ channelID: String, session: AccountSession) {
        guard isCurrent(session), !home.isHidden,
              let destination = homeDraftDestinations(for: session).first(where: { $0.channel.id == channelID }) else { return }
        select(destination.channel)
    }

    /// Opens a message in its conversation in this window. Thread replies
    /// open their thread; access the session lost stays closed.
    func openMessage(channelID: String?, messageID: String?, parentID: String?) {
        guard let session, let channelID, !session.revokedChannels.contains(channelID), parentID.map(session.revokedChannels.contains) != true else { return }
        if let known = session.channels.first(where: { $0.id == channelID }) { select(known, anchor: messageID); return }
        var fields: [String: JSONValue] = ["name": .string(channelID), "channel_name": .string(parentID == nil ? channelID : "Thread")]
        if let parentID { fields["is_thread"] = .bool(true); fields["parent_channel_id"] = .string(parentID) }
        select(RavenChannel(raw: .object(fields)), anchor: messageID)
    }

    /// Opens a followed thread in this window.
    func openThread(id: String, parentID: String) {
        guard let session, !session.revokedChannels.contains(id), !session.revokedChannels.contains(parentID) else { return }
        select(RavenChannel(raw: .object(["name": .string(id), "channel_name": .string("Thread"), "is_thread": .bool(true), "parent_channel_id": .string(parentID)])))
    }

    /// Marks every conversation in Home's Unread module read, up to the
    /// newest message the channel list reported or, when that is missing,
    /// the newest cached one. A message that arrives meanwhile stays unread.
    func markAllRead(_ digest: HomeUnreadDigest) {
        guard let session, !digest.entries.isEmpty else { return }
        let count = digest.entries.count
        let location = navigationGeneration
        Task { [weak self] in
            guard let self else { return }
            @MainActor func isCurrentHome() -> Bool {
                self.isCurrentAccount(session) && self.navigationGeneration == location &&
                    self.channel == nil && !self.isSearching && !session.readOnly
            }
            guard isCurrentHome() else { return }
            // Resolve every timestamp before confirming, so the sheet counts
            // only conversations that can actually be acknowledged. The
            // cache is consulted for a missing or unparseable reported
            // timestamp; its creation uses the same Frappe datetime format
            // markSeen validates. cachedMessages returns the newest `limit`
            // rows in ascending order, so `.last` is the newest cached one.
            var cached: [String: HomeCachedNewest] = [:]
            for entry in digest.entries {
                guard isCurrentHome() else { return }
                guard !session.channelIsRevoked(entry.channel.id),
                      !HomeMarkAllReadPlan.acceptsTimestamp(entry.latest?.timestamp) else { continue }
                do {
                    if let newest = try await session.cachedMessages(channelID: entry.channel.id, limit: 1).last {
                        cached[entry.channel.id] = .message(newest.creation)
                    } else {
                        cached[entry.channel.id] = .empty
                    }
                } catch {
                    Self.logger.error("markAllRead could not read the cached messages of \(entry.channel.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    cached[entry.channel.id] = .failed
                }
            }
            guard isCurrentHome() else { return }
            let readable = digest.entries.filter { !session.channelIsRevoked($0.channel.id) }
            let plan = HomeMarkAllReadPlan(entries: readable, cached: cached)
            var accessChanged = count - readable.count
            var details: [String] = []
            if plan.skipped > 0 { details.append("No message to mark in \(plan.skipped)") }
            if plan.unavailable > 0 { details.append("Could not check \(plan.unavailable)") }
            let priorAccess = accessChanged > 0 ? ["Access changed for \(accessChanged)"] : []
            guard !plan.isEmpty else {
                await SheetPrompt.inform("Nothing to Mark as Read", message: (details + priorAccess).joined(separator: ". ") + ".", on: self.window)
                return
            }
            let message = (["Muted conversations stay as they are"] + details + priorAccess).joined(separator: ". ") + "."
            let confirmed = await SheetPrompt.confirm("Mark \(plan.targets.count) conversation\(plan.targets.count == 1 ? "" : "s") as read?", message: message, confirm: "Mark as Read", on: self.window)
            guard confirmed, isCurrentHome() else { return }
            var recorded = 0
            var failed = 0
            for target in plan.targets {
                guard isCurrentHome() else { return }
                let id = target.channel.id
                guard !session.channelIsRevoked(id) else { accessChanged += 1; continue }
                session.intentionallyUnread.remove(id)
                if await session.markSeen(channelID: id, timestamp: target.timestamp) {
                    recorded += 1
                } else if session.channelIsRevoked(id) {
                    accessChanged += 1
                } else {
                    failed += 1
                }
            }
            guard isCurrentHome() else { return }
            session.requestReconciliation()
            if recorded != count {
                let noun = count == 1 ? "conversation" : "conversations"
                var parts = ["Read progress saved for \(recorded) of \(count) \(noun)"] + details
                if accessChanged > 0 { parts.append("Access changed for \(accessChanged)") }
                if failed > 0 { parts.append("Could not save \(failed)") }
                self.status.stringValue = parts.joined(separator: ". ") + "."
            }
        }
    }

    @objc func goHome(_ sender: Any?) { showHome() }
    @objc func customizeHome(_ sender: Any?) {
        if channel != nil { showHome() }
        home.customize(sender)
    }
}

// MARK: - Views

/// Text styles for Home, in the theme's colors.
@MainActor enum HomeText {
    static var titleAttributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.themeText] }
    static var accentAttributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.themeAccent] }
    static var detailAttributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.themeSecondaryText] }
    static var detailStrongAttributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.themeSecondaryText] }

    static func title(_ text: String) -> NSAttributedString { NSAttributedString(string: text, attributes: titleAttributes) }
    static func detail(_ text: String) -> NSAttributedString? { text.isEmpty ? nil : NSAttributedString(string: text, attributes: detailAttributes) }

    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        // Guidance, not content: selectable, it showed the I-beam on a page
        // the reader clicks through.
        label.isSelectable = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .themeSecondaryText
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func quietLine(symbol: String, _ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .themeTertiaryText
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        let line = label(text, font: .systemFont(ofSize: 12), color: .themeTertiaryText)
        let stack = NSStackView(views: [icon, line])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 0)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel(text)
        return stack
    }
}

/// A module: a glass panel with a small heading, an optional action or
/// caption at the right, and rows.
@MainActor final class HomeCard: NSView {
    let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private let header = NSStackView()
    private let heading: NSTextField

    init(title: String) {
        heading = HomeText.label(title.uppercased(), font: .systemFont(ofSize: 11, weight: .bold), color: .themeSecondaryText)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        heading.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.themeSecondaryText, .kern: 0.6])
        heading.setAccessibilityElement(false)
        header.orientation = .horizontal
        header.setViews([heading], in: .leading)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.addArrangedSubview(header)
        glass.cornerRadius = 16
        // The rows hang from the top; a card stretched to its neighbour's
        // height leaves the space below them.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        glass.contentView = container
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Adds a row. `fill` stretches it to the card's width.
    func add(_ view: NSView, fill: Bool = true) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
    }

    func setAction(_ title: String, handler: @escaping () -> Void) {
        header.setViews([HomeLinkButton(title, action: handler)], in: .trailing)
    }

    func setCaption(_ text: String, symbol: String? = nil) {
        var views: [NSView] = []
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            icon.contentTintColor = .themeTertiaryText
            views.append(icon)
        }
        views.append(HomeText.label(text, font: .systemFont(ofSize: 11), color: .themeTertiaryText))
        let caption = NSStackView(views: views)
        caption.spacing = 4
        caption.setHuggingPriority(.required, for: .horizontal)
        header.setViews([caption], in: .trailing)
    }
}

/// A borderless text button in the accent color.
@MainActor final class HomeLinkButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.themeLink])
        target = self
        action = #selector(press)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func press() { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A clickable surface with hover feedback that VoiceOver and Full
/// Keyboard Access treat as a button.
@MainActor class HomePressable: NSView {
    var onPress: (() -> Void)?
    private var hovering = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = onPress != nil }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let onPress, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }
    override func resetCursorRects() { if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override var acceptsFirstResponder: Bool { onPress != nil && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode), let onPress { onPress(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? NSColor.themeText.withAlphaComponent(0.07).cgColor : nil
        }
    }
}

/// One line item: an icon, a title, an optional detail line and a time.
@MainActor final class HomeRow: HomePressable {
    init(icon: NSView, title: NSAttributedString, detail: NSAttributedString?, trailing: String?) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithAttributedString: title)
        let lines = NSStackView(views: [titleLabel])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if let detail { lines.addArrangedSubview(NSTextField(labelWithAttributedString: detail)) }
        for case let label as NSTextField in lines.arrangedSubviews {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        var views: [NSView] = [icon, lines]
        if let trailing {
            let time = HomeText.label(trailing, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .themeTertiaryText)
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            time.setContentHuggingPriority(.required, for: .horizontal)
            views.append(time)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews { view.setAccessibilityElement(false) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A favorite: a large portrait with its name below.
@MainActor final class HomeTile: HomePressable {
    static let width: CGFloat = 76
    init(avatar: HomeAvatar, name: String) {
        super.init(frame: .zero)
        let label = HomeText.label(name, font: .systemFont(ofSize: 12), color: .themeText)
        label.alignment = .center
        let stack = NSStackView(views: [avatar, label])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 8),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A person in "People You Talk With Most": portrait, first name, status.
@MainActor final class HomePerson: HomePressable {
    static let width: CGFloat = 84
    init(avatar: HomeAvatar, name: String, status: String) {
        super.init(frame: .zero)
        let nameLabel = HomeText.label(name, font: .systemFont(ofSize: 12, weight: .semibold), color: .themeText)
        let statusLabel = HomeText.label(status, font: .systemFont(ofSize: 11), color: .themeSecondaryText)
        for label in [nameLabel, statusLabel] { label.alignment = .center }
        let stack = NSStackView(views: [avatar, nameLabel, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -4),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One number in "Your Week".
@MainActor final class HomeStat: NSStackView {
    init(label: String, value: String, detail: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        let valueLabel = HomeText.label(value, font: ThemeFonts.senderName(ofSize: 24, weight: .bold), color: .themeText)
        setViews([
            HomeText.label(label, font: .systemFont(ofSize: 11.5), color: .themeSecondaryText),
            valueLabel,
            HomeText.label(detail, font: .systemFont(ofSize: 11), color: .themeSecondaryText)
        ], in: .top)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(label): \(value), \(detail)")
        for view in arrangedSubviews { view.setAccessibilityElement(false) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Messages per day for the last week: one thin bar per day, today last,
/// with the day's initial below. Bars use the accent at one strength;
/// no day is marked as better or worse.
@MainActor final class HomeBars: NSView, NSViewToolTipOwner {
    private let days: [Int]
    private let names: [String]
    private let fullNames: [String]
    static let barWidth: CGFloat = 14
    static let plotHeight: CGFloat = 34

    init(days: [Int], today: Date, calendar: Calendar) {
        self.days = days
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let dates = (0..<days.count).map { calendar.date(byAdding: .day, value: $0 - (days.count - 1), to: today) ?? today }
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        names = dates.map { formatter.string(from: $0) }
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        fullNames = dates.map { formatter.string(from: $0) }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Messages per day: " + zip(fullNames, days).map { "\($0) \($1)" }.joined(separator: ", "))
        heightAnchor.constraint(equalToConstant: Self.plotHeight + 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func barRect(_ index: Int) -> NSRect {
        let step = Self.barWidth + 8
        let peak = max(1, days.max() ?? 1)
        let height = days[index] == 0 ? 2 : max(4, Self.plotHeight * CGFloat(days[index]) / CGFloat(peak))
        return NSRect(x: 2 + CGFloat(index) * step, y: 4 + Self.plotHeight - height, width: Self.barWidth, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 9.5)
        for index in days.indices {
            let rect = barRect(index)
            NSColor.themeAccent.withAlphaComponent(days[index] == 0 ? 0.25 : 0.75).setFill()
            // Rounded at the data end only; anchored to the baseline.
            let path = NSBezierPath(roundedRect: rect, xRadius: min(4, rect.height / 2), yRadius: min(4, rect.height / 2))
            path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - min(4, rect.height / 2), width: rect.width, height: min(4, rect.height / 2))))
            path.fill()
            let name = NSAttributedString(string: names[index], attributes: [.font: font, .foregroundColor: NSColor.themeTertiaryText])
            let size = name.size()
            name.draw(at: NSPoint(x: rect.midX - size.width / 2, y: 6 + Self.plotHeight))
        }
    }

    /// Each column's tooltip by its tag. The view answers for its own
    /// tooltips: AppKit holds a tooltip's owner weakly, so a string passed
    /// as the owner is freed as soon as the column is added.
    private(set) var toolTipTexts: [NSView.ToolTipTag: String] = [:]

    override func layout() {
        super.layout()
        removeAllToolTips()
        toolTipTexts = [:]
        for index in days.indices {
            let column = barRect(index)
            let tag = addToolTip(NSRect(x: column.minX - 4, y: 0, width: column.width + 8, height: bounds.height), owner: self, userData: nil)
            toolTipTexts[tag] = "\(fullNames[index]): \(days[index]) message\(days[index] == 1 ? "" : "s")"
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipTexts[tag] ?? ""
    }
}

/// Lays favorites out in rows that wrap with the card's width.
@MainActor final class HomeFlowView: NSView {
    private var tiles: [HomeTile] = []
    private var lastHeight: CGFloat = 0
    static let spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    func addTile(_ tile: HomeTile) {
        tiles.append(tile)
        addSubview(tile)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: lastHeight) }

    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for tile in tiles {
            let size = tile.fittingSize
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + Self.spacing; rowHeight = 0 }
            tile.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        let height = y + rowHeight
        if abs(height - lastHeight) > 0.5 { lastHeight = height; invalidateIntrinsicContentSize() }
    }
}

/// A portrait, conversation tile or symbol, with an optional presence dot
/// and unread badge.
@MainActor final class HomeAvatar: NSView {
    enum Shape { case circle, tile }
    var image: NSImage?
    var symbol = "number"
    var presence: String?
    var badge = 0
    private let size: CGFloat
    private let shape: Shape

    init(size: CGFloat, shape: Shape) {
        self.size = size; self.shape = shape
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func badgeTextColor(on fill: NSColor) -> NSColor {
        guard let color = ThemeColor(nsColor: fill) else { return .labelColor }
        return NSColor(theme: color.readableForeground)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        if let image {
            switch shape {
            case .circle: ProfilePhoto.draw(image, in: rect)
            case .tile:
                let clip = NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24)
                NSGraphicsContext.saveGraphicsState(); clip.addClip()
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            NSColor.themeText.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: shape == .circle ? size / 2 : size * 0.24, yRadius: shape == .circle ? size / 2 : size * 0.24).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium).applying(.init(paletteColors: [.themeSecondaryText]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let glyphSize = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2, width: glyphSize.width, height: glyphSize.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let color: NSColor? = switch presence {
        case "Active": .systemGreen
        case "Away": .systemYellow
        case "Do not disturb": .systemRed
        default: nil
        }
        if let color {
            let dot = max(7, size * 0.26)
            let ring = NSRect(x: rect.maxX - dot + 1, y: rect.maxY - dot + 1, width: dot, height: dot)
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: ring).fill()
            color.setFill(); NSBezierPath(ovalIn: ring.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
        if badge > 0 {
            let fill = NSColor.themeAccent
            let text = NSAttributedString(string: badge > 99 ? "99+" : String(badge), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: Self.badgeTextColor(on: fill)])
            let textSize = text.size()
            let height: CGFloat = 17
            let width = max(height, textSize.width + 9)
            let pill = NSRect(x: rect.maxX - width + 5, y: rect.minY - 4, width: width, height: height)
            fill.setFill(); NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
            text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2))
        }
    }
}

/// An SF Symbol in a soft square, for rows without a portrait.
@MainActor final class HomeSymbol: NSView {
    init(_ name: String, tint: NSColor = .themeSecondaryText) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateLayer()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.themeText.withAlphaComponent(0.07).cgColor }
}

/// The Finder icon for a file's type.
@MainActor final class HomeFileIcon: NSImageView {
    init(filename: String) {
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Three ravens on the module's floor, for an empty Unread.
@MainActor final class HomeRestingRavens: NSView {
    private let birds = [RavenPerchView(), RavenPerchView(), RavenPerchView()]
    static let scale: CGFloat = 2

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        for bird in birds {
            bird.tint(ink: .themeSecondaryText, lit: false)
            bird.figure.layer.setAffineTransform(CGAffineTransform(scaleX: Self.scale, y: Self.scale))
            bird.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bird)
        }
        let width = RavenFigure.size.width * Self.scale, height = RavenFigure.size.height * Self.scale
        var constraints = [heightAnchor.constraint(equalToConstant: height + 10), widthAnchor.constraint(equalToConstant: width * 3 + 24)]
        for (index, bird) in birds.enumerated() {
            constraints += [
                bird.bottomAnchor.constraint(equalTo: bottomAnchor, constant: index == 1 ? -4 : 0),
                bird.leadingAnchor.constraint(equalTo: leadingAnchor, constant: (width + 12) * CGFloat(index) + width / 2 - RavenFigure.size.width / 2),
                bird.widthAnchor.constraint(equalToConstant: RavenFigure.size.width),
                bird.heightAnchor.constraint(equalToConstant: RavenFigure.size.height)
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for bird in birds { bird.tint(ink: .themeSecondaryText, lit: false) }
    }
}

// MARK: - Customize Home

/// Show, hide and reorder Home's modules. Changes apply at once to every
/// window; drag rows to reorder.
@MainActor final class HomeCustomizeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private lazy var moveUp = moveButton("Move Up", symbol: "arrow.up", key: NSUpArrowFunctionKey)
    private lazy var moveDown = moveButton("Move Down", symbol: "arrow.down", key: NSDownArrowFunctionKey)
    private var layout = HomePreferences.layout
    private static let dragType = NSPasteboard.PasteboardType("ch.goodvantage.Nevermore.home-module")

    private func moveButton(_ title: String, symbol: String, key: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: #selector(moveSelected(_:)))
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        button.toolTip = title
        button.keyEquivalent = String(UnicodeScalar(key)!)
        button.keyEquivalentModifierMask = .option
        return button
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Customize Home")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Choose what Home shows. Drag rows or select one and use the arrows to reorder.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("module"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Home modules")
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.controlSize = .small
        let actions = NSStackView(views: [moveUp, moveDown, NSView(), restore])
        actions.orientation = .horizontal
        actions.spacing = 4
        updateMoveButtons()
        let stack = NSStackView(views: [title, hint, table, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 260),
            table.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            actions.widthAnchor.constraint(equalTo: table.widthAnchor),
            table.heightAnchor.constraint(equalToConstant: CGFloat(HomeModule.allCases.count) * 26),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])
        view = stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layout.order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let module = layout.order[row]
        let box = NSButton(checkboxWithTitle: module.title, target: self, action: #selector(toggle(_:)))
        box.tag = row
        box.state = layout.hidden.contains(module) ? .off : .on
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
        grip.contentTintColor = .tertiaryLabelColor
        let cell = NSStackView(views: [box, NSView(), grip])
        cell.orientation = .horizontal
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        return cell
    }

    @objc private func toggle(_ sender: NSButton) {
        guard layout.order.indices.contains(sender.tag) else { return }
        layout.setVisible(layout.order[sender.tag], sender.state == .on)
        HomePreferences.layout = layout
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateMoveButtons() }

    private func updateMoveButtons() {
        let row = table.selectedRow
        moveUp.isEnabled = layout.order.indices.contains(row) && row > 0
        moveDown.isEnabled = layout.order.indices.contains(row) && row + 1 < layout.order.count
    }

    @objc private func moveSelected(_ sender: NSButton) {
        let row = table.selectedRow
        guard layout.order.indices.contains(row) else { return }
        let target = sender === moveUp ? row - 1 : row + 1
        guard layout.order.indices.contains(target) else { return }
        move(layout.order[row], to: target)
    }

    private func move(_ module: HomeModule, to index: Int) {
        layout.move(module, to: index)
        HomePreferences.layout = layout
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateMoveButtons()
        NSAccessibility.post(element: table, notification: .announcementRequested, userInfo: [
            .announcement: "\(module.title), position \(index + 1) of \(layout.order.count)",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    @objc private func restoreDefaults() {
        layout = .standard
        HomePreferences.layout = layout
        table.reloadData()
        updateMoveButtons()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(layout.order[row].rawValue, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { tableView.setDropRow(row, dropOperation: .above); return .move }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let module = HomeModule(rawValue: raw), let from = layout.order.firstIndex(of: module) else { return false }
        guard (0...layout.order.count).contains(row) else { return false }
        move(module, to: from < row ? row - 1 : row)
        return true
    }
}
