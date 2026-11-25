import AppKit

/// The editor keeps key focus while the reader chooses a shortcut.
@MainActor final class SlashShortcutPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let popover = NSPopover()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: table.rowHeight)
    private(set) var shortcuts: [ComposerShortcut] = []
    private var input: ComposerShortcutInput?
    private var dismissed: ComposerShortcutInput?
    enum Action { case complete, run }
    var onChoose: ((ComposerShortcut, ComposerShortcutInput, Action) -> Void)?

    override init() {
        super.init()
        let controller = NSViewController()
        let root = NSView()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .plain
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.headerView = nil
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClicked)
        table.setAccessibilityLabel("Composer shortcuts")

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        let hint = NSTextField(labelWithString: "↵ Run   ⇥ Complete   Esc Dismiss")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.setAccessibilityLabel("Return to run, Tab to complete, Escape to dismiss")
        let stack = NSStackView(views: [scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listHeight
        ])
    }

    static func isAtEnd(of editor: NSTextView) -> Bool {
        editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0)
    }

    func update(_ input: ComposerShortcutInput, in editor: NSTextView) {
        if dismissed != input { dismissed = nil }
        guard dismissed == nil, let window = editor.window, window.isKeyWindow,
              window.firstResponder === editor, Self.isAtEnd(of: editor) else { close(); return }
        let matches = ComposerShortcut.allCases.filter(input.matches)
        guard !matches.isEmpty else { close(); return }

        self.input = input
        if shortcuts != matches {
            let previous = shortcuts.indices.contains(table.selectedRow) ? shortcuts[table.selectedRow] : nil
            shortcuts = matches
            table.reloadData()
            table.selectRowIndexes(IndexSet(integer: matches.firstIndex { $0 == previous } ?? 0), byExtendingSelection: false)
        }
        if let root = popover.contentViewController?.view {
            listHeight.constant = CGFloat(matches.count) * table.rowHeight
            root.layoutSubtreeIfNeeded()
            popover.contentSize = NSSize(width: 322, height: root.fittingSize.height)
        }
        if !popover.isShown {
            let screen = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            var anchor = editor.convert(window.convertFromScreen(screen), from: nil)
            anchor.size.width = max(1, anchor.width)
            anchor.size.height = max(16, anchor.height)
            popover.show(relativeTo: anchor, of: editor, preferredEdge: editor.isFlipped ? .minY : .maxY)
        }
    }

    func handle(_ event: NSEvent, input: ComposerShortcutInput, in editor: NSTextView) -> Bool {
        guard input == self.input, Self.isAtEnd(of: editor) else { return false }
        if event.keyCode == 53 {
            dismissed = input
            close()
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125, 126:
            let index = min(max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)), shortcuts.count - 1)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return true
        case 36, 76:
            return choose(row: table.selectedRow, action: .run)
        case 48:
            if choose(row: table.selectedRow, action: .complete) { return true }
            dismissed = input
            close()
            return false
        default:
            return false
        }
    }

    func close() {
        guard input != nil else { return }
        popover.performClose(nil)
        input = nil
        shortcuts = []
        table.reloadData()
    }

    func reset() {
        dismissed = nil
        close()
    }

    @objc private func chooseClicked() { _ = choose(row: table.clickedRow, action: .run) }

    private func choose(row: Int, action: Action) -> Bool {
        guard let input, shortcuts.indices.contains(row) else { return false }
        let shortcut = shortcuts[row]
        guard action != .complete || input.completion(for: shortcut) != input.text else { return false }
        onChoose?(shortcut, input, action)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shortcuts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shortcuts.indices.contains(row) else { return nil }
        let shortcut = shortcuts[row]
        let name = NSTextField(labelWithString: shortcut.usage)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        let detail = NSTextField(labelWithString: shortcut.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let cell = NSTableCellView()
        let stack = NSStackView(views: [name, detail])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel("\(shortcut.usage), \(shortcut.detail)")
        return cell
    }
}
