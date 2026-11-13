import AppKit
import NevermoreCore

@MainActor final class MentionPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let popover = NSPopover()
    let table = NSTableView()
    let scroll = NSScrollView()
    let heading = NSTextField(labelWithString: "")
    var candidates: [MentionCandidate] = []
    private(set) var query: MentionQuery?
    var onChoose: ((MentionCandidate, MentionQuery) -> Void)?
    private var dismissed: MentionQuery?
    override init() {
        super.init()
        let controller = NSViewController(); let root = NSView()
        controller.view = root; popover.contentViewController = controller; popover.behavior = .semitransient; popover.animates = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(chooseSelected)
        table.setAccessibilityLabel("Mention suggestions"); table.allowsEmptySelection = false
        scroll.documentView = table; scroll.hasVerticalScroller = true
        heading.font = .systemFont(ofSize: 11, weight: .medium); heading.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    func update(textView: NSTextView, pool: [MentionCandidate]) {
        guard textView.window?.isKeyWindow == true, textView.window?.firstResponder === textView,
              let query = MentionCompletion.query(in: textView.string, selection: textView.selectedRange(), hasMarkedText: textView.hasMarkedText()) else { close(); return }
        if textView.selectedRange().location > 0, let font = textView.attributedString().attribute(.font, at: textView.selectedRange().location - 1, effectiveRange: nil) as? NSFont,
           NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) { close(); return }
        var hasSemantic = false
        textView.attributedString().enumerateAttribute(NSAttributedString.Key("Nevermore.SemanticNode"), in: query.range) { marker, _, stop in if marker != nil { hasSemantic = true; stop.pointee = true } }
        guard !hasSemantic, query != dismissed else { close(); return }
        let next = MentionCompletion.matches(pool, query: query)
        guard !next.isEmpty else { close(); return }
        let previous = candidates.indices.contains(table.selectedRow) ? candidates[table.selectedRow].id : nil
        self.query = query; candidates = next; table.reloadData()
        let index = candidates.firstIndex { $0.id == previous } ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        heading.stringValue = query.kind == .person ? "People · Return or Tab to insert · Escape to dismiss" : "Channels · Return or Tab to insert · Escape to dismiss"
        popover.contentSize = NSSize(width: 410, height: 35 + min(8, candidates.count) * 38)
        if !popover.isShown, let window = textView.window {
            let screen = textView.firstRect(forCharacterRange: NSRange(location: query.range.location, length: 0), actualRange: nil)
            var anchor = textView.convert(window.convertFromScreen(screen), from: nil)
            anchor.size.width = max(1, anchor.width); anchor.size.height = max(16, anchor.height)
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        }
    }
    func handle(_ event: NSEvent) -> Bool {
        guard popover.isShown, query != nil else { return false }
        if event.keyCode != 53 && !event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { close(); return false }
        switch event.keyCode {
        case 125, 126:
            let next = min(max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)), max(0, candidates.count - 1))
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next); return true
        case 36, 76, 48: chooseSelected(); return true
        case 53: dismissed = query; close(); return true
        default: return false
        }
    }
    func close() { popover.performClose(nil); query = nil; candidates = []; table.reloadData() }
    func reset() { dismissed = nil; close() }
    @objc func chooseSelected() {
        guard let query, candidates.indices.contains(table.selectedRow) else { return }
        let candidate = candidates[table.selectedRow]; close(); onChoose?(candidate, query)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // AppKit can finish laying out an old row after dismissal/reload.
        guard candidates.indices.contains(row) else { return nil }
        let candidate = candidates[row]
        let label = NSTextField(wrappingLabelWithString: "\(candidate.kind == .person ? "@" : "#") \(candidate.title)\n\(candidate.detail.isEmpty ? candidate.serverID : candidate.detail)")
        label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail; return label
    }
}
