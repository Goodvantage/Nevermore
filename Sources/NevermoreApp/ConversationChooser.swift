import AppKit
import RavenProtocol
import NevermoreCore

@MainActor private final class ChooserTable: NSTableView {
    var onPick: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36,76].contains(event.keyCode) { onPick?(); return }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}
@MainActor final class ConversationChooser: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let search = NSSearchField()
    private let table = ChooserTable()
    let candidates: [MentionCandidate]
    private(set) var matches: [MentionCandidate] = []
    weak var parent: NSWindow?
    var onPick: ((MentionCandidate, Bool) -> Void)?
    var onClose: (() -> Void)?
    private var finished = false
    init(session: AccountSession) {
        candidates = session.channels.filter { !session.revokedChannels.contains($0.id) }.map { MentionCandidate(kind: .channel, serverID: $0.id, title: $0.title, detail: $0.isDM ? "Direct message" : $0.workspace) } + session.userNames.map { MentionCandidate(kind: .person, serverID: $0.key, title: $0.value, detail: "Direct message · \($0.key)") }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 410), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Open Conversation · \(session.account.user)"; window.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(chooseSelected)
        table.onPick = { [weak self] in self?.chooseSelected() }; table.onCancel = { [weak self] in self?.cancel() }; table.setAccessibilityLabel("Matching conversations and people")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        search.placeholderString = "Search conversations or people · # channels · @ people"; search.delegate = self; search.setAccessibilityLabel("Find a conversation or person")
        let note = NSTextField(labelWithString: "Return opens · Option-Return opens a new window · Escape cancels"); note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let open = NSButton(title: "Open", target: self, action: #selector(chooseSelected)); open.keyEquivalent = "\r"
        let buttons = NSStackView(views: [note, NSView(), cancel, open]); buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [search, scroll, buttons]); stack.orientation = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(stack)
        if let view = window.contentView { NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14), search.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)]) }
        window.initialFirstResponder = search; updateMatches()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(on parent: NSWindow) { self.parent = parent; guard let window else { return }; parent.beginSheet(window) { [weak self] _ in self?.finish() }; window.makeFirstResponder(search) }
    func controlTextDidChange(_ notification: Notification) { updateMatches() }
    func updateMatches() {
        var text = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: MentionCandidate.Kind? = text.hasPrefix("#") ? .channel : text.hasPrefix("@") ? .person : nil
        if kind != nil { text.removeFirst() }
        let before = matches.indices.contains(table.selectedRow) ? matches[table.selectedRow].id : nil
        var result: [MentionCandidate] = []
        for candidateKind in [MentionCandidate.Kind.channel, .person] where kind == nil || kind == candidateKind {
            result += MentionCompletion.matches(candidates, query: MentionQuery(kind: candidateKind, range: NSRange(location: 0, length: 0), text: text), limit: 100)
        }
        matches = Array(result.prefix(100)); table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: matches.firstIndex { $0.id == before } ?? 0), byExtendingSelection: false) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:", "moveUp:":
            let delta = NSStringFromSelector(commandSelector) == "moveDown:" ? 1 : -1
            if !matches.isEmpty { let row = min(max(0, table.selectedRow + delta), matches.count - 1); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }; return true
        case "insertNewline:": chooseSelected(); return true
        case "cancelOperation:": cancel(); return true
        default: return false
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = matches[row]
        let label = NSTextField(wrappingLabelWithString: "\(candidate.kind == .person ? "@" : "#") \(candidate.title)\n\(candidate.detail)"); label.maximumNumberOfLines = 2; return label
    }
    @objc func chooseSelected() {
        guard !finished, matches.indices.contains(table.selectedRow) else { return }
        let candidate = matches[table.selectedRow], newWindow = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let callback = onPick; finish(); callback?(candidate, newWindow)
    }
    @objc func cancel() { finish() }
    func windowWillClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !finished else { return }; finished = true
        if let window { parent?.endSheet(window); window.orderOut(nil) }
        onPick = nil; let callback = onClose; onClose = nil; callback?()
    }
}
