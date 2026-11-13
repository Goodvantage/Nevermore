import AppKit
import RavenProtocol
import NevermoreCore

@MainActor final class CollectionWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate {
    enum Kind: Equatable { case search, inbox, threads, saved, reminders, scheduled }
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
    let batchTransport: CollectionBatchActions.Transport?
    var batchTask: Task<Void, Never>?
    var batchGeneration = UUID()
    var isBatchRunning = false
    let attachmentTransport: CollectionAttachmentActions.Transport?
    var attachmentTask: Task<Void, Never>?
    var attachmentRevision = UUID()
    var attachmentCanonicalParents: [String] = []
    var attachmentIdentity: SearchAttachment?
    var searchAttachmentWindows: [AttachmentWindow] = []
    var attachmentObservers: [NSObjectProtocol] = []
    let previewAttachmentButton = NSButton(title: "Quick Look", target: nil, action: nil)
    let saveAttachmentButton = NSButton(title: "Save Attachment…", target: nil, action: nil)
    var loadTask: Task<Void, Never>?
    private(set) var isClosed = false
    var isLoading = false
    var statusMessage = ""
    var active: Bool {
        guard let session, let owner = conversationOwner else { return false }
        return !isClosed && owner.isCurrent(session)
    }
    init(owner: ConversationWindow, title: String, records: [JSONValue], kind: Kind, source: CollectionSource? = nil, batchTransport: CollectionBatchActions.Transport? = nil, attachmentTransport: CollectionAttachmentActions.Transport? = nil) {
        self.attachmentTransport = owner.session?.demo == true ? attachmentTransport : nil
        self.batchTransport = owner.session?.demo == true ? batchTransport : nil
        self.conversationOwner = owner; self.session = owner.session; self.kind = kind; self.source = source
        self.pager = CollectionPager(records: records, pageSize: source?.pageSize ?? CollectionSource.defaultPageSize)
        self.records = pager.records
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = title; window.subtitle = owner.session.map { $0.account.displayName.isEmpty ? $0.account.user : $0.account.displayName } ?? ""
        window.minSize = NSSize(width: 520, height: 300); window.center(); window.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.title = "Results"; table.addTableColumn(column)
        table.headerView = nil; table.style = .inset; table.rowHeight = 44; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(open)
        table.onOpen = { [weak self] in self?.open() }; table.onClose = { [weak self] in self?.close() }; table.onRefresh = { [weak self] in self?.refresh() }
        table.allowsMultipleSelection = kind == .inbox
        table.canRefresh = source != nil
        table.setAccessibilityLabel("Collection results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        openButton.target = self; openButton.action = #selector(open); openButton.setAccessibilityLabel("Open selected result"); openButton.toolTip = "Open the selected item in a conversation window (Return)"
        manageButton.target = self; manageButton.action = #selector(manage); manageButton.setAccessibilityLabel("Actions for selected result")
        markReadButton.target = self; markReadButton.action = #selector(markSelectedRead)
        markReadButton.setAccessibilityLabel("Mark selected inbox notifications read")
        markReadButton.toolTip = "Select up to 100 inbox items to mark their notifications read."
        markReadButton.isHidden = kind != .inbox
        previewAttachmentButton.target = self; previewAttachmentButton.action = #selector(previewSearchAttachment)
        previewAttachmentButton.setAccessibilityLabel("Quick Look selected file search result"); previewAttachmentButton.toolTip = "Space previews the selected file when the results table has focus."
        saveAttachmentButton.target = self; saveAttachmentButton.action = #selector(saveSearchAttachment)
        saveAttachmentButton.setAccessibilityLabel("Save selected file search result"); saveAttachmentButton.toolTip = "Command-Shift-S saves the selected file."
        saveAttachmentButton.keyEquivalent = "s"; saveAttachmentButton.keyEquivalentModifierMask = [.command, .shift]
        if supportsSearchAttachments {
            table.onPreviewAttachment = { [weak self] in self?.previewSearchAttachment() }
            table.onSaveAttachment = { [weak self] in self?.saveSearchAttachment() }
            let menu = NSMenu()
            for (title, action) in [("Quick Look Attachment", #selector(previewSearchAttachment)), ("Save Attachment…", #selector(saveSearchAttachment))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            table.menu = menu
        }
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
        let bar = NSStackView(); bar.setViews([status], in: .leading); bar.setViews([moreButton, markReadButton, previewAttachmentButton, saveAttachmentButton, manageButton, openButton], in: .trailing); bar.spacing = 8
        for view in [scroll, bar, emptyState] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(view) }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), scroll.topAnchor.constraint(equalTo: window.contentView!.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10), bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), bar.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12), emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        installSearchAttachmentObservers(); updateChrome()
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
            close(); return
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
    func tableViewSelectionDidChange(_ notification: Notification) { validateSearchAttachment(); updateChrome() }
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
        cancelSearchAttachment()
        for token in attachmentObservers { NotificationCenter.default.removeObserver(token) }; attachmentObservers.removeAll()
        // Delayed results must not repopulate a closed collection.
        batchGeneration = UUID(); batchTask?.cancel(); batchTask = nil; isBatchRunning = false
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
        let value = source?.method == LinkSearch.method ? LinkSearch.preview(record) : text.isEmpty ? record["content"].string ?? record["message_content"].string ?? record["description"].string ?? record["name"].string ?? "Item" : text
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
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier); item.searchField = search; item.label = "Filter"; item.preferredWidthForSearchField = 220
            return item
        }
        guard itemIdentifier == Self.refreshItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier); item.label = "Refresh"; item.view = refreshButton
        return item
    }
    // MARK: Local scoped filter (native search field)
    @objc func applySearch() { cancelSearchAttachment(); applyFilter(); table.reloadData(); updateChrome() }
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
        if source?.method == LinkSearch.method { return LinkSearch.preview(record).lowercased() }
        var parts: [String] = []
        for key in ["description","name","id","channel_id","parent_channel_id","channel_name","status","error","scheduled_time","remind_at","notification_type"] {
            if let value = record[key].string { parts.append(value) }
        }
        if let html = record["text"].string ?? record["message_text"].string { if let document = try? RichTextCodec.parse(html) { parts.append(RichTextCodec.plainText(document)) } }
        else { parts.append(record["content"].string ?? record["message_content"].string ?? "") }
        return parts.joined(separator: "\n").lowercased()
    }
    // MARK: Refresh / Load More (read-only RPCs)
    @objc func refresh() {
        guard active, source != nil, !isLoading, !isBatchRunning else { return }
        cancelSearchAttachment()
        isLoading = true; statusMessage = ""; updateChrome()
        loadTask?.cancel()
        let generation = pager.beginRefresh()
        loadTask = Task { [weak self] in
            guard let self, let session = self.session, let source = self.source else { return }
            do {
                let response = try await session.client.rpc(source.method, arguments: CollectionPaging.pageArguments(source, offset: 0))
                if self.apply(rows: try CollectionPaging.decodeRows(response), generation: generation, refresh: true) {
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
    }
    @objc func loadMore() {
        guard active, let source, source.supportsPaging, pager.hasMore, !isLoading, !isBatchRunning else { return }
        cancelSearchAttachment()
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
        cancelSearchAttachment()
        var filtered = source?.method == LinkSearch.method ? rows.map(LinkSearch.normalize) : source?.method == "raven.api.search.sqlite_search" ? rows.map(RavenSearchResult.normalize) : rows
        if let source { filtered = CollectionPaging.scopedSearchRows(filtered, source: source) }
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
        applyFilter(); validateSearchAttachment(); table.reloadData(); updateChrome()
    }
    func updateChrome() {
        previewAttachmentButton.isHidden = !supportsSearchAttachments; saveAttachmentButton.isHidden = !supportsSearchAttachments
        previewAttachmentButton.isEnabled = canReadSearchAttachment; saveAttachmentButton.isEnabled = canReadSearchAttachment
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
        if isBatchRunning { status.stringValue = "Marking selected notifications read…"; status.textColor = .secondaryLabelColor }
        else if isLoading { status.stringValue = "Loading…"; status.textColor = .secondaryLabelColor }
        else if attachmentTask != nil { status.stringValue = "Downloading selected attachment…"; status.textColor = .secondaryLabelColor }
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
        owner.app.open(session: session, channel: channel, anchor: kind == .threads ? nil : message)
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
                guard let option = await SheetPrompt.choose("Reminder", items: ["Snooze…", "Edit Time…", "Delete Reminder"], confirm: "Continue", on: self?.window), let self, self.active else { return }
                owner.action {
                    if option == 2 { _ = try await session.mutate("raven.api.reminders.delete_reminder", ["reminder": .string(id)]) }
                    else if let date = await owner.pickDate(option == 0 ? "Snooze Reminder" : "Edit Reminder", confirm: option == 0 ? "Snooze" : "Save", on: self.window), self.active { _ = try await session.mutate("raven.api.reminders.\(option == 0 ? "snooze_reminder" : "update_reminder")", ["reminder": .string(id), "remind_at": .string(owner.timestamp(date))]) }
                    else { return }
                    self.refreshOrClose()
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
                    _ = try await session.mutateResource("Raven Scheduled Message", name: id, values: ["scheduled_time": .string(owner.timestamp(date))])
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
    /// `sqlite_search` has no offset/cursor argument in the pinned contract,
    /// so search collections are `.none` and never page.
    var source: CollectionSource? {
        switch self {
        case .search: return CollectionSource(method: "raven.api.search.sqlite_search", strategy: .none)
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
