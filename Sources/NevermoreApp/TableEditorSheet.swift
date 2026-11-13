import AppKit
import NevermoreCore

/// A table transaction, isolated from the draft and its undo history. Cell
/// edits preserve all table metadata; Cancel never mutates the caller's value.
@MainActor final class TableEditorSheet: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var table: EditableRichTable
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let grid = NSTableView()
    private let cellEditor = ComposerView()
    private let status = NSTextField(labelWithString: "")
    private let cellLabel = NSTextField(labelWithString: "")
    private var row = 0
    private var column = 0
    private var continuation: CheckedContinuation<EditableRichTable?, Never>?
    private var finished = false
    private var commit: ((EditableRichTable) throws -> Void)?

    private init(_ table: EditableRichTable) {
        self.table = table
        super.init()
        sheet.title = "Edit Table"
        sheet.delegate = self; sheet.isReleasedWhenClosed = false
        grid.dataSource = self; grid.delegate = self
        grid.rowHeight = 28
        grid.allowsEmptySelection = true
        grid.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        grid.setAccessibilityLabel("Table cells")
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
        tableScroll.documentView = grid; tableScroll.borderType = .bezelBorder

        cellEditor.isRichText = true; cellEditor.importsGraphics = false
        cellEditor.allowsUndo = true; cellEditor.sharedUndoManager = UndoManager()
        cellEditor.alwaysInsertNewline = true
        cellEditor.font = .systemFont(ofSize: 14); cellEditor.textColor = .labelColor
        cellEditor.isVerticallyResizable = true; cellEditor.autoresizingMask = .width
        cellEditor.textContainer?.widthTracksTextView = true
        cellEditor.textContainerInset = NSSize(width: 6, height: 6)
        cellEditor.setAccessibilityLabel("Selected table cell")
        let cellScroll = NSScrollView()
        cellScroll.hasVerticalScroller = true; cellScroll.borderType = .bezelBorder
        cellScroll.documentView = cellEditor
        let formatting = ComposerFormattingBar(composer: cellEditor, includesTable: false)
        let actions = NSStackView()
        actions.spacing = 6
        for (label, action) in [("Add Row", #selector(addRow)), ("Remove Row", #selector(removeRow)), ("Add Column", #selector(addColumn)), ("Remove Column", #selector(removeColumn))] {
            actions.addArrangedSubview(NSButton(title: label, target: self, action: action))
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.stringValue = "Choose a cell. Merged-cell text stays editable; geometry needs an unmerged table. Cell undo resets when you change cells or table size; Cancel discards all edits."
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Use Table", target: self, action: #selector(save))
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [NSView(), cancel, save]); buttons.spacing = 8
        let stack = NSStackView(views: [tableScroll, actions, cellLabel, formatting, cellScroll, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView?.addSubview(stack)
        if let content = sheet.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), tableScroll.heightAnchor.constraint(equalToConstant: 180),
                cellScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), cellScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        cellEditor.onSend = { [weak self] in self?.save() }
        cellEditor.onEscape = { [weak self] in self?.cancel() }
        rebuildGrid(); loadCell()
    }

    static func edit(_ table: EditableRichTable, on parent: NSWindow, commit: ((EditableRichTable) throws -> Void)? = nil) async -> EditableRichTable? {
        let editor = TableEditorSheet(table)
        editor.commit = commit
        ComposerEditorLifetime.register(editor.sheet) { [weak editor] in editor?.finish(nil) }
        return await withCheckedContinuation { continuation in
            editor.continuation = continuation
            parent.beginSheet(editor.sheet) { _ in editor.finish(nil) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { table.layout.rows }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = tableColumn.flatMap({ Int($0.identifier.rawValue) }), let cell = table.cell(row: row, column: index) else { return nil }
        let text = RichTextCodec.plainText(RichDocument(nodes: cell.children), revealSpoilers: true)
        let button = NSButton(title: text.isEmpty ? "(empty)" : String(text.prefix(60)).replacingOccurrences(of: "\n", with: " "), target: self, action: #selector(selectCell(_:)))
        button.tag = row * 20 + index
        button.bezelStyle = .inline; button.alignment = .left
        button.setAccessibilityLabel("Row \(row + 1), column \(index + 1): \(text.isEmpty ? "empty" : text)")
        return button
    }

    private func rebuildGrid() {
        for column in grid.tableColumns { grid.removeTableColumn(column) }
        for index in 0..<table.layout.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = "Column \(index + 1)"; column.width = 150
            grid.addTableColumn(column)
        }
        grid.reloadData()
    }

    private func loadCell() {
        guard let cell = table.cell(row: row, column: column) else { return }
        cellLabel.stringValue = "Row \(row + 1), column \(column + 1)"
        cellEditor.textStorage?.setAttributedString(NativeRichText.attributedString(document: RichDocument(nodes: cell.children), revealSpoilers: true))
        cellEditor.undoManager?.removeAllActions()
        cellEditor.typingAttributes = NativeRichText.plainTypingAttributes
        cellEditor.setSelectedRange(NSRange(location: 0, length: 0))
        sheet.makeFirstResponder(cellEditor)
    }

    private func commitCell() throws {
        guard !cellEditor.hasMarkedText() else { throw AppError.message("Finish composing the cell text first.") }
        cellEditor.flushPendingShortcut()
        let content = try NativeRichText.document(from: cellEditor.attributedString())
        try table.replaceCell(row: row, column: column, content: content.nodes)
    }

    @objc private func selectCell(_ sender: NSButton) {
        do { try commitCell(); row = sender.tag / 20; column = sender.tag % 20; grid.reloadData(); loadCell() }
        catch { show(error) }
    }

    private func mutate(_ operation: (inout EditableRichTable) throws -> Void) {
        do {
            try commitCell(); try operation(&table)
            row = min(row, table.layout.rows - 1); column = min(column, table.layout.columns - 1)
            rebuildGrid(); loadCell()
        } catch { show(error) }
    }
    @objc private func addRow() { let index = row + 1; mutate { try $0.insertRow(at: index) } }
    @objc private func removeRow() { let index = row; mutate { try $0.removeRow(at: index) } }
    @objc private func addColumn() { let index = column + 1; mutate { try $0.insertColumn(at: index) } }
    @objc private func removeColumn() { let index = column; mutate { try $0.removeColumn(at: index) } }
    @objc private func save() {
        guard !finished else { return }
        do { try commitCell(); try commit?(table); finish(table) } catch { show(error) }
    }
    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func show(_ error: Error) { status.textColor = .systemRed; status.stringValue = error.localizedDescription }
    private func finish(_ result: EditableRichTable?) {
        guard !finished else { return }; finished = true
        ComposerEditorLifetime.unregister(sheet)
        if let child = sheet.attachedSheet { sheet.endSheet(child, returnCode: .cancel); child.orderOut(nil) }
        sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil)
        continuation?.resume(returning: result); continuation = nil
    }
}

@MainActor enum ComposerEditorLifetime {
    private struct Entry { var sheet: NSWindow; var cancel: () -> Void }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    static var activeCount: Int { entries.count }
    static func register(_ sheet: NSWindow, cancel: @escaping () -> Void) { entries[ObjectIdentifier(sheet)] = Entry(sheet: sheet, cancel: cancel) }
    static func unregister(_ sheet: NSWindow) { entries.removeValue(forKey: ObjectIdentifier(sheet)) }

    /// Account removal and window closure must also remove private editor
    /// surfaces. Close nested editors before their parents.
    static func cancel(attachedTo window: NSWindow?) {
        guard let window else { return }
        func depth(_ sheet: NSWindow) -> Int? {
            var parent = sheet.sheetParent, depth = 0
            while let ancestor = parent {
                depth += 1
                if ancestor === window { return depth }
                parent = ancestor.sheetParent
            }
            return nil
        }
        let owned = entries.values.compactMap { entry in depth(entry.sheet).map { (entry, $0) } }.sorted { $0.1 > $1.1 }
        for (entry, _) in owned { entry.cancel() }
    }
}
