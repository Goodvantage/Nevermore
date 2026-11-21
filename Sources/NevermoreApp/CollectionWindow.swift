import AppKit
import RavenProtocol
import NevermoreCore

@MainActor final class CollectionWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate {
    /// `messages` is a fixed list of messages (pinned messages, a
    /// conversation's files) whose rows open the message.
    enum Kind: Equatable { case messages, inbox, threads, saved, reminders, scheduled }
    /// The reminder actions, in menu order. Complete is inserted only for a
    /// fired, unread reminder; the others are always retained.
    private enum ReminderAction {
        case complete, snooze, editTime, delete
        var title: String {
            switch self {
            case .complete: return "Mark Complete"
            case .snooze: return "Snooze…"
            case .editTime: return "Edit Time…"
            case .delete: return "Delete Reminder"
            }
        }
    }
    weak var conversationOwner: ConversationWindow?
    let session: AccountSession?
    /// The rows currently shown (the filtered view of `pager.records`).
    var records: [JSONValue]
    let kind: Kind
    /// Optional verified server source for refresh and pagination. `nil` keeps
    /// the window static on the records it was opened with. Root wires this.
    let source: CollectionSource?
    var pager: CollectionPager
    let table = CollectionTableView()
    let search = NSSearchField()
    let status = NSTextField(labelWithString: "")
    private let emptyState = NSTextField(labelWithString: "No Items")
    /// Shown instead of "No Items" when the collection is empty for a known reason.
    var emptyMessage: String?
    private static let searchItem = NSToolbarItem.Identifier("collectionSearch")
    private static let refreshItem = NSToolbarItem.Identifier("collectionRefresh")
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let moreButton = NSButton(title: "Load More", target: nil, action: nil)
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let manageButton = NSButton(title: "Actions…", target: nil, action: nil)
    let markReadButton = NSButton(title: "Mark Selected Read", target: nil, action: nil)
    let markAllButton = NSButton(title: "Mark All Read", target: nil, action: nil)
    let batchTransport: CollectionBatchActions.Transport?
    var batchTask: Task<Void, Never>?
    var batchGeneration = UUID()
    var isBatchRunning = false
    var batchIsMarkAll = false
    var loadTask: Task<Void, Never>?
    private(set) var isClosed = false
    var isLoading = false
    var statusMessage = ""
    var active: Bool {
        guard let session, let owner = conversationOwner else { return false }
        return !isClosed && owner.isCurrent(session)
    }
    init(owner: ConversationWindow, title: String, records: [JSONValue], kind: Kind, source: CollectionSource? = nil, batchTransport: CollectionBatchActions.Transport? = nil) {
        self.batchTransport = owner.session?.demo == true ? batchTransport : nil
        self.conversationOwner = owner; self.session = owner.session; self.kind = kind; self.source = source
        self.pager = CollectionPager(records: records, pageSize: source?.pageSize ?? CollectionSource.defaultPageSize)
        self.records = pager.records
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = title; window.subtitle = owner.session.map { $0.account.displayName.isEmpty ? $0.account.user : $0.account.displayName } ?? ""
        window.minSize = NSSize(width: 520, height: 300); window.center(); window.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.title = "Results"; table.addTableColumn(column)
        table.headerView = nil; table.style = .inset; table.rowHeight = 44; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(open)
        table.onOpen = { [weak self] in self?.open() }; table.onClose = { [weak self] in self?.cancelFilterOrClose() }; table.onRefresh = { [weak self] in self?.refresh() }
        table.allowsMultipleSelection = kind == .inbox
        table.canRefresh = source != nil
        table.setAccessibilityLabel("Collection results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        openButton.target = self; openButton.action = #selector(open); openButton.setAccessibilityLabel("Open selected result"); openButton.toolTip = "Show the selected item in its conversation window (Return). Option-click opens a new window."
        manageButton.target = self; manageButton.action = #selector(manage); manageButton.setAccessibilityLabel("Actions for selected result")
        markReadButton.target = self; markReadButton.action = #selector(markSelectedRead)
        markReadButton.setAccessibilityLabel("Mark selected inbox notifications read")
        markReadButton.toolTip = "Select up to 100 inbox items to mark their notifications read."
        markReadButton.isHidden = kind != .inbox
        markAllButton.target = self; markAllButton.action = #selector(markAllRead)
        markAllButton.setAccessibilityLabel("Mark all notifications for this account read")
        markAllButton.toolTip = "Marks every notification for this account as read, including rows hidden by the current filter or later pages."
        markAllButton.isHidden = kind != .inbox
        search.placeholderString = "Filter"
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        search.target = self; search.action = #selector(applySearch); search.delegate = self
        search.setAccessibilityLabel("Filter collection results")
        refreshButton.target = self; refreshButton.action = #selector(refresh); refreshButton.setAccessibilityLabel("Refresh collection")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh"); refreshButton.imagePosition = .imageOnly; refreshButton.bezelStyle = .toolbar; refreshButton.toolTip = "Refresh (⌘R)"
        moreButton.target = self; moreButton.action = #selector(loadMore); moreButton.setAccessibilityLabel("Load more results")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail; status.setAccessibilityLabel("Collection status")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyState.font = .preferredFont(forTextStyle: .title3); emptyState.textColor = .tertiaryLabelColor; emptyState.alignment = .center
        // Mail-style chrome: filter and refresh in the toolbar, actions in
        // one bottom bar with the status on its leading edge.
        // Separate identifiers: windows sharing one would sync item sets.
        let toolbar = NSToolbar(identifier: source == nil ? "NevermoreCollectionToolbar.static" : "NevermoreCollectionToolbar.refreshable"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar; window.toolbarStyle = .unified
        window.initialFirstResponder = table
        let bar = NSStackView(); bar.setViews([status], in: .leading); bar.setViews([moreButton, markAllButton, markReadButton, manageButton, openButton], in: .trailing); bar.spacing = 8
        for view in [scroll, bar, emptyState] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(view) }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), scroll.topAnchor.constraint(equalTo: window.contentView!.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10), bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), bar.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12), emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        updateChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    // MARK: Native keyboard dispatch
    /// Fallback for keys delivered while a text field is first responder. The
    /// table and search delegate normally consume these; this keeps Command-R
    /// working from the search field and plain Return/Escape working when no
    /// other responder handles them.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            guard flags.isEmpty else { super.keyDown(with: event); return }
            open(); return
        }
        if event.keyCode == 53 {
            guard flags.isEmpty else { super.keyDown(with: event); return }
            cancelFilterOrClose(); return
        }
        if event.keyCode == 15, flags == .command {
            guard source != nil else { super.keyDown(with: event); return }
            refresh(); return
        }
        super.keyDown(with: event)
    }
    private func hasMarkedText() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return (responder as? NSTextView)?.hasMarkedText() ?? false
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateChrome() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        let modifiers: NSEvent.ModifierFlags = {
            guard let current = NSApp.currentEvent, current.type == .keyDown else { return [] }
            return current.modifierFlags.intersection([.shift, .control, .option, .command])
        }()
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:":
            guard modifiers.isEmpty else { return false }
            open(); return true
        case "cancelOperation:":
            guard modifiers.isEmpty else { return false }
            if clearFilter(editor: textView) { return true }
            close(); return true
        default: return false
        }
    }
    override func showWindow(_ sender: Any?) {
        isClosed = false
        updateChrome()
        super.showWindow(sender)
        // Read-only initial fetch when wired with a source but no seed rows.
        if source != nil, records.isEmpty, !isLoading { refresh() }
    }
    func windowWillClose(_ notification: Notification) {
        // Delayed results must not repopulate a closed collection.
        batchGeneration = UUID(); batchTask?.cancel(); batchTask = nil; isBatchRunning = false; batchIsMarkAll = false
        isClosed = true; pager.invalidate(); loadTask?.cancel(); pager.records.removeAll(); records.removeAll(); table.reloadData()
        statusMessage = ""; isLoading = false
        conversationOwner?.collectionWindows.removeAll { $0 === self }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let html = record["text"].string ?? record["message_text"].string ?? ""
        let text = (try? RichTextCodec.plainText(RichTextCodec.parse(html))) ?? ""
        let value = text.isEmpty ? record["content"].string ?? record["message_content"].string ?? record["description"].string ?? record["name"].string ?? "Item" : text
        let cell = tableView.makeView(withIdentifier: CollectionRowCell.identifier, owner: self) as? CollectionRowCell ?? CollectionRowCell()
        cell.configure(title: String(value.prefix(220)).replacingOccurrences(of: "\n", with: " "), detail: detail(for: record))
        return cell
    }
    /// "#channel · when" for a row: the conversation's title rather than its
    /// opaque ID, and the scheduled, reminder or creation time when present.
    private func detail(for record: JSONValue) -> String {
        var parts: [String] = []
        if let channelID = record["channel_id"].string, !channelID.isEmpty {
            let channel = session?.channels.first { $0.id == channelID }
            parts.append(channel.map { $0.isDM ? $0.title : "#\($0.title)" } ?? channelID)
        }
        if let owner = record["owner"].string, let name = session?.userNames[owner] { parts.append(name) }
        if let time = record["scheduled_time"].string ?? record["remind_at"].string ?? record["creation"].string, let session { parts.append(session.displayTimestamp(time)) }
        return parts.joined(separator: " · ")
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { source == nil ? [.flexibleSpace, Self.searchItem] : [.flexibleSpace, Self.refreshItem, Self.searchItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.refreshItem, Self.searchItem] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.searchItem {
            let field = flag ? search : NSSearchField()
            if !flag { field.placeholderString = "Filter" }
            let item = GlassSearchToolbarItem(itemIdentifier: itemIdentifier, searchField: field, minimumWidth: 220); item.label = "Filter"
            return item
        }
        guard itemIdentifier == Self.refreshItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier); item.label = "Refresh"; item.view = refreshButton
        return item
    }
    // MARK: Local scoped filter (native search field)
    /// Escape from the field or the results: close only when no filter is
    /// populated, so every route enforces one policy.
    private func cancelFilterOrClose() {
        if !clearFilter(editor: search.currentEditor()) { close() }
    }

    /// Shared Escape policy for the field editor and the results. Returns
    /// true when a populated filter (committed value or live editor buffer)
    /// was cleared and the window stays open; the caller closes on false.
    /// The selection is captured before the rows are restored and matched
    /// afterwards by row ID, so an Inbox selection spanning several rows
    /// survives clearing its filter instead of following the moving indices.
    private func clearFilter(editor: NSText?) -> Bool {
        guard !search.stringValue.isEmpty || !(editor?.string.isEmpty ?? true) else { return false }
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { index in
            records.indices.contains(index) ? rowID(for: records[index]) : nil
        })
        search.stringValue = ""
        editor?.string = ""
        applySearch()
        restoreSelection(matching: selectedIDs)
        // Clearing the editor first keeps end-editing from committing the
        // stale buffer back into the field.
        window?.makeFirstResponder(table)
        return true
    }

    /// A notification's message can occur in multiple records. Restore
    /// selection only when the collection supplies the document's own ID.
    private func rowID(for record: JSONValue) -> String? {
        guard let id = record["name"].string, !id.isEmpty else { return nil }
        return id
    }

    /// Reselects the rows whose IDs were selected before a filter was cleared,
    /// wherever they now sit in the unfiltered list.
    private func restoreSelection(matching ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var restored = IndexSet()
        for (index, record) in records.enumerated() {
            guard let id = rowID(for: record), ids.contains(id) else { continue }
            restored.insert(index)
        }
        guard !restored.isEmpty else { return }
        table.selectRowIndexes(restored, byExtendingSelection: false)
        table.scrollRowToVisible(restored.first ?? 0)
    }
    @objc func applySearch() { applyFilter(); table.reloadData(); updateChrome() }
    @objc func findNext(_ sender: Any?) { moveResult(1) }
    @objc func findPrevious(_ sender: Any?) { moveResult(-1) }
    private func moveResult(_ delta: Int) {
        guard active, !records.isEmpty else { return }
        let selected = table.selectedRow
        let next = selected < 0 ? (delta > 0 ? 0 : records.count - 1) : (selected + delta + records.count) % records.count
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
        window?.makeFirstResponder(table)
    }
    func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { records = pager.records; return }
        let needle = query.lowercased()
        records = pager.records.filter { haystack($0).contains(needle) }
    }
    private func haystack(_ record: JSONValue) -> String {
        var parts: [String] = []
        for key in ["description","name","id","channel_id","parent_channel_id","channel_name","status","error","scheduled_time","remind_at","notification_type"] {
            if let value = record[key].string { parts.append(value) }
        }
        if let html = record["text"].string ?? record["message_text"].string { if let document = try? RichTextCodec.parse(html) { parts.append(RichTextCodec.plainText(document)) } }
        else { parts.append(record["content"].string ?? record["message_content"].string ?? "") }
        return parts.joined(separator: "\n").lowercased()
    }
    // MARK: Refresh / Load More (read-only RPCs)
    @objc func refresh() { _ = startRefresh() }

    /// Starts a refresh and returns the task performing it, so a mutation can
    /// await the canonical list state. Returns nil when no refresh can start.
    @discardableResult func startRefresh(onFreshRows: (@MainActor ([JSONValue]) -> Void)? = nil) -> Task<Void, Never>? {
        guard active, source != nil, !isLoading, !isBatchRunning else { return nil }
        isLoading = true; statusMessage = ""; updateChrome()
        loadTask?.cancel()
        let generation = pager.beginRefresh()
        let task = Task { [weak self] in
            guard let self, let session = self.session, let source = self.source else { return }
            do {
                let response = try await session.client.rpc(source.method, arguments: CollectionPaging.pageArguments(source, offset: 0))
                let rows = try CollectionPaging.decodeRows(response)
                if self.apply(rows: rows, generation: generation, refresh: true) {
                    onFreshRows?(rows)
                    if session.retainHistory { try? await session.store.cacheProjection(key: source.cacheKey, value: response) }
                    self.statusMessage = ""
                }
            } catch {
                if error is CancellationError || Task.isCancelled { self.isLoading = false; self.updateChrome(); return }
                // The error stays visible; a cached copy is used only when one
                // exists and is explicitly labeled incomplete.
                let denied = (error as? RavenError)?.isPermissionDenied == true
                if denied { try? await session.store.cacheProjection(key: source.cacheKey, value: .null) }
                let cached = session.retainHistory && !denied ? (try? await session.store.projection(key: source.cacheKey)).map(CollectionPaging.extractRows) ?? [] : []
                if self.apply(rows: cached, generation: generation, refresh: true) {
                    self.statusMessage = cached.isEmpty
                        ? "Refresh failed: \(error.localizedDescription)"
                        : "Refresh failed: \(error.localizedDescription) · showing cached results (incomplete)"
                } else {
                    self.statusMessage = "Refresh failed: \(error.localizedDescription)"
                }
            }
            self.isLoading = false; self.updateChrome()
        }
        loadTask = task
        return task
    }

    /// A mutation needs the rows from its own successful refresh. Rows from
    /// the offline cache and unrelated status updates cannot confirm a POST.
    private func freshRowsAfterMutation() async -> [JSONValue]? {
        if isLoading, let task = loadTask { await task.value }
        var freshRows: [JSONValue]?
        let task = startRefresh { freshRows = $0 }
        await task?.value
        return freshRows
    }
    @objc func loadMore() {
        guard active, let source, source.supportsPaging, pager.hasMore, !isLoading, !isBatchRunning else { return }
        isLoading = true; statusMessage = ""; updateChrome()
        let generation = pager.generation
        let offset = pager.nextOffset
        loadTask = Task { [weak self] in
            guard let self, let session = self.session, let source = self.source else { return }
            do {
                let response = try await session.client.rpc(source.method, arguments: CollectionPaging.pageArguments(source, offset: offset))
                if self.apply(rows: try CollectionPaging.decodeRows(response), generation: generation, refresh: false) { self.statusMessage = "" }
            } catch {
                if error is CancellationError || Task.isCancelled { self.isLoading = false; self.updateChrome(); return }
                // Loaded rows stay; the failure is shown instead of a silent short list.
                self.statusMessage = "Could not load more: \(error.localizedDescription)"
            }
            self.isLoading = false; self.updateChrome()
        }
    }
    /// Applies fetched rows only when the window is still open, still on the
    /// same account, and no newer refresh/invalidation superseded this page.
    @discardableResult func apply(rows: [JSONValue], generation: Int, refresh: Bool) -> Bool {
        guard let session, let owner = conversationOwner, owner.session === session, !session.stopped,
              !isClosed, !owner.isClosed, isWindowLoaded, window != nil, pager.generation == generation else { return false }
        var filtered = rows
        filtered.removeAll { session.revokedChannels.contains($0["channel_id"].string ?? "") || session.revokedChannels.contains($0["parent_channel_id"].string ?? "") }
        let oldOffset = refresh ? 0 : pager.nextOffset
        let applied = refresh ? pager.applyRefresh(filtered, generation: generation) : pager.applyAppend(filtered, generation: generation)
        if applied { pager.nextOffset = oldOffset + rows.count; pager.hasMore = CollectionPaging.hasMore(received: rows.count, pageSize: pager.pageSize) }
        guard applied else { return false }
        applyFilter(); table.reloadData(); updateChrome()
        return true
    }
    func restrictRevoked() {
        guard let session else { return }
        let revoked = session.revokedChannels
        pager.records.removeAll { revoked.contains($0["channel_id"].string ?? "") || revoked.contains($0["parent_channel_id"].string ?? "") }
        applyFilter(); table.reloadData(); updateChrome()
    }
    func updateChrome() {
        let total = pager.records.count
        let hasSelection = active && selected != nil && !isBatchRunning
        if let column = table.tableColumns.first {
            column.title = records.count == total ? "\(total) items · double-click to open" : "\(records.count) of \(total) shown · double-click to open"
        }
        emptyState.isHidden = !records.isEmpty || isLoading
        emptyState.stringValue = total == 0 ? (emptyMessage ?? "No Items") : "No Matches"
        refreshButton.isHidden = source == nil
        moreButton.isHidden = !(source?.supportsPaging ?? false)
        refreshButton.isEnabled = active && source != nil && !isLoading && !isBatchRunning
        moreButton.isEnabled = active && (source?.supportsPaging ?? false) && pager.hasMore && !isLoading && !isBatchRunning
        openButton.isEnabled = hasSelection
        manageButton.isEnabled = hasSelection
        markReadButton.isEnabled = canMarkSelectedRead
        markAllButton.isHidden = kind != .inbox
        markAllButton.isEnabled = canMarkAllRead
        if isBatchRunning { status.stringValue = batchIsMarkAll ? "Marking all notifications read…" : "Marking selected notifications read…"; status.textColor = .secondaryLabelColor }
        else if isLoading { status.stringValue = "Loading…"; status.textColor = .secondaryLabelColor }
        else if !statusMessage.isEmpty { status.stringValue = statusMessage; status.textColor = .systemRed }
        else if let source { status.stringValue = (records.count == total ? "\(total) items" : "\(records.count) of \(total) shown") + (source.supportsPaging && pager.hasMore ? " · more available" : ""); status.textColor = .secondaryLabelColor }
        else { status.stringValue = records.count == total ? "\(total) items" : "\(records.count) of \(total) shown"; status.textColor = .secondaryLabelColor }
    }
    var selected: JSONValue? { table.selectedRowIndexes.count == 1 && records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil }
    @objc func open() {
        guard active, !isBatchRunning, let record = selected, let owner = conversationOwner, let session else { return }
        let channelID = kind == .threads ? record["name"].string ?? record["thread_id"].string : record["channel_id"].string
        let parentID = record["parent_channel_id"].string ?? (kind == .threads ? record["channel_id"].string : nil)
        guard let channelID, !session.revokedChannels.contains(channelID), parentID.map(session.revokedChannels.contains) != true else { return }
        var fields: [String: JSONValue] = ["name": .string(channelID), "channel_name": .string(kind == .threads ? "Thread" : channelID)]
        if kind == .threads { fields["is_thread"] = .bool(true); if let parentID { fields["parent_channel_id"] = .string(parentID) } }
        let channel = session.channels.first { $0.id == channelID } ?? RavenChannel(raw: .object(fields))
        let message = record["message_id"].string ?? record["message"].string ?? record["name"].string
        let anchor = kind == .threads ? nil : message
        // Option opens a window of its own, as in Mail; otherwise the window
        // this collection belongs to shows the item.
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { owner.app.open(session: session, channel: channel, anchor: anchor) }
        else { owner.app.reveal(session: session, channel: channel, anchor: anchor, preferring: owner) }
    }
    @objc func manage() {
        guard active, !isBatchRunning, let record = selected, let owner = conversationOwner, let session else { return }
        let id = record["name"].string ?? ""
        switch kind {
        case .scheduled:
            Task { [weak self] in
                guard let option = await SheetPrompt.choose("Scheduled Message", items: ["Edit Text…", "Send Now", "Change Time…", "Cancel Scheduled Message"], confirm: "Continue", on: self?.window), let self, self.active else { return }
                self.manageScheduled(option: option, record: record, id: id, owner: owner, session: session)
            }
        case .reminders:
            Task { [weak self] in
                guard let self else { return }
                var actions: [ReminderAction] = [.snooze, .editTime, .delete]
                if ReminderCompletion.canComplete(record) { actions.insert(.complete, at: 0) }
                guard let option = await SheetPrompt.choose("Reminder", items: actions.map(\.title), confirm: "Continue", on: self.window),
                      self.active, actions.indices.contains(option) else { return }
                switch actions[option] {
                case .complete:
                    self.completeReminder(record, owner: owner, session: session)
                case .delete:
                    owner.action {
                        _ = try await session.mutate("raven.api.reminders.delete_reminder", ["reminder": .string(id)])
                        self.refreshOrClose()
                    }
                case .snooze, .editTime:
                    let snooze = actions[option] == .snooze
                    owner.action {
                        guard let date = await owner.pickDate(snooze ? "Snooze Reminder" : "Edit Reminder", confirm: snooze ? "Snooze" : "Save", on: self.window), self.active else { return }
                        _ = try await session.mutate("raven.api.reminders.\(snooze ? "snooze_reminder" : "update_reminder")", ["reminder": .string(id), "remind_at": .string(owner.timestamp(date))])
                        self.refreshOrClose()
                    }
                }
            }
        case .saved: owner.action { _ = try await session.mutate("raven.api.raven_message.save_message", ["message_id": .string(id), "add": .bool(false)]); self.refreshOrClose() }
        case .inbox: markSelectedRead()
        default: open()
        }
    }
    /// A collection with a server source reloads after an action; a static
    /// one cannot, so it closes rather than keep showing a changed row.
    private func refreshOrClose() { if source == nil { close() } else { refresh() } }

    /// Marks the selected fired, unread reminder complete through the pinned
    /// `mark_reminder_read(message_id)`. The server returns no state, so the
    /// canonical list and Home refresh decide the outcome: explicit success
    /// only when the list no longer shows a fired, unread reminder for the
    /// message, an explicit unavailable result on HTTP 404, and an uncertain
    /// result otherwise. A failed POST is never replayed.
    private func completeReminder(_ record: JSONValue, owner: ConversationWindow, session: AccountSession) {
        guard let messageID = ReminderCompletion.messageID(record),
              ReminderCompletion.isFiredUnread(record) else { return }
        owner.action {
            var unavailable = false
            var explicitFailure: String?
            do {
                _ = try await session.mutate(ReminderCompletion.markReadMethod, ["message_id": .string(messageID)])
            } catch let error as RavenError {
                if case .http(404, _) = error { unavailable = true }
                else if error.isPermanent { explicitFailure = StatusLocalization.errorDescription(error) }
            } catch { explicitFailure = error.localizedDescription }
            guard self.active else { return }
            if self.source == nil { self.close(); return }
            async let refreshedRows = self.freshRowsAfterMutation()
            let homeTask = await session.home.refreshAfterInflight()
            let rows = await refreshedRows
            await homeTask?.value
            guard self.active else { return }
            let stillFired = rows?.contains {
                ReminderCompletion.messageID($0) == messageID && ReminderCompletion.isFiredUnread($0)
            }
            if unavailable {
                self.statusMessage = "This server cannot complete reminders."
            } else if stillFired == false {
                self.statusMessage = ""
            } else if let explicitFailure {
                self.statusMessage = explicitFailure
            } else {
                let detail = rows == nil ? self.statusMessage : ""
                self.statusMessage = "Reminder completion could not be confirmed. " + (detail.isEmpty ? "Refresh before trying again." : detail)
            }
            self.updateChrome()
        }
    }
    private func manageScheduled(option: Int, record: JSONValue, id: String, owner: ConversationWindow, session: AccountSession) {
            if option == 0 {
                guard let window, let html = record["text"].string else { return }
                owner.action {
                    let edited: String?
                    do { edited = try await MessageEditorSheet.edit(html: html, title: "Edit Scheduled Message", on: window) }
                    catch { owner.app.showError(error); return } // failure: the original draft is untouched
                    guard let edited, !self.isClosed, owner.isCurrent(session) else { return } // cancel: nothing mutated
                    // Single-attempt mutation through the session guards.
                    _ = try await session.mutateResource("Raven Scheduled Message", name: id, values: ["text": .string(edited)])
                    if let index = self.pager.records.firstIndex(where: { $0["name"].string == id }) {
                        var fields = self.pager.records[index].object; fields["text"] = .string(edited)
                        self.pager.records[index] = .object(fields)
                    }
                    self.applyFilter(); self.table.reloadData(); self.updateChrome()
                }
                return
            }
            owner.action {
                if option == 1 { _ = try await session.mutate("raven.api.scheduled_message.send_now", ["name": .string(id)]) }
                if option == 2 {
                    guard let date = await owner.pickDate("Reschedule", confirm: "Reschedule", on: self.window), self.active else { return }
                    _ = try await session.mutateResource("Raven Scheduled Message", name: id, values: ["scheduled_time": .string(try owner.scheduledTimestamp(date))])
                }
                if option == 3 {
                    guard await SheetPrompt.confirm("Cancel this scheduled message?", message: "It will not be sent. Its text is not kept anywhere else.", confirm: "Cancel Message", destructive: true, on: self.window), self.active else { return }
                    _ = try await session.mutateResource("Raven Scheduled Message", name: id, values: nil, delete: true)
                }
                self.refreshOrClose()
            }
    }
}

extension CollectionWindow.Kind {
    /// Verified server contracts per collection, exposed for root wiring.
    var source: CollectionSource? {
        switch self {
        case .messages: return nil
        case .inbox: return CollectionSource(method: "raven.api.notifications.get_notifications", strategy: .offset(parameter: "start"))
        case .threads: return CollectionSource(method: "raven.api.threads.get_all_threads", strategy: .offset(parameter: "start_after"))
        case .saved: return CollectionSource(method: "raven.api.raven_message.get_saved_messages", strategy: .offset(parameter: "start"))
        case .reminders: return CollectionSource(method: "raven.api.reminders.get_reminders", strategy: .none)
        case .scheduled: return CollectionSource(method: "raven.api.scheduled_message.get_scheduled_messages", strategy: .none)
        }
    }
}

/// Two-line collection row: the message or item text, then where and when.
@MainActor final class CollectionRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CollectionRowCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        textField = title
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(title: String, detail: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        setAccessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
    }
}
