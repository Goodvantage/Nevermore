import AppKit
import NevermoreCore
import RavenProtocol

/// The system emoji palette remains available for Unicode; custom emoji use
/// permission-filtered, cancellable pages from the current account.
enum EmojiSelection: Sendable { case unicode(String), custom(RavenCustomEmoji) }

@MainActor final class EmojiPickerSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Purpose { case compose, reaction }
    private weak var parent: NSWindow?
    private let session: AccountSession
    private let purpose: Purpose
    private let active: () -> Bool
    private let existing: [RavenCustomEmoji]
    let panel: NSPanel
    private let search = NSSearchField()
    private let unicode = NSTextField()
    private let table = CollectionTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let more = NSButton(title: "Load More", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let choose = NSButton(title: "Choose", target: nil, action: nil)
    private var items: [RavenCustomEmoji] = []
    private var nextOffset: Int?
    private var skipped = 0
    private var loading = false
    private var finished = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<EmojiSelection?, Never>?

    static func pick(on parent: NSWindow, session: AccountSession, purpose: Purpose, existing: [RavenCustomEmoji] = [], active: @escaping () -> Bool) async throws -> EmojiSelection? {
        guard parent.attachedSheet == nil else { throw AppError.message("Finish the current sheet before choosing an emoji.") }
        let controller = EmojiPickerSheet(parent: parent, session: session, purpose: purpose, existing: existing, active: active)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { controller.finish(nil); return nil }
            return await withCheckedContinuation { controller.present($0) }
        } onCancel: { Task { @MainActor in controller.finish(nil) } }
    }
    private init(parent: NSWindow, session: AccountSession, purpose: Purpose, existing: [RavenCustomEmoji], active: @escaping () -> Bool) {
        self.parent = parent; self.session = session; self.purpose = purpose; self.existing = Array(existing.prefix(500)); self.active = active
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = purpose == .compose ? "Insert Custom Emoji" : "Choose a Reaction"
        panel.isReleasedWhenClosed = false
        unicode.placeholderString = "For example, 👍"; unicode.delegate = self; unicode.setAccessibilityLabel("Unicode reaction")
        let symbols = NSButton(title: "Emoji & Symbols…", target: self, action: #selector(showSymbols))
        let unicodeRow = NSStackView(views: [NSTextField(labelWithString: "Unicode emoji"), unicode, symbols]); unicodeRow.spacing = 8
        unicodeRow.isHidden = purpose != .reaction
        search.placeholderString = "Search custom emoji names or keywords"; search.delegate = self
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false; search.setAccessibilityLabel("Search custom emoji")
        refresh.target = self; refresh.action = #selector(reload)
        more.target = self; more.action = #selector(loadMore)
        let top = NSStackView(views: [search, refresh, more]); top.spacing = 8
        let column = NSTableColumn(identifier: .init("emoji")); column.title = "Custom emoji"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 40; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(accept); table.setAccessibilityLabel("Custom emoji results")
        table.onOpen = { [weak self] in self?.accept() }; table.onClose = { [weak self] in self?.cancel() }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        status.textColor = .secondaryLabelColor; status.setAccessibilityLabel("Emoji catalog status")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        choose.target = self; choose.action = #selector(accept); choose.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, choose]); buttons.spacing = 8
        let stack = NSStackView(views: [unicodeRow, top, scroll, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
            for view in [unicodeRow, top, scroll, status, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        panel.initialFirstResponder = purpose == .reaction ? unicode : search
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.finish(nil) } })
        observers.append(NotificationCenter.default.addObserver(forName: .sessionChanged, object: session, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in guard let self, !self.active() else { return }; self.finish(nil) } })
        updateControls()
    }
    private func present(_ continuation: CheckedContinuation<EmojiSelection?, Never>) {
        guard let parent, !finished, active() else { finish(nil); continuation.resume(returning: nil); return }
        self.continuation = continuation
        parent.beginSheet(panel) { [weak self] _ in self?.finish(nil) }
        load(reset: true)
    }
    private var unicodeChoice: String? {
        let value = unicode.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard purpose == .reaction, QuickReactions.isUnicodeReaction(value) else { return nil }
        return value
    }
    private func updateControls() {
        refresh.isEnabled = !finished && active() && !loading
        more.isEnabled = !finished && active() && !loading && nextOffset != nil && items.count < 500
        choose.isEnabled = !finished && active() && (unicodeChoice != nil || items.indices.contains(table.selectedRow))
    }
    @objc private func showSymbols() { panel.makeFirstResponder(unicode); NSApp.orderFrontCharacterPalette(nil) }
    @objc private func reload() { load(reset: true) }
    @objc private func loadMore() { load(reset: false) }
    private func load(reset: Bool, delayed: Bool = false) {
        guard !finished, active() else { finish(nil); return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1; let request = generation
        loadTask?.cancel(); loadTask = nil
        guard query.utf8.count <= 256 else { nextOffset = nil; skipped = 0; items.removeAll(); table.reloadData(); loading = false; status.stringValue = "Shorten this search."; updateControls(); return }
        if reset {
            items = existing.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query) }
            nextOffset = 0; skipped = 0; table.reloadData()
        }
        guard let offset = nextOffset, items.count < 500 else {
            if items.count >= 500 { status.stringValue = "500 custom emoji loaded. Search by name to find more." }
            updateControls(); return
        }
        loading = true; status.stringValue = "Loading custom emoji…"; updateControls()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if request == self.generation { self.loadTask = nil; self.loading = false; self.updateControls() } }
            do {
                if delayed { try await Task.sleep(for: .milliseconds(250)) }
                let page = try await self.session.customEmojiPage(query: query, offset: offset)
                guard !Task.isCancelled, request == self.generation, !self.finished, self.active() else { return }
                let selectedID = self.items.indices.contains(self.table.selectedRow) ? self.items[self.table.selectedRow].id : nil
                for item in page.items {
                    if let index = self.items.firstIndex(where: { $0.id == item.id }) { self.items[index] = item }
                    else if self.items.count < 500 { self.items.append(item) }
                }
                self.nextOffset = page.nextOffset; self.skipped += page.skippedCount; self.table.reloadData()
                if let selectedID, let index = self.items.firstIndex(where: { $0.id == selectedID }) { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                else if self.purpose == .compose, !self.items.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                self.status.stringValue = self.items.isEmpty ? "No matching custom emoji." : "\(self.items.count) custom emoji loaded."
                if self.skipped > 0 { self.status.stringValue += " Some site entries are unavailable." }
                if self.items.count >= 500 { self.status.stringValue += " Search by name to find more." }
            } catch {
                guard !Task.isCancelled, request == self.generation, !self.finished else { return }
                self.items.removeAll(); self.nextOffset = nil; self.table.reloadData()
                self.status.stringValue = "Custom emoji could not be loaded. Try Refresh."
            }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if notification.object as? NSSearchField === search { unicode.stringValue = ""; load(reset: true, delayed: true) }
        else if notification.object as? NSTextField === unicode { table.deselectAll(nil); updateControls() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if command == #selector(NSResponder.moveDown(_:)), control === search, !items.isEmpty {
            let row = items.indices.contains(table.selectedRow) ? table.selectedRow : 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            panel.makeFirstResponder(table); return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) { accept(); return true }
        return false
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if table.selectedRow >= 0 { unicode.stringValue = "" }; updateControls() }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let field = NSTextField(wrappingLabelWithString: "\(Self.shortcode(item))\n\(item.keywords.prefix(120))")
        field.maximumNumberOfLines = 2; field.setAccessibilityLabel("Custom emoji \(Self.shortcode(item))"); return field
    }
    static func shortcode(_ item: RavenCustomEmoji) -> String { item.name.hasPrefix(":") && item.name.hasSuffix(":") ? item.name : ":\(item.name):" }
    @objc private func accept() {
        guard !finished, active(), (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if let value = unicodeChoice { finish(.unicode(value)) }
        else if items.indices.contains(table.selectedRow) { finish(.custom(items[table.selectedRow])) }
    }
    @objc private func cancel() { finish(nil) }
    private func finish(_ value: EmojiSelection?) {
        guard !finished else { return }; finished = true; generation += 1
        loadTask?.cancel(); loadTask = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }; observers.removeAll()
        if let parent, parent.attachedSheet === panel { parent.endSheet(panel) }
        panel.orderOut(nil); items.removeAll(); table.reloadData(); search.stringValue = ""; unicode.stringValue = ""; status.stringValue = ""
        let pending = continuation; continuation = nil; pending?.resume(returning: value)
    }
}
