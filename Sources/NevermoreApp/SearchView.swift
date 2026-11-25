import AppKit
import NevermoreCore
import RavenProtocol

/// The search results screen: it replaces the conversation pane, as Home
/// does (`docs/design/search/SEARCH-RESULTS.md`, section 6). Tabs and
/// filter chips on top, results grouped by conversation, and a column that
/// shows Top hits and saved searches until a result is selected, then a
/// preview of it.
///
/// Searching and previewing never mark anything read: previews load with
/// `update_last_visit: false`, and only opening a conversation counts.
@MainActor final class SearchView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Item {
        case conversation(id: String, count: Int)
        case hit(SearchHit)
        case more(conversationID: String, hidden: Int)
        case link(JSONValue)
        case channel(RavenChannel)
        case person(String)

        var isSelectable: Bool { if case .conversation = self { return false }; return true }
        var key: String {
            switch self {
            case .conversation(let id, _): "c:" + id
            case .hit(let hit): "h:" + hit.id
            case .more(let id, _): "m:" + id
            case .link(let row): "l:" + (row["Nevermore.LinkKey"].string ?? row["message_id"].string ?? "")
            case .channel(let channel): "ch:" + channel.id
            case .person(let user): "p:" + user
            }
        }
    }

    private weak var owner: ConversationWindow?
    private(set) var feed: SearchFeed
    private(set) var criteria = SearchCriteria()
    private(set) var tab: SearchTab = .messages
    private(set) var order: SearchOrder = .bestMatch
    private var expanded: Set<String> = []
    private(set) var items: [Item] = []
    /// The conversation open when the search began, offered in the In menu.
    private var origin: RavenChannel?

    let tabs = NSSegmentedControl()
    private let chips = NSStackView()
    private let chipScroll = NSScrollView()
    /// The chip row's overflow menu, shown only when the chips themselves
    /// do not fit the pane.
    private let filtersButton = NSButton()
    private static let contentInset: CGFloat = 20
    private let chipRow = NSStackView()
    private let filterSpacer = NSView()
    private let orderPopup = NSPopUpButton()
    let table = SearchResultsTable()
    private let tableScroll = NSScrollView()
    private let listPanel = NSGlassEffectView()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField(wrappingLabelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let emptyAction = NSButton()
    private var emptyHandler: (() -> Void)?
    let side = SearchSideColumn()
    /// The compact window's preview affordance, in the footer below the
    /// side-pane threshold.
    let previewButton = NSButton(title: "Preview Context", target: nil, action: nil)
    private(set) var compactPreviewPopover: NSPopover?
    private(set) var compactPreviewView: SearchCompactPreviewView?
    private let sidePanel = NSGlassEffectView()
    private let status = NSTextField(labelWithString: "")
    private let hints = NSTextField(labelWithString: "")
    private let footerButtons = NSStackView()
    private var sideWidth: NSLayoutConstraint?
    private var observers: [NSObjectProtocol] = []
    private var previewTask: Task<Void, Never>?
    private var previewCache: [String: [RavenMessage]] = [:]
    /// Most-recently-used-last order of `previewCache` keys.
    private var previewRecency: [String] = []
    private(set) var attachments = SearchAttachmentReader()

    /// Caches a preview context as most recently used; beyond 50 entries the
    /// least recently used one is evicted instead of dropping the whole cache.
    private func cachePreview(_ context: [RavenMessage], for id: String) {
        guard !context.isEmpty else { return }
        previewCache[id] = context
        previewRecency.removeAll { $0 == id }
        previewRecency.append(id)
        while previewRecency.count > 50, let oldest = previewRecency.first {
            previewRecency.removeFirst()
            previewCache.removeValue(forKey: oldest)
        }
    }

    /// Returns the cached preview, marking it most recently used.
    private func cachedPreview(_ id: String) -> [RavenMessage]? {
        guard let context = previewCache[id] else { return nil }
        previewRecency.removeAll { $0 == id }
        previewRecency.append(id)
        return context
    }

    /// Below this pane width the side column hides.
    static let sideColumnMinimumWidth: CGFloat = 900
    static let sideColumnWidth: CGFloat = 320
    /// The compact preview popover's widest content, still inside a
    /// 650-point window.
    static let compactPreviewWidth: CGFloat = 420

    init(owner: ConversationWindow) {
        self.owner = owner
        feed = SearchFeed(session: owner.session)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search")
        build()
        feed.onChange = { [weak self] in self?.reload() }
        attachments.onStatus = { [weak self] _ in self?.updateFooter() }
        let center = NotificationCenter.default
        for name in [Notification.Name.sessionChanged, .sessionAvatarsChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? AccountSession
                MainActor.assumeIsolated {
                    guard let self, source === self.owner?.session else { return }
                    // Sessions change often; rebuild only when access did.
                    // Hidden results narrow too, for Back to bring them up.
                    if self.feed.restrict(), !self.isHidden { self.closeCompactPreview(); self.reload() }
                }
            })
        }
        observers.append(center.addObserver(forName: .savedSearchesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.isHidden else { return }; self.reloadSide() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }

    // MARK: Layout

    private func build() {
        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.segmentCount = SearchTab.allCases.count
        for (index, tab) in SearchTab.allCases.enumerated() { tabs.setLabel(tab.title, forSegment: index); tabs.setWidth(0, forSegment: index) }
        tabs.selectedSegment = 0
        // The theme accent, not the system blue, marks the selected tab.
        tabs.selectedSegmentBezelColor = .themeAccent
        tabs.target = self; tabs.action = #selector(tabChanged)
        tabs.setAccessibilityLabel("Result type")
        orderPopup.addItems(withTitles: ["Best Match", "Newest First"])
        orderPopup.controlSize = .small
        orderPopup.target = self; orderPopup.action = #selector(orderChanged)
        orderPopup.setAccessibilityLabel("Order of results")
        orderPopup.toolTip = "Best Match groups results by conversation"
        let top = NSStackView(views: [tabs])
        top.orientation = .horizontal
        top.alignment = .centerY
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.alignment = .centerY
        chips.setHuggingPriority(.defaultLow, for: .horizontal)
        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.verticalScrollElasticity = .none
        let chipDocument = HomeDocumentView()
        chipDocument.translatesAutoresizingMaskIntoConstraints = false
        chips.translatesAutoresizingMaskIntoConstraints = false
        chipDocument.addSubview(chips)
        chipScroll.documentView = chipDocument
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: chipDocument.leadingAnchor), chips.topAnchor.constraint(equalTo: chipDocument.topAnchor, constant: 2),
            chips.bottomAnchor.constraint(equalTo: chipDocument.bottomAnchor, constant: -2), chips.trailingAnchor.constraint(equalTo: chipDocument.trailingAnchor),
            chipDocument.topAnchor.constraint(equalTo: chipScroll.contentView.topAnchor), chipDocument.leadingAnchor.constraint(equalTo: chipScroll.contentView.leadingAnchor),
            chipDocument.heightAnchor.constraint(equalTo: chipScroll.contentView.heightAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 30)
        ])
        orderPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        filtersButton.title = "Filters"
        filtersButton.target = self
        filtersButton.action = #selector(filtersButtonPressed)
        let filterMenu = NSMenu(title: "Filters")
        filterMenu.delegate = self
        filtersButton.menu = filterMenu
        filtersButton.bezelStyle = .glass
        filtersButton.controlSize = .small
        filtersButton.setAccessibilityLabel("Filters")
        // The window's key loop covers the conversation controls, so the
        // menu also answers a chord while the pane is focused.
        filtersButton.keyEquivalent = "f"
        filtersButton.keyEquivalentModifierMask = [.control, .option, .command]
        filtersButton.toolTip = "Filters (⌃⌥⌘F), with the active count"
        filtersButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        filtersButton.setContentHuggingPriority(.required, for: .horizontal)
        filtersButton.isHidden = true
        filterSpacer.isHidden = true
        chipRow.setViews([chipScroll, filtersButton, filterSpacer, orderPopup], in: .leading)
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Search results")
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onQuickLook = { [weak self] in self?.quickLookSelected() }
        table.onSave = { [weak self] in self?.saveSelectedFile() }
        table.onCancel = { [weak self] in self?.cancelSearchOrPreview() }
        table.onFocusField = { [weak self] in self?.owner?.focusSearchField() }
        table.onTogglePreview = { [weak self] in self?.toggleCompactPreview() }
        let menu = NSMenu(title: "Result")
        menu.delegate = table
        table.menu = menu
        table.menuProvider = { [weak self] row in self?.contextMenu(row: row) }
        tableScroll.documentView = table
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = .themeText
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .themeSecondaryText
        emptyDetail.alignment = .center
        emptyAction.bezelStyle = .glass
        emptyAction.target = self; emptyAction.action = #selector(emptyActionPressed)
        emptyState.setViews([RavenPerchView(), emptyTitle, emptyDetail, emptyAction], in: .center)
        emptyState.orientation = .vertical
        emptyState.spacing = 8
        emptyState.alignment = .centerX
        let listContainer = NSView()
        for view in [tableScroll, emptyState] { view.translatesAutoresizingMaskIntoConstraints = false; listContainer.addSubview(view) }
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 6), tableScroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -6),
            tableScroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 6), tableScroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -6),
            emptyState.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: -20),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: listContainer.widthAnchor, constant: -48),
            emptyTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420), emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        listPanel.cornerRadius = 16
        listPanel.contentView = listContainer
        side.owner = owner
        side.view = self
        sidePanel.cornerRadius = 16
        sidePanel.contentView = side
        let body = NSStackView(views: [listPanel, sidePanel])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 14
        body.distribution = .fill
        listPanel.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        sidePanel.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let width = sidePanel.widthAnchor.constraint(equalToConstant: Self.sideColumnWidth); width.isActive = true; sideWidth = width
        listPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .themeSecondaryText
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .themeTertiaryText
        hints.lineBreakMode = .byTruncatingTail
        hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.stringValue = "↑↓ Move · Return Open · Space Quick Look · ⇧⌘S Save File · ⌘[ Back to Results · Esc Close"
        footerButtons.orientation = .horizontal
        footerButtons.spacing = 6
        previewButton.bezelStyle = .glass
        previewButton.controlSize = .small
        previewButton.setAccessibilityLabel("Preview context")
        previewButton.toolTip = "Show the messages around the selected result (⌘L)"
        previewButton.keyEquivalent = "l"
        previewButton.keyEquivalentModifierMask = .command
        previewButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        previewButton.target = self
        previewButton.action = #selector(toggleCompactPreview)
        previewButton.isHidden = true
        footerButtons.addArrangedSubview(previewButton)
        let footerText = NSStackView(views: [status, hints])
        footerText.orientation = .vertical
        footerText.alignment = .leading
        footerText.spacing = 2
        let footer = NSStackView(views: [footerText, NSView(), footerButtons])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [top, chipRow, body, footer])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: Self.contentInset, bottom: 12, right: Self.contentInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [top, chipRow, body, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.contentInset).isActive = true }
        // The screen shares the conversation pane even while hidden, so it
        // must never hold the window wider: below its content's width the
        // trailing edge gives way and the pane clips.
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            // Below the toolbar: the window draws content under it.
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), trailing
        ])
        sidePanel.isHidden = true
        clipsToBounds = true
        // The results take every point the other rows leave.
        // NSStackView sizes itself by its own hugging, not content hugging.
        for row in [top, chipRow, footer, footerText] { row.setHuggingPriority(.required, for: .vertical) }
        body.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        body.setClippingResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        applyTheme()
    }

    override func layout() {
        super.layout()
        let wide = bounds.width >= Self.sideColumnMinimumWidth
        if sidePanel.isHidden == wide {
            sidePanel.isHidden = !wide
            if wide { closeCompactPreview(); reloadSide() } else { updatePreviewAffordance() }
        }
        let compact = bounds.width < Self.compactWidth
        if compact != isCompact { isCompact = compact; tabs.controlSize = compact ? .small : .regular; if let session = owner?.session { updateTabLabels(session) } }
        let available = bounds.width - 2 * Self.contentInset - (orderPopup.isHidden ? 0 : orderPopup.fittingSize.width + chipRow.spacing)
        guard available > 0 else { return }
        let overflow = chips.fittingSize.width > available + 1
        if overflow != chipScroll.isHidden {
            chipScroll.isHidden = overflow
            filtersButton.isHidden = !overflow
            filterSpacer.isHidden = !overflow
        }
    }

    /// Below this width the tabs shrink and drop their counts.
    static let compactWidth: CGFloat = 620
    private var isCompact = false

    var showsSideColumn: Bool { !sidePanel.isHidden }

    func applyTheme() {
        let theme = ThemeManager.shared.current
        let tint = theme.palette.map { NSColor(theme: $0.composerTint, alpha: 0.22) }
        listPanel.tintColor = tint
        sidePanel.tintColor = tint
        markThemeSubtreeNeedsDisplay()
        table.reloadData()
    }

    // MARK: Searching

    /// Shows `criteria`. `origin` is the conversation the search began in.
    func begin(_ criteria: SearchCriteria, origin: RavenChannel?, immediately: Bool) {
        if let origin { self.origin = origin }
        // The Conversations and People tabs share the Messages search.
        let tab = criteria.tab == .messages && [.conversations, .people].contains(self.tab) ? self.tab : criteria.tab
        apply(criteria, tab: tab, immediately: immediately)
    }

    /// The toolbar field changed.
    func queryChanged(_ text: String, immediately: Bool) {
        var next = criteria
        next.query = SearchCriteria(query: text).query
        apply(next, tab: tab, immediately: immediately)
    }

    /// `force` searches again even when nothing changed (Return).
    private func apply(_ next: SearchCriteria, tab: SearchTab, immediately: Bool, force: Bool = false) {
        let changed = next != criteria || next != feed.criteria
        if changed { expanded = []; previewTask?.cancel() }
        criteria = next
        self.tab = tab
        if changed || force { feed.search(next, tab: tab, immediately: immediately, refresh: force) }
        else { feed.ensureLoaded(tab) }
        owner?.recordSearch(next)
        rebuildChips()
        reload()
    }

    /// Return in the search field: search now, even for the same words.
    func searchNow(_ text: String) {
        var next = criteria
        next.query = SearchCriteria(query: text).query
        apply(next, tab: tab, immediately: true, force: true)
    }

    /// The account changed or the window closed.
    func reset(session: AccountSession?) {
        feed.cancel(); previewTask?.cancel(); attachments.cancel()
        closeCompactPreview()
        feed = SearchFeed(session: session)
        feed.onChange = { [weak self] in self?.reload() }
        criteria = SearchCriteria(); tab = .messages; expanded = []; origin = nil; previewCache.removeAll(); previewRecency.removeAll()
        items = []; table.reloadData()
    }

    @objc private func tabChanged() {
        let next = SearchTab.allCases[max(0, tabs.selectedSegment)]
        guard next != tab else { return }
        tab = next
        previewTask?.cancel()
        // Every tab, including the local Conversations and People views:
        // a Files or Links kind left over from another tab would leak into
        // the local result set, the Filters menu and a saved search. A
        // detour through a local tab is a clean slate; switching back
        // re-derives that tab's default kind.
        criteria = criteria.on(next)
        if [.messages, .files, .links].contains(next) {
            if criteria == feed.criteria { feed.ensureLoaded(next) } else { feed.search(criteria, tab: next, immediately: true) }
            owner?.recordSearch(criteria)
        }
        rebuildChips()
        reload()
    }

    @objc private func orderChanged() {
        order = orderPopup.indexOfSelectedItem == 1 ? .newest : .bestMatch
        reload()
    }

    func select(tab next: SearchTab) {
        guard let index = SearchTab.allCases.firstIndex(of: next) else { return }
        tabs.selectedSegment = index
        tabChanged()
    }

    private func change(_ edit: (inout SearchCriteria) -> Void) {
        var next = criteria
        edit(&next)
        apply(next, tab: tab, immediately: true)
    }

    // MARK: Chips

    private func rebuildChips() {
        updateFiltersButton()
        guard let session = owner?.session else { chips.setViews([], in: .leading); return }
        var views: [NSView] = []
        let local = [.conversations, .people].contains(tab)
        views.append(SearchChip(title: "In: " + scopeTitle(session), active: criteria.scope != .account, menu: { [weak self] in self?.scopeMenu(session) ?? NSMenu() }))
        if !local {
            views.append(SearchChip(title: "From: " + (criteria.author.map { $0 == session.account.user ? "Me" : session.userNames[$0] ?? $0 } ?? "Anyone"), active: criteria.author != nil, menu: { [weak self] in self?.authorMenu(session) ?? NSMenu() }))
            if tab != .links {
                views.append(SearchChip(title: "Date: " + (criteria.date.map { Self.dateTitle($0) } ?? "Any Time"), active: criteria.date != nil, menu: { [weak self] in self?.dateMenu() ?? NSMenu() }))
            }
            switch tab {
            case .messages: views.append(SearchChip(title: "Has: " + hasTitle, active: hasTitle != "Anything", menu: { [weak self] in self?.hasMenu() ?? NSMenu() }))
            case .files: views.append(SearchChip(title: "Type: " + (criteria.kind == .images ? "Images" : "All Files"), active: criteria.kind == .images, menu: { [weak self] in self?.fileTypeMenu() ?? NSMenu() }))
            default: break
            }
            views.append(SearchChip(toggle: "Saved by Me", on: criteria.savedOnly) { [weak self] in self?.change { $0.savedOnly.toggle() } })
            views.append(SearchChip(toggle: "Mentions Me", on: criteria.mentionsMe) { [weak self] in self?.change { $0.mentionsMe.toggle() } })
            if criteria.scopeHasThreads, !(tab == .links && linksWorkspaceScope) {
                views.append(SearchChip(toggle: "Include Threads", on: criteria.includeThreads) { [weak self] in self?.change { $0.includeThreads.toggle() } })
            }
        }
        if activeFilterCount > 0 {
            views.append(HomeLinkButton("Clear Filters") { [weak self] in self?.clearFilters() })
        }
        chips.setViews(views, in: .leading)
        tabs.selectedSegment = SearchTab.allCases.firstIndex(of: tab) ?? 0
        orderPopup.isHidden = ![.messages, .files].contains(tab)
    }

    /// The chips that are active, the same set that shows Clear Filters.
    private var activeFilterCount: Int {
        var count = 0
        if criteria.scope != .account { count += 1 }
        if criteria.author != nil { count += 1 }
        if criteria.date != nil { count += 1 }
        if criteria.attribute != nil { count += 1 }
        if [.text, .polls, .images].contains(criteria.kind) { count += 1 }
        if criteria.savedOnly { count += 1 }
        if criteria.mentionsMe { count += 1 }
        return count
    }

    /// Whether the Links tab's workspace scope, which cannot take threads.
    private var linksWorkspaceScope: Bool { if case .workspace = criteria.scope { return true }; return false }

    /// The chip row's Filters menu, built from the chips' own menus and
    /// toggles so a narrow pane still reaches every filter.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === filtersButton.menu else { return }
        menu.removeAllItems()
        guard let session = owner?.session else { return }
        func section(_ title: String, _ builder: () -> NSMenu) {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let built = builder()
            for item in built.items { built.removeItem(item); menu.addItem(item) }
        }
        func toggle(_ title: String, on: Bool, _ handler: @escaping () -> Void) {
            menu.addItem(SearchMenuItem(title, on: on, handler: handler))
        }
        section("In") { self.scopeMenu(session) }
        if ![.conversations, .people].contains(tab) {
            section("From") { self.authorMenu(session) }
            if tab != .links { section("Date") { self.dateMenu() } }
            switch tab {
            case .messages: section("Has") { self.hasMenu() }
            case .files: section("Type") { self.fileTypeMenu() }
            default: break
            }
            toggle("Saved by Me", on: criteria.savedOnly) { [weak self] in self?.change { $0.savedOnly.toggle() } }
            toggle("Mentions Me", on: criteria.mentionsMe) { [weak self] in self?.change { $0.mentionsMe.toggle() } }
            if criteria.scopeHasThreads, !(tab == .links && linksWorkspaceScope) {
                toggle("Include Threads", on: criteria.includeThreads) { [weak self] in self?.change { $0.includeThreads.toggle() } }
            }
        }
        if activeFilterCount > 0 {
            menu.addItem(.separator())
            toggle("Clear Filters", on: false) { [weak self] in self?.clearFilters() }
        }
    }

    private func updateFiltersButton() {
        let count = activeFilterCount
        filtersButton.title = count > 0 ? "Filters (\(count)) ▾" : "Filters ▾"
        filtersButton.setAccessibilityLabel(count > 0 ? "Filters, \(count) active" : "Filters")
        filtersButton.bezelColor = count > 0 ? .themeAccent.withAlphaComponent(0.45) : nil
    }

    @objc private func filtersButtonPressed() {
        guard !filtersButton.isHidden, let menu = filtersButton.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filtersButton.bounds.height + 4), in: filtersButton)
    }

    private func clearFilters() {
        change { $0 = SearchCriteria(query: $0.query, kind: $0.kind == .images ? .files : [.text, .polls].contains($0.kind) ? .all : $0.kind) }
    }

    private var hasTitle: String {
        switch (criteria.kind, criteria.attribute) {
        case (_, .reactions): "Reactions"
        case (_, .thread): "Started a Thread"
        case (.text, _): "Text Only"
        case (.polls, _): "Polls"
        default: "Anything"
        }
    }

    private func scopeTitle(_ session: AccountSession) -> String {
        switch criteria.scope {
        case .account: "Everywhere"
        case .conversation(let id): session.channels.first { $0.id == id }.map { $0.isDM ? $0.title : "# " + $0.title } ?? "This Conversation"
        case .workspace(let workspace): workspace
        }
    }

    private func scopeMenu(_ session: AccountSession) -> NSMenu {
        let menu = NSMenu(title: "In")
        menu.addItem(SearchMenuItem("Everywhere", on: criteria.scope == .account) { [weak self] in self?.change { $0.scope = .account } })
        var conversations: [RavenChannel] = []
        if let origin { conversations.append(origin) }
        if case .conversation(let id) = criteria.scope, let current = session.channels.first(where: { $0.id == id }), !conversations.contains(where: { $0.id == id }) { conversations.append(current) }
        if !conversations.isEmpty { menu.addItem(.separator()) }
        for channel in conversations {
            menu.addItem(SearchMenuItem(channel.isDM ? channel.title : "# " + channel.title, on: criteria.scope == .conversation(channel.id)) { [weak self] in self?.change { $0.scope = .conversation(channel.id) } })
        }
        let workspaces = Set(session.channels.filter { !$0.isDM && !$0.workspace.isEmpty }.map(\.workspace)).sorted()
        if !workspaces.isEmpty {
            menu.addItem(.separator())
            for workspace in workspaces {
                menu.addItem(SearchMenuItem("All of \(workspace)", on: criteria.scope == .workspace(workspace)) { [weak self] in self?.change { $0.scope = .workspace(workspace) } })
            }
        }
        menu.addItem(.separator())
        menu.addItem(SearchMenuItem("Choose Conversation…", on: false) { [weak self] in
            self?.owner?.chooseSearchTarget(kind: .channel) { candidate in self?.change { $0.scope = .conversation(candidate.serverID) } }
        })
        return menu
    }

    private func authorMenu(_ session: AccountSession) -> NSMenu {
        let menu = NSMenu(title: "From")
        menu.addItem(SearchMenuItem("Anyone", on: criteria.author == nil) { [weak self] in self?.change { $0.author = nil } })
        menu.addItem(SearchMenuItem("Me", on: criteria.author == session.account.user) { [weak self] in self?.change { $0.author = session.account.user } })
        let people = HomePeople.rank(sent: session.home.snapshot.sent.value ?? [], channels: session.channels, me: session.account.user, now: Date(), limit: 6)
        if !people.isEmpty { menu.addItem(.separator()) }
        for user in people {
            menu.addItem(SearchMenuItem(session.userNames[user] ?? user, on: criteria.author == user) { [weak self] in self?.change { $0.author = user } })
        }
        if let author = criteria.author, author != session.account.user, !people.contains(author) {
            menu.addItem(SearchMenuItem(session.userNames[author] ?? author, on: true) {})
        }
        menu.addItem(.separator())
        menu.addItem(SearchMenuItem("Choose Person…", on: false) { [weak self] in
            self?.owner?.chooseSearchTarget(kind: .person) { candidate in self?.change { $0.author = candidate.serverID } }
        })
        return menu
    }

    private func dateMenu() -> NSMenu {
        let menu = NSMenu(title: "Date")
        let calendar = serverCalendar
        let now = Date()
        func add(_ range: SearchDateRange?) {
            menu.addItem(SearchMenuItem(range.map { Self.dateTitle($0) } ?? "Any Time", on: criteria.date == range) { [weak self] in self?.change { $0.date = range } })
        }
        add(nil)
        menu.addItem(.separator())
        for range in [SearchDateRange.today, .yesterday, .lastDays(7), .lastDays(30)] { add(range) }
        menu.addItem(.separator())
        var month = SearchDateRange.monthContaining(now, calendar: calendar)
        for _ in 0..<12 {
            add(month)
            guard let earlier = month.steppingMonth(by: -1) else { break }
            month = earlier
        }
        menu.addItem(.separator())
        let year = calendar.component(.year, from: now)
        add(.year(year)); add(.year(year - 1))
        if case .month = criteria.date, !menu.items.contains(where: { $0.state == .on }) { add(criteria.date) }
        if case .year = criteria.date, !menu.items.contains(where: { $0.state == .on }) { add(criteria.date) }
        return menu
    }

    private func hasMenu() -> NSMenu {
        let menu = NSMenu(title: "Has")
        func add(_ title: String, kind: SearchCriteria.Kind, attribute: SearchCriteria.Attribute?) {
            menu.addItem(SearchMenuItem(title, on: hasTitle == title) { [weak self] in self?.change { $0.kind = kind; $0.attribute = attribute } })
        }
        add("Anything", kind: .all, attribute: nil)
        menu.addItem(.separator())
        add("Text Only", kind: .text, attribute: nil)
        add("Polls", kind: .polls, attribute: nil)
        add("Reactions", kind: .all, attribute: .reactions)
        add("Started a Thread", kind: .all, attribute: .thread)
        return menu
    }

    private func fileTypeMenu() -> NSMenu {
        let menu = NSMenu(title: "Type")
        menu.addItem(SearchMenuItem("All Files", on: criteria.kind != .images) { [weak self] in self?.change { $0.kind = .files } })
        menu.addItem(SearchMenuItem("Images", on: criteria.kind == .images) { [weak self] in self?.change { $0.kind = .images } })
        return menu
    }

    var serverCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: owner?.session?.account.timezone ?? "UTC") ?? .gmt
        return calendar
    }

    static func dateTitle(_ range: SearchDateRange) -> String {
        switch range {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .lastDays(let days): return "Last \(days) Days"
        case .month(let year, let month):
            var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = 15
            let calendar = Calendar(identifier: .gregorian)
            guard let date = calendar.date(from: parts) else { return "\(year)-\(month)" }
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.setLocalizedDateFormatFromTemplate("MMMM y")
            return formatter.string(from: date)
        case .year(let year): return String(year)
        }
    }

    // MARK: Rows

    func reload() {
        guard let owner, let session = owner.session else { items = []; table.reloadData(); return }
        let selectedKey = table.selectedRow >= 0 && items.indices.contains(table.selectedRow) ? items[table.selectedRow].key : nil
        let results = feed.results
        switch tab {
        case .messages: items = (results.messages.value ?? []).isEmpty ? [] : SearchResultLayout.rows(results.messages.value ?? [], order: order, expanded: expanded).map(Self.item)
        case .files: items = (results.files.value ?? []).isEmpty ? [] : SearchResultLayout.rows(results.files.value ?? [], order: order, expanded: expanded).map(Self.item)
        case .links: items = (results.links.value ?? []).map(Item.link)
        case .conversations: items = Self.conversations(criteria.query, session: session, limit: 100).map(Item.channel)
        case .people: items = SearchTopHits.people(criteria.query, names: session.userNames, limit: 100).map(Item.person)
        }
        table.reloadData()
        if let selectedKey, let row = items.firstIndex(where: { $0.key == selectedKey }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        noteSelection()
        updateTabLabels(session)
        updateEmptyState(session)
        updateFooter()
        reloadSide()
    }

    private static func item(_ row: SearchResultLayout.Row) -> Item {
        switch row {
        case .conversation(let id, let count): .conversation(id: id, count: count)
        case .hit(let hit): .hit(hit)
        case .more(let id, let hidden): .more(conversationID: id, hidden: hidden)
        }
    }

    /// Conversations named like `query` that the reader can still open.
    static func conversations(_ query: String, session: AccountSession, limit: Int) -> [RavenChannel] {
        SearchTopHits.conversations(query, channels: session.channels.filter { !session.revokedChannels.contains($0.id) }, limit: limit)
    }

    private func updateTabLabels(_ session: AccountSession) {
        let results = feed.results
        func count<T>(_ part: SearchFeed.Part<[T]>, cap: Int) -> String {
            guard let value = part.value else { return "" }
            return value.count >= cap ? " \(cap)+" : " \(value.count)"
        }
        let query = criteria.query
        let labels: [SearchTab: String] = [
            .messages: count(results.messages, cap: SearchFeed.serverLimit),
            .files: count(results.files, cap: SearchFeed.serverLimit),
            .links: count(results.links, cap: SearchFeed.linkPageSize),
            .conversations: query.isEmpty ? "" : " \(Self.conversations(query, session: session, limit: 100).count)",
            .people: query.isEmpty ? "" : " \(SearchTopHits.people(query, names: session.userNames, limit: 100).count)"
        ]
        for (index, tab) in SearchTab.allCases.enumerated() {
            tabs.setLabel(tab.title + (isCompact ? "" : labels[tab] ?? ""), forSegment: index)
        }
    }

    private func updateEmptyState(_ session: AccountSession) {
        emptyHandler = nil
        emptyAction.isHidden = true
        let part: SearchFeed.Part<Int>? = switch tab {
        case .messages: feed.results.messages.map(\.count)
        case .files: feed.results.files.map(\.count)
        case .links: feed.results.links.map(\.count)
        default: nil
        }
        defer { emptyState.isHidden = !items.isEmpty; tableScroll.isHidden = items.isEmpty }
        guard items.isEmpty else { return }
        let account = session.account.displayName.isEmpty ? session.account.user : session.account.displayName
        if criteria.query.isEmpty, !SearchFeed.listsWithoutQuery(criteria, tab: tab) {
            emptyTitle.stringValue = "Search \(account)"
            emptyDetail.stringValue = tab == .conversations || tab == .people ? "Type a name to find conversations and people." : "Type in the search field to find messages, files and links. Filters narrow the results."
            return
        }
        if feed.results.pendingIndexTabs.contains(tab) {
            emptyTitle.stringValue = "Searching…"
            emptyDetail.stringValue = ""
            return
        }
        switch part {
        case .loading?, .idle?:
            emptyTitle.stringValue = "Searching…"
            emptyDetail.stringValue = ""
        case .failed(let message)?:
            emptyTitle.stringValue = "Search is not available"
            emptyDetail.stringValue = message
        default:
            emptyTitle.stringValue = criteria.query.isEmpty ? "Nothing here yet" : "No \(tab.title.lowercased()) match “\(criteria.query)”"
            emptyDetail.stringValue = "Try fewer or different words, or remove a filter. New messages can take a few minutes to become searchable."
            if criteria.scope != .account {
                emptyAction.title = "Search Everywhere"
                emptyAction.isHidden = false
                emptyHandler = { [weak self] in self?.change { $0.scope = .account } }
            }
        }
    }

    @objc private func emptyActionPressed() { emptyHandler?() }

    private func updateFooter() {
        let results = feed.results
        var parts: [String] = []
        var buttons: [NSView] = []
        let list: SearchFeed.Part<[SearchHit]>? = tab == .messages ? results.messages : tab == .files ? results.files : nil
        if let list {
            if list.isLoading { parts.append("Searching…") }
            else if results.pendingIndexTabs.contains(tab) { parts.append("Searching the server…") }
            else if let error = results.indexErrors[tab], list.value?.isEmpty == false {
                parts.append("The server search failed (\(error)). Showing available matches, which may be incomplete.")
            } else if owner?.session?.demo == true, !criteria.query.isEmpty {
                parts.append("The demo searches the messages saved on this Mac.")
            } else if let serverCount = results.serverHits[tab], serverCount >= SearchFeed.serverLimit {
                parts.append("Showing the \(SearchFeed.serverLimit) best matches.")
            }
            if results.cacheOnly.contains(tab) {
                parts.append("Includes matches saved on this Mac that the server's search did not find.")
            }
            if let note = results.threadNote, criteria.includeThreads { parts.append(note) }
            if case .month = criteria.date {
                if let earlier = criteria.date?.steppingMonth(by: -1) {
                    buttons.append(SearchFooterButton("‹ " + Self.dateTitle(earlier), help: "Search the month before") { [weak self] in self?.change { $0.date = earlier } })
                }
                let now = SearchDateRange.monthContaining(Date(), calendar: serverCalendar)
                if let later = criteria.date?.steppingMonth(by: 1), criteria.date != now {
                    buttons.append(SearchFooterButton(Self.dateTitle(later) + " ›", help: "Search the month after") { [weak self] in self?.change { $0.date = later } })
                }
            } else if criteria.date == nil, (results.serverHits[tab] ?? 0) >= SearchFeed.serverLimit {
                buttons.append(SearchFooterButton("Search Month by Month", help: "Each month returns up to \(SearchFeed.serverLimit) matches, so older ones appear") { [weak self] in
                    guard let self else { return }
                    let month = SearchDateRange.monthContaining(Date(), calendar: self.serverCalendar)
                    self.change { $0.date = month }
                })
            }
        } else if tab == .links, let rows = results.links.value, rows.count >= SearchFeed.linkPageSize {
            parts.append("Showing the newest \(SearchFeed.linkPageSize) links. Add words or filters to narrow them.")
        } else if tab == .links, results.links.isLoading {
            parts.append("Searching…")
        }
        if !attachments.status.isEmpty { parts.insert(attachments.status, at: 0) }
        status.stringValue = parts.joined(separator: " ")
        status.textColor = results.indexErrors[tab] != nil ? .themeAlert : .themeSecondaryText
        // The preview affordance stays ahead of the footer buttons, which a
        // reload replaces.
        for arranged in footerButtons.arrangedSubviews where arranged !== previewButton {
            footerButtons.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for view in buttons { footerButtons.addArrangedSubview(view) }
        updatePreviewAffordance()
    }

    /// The compact preview affordance follows the selected result and the
    /// side column's visibility.
    private func updatePreviewAffordance() {
        let visible = selectedHit != nil && !showsSideColumn
        previewButton.isHidden = !visible
        previewButton.isEnabled = visible
    }

    private var selectedHit: SearchHit? {
        if case .hit(let hit)? = selectedItem { return hit }
        return nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { guard items.indices.contains(row), case .conversation = items[row] else { return false }; return true }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items.indices.contains(row) && items[row].isSelectable }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 30 }
        switch items[row] {
        case .conversation: return 34
        case .more: return 28
        case .hit(let hit): return hit.isFile ? (hit.snippet.text.isEmpty ? 50 : 66) : 62
        case .link: return 62
        case .channel, .person: return 48
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let owner, let session = owner.session else { return nil }
        let cells = SearchCells(owner: owner, session: session, flat: order == .newest)
        switch items[row] {
        case .conversation(let id, let count): return cells.heading(conversationID: id, count: count)
        case .more(let id, let hidden):
            return cells.more(hidden: hidden) { [weak self] in self?.expanded.insert(id); self?.reload() }
        case .hit(let hit): return cells.hit(hit)
        case .link(let row): return cells.link(row)
        case .channel(let channel): return cells.channel(channel)
        case .person(let user): return cells.person(user)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SearchRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        noteSelection()
        reloadSide()
    }

    /// A reload selects the same result again; only a different one, or
    /// none, stops a download or closes its Quick Look.
    private func noteSelection() {
        let key = selectedItem?.key
        guard key != selectionKey else { return }
        selectionKey = key
        attachments.cancel()
        // A different result invalidates the compact preview; the wide
        // column follows the selection in reloadSide().
        if !showsSideColumn { closeCompactPreview() }
        updatePreviewAffordance()
    }
    private var selectionKey: String?

    var selectedItem: Item? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    @objc func openSelected() {
        guard let owner, let item = selectedItem ?? (table.clickedRow >= 0 && items.indices.contains(table.clickedRow) ? items[table.clickedRow] : nil) else { return }
        switch item {
        case .hit(let hit): owner.openSearchResult(channelID: hit.channelID, messageID: hit.id, parentID: hit.isThreadReply ? hit.conversationID : nil)
        case .link(let row): owner.openSearchResult(channelID: row["channel_id"].string, messageID: row["message_id"].string, parentID: row["parent_channel_id"].string)
        case .channel(let channel): owner.openSearchResult(channelID: channel.id, messageID: nil, parentID: nil)
        case .person(let user): owner.openDirectMessage(with: user)
        case .more(let id, _): expanded.insert(id); reload()
        case .conversation: break
        }
    }

    func quickLookSelected() {
        guard case .hit(let hit)? = selectedItem, hit.isFile, let owner, let session = owner.session else { return }
        attachments.read(hit, session: session, owner: owner, save: false) { [weak self] in self?.selectedHitID == hit.id && self?.isHidden == false }
    }

    func saveSelectedFile() {
        guard case .hit(let hit)? = selectedItem, hit.isFile, let owner, let session = owner.session else { return }
        attachments.read(hit, session: session, owner: owner, save: true) { [weak self] in self?.selectedHitID == hit.id && self?.isHidden == false }
    }

    private var selectedHitID: String? { if case .hit(let hit)? = selectedItem { return hit.id }; return nil }

    private func contextMenu(row: Int) -> NSMenu? {
        guard items.indices.contains(row) else { return nil }
        let menu = NSMenu(title: "Result")
        switch items[row] {
        case .hit(let hit):
            menu.addItem(SearchMenuItem("Open in Conversation", on: false) { [weak self] in self?.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self?.openSelected() })
            if hit.isFile {
                menu.addItem(SearchMenuItem("Quick Look", on: false) { [weak self] in self?.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self?.quickLookSelected() })
                menu.addItem(SearchMenuItem("Save As…", on: false) { [weak self] in self?.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self?.saveSelectedFile() })
            }
            menu.addItem(SearchMenuItem("Copy Link", on: false) { [weak self] in self?.owner?.copySearchResultLink(messageID: hit.id) })
            menu.addItem(.separator())
            menu.addItem(SearchMenuItem("Search in This Conversation", on: false) { [weak self] in self?.change { $0.scope = .conversation(hit.conversationID) } })
            if !hit.authorID.isEmpty {
                menu.addItem(SearchMenuItem("Messages from This Person", on: false) { [weak self] in self?.change { $0.author = hit.authorID } })
            }
        case .link(let row):
            menu.addItem(SearchMenuItem("Open in Conversation", on: false) { [weak self] in self?.owner?.openSearchResult(channelID: row["channel_id"].string, messageID: row["message_id"].string, parentID: row["parent_channel_id"].string) })
        case .person(let user):
            menu.addItem(SearchMenuItem("Messages from This Person", on: false) { [weak self] in self?.select(tab: .messages); self?.change { $0.author = user } })
        default: return nil
        }
        return menu
    }

    // MARK: Side column

    func reloadSide() {
        if !showsSideColumn {
            if compactPreviewPopover?.isShown == true, selectedHitID == nil { closeCompactPreview() }
            updatePreviewAffordance()
            return
        }
        guard let owner, let session = owner.session else { return }
        previewTask?.cancel()
        switch selectedItem {
        case .hit(let hit)?:
            if let cached = cachedPreview(hit.id) { side.showPreview(hit, context: cached, loading: false); return }
            side.showPreview(hit, context: [], loading: true)
            previewTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                let context = await Self.context(for: hit, session: session)
                guard !Task.isCancelled, self.selectedHitID == hit.id else { return }
                self.cachePreview(context, for: hit.id)
                self.side.showPreview(hit, context: context, loading: false)
            }
        default:
            side.showTopHits(query: criteria.query, session: session, saved: SavedSearchStore.load(session.account.id), current: criteria)
        }
    }

    // MARK: Compact preview

    var showsCompactPreview: Bool { compactPreviewPopover?.isShown == true }

    @objc private func toggleCompactPreview() {
        if compactPreviewPopover?.isShown == true { closeCompactPreview() } else { openCompactPreview() }
    }

    /// Esc closes the compact preview first, then leaves search.
    private func cancelSearchOrPreview() {
        if compactPreviewPopover?.isShown == true { closeCompactPreview() } else { owner?.leaveSearch() }
    }

    /// Opens the selected result's context in a popover, using the same
    /// messages and actions as the wide side column.
    private func openCompactPreview() {
        guard !showsSideColumn, let hit = selectedHit, let owner, let session = owner.session,
              compactPreviewPopover?.isShown != true else { return }
        previewTask?.cancel()
        let content = SearchCompactPreviewView()
        content.onOpen = { [weak self] in self?.closeCompactPreview(); self?.openSelected() }
        content.onQuickLook = { [weak self] in self?.quickLookSelected() }
        content.onCopyLink = { [weak self] in self?.owner?.copySearchResultLink(messageID: hit.id) }
        content.onClose = { [weak self] in self?.closeCompactPreview() }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        let width = min(Self.compactPreviewWidth, max(300, bounds.width - 24))
        let height = min(520, max(240, bounds.height - 60))
        let size = NSSize(width: width, height: height)
        popover.contentSize = size
        controller.preferredContentSize = size
        let cached = cachedPreview(hit.id)
        content.show(hit, context: cached ?? [], loading: cached == nil, owner: owner, session: session, size: size)
        popover.show(relativeTo: previewButton.bounds, of: previewButton, preferredEdge: .minY)
        compactPreviewPopover = popover
        compactPreviewView = content
        // The preview takes key focus so Escape dismisses it, not the search.
        content.window?.makeKey()
        content.window?.makeFirstResponder(content)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.selectedHitID == hit.id, self.compactPreviewPopover === popover else { return }
            let context = await Self.context(for: hit, session: session)
            guard !Task.isCancelled, self.selectedHitID == hit.id, self.compactPreviewPopover === popover else { return }
            self.cachePreview(context, for: hit.id)
            content.show(hit, context: context, loading: false, owner: owner, session: session, size: size)
        }
    }

    private func closeCompactPreview() {
        guard let popover = compactPreviewPopover else { return }
        let wasShown = popover.isShown
        previewTask?.cancel()
        if wasShown { popover.close() }
        compactPreviewPopover = nil
        compactPreviewView = nil
        // The selection never moved; put the focus back on the results.
        if wasShown { window?.makeFirstResponder(table) }
    }

    /// A few messages around a hit. The cache answers when it has the
    /// message; otherwise one history read that does not move the read
    /// position.
    private static func context(for hit: SearchHit, session: AccountSession) async -> [RavenMessage] {
        if let cached = try? await session.cachedMessages(channelID: hit.channelID, limit: 1500), let index = cached.firstIndex(where: { $0.id == hit.id }) {
            return Array(cached[max(0, index - 3)..<min(cached.count, index + 3)])
        }
        guard !session.demo, !session.stopped else { return [] }
        let arguments: [String: JSONValue] = ["channel_id": .string(hit.channelID), "base_message": .string(hit.id), "limit": .number(6), "update_last_visit": .bool(false)]
        guard let response = try? await session.client.rpc("raven.api.chat_stream.get_messages", arguments: arguments) else { return [] }
        return response["messages"].array.map(RavenMessage.init(raw:)).filter { $0.channelID == hit.channelID && !session.deletedIDs.contains($0.id) }.sorted { $0.creation < $1.creation }
    }

    func apply(saved: SavedSearch) {
        owner?.search.stringValue = saved.criteria.query
        let next = saved.criteria
        apply(next, tab: next.tab, immediately: true)
    }

    func saveCurrentSearch() {
        guard let owner, let session = owner.session, let window = owner.window else { return }
        let criteria = self.criteria
        Task { [weak self] in
            guard let title = await SheetPrompt.text("Save Search", message: "Saved searches stay on this Mac.", placeholder: "Search name", value: String(criteria.query.prefix(80)), confirm: "Save", on: window),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self != nil, owner.isCurrent(session) else { return }
            do {
                var items = SavedSearchStore.load(session.account.id)
                items.append(SavedSearch(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), criteria: criteria))
                try SavedSearchStore.save(items, account: session.account.id)
            } catch { owner.app.showError(error) }
        }
    }

    func remove(saved: SavedSearch) {
        guard let session = owner?.session else { return }
        do { try SavedSearchStore.save(SavedSearchStore.load(session.account.id).filter { $0.id != saved.id }, account: session.account.id) }
        catch { owner?.app.showError(error) }
    }
}

// MARK: - Cells

/// Builds result rows in the theme's colors.
@MainActor struct SearchCells {
    let owner: ConversationWindow
    let session: AccountSession
    /// Newest First shows one list, so each hit names its conversation.
    let flat: Bool

    func heading(conversationID: String, count: Int) -> NSView {
        let channel = session.channels.first { $0.id == conversationID }
        let title = channel.map { $0.isDM ? $0.title : "# " + $0.title } ?? "Conversation"
        let label = HomeText.label(title, font: .systemFont(ofSize: 12, weight: .bold), color: .themeSecondaryText)
        let detail = HomeText.label(count == 1 ? "1 result" : "\(count) results", font: .systemFont(ofSize: 11), color: .themeTertiaryText)
        var views: [NSView] = [label]
        if let workspace = channel?.workspace, !workspace.isEmpty, channel?.isDM == false { views.append(HomeText.label(workspace, font: .systemFont(ofSize: 11), color: .themeTertiaryText)) }
        views += [NSView(), detail]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 2, right: 12)
        let cell = SearchCell(content: stack)
        cell.setAccessibilityLabel("\(title), \(detail.stringValue)")
        cell.setAccessibilityRole(.staticText)
        return cell
    }

    func more(hidden: Int, action: @escaping () -> Void) -> NSView {
        let button = HomeLinkButton("Show \(hidden) more", action: action)
        let stack = NSStackView(views: [button])
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 54, bottom: 4, right: 12)
        return SearchCell(content: stack)
    }

    func hit(_ hit: SearchHit) -> NSView {
        let author = name(hit.authorID)
        let avatar = HomeAvatar(size: 32, shape: .circle)
        if !hit.authorID.isEmpty { session.loadAvatars([hit.authorID]); avatar.image = session.avatarImage(for: hit.authorID) }
        avatar.symbol = "person.crop.circle"
        let header = NSMutableAttributedString(string: author, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.themeText])
        var place: [String] = []
        if flat { place.append(conversationTitle(hit.conversationID)) }
        if hit.isThreadReply { place.append("in a thread") }
        if !place.isEmpty { header.append(NSAttributedString(string: "  " + place.joined(separator: " · "), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.themeSecondaryText])) }
        let title = NSTextField(labelWithAttributedString: header)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let time = HomeText.label(when(hit.creation), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .themeTertiaryText)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        var badges: [NSView] = []
        func badge(_ symbol: String, _ description: String) {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
            icon.contentTintColor = .themeTertiaryText
            icon.toolTip = description
            badges.append(icon)
        }
        if hit.hasReactions { badge("face.smiling", "Has reactions") }
        if hit.startsThread { badge("bubble.left.and.bubble.right", "Started a thread") }
        if hit.isSaved { badge("bookmark.fill", "Saved") }
        let top = NSStackView(views: [title] + badges + [NSView(), time])
        top.orientation = .horizontal
        top.spacing = 6
        var lines: [NSView] = [top]
        if let file = hit.fileName {
            let icon = HomeFileIcon(filename: file.text)
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let size = hit.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let name = NSTextField(labelWithAttributedString: SearchText.highlighted(file, size: 12.5, color: .themeText, suffix: size))
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, name])
            row.spacing = 5
            lines.append(row)
        }
        if !hit.snippet.text.isEmpty {
            let text = NSTextField(wrappingLabelWithString: "")
            // A click selects the row; an I-beam would promise text selection.
            text.isSelectable = false
            text.attributedStringValue = SearchText.highlighted(hit.snippet, size: 12.5, color: .themeSecondaryText)
            text.maximumNumberOfLines = hit.fileName == nil ? 2 : 1
            text.lineBreakMode = .byWordWrapping
            text.cell?.truncatesLastVisibleLine = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            lines.append(text)
        }
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        for line in lines { line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let stack = NSStackView(views: [avatar, column])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        let cell = SearchCell(content: stack)
        var spoken = [author, flat || hit.isThreadReply ? place.joined(separator: ", ") : "", whenSpoken(hit.creation), hit.fileName?.text ?? "", hit.snippet.text]
        if hit.hasReactions { spoken.append("has reactions") }
        if hit.startsThread { spoken.append("started a thread") }
        if hit.isSaved { spoken.append("saved") }
        let matches = Set(hit.snippet.highlights.compactMap { SearchText.substring(hit.snippet.text, $0)?.lowercased() })
        if !matches.isEmpty { spoken.append("matches " + matches.sorted().joined(separator: ", ")) }
        cell.setAccessibilityLabel(spoken.filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }

    func link(_ row: JSONValue) -> NSView {
        // Raven extracts links before it masks spoiler text, so a message
        // with a spoiler may have its hidden link here: show neither the
        // link nor its preview, as `LinkSearch.preview` does.
        let content = row["content"].string ?? ""
        let spoiler = content.contains("▒▒▒▒▒▒") || content.contains("[Spoiler]")
        let url = row["url"].string ?? ""
        let host = spoiler ? "" : URL(string: url)?.host ?? url
        let title = spoiler ? "A link in a message with hidden spoiler text" : [row["title"].string, row["site_name"].string, host].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Link"
        let author = name(row["author"].string ?? row["owner"].string ?? "")
        let detail = [host, author, conversationTitle(row["parent_channel_id"].string ?? row["channel_id"].string ?? "")].filter { !$0.isEmpty }.joined(separator: " · ")
        let homeRow = HomeRow(icon: HomeSymbol("link"), title: HomeText.title(String(title.prefix(200))), detail: HomeText.detail(detail), trailing: when(row["creation"].string ?? ""))
        homeRow.setAccessibilityElement(false)
        let cell = SearchCell(content: homeRow, inset: 4)
        cell.setAccessibilityLabel([title, detail, whenSpoken(row["creation"].string ?? "")].filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }

    func channel(_ channel: RavenChannel) -> NSView {
        let avatar = HomeAvatar(size: 28, shape: channel.isDM ? .circle : .tile)
        let peer = owner.sidebarAvatarUserID(for: channel)
        if let peer { session.loadAvatars([peer]) }
        avatar.image = peer.flatMap { session.avatarImage(for: $0) } ?? session.channelAvatarImage(for: channel)
        avatar.symbol = channel.isDM ? "person.crop.circle" : channel.raw["type"].string == "Private" ? "lock" : "number"
        var detail = channel.isDM ? "Direct message" : channel.workspace
        if channel.raw["is_archived"].bool { detail += detail.isEmpty ? "Archived" : " · Archived" }
        let row = HomeRow(icon: avatar, title: HomeText.title(channel.isDM ? channel.title : "# " + channel.title), detail: HomeText.detail(detail), trailing: nil)
        row.setAccessibilityElement(false)
        let cell = SearchCell(content: row, inset: 4)
        cell.setAccessibilityLabel("\(channel.title), \(detail)")
        return cell
    }

    func person(_ user: String) -> NSView {
        let avatar = HomeAvatar(size: 28, shape: .circle)
        session.loadAvatars([user])
        avatar.image = session.avatarImage(for: user)
        avatar.symbol = "person.crop.circle"
        avatar.presence = session.presenceDescription(for: user)
        let detail = [session.presenceDescription(for: user), user == session.account.user ? "You" : nil].compactMap { $0 }.joined(separator: " · ")
        let row = HomeRow(icon: avatar, title: HomeText.title(session.userNames[user] ?? user), detail: HomeText.detail(detail), trailing: nil)
        row.setAccessibilityElement(false)
        let cell = SearchCell(content: row, inset: 4)
        cell.setAccessibilityLabel("\(session.userNames[user] ?? user)\(detail.isEmpty ? "" : ", " + detail)")
        return cell
    }

    func name(_ user: String) -> String {
        if user.isEmpty { return "Unknown" }
        if user == session.account.user { return "You" }
        return session.userNames[user] ?? user
    }

    func conversationTitle(_ id: String) -> String {
        guard let channel = session.channels.first(where: { $0.id == id }) else { return "" }
        return channel.isDM ? channel.title : "# " + channel.title
    }

    /// "13:32" today, "Fri" in the last six days, "12 Nov" this year,
    /// "12 Nov 2025" before.
    func when(_ raw: String) -> String {
        guard let date = session.messageDate(raw) else { return "" }
        let calendar = session.displayCalendar
        if calendar.isDateInToday(date) { return session.displayTime(raw) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(days < 7 && days > 0 ? "EEE" : sameYear ? "d MMM" : "d MMM y")
        return formatter.string(from: date)
    }

    func whenSpoken(_ raw: String) -> String {
        guard let date = session.messageDate(raw) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = session.displayCalendar
        formatter.timeZone = session.displayCalendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

/// Snippet text with its matches marked by weight and a soft accent
/// background, never by color alone.
@MainActor enum SearchText {
    static func highlighted(_ snippet: SearchSnippet, size: CGFloat, color: NSColor, suffix: String = "") -> NSAttributedString {
        let text = NSMutableAttributedString(string: snippet.text + suffix, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        let length = (snippet.text as NSString).length
        for range in snippet.highlights where range.upperBound <= length {
            text.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.themeText, .backgroundColor: NSColor.themeAccent.withAlphaComponent(0.22)], range: NSRange(location: range.lowerBound, length: range.count))
        }
        return text
    }

    static func substring(_ text: String, _ range: Range<Int>) -> String? {
        let ns = text as NSString
        guard range.upperBound <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }
}

/// A row's content view, inset from the row edges.
@MainActor final class SearchCell: NSTableCellView {
    init(content: NSView, inset: CGFloat = 0) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Rounded selection in the accent color, as the sidebar draws it.
@MainActor class SearchRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        (isEmphasized ? NSColor.themeAccent.withAlphaComponent(0.28) : NSColor.themeText.withAlphaComponent(0.10)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
    /// Group rows draw no bar: the heading's type carries it.
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// The results list's keys: Return opens, Space is Quick Look, Escape
/// leaves search, and Up from the first row returns to the search field.
@MainActor final class SearchResultsTable: NSTableView, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusField: (() -> Void)?
    var onTogglePreview: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 1, flags == [.command, .shift] { onSave?(); return }
        if flags == [.command], event.charactersIgnoringModifiers == "l" { onTogglePreview?(); return }
        guard flags.isEmpty || event.keyCode == 126 else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 49: onQuickLook?()
        case 53: onCancel?()
        case 126 where selectedRow <= firstSelectableRow:
            onFocusField?()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private var firstSelectableRow: Int {
        (0..<numberOfRows).first { delegate?.tableView?(self, shouldSelectRow: $0) ?? true } ?? 0
    }

    /// Selects the first result, for moving down from the search field.
    func focusFirstResult() -> Bool {
        guard numberOfRows > 0 else { return false }
        if selectedRow < 0 { selectRowIndexes(IndexSet(integer: firstSelectableRow), byExtendingSelection: false) }
        scrollRowToVisible(selectedRow)
        return window?.makeFirstResponder(self) ?? false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clickedRow >= 0, let built = menuProvider?(clickedRow) else { return }
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }
}

/// A filter: a glass button with a menu, or a toggle.
@MainActor final class SearchChip: NSButton {
    private var menuBuilder: (() -> NSMenu)?
    private var toggleHandler: (() -> Void)?

    init(title: String, active: Bool, menu: @escaping () -> NSMenu) {
        menuBuilder = menu
        super.init(frame: .zero)
        configure(title: title + " ▾", active: active)
        setAccessibilityLabel(title)
        setAccessibilityRole(.popUpButton)
    }

    init(toggle title: String, on: Bool, handler: @escaping () -> Void) {
        toggleHandler = handler
        super.init(frame: .zero)
        configure(title: (on ? "✓ " : "") + title, active: on)
        setAccessibilityLabel(title)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(on ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(title: String, active: Bool) {
        bezelStyle = .glass
        controlSize = .small
        self.title = title
        if active { bezelColor = .themeAccent.withAlphaComponent(0.45) }
        target = self
        action = #selector(press)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func press() {
        if let toggleHandler { toggleHandler(); return }
        guard let menu = menuBuilder?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// A menu item that runs a closure.
@MainActor final class SearchMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, on: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// A small glass button in the footer.
@MainActor final class SearchFooterButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, help: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .glass
        controlSize = .small
        toolTip = help
        target = self
        action = #selector(press)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func press() { handler() }
}
