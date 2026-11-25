import AppKit
import RavenProtocol
import NevermoreCore

/// Queued sends as a native table (Mail's Outbox/Activity pattern), replacing
/// a chain of modal alerts. Retry, copy and cancel keep the durable outbox
/// semantics: retry reuses the immutable payload and retry ID.
@MainActor final class OutboxWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    weak var conversationOwner: ConversationWindow?
    let session: AccountSession
    var didClose: (() -> Void)?
    private(set) var isClosed = false
    private(set) var operations: [SendOperation] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyState = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Send…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var generation = 0
    private var isWorking = false

    private enum Column: String { case status, conversation, queued, message }
    /// States a person can retry after reviewing them.
    private static let retryableStates: Set<SendState> = [.retryable, .needsReview, .rejected]
    private static let columns: [(Column, String, CGFloat)] = [(.status, "Status", 120), (.conversation, "Conversation", 160), (.queued, "Queued", 140), (.message, "Message", 260)]
    private static let refreshItem = NSToolbarItem.Identifier("refresh")

    init?(owner: ConversationWindow) {
        guard let session = owner.session, !session.stopped else { return nil }
        self.conversationOwner = owner
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Outbox"
        window.subtitle = session.account.displayName.isEmpty ? session.account.user : session.account.displayName
        window.minSize = NSSize(width: 520, height: 260)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("NevermoreOutbox")
        let toolbar = NSToolbar(identifier: "NevermoreOutboxToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        buildContent()
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        for (column, title, width) in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = 60
            table.addTableColumn(tableColumn)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openConversation(_:))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Queued sends")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "No Queued Messages")
        title.font = .preferredFont(forTextStyle: .title3)
        title.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: "Messages waiting to send appear here.")
        detail.textColor = .tertiaryLabelColor
        emptyState.setViews([icon, title, detail], in: .center)
        emptyState.orientation = .vertical
        emptyState.spacing = 6

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.target = self
        copyButton.action = #selector(copyText(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelSend(_:))
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.keyEquivalent = "\r"
        copyButton.setAccessibilityLabel("Copy the selected message text")
        cancelButton.setAccessibilityLabel("Cancel the selected unsent message")
        retryButton.setAccessibilityLabel("Retry the selected send")
        let bar = NSStackView()
        bar.setViews([statusLabel], in: .leading)
        bar.setViews([copyButton, cancelButton, retryButton], in: .trailing)
        bar.spacing = 8

        for view in [scroll, emptyState, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        updateControls()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        generation += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        operations = []
        table.reloadData()
        didClose?()
    }

    func reload() {
        guard !isClosed, !session.stopped else { return }
        generation += 1
        let expected = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.session.store.operations()
                guard expected == self.generation, !self.isClosed else { return }
                self.apply(loaded.sorted { $0.createdAt > $1.createdAt })
            } catch {
                guard expected == self.generation, !self.isClosed else { return }
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func apply(_ loaded: [SendOperation]) {
        let selectedID = selectedOperation?.id
        operations = loaded
        table.reloadData()
        if let selectedID, let row = operations.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let empty = operations.isEmpty
        scroll.isHidden = empty
        emptyState.isHidden = !empty
        if !isWorking {
            statusLabel.stringValue = empty ? "" : operations.count == 1 ? "1 queued send" : "\(operations.count) queued sends"
        }
        updateControls()
    }

    private var selectedOperation: SendOperation? {
        operations.indices.contains(table.selectedRow) ? operations[table.selectedRow] : nil
    }

    private func plainText(_ operation: SendOperation) -> String {
        let text = (try? RichTextCodec.plainText(RichTextCodec.parse(operation.html))) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !operation.attachments.isEmpty { return "Attachment" }
        return text
    }

    private func conversationTitle(_ operation: SendOperation) -> String {
        session.channels.first { $0.id == operation.channelID }?.title ?? operation.channelID
    }

    private func updateControls() {
        let operation = selectedOperation
        let available = operation != nil && !isWorking && !session.stopped
        copyButton.isEnabled = available
        // Share the core rule so the outbox and the transcript ink blot
        // cannot disagree about which sends are still cancellable.
        cancelButton.isEnabled = available && operation.map(InkRules.canTakeBack) == true
        retryButton.isEnabled = available && operation.map { Self.retryableStates.contains($0.state) } == true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { operations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard operations.indices.contains(row), let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let operation = operations[row]
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        let field = cell.textField
        field?.toolTip = nil
        field?.textColor = .labelColor
        switch column {
        case .status:
            field?.stringValue = operation.state.localizedLabel()
            if let error = operation.error, !error.isEmpty { field?.toolTip = error }
            // Retryable stays a warning, visually distinct from the red used
            // for hard failures (themeAlert): orange means "will retry",
            // red means "failed".
            if Self.retryableStates.contains(operation.state) { field?.textColor = .systemOrange }
        case .conversation: field?.stringValue = conversationTitle(operation)
        case .queued: field?.stringValue = operation.createdAt.formatted(date: .abbreviated, time: .shortened)
        case .message: field?.stringValue = plainText(operation).replacingOccurrences(of: "\n", with: " ")
        }
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    // MARK: Actions

    @objc func openConversation(_ sender: Any?) {
        guard let operation = selectedOperation, let owner = conversationOwner else { return }
        let channelID = operation.channelID
        let matches = session.channels.filter { $0.id == channelID }
        guard let channel = matches.first, owner.isCurrent(session) else { return }
        owner.select(channel, anchor: nil, record: true)
        owner.window?.makeKeyAndOrderFront(nil)
    }

    @objc func copyText(_ sender: Any?) {
        guard let operation = selectedOperation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(operation), forType: .string)
    }

    /// The stored operation, if it is still in one of the expected states.
    /// Another window or the flush loop may have changed it since the table
    /// was loaded; acting on a stale copy could re-queue an accepted send.
    private static func current(_ id: UUID, in session: AccountSession, where valid: (SendOperation) -> Bool) async throws -> SendOperation {
        guard let stored = try await session.store.operations().first(where: { $0.id == id }), valid(stored) else {
            throw AppError.message("This send changed in the meantime. Review the outbox again before retrying or cancelling it.")
        }
        return stored
    }

    @objc func retry(_ sender: Any?) {
        guard let selected = selectedOperation, retryButton.isEnabled else { return }
        runAction("Retrying…") { session in
            try await session.refresh()
            var operation = try await Self.current(selected.id, in: session) { Self.retryableStates.contains($0.state) }
            operation.state = .queued
            operation.error = nil
            session.approvedOldSends.insert(operation.id)
            guard try await session.store.updateOperation(operation) else {
                throw AppError.message("This send changed in the meantime. Review the outbox again before retrying it.")
            }
            await session.flush()
        }
    }

    @objc func cancelSend(_ sender: Any?) {
        guard let selected = selectedOperation, cancelButton.isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await SheetPrompt.confirm("Cancel this unsent message?", message: "It is removed from the outbox and will not be sent. You can copy its text first.", confirm: "Cancel Send", destructive: true, on: self.window)
            guard confirmed, !self.isClosed else { return }
            self.runAction("Cancelling…") { session in
                guard try await session.store.takeBack(id: selected.id) != nil else {
                    throw AppError.message("This send has already left or changed. Review the outbox again before cancelling it.")
                }
                session.notify()
            }
        }
    }

    private func runAction(_ progress: String, _ work: @escaping @MainActor (AccountSession) async throws -> Void) {
        guard !isWorking, !session.stopped else { return }
        isWorking = true
        statusLabel.stringValue = progress
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.updateControls(); self.reload() }
            do {
                try await work(self.session)
            } catch {
                guard !self.isClosed, !self.session.stopped else { return }
                self.conversationOwner?.app.showError(error)
            }
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.refreshItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.refreshItem] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.refreshItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Refresh"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        item.target = self
        item.action = #selector(refreshFromToolbar(_:))
        return item
    }
    @objc func refreshFromToolbar(_ sender: Any?) { reload() }
}
