import AppKit
import RavenProtocol
import NevermoreCore

/// A native, searchable roster of the members the server returned for one
/// channel. Return (or the Message button) hands a selected other member to
/// the existing account-specific DM flow; Escape or Cancel closes it without
/// an action. The sheet closes itself when the account or channel access it
/// was opened for no longer applies.
@MainActor final class MemberRosterWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private weak var conversation: ConversationWindow?
    private let session: AccountSession
    private let channel: RavenChannel
    private let accountUser: String
    let members: [MemberRosterEntry]
    private(set) var matches: [MemberRosterEntry] = []
    let search = NSSearchField()
    let table = CollectionTableView()
    let status = NSTextField(labelWithString: "")
    let messageButton = NSButton(title: "Message", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private weak var parent: NSWindow?
    private var observer: NSObjectProtocol?
    private var finished = false
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(owner: ConversationWindow, session: AccountSession, channel: RavenChannel, response: JSONValue) {
        self.conversation = owner
        self.session = session
        self.channel = channel
        self.accountUser = session.account.user
        self.members = MemberRoster.entries(from: response, names: session.userNames)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = members.count == 1 ? "1 Member · \(channel.title)" : "\(members.count) Members · \(channel.title)"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("member"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(message)
        table.onOpen = { [weak self] in self?.message() }
        table.onClose = { [weak self] in self?.cancel() }
        table.canRefresh = false
        table.setAccessibilityLabel("Channel members")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        search.placeholderString = "Search members"
        search.delegate = self
        search.setAccessibilityLabel("Search members")

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel("Member count")

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        messageButton.target = self
        messageButton.action = #selector(message)
        messageButton.keyEquivalent = "\r"
        messageButton.setAccessibilityLabel("Message selected member")
        messageButton.toolTip = "Message the selected member (Return)"

        let buttons = NSStackView(views: [status, NSView(), cancelButton, messageButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let root = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
                search.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        window.initialFirstResponder = search
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isActive else { return }
                self.cancel()
            }
        }
        updateMatches()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The sheet is only useful while its window still shows the same account
    /// and channel, that channel is not revoked, and the session is alive.
    var isActive: Bool {
        guard !finished, conversation?.isCurrent(session, channelID: channel.id) == true else { return false }
        return !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents)
    }

    func present(on parent: NSWindow) {
        guard isActive else { cancel(); return }
        self.parent = parent
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.finish() }
        window.makeFirstResponder(search)
    }

    func updateMatches() {
        let before = selectedEntry?.userID
        matches = MemberRoster.filtered(members, query: search.stringValue)
        table.reloadData()
        if let before, let row = matches.firstIndex(where: { $0.userID == before }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        updateChrome()
    }

    private func updateChrome() {
        status.stringValue = MemberRoster.countLabel(total: members.count, shown: matches.count)
        messageButton.isEnabled = selectedEntry.map { MemberRoster.canMessage($0, accountUser: accountUser) } == true
    }

    var selectedEntry: MemberRosterEntry? {
        matches.indices.contains(table.selectedRow) ? matches[table.selectedRow] : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateChrome() }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let entry = matches[row]
        var detail = entry.isAdmin ? "Admin · \(entry.userID)" : entry.userID
        if entry.userID == accountUser { detail = "You · \(detail)" }
        let identifier = NSUserInterfaceItemIdentifier("MemberRosterLabel")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(wrappingLabelWithString: "")
        label.identifier = identifier
        label.stringValue = "\(entry.displayName)\n\(detail)"
        label.maximumNumberOfLines = 2
        label.setAccessibilityLabel("\(entry.displayName)\(entry.isAdmin ? ", admin" : ""), \(entry.userID)")
        return label
    }

    @objc func message() {
        guard !finished, isActive, let entry = selectedEntry, MemberRoster.canMessage(entry, accountUser: accountUser) else { return }
        let userID = entry.userID
        let callback = onMessage
        finish()
        callback?(userID)
    }

    @objc func cancel() { finish() }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === search else { return }
        updateMatches()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:":
            guard !matches.isEmpty else { return true }
            let row = max(0, min(table.selectedRow + 1, matches.count - 1))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case "moveUp:":
            guard !matches.isEmpty else { return true }
            let row = max(0, table.selectedRow - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case "insertNewline:":
            message()
            return true
        case "cancelOperation:":
            cancel()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let window {
            parent?.endSheet(window)
            window.orderOut(nil)
        }
        onMessage = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
