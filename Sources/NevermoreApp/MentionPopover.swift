import AppKit
import NevermoreCore

@MainActor final class MentionPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// What a row shows beside the name: a portrait or channel tile, the
    /// symbol drawn while there is no image, and a person's presence.
    struct Artwork {
        var image: NSImage?
        var symbol: String
        var presence: String?
        static func placeholder(for kind: MentionCandidate.Kind) -> Artwork { Artwork(symbol: kind == .person ? "person.crop.circle" : "number") }
    }
    /// Rows shown before the list scrolls.
    static let visibleRows = 8
    private static let rowHeight: CGFloat = 30
    private static let width: CGFloat = 360
    let popover = NSPopover()
    let table = NSTableView()
    let scroll = NSScrollView()
    let heading = NSTextField(labelWithString: "")
    private let root = NSView()
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
    var candidates: [MentionCandidate] = []
    private(set) var query: MentionQuery?
    var onChoose: ((MentionCandidate, MentionQuery) -> Void)?
    /// Supplies each row's artwork; without it a row shows its kind's symbol.
    var artwork: ((MentionCandidate) -> Artwork?)?
    private var dismissed: MentionQuery?
    override init() {
        super.init()
        let controller = NSViewController()
        controller.view = root; popover.contentViewController = controller; popover.behavior = .semitransient; popover.animates = false
        // The editor drives the list by its keys. A list that accepted focus
        // took it from the Markdown editor when the popover appeared.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.refusesFirstResponder = true; table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(chooseSelected)
        table.setAccessibilityLabel("Mention suggestions"); table.allowsEmptySelection = false
        // Plain rows on the popover's own material. The default inset style
        // padded the list past the height the popover gave it, clipping
        // rows behind a scroll bar, and the table's opaque background
        // covered the material.
        table.style = .plain; table.backgroundColor = .clear; table.intercellSpacing = .zero; table.rowHeight = Self.rowHeight; table.rowSizeStyle = .custom
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsetsZero
        heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .themeSecondaryText
        let hint = HomeText.label("Return or Tab to insert · Escape to dismiss", font: .systemFont(ofSize: 11), color: .themeTertiaryText)
        let header = NSStackView(views: [heading, NSView(), hint]); header.orientation = .horizontal; header.spacing = 8; header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let stack = NSStackView(views: [header, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        // Rows sit 10 points in from the popover's edge, so their rounded
        // selection nests inside its corners.
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6), header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), listHeight])
    }
    func update(textView: NSTextView, pool: [MentionCandidate]) {
        guard textView.window?.isKeyWindow == true, textView.window?.firstResponder === textView,
              let query = MentionCompletion.query(in: textView.string, selection: textView.selectedRange(), hasMarkedText: textView.hasMarkedText()) else { close(); return }
        // Code is literal: the visual composer marks it with a fixed-pitch
        // font, while Markdown source is all fixed pitch and marks it with
        // backticks and fences.
        let location = textView.selectedRange().location
        if textView.isRichText {
            if location > 0, let font = textView.attributedString().attribute(.font, at: location - 1, effectiveRange: nil) as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) { close(); return }
        } else if MentionCompletion.isInsideMarkdownCode(textView.string, at: location) { close(); return }
        var hasSemantic = false
        textView.attributedString().enumerateAttribute(NSAttributedString.Key("Nevermore.SemanticNode"), in: query.range) { marker, _, stop in if marker != nil { hasSemantic = true; stop.pointee = true } }
        guard !hasSemantic, query != dismissed else { close(); return }
        let next = MentionCompletion.matches(pool, query: query)
        guard !next.isEmpty else { close(); return }
        let previous = candidates.indices.contains(table.selectedRow) ? candidates[table.selectedRow].id : nil
        self.query = query; candidates = next; table.reloadData()
        let index = candidates.firstIndex { $0.id == previous } ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        heading.stringValue = query.kind == .person ? "People" : "Channels"
        // The popover takes the height of the rows it shows, so a short
        // list neither clips nor scrolls.
        listHeight.constant = CGFloat(min(Self.visibleRows, candidates.count)) * Self.rowHeight
        root.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: Self.width, height: root.fittingSize.height)
        if !popover.isShown, let window = textView.window {
            let screen = textView.firstRect(forCharacterRange: NSRange(location: query.range.location, length: 0), actualRange: nil)
            var anchor = textView.convert(window.convertFromScreen(screen), from: nil)
            anchor.size.width = max(1, anchor.width); anchor.size.height = max(16, anchor.height)
            // Above the line, over the transcript: the composer sits at the
            // window's foot, and a list below it hung off the window. A
            // flipped view's top edge is its minimum Y.
            popover.show(relativeTo: anchor, of: textView, preferredEdge: textView.isFlipped ? .minY : .maxY)
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
    /// Redraws the shown rows, as when a profile photo arrives.
    func refreshArtwork() {
        guard popover.isShown else { return }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: IndexSet(integer: 0))
    }
    func reset() { dismissed = nil; close() }
    @objc func chooseSelected() {
        guard let query, candidates.indices.contains(table.selectedRow) else { return }
        let candidate = candidates[table.selectedRow]; close(); onChoose?(candidate, query)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MentionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // AppKit can finish laying out an old row after dismissal/reload.
        guard candidates.indices.contains(row) else { return nil }
        let candidate = candidates[row]
        return MentionCell(candidate, artwork: artwork?(candidate) ?? .placeholder(for: candidate.kind))
    }
}

/// One suggestion on one line: portrait or channel tile, the name, and a
/// quieter detail (a person's username, a channel's workspace) that gives
/// way first when space runs out.
@MainActor private final class MentionCell: NSTableCellView {
    init(_ candidate: MentionCandidate, artwork: MentionPopover.Artwork) {
        super.init(frame: .zero)
        let avatar = HomeAvatar(size: 22, shape: candidate.kind == .person ? .circle : .tile)
        avatar.image = artwork.image; avatar.symbol = artwork.symbol; avatar.presence = artwork.presence
        // The tile already marks a channel, as in the sidebar.
        let title = HomeText.label(candidate.title, font: .systemFont(ofSize: 13, weight: .semibold), color: .themeText)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let detailText = candidate.detail == candidate.title ? "" : candidate.detail
        let detail = HomeText.label(detailText, font: .systemFont(ofSize: 12), color: .themeSecondaryText)
        let stack = NSStackView(views: [avatar, title, detail]); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 6; stack.setCustomSpacing(8, after: avatar)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews { view.setAccessibilityElement(false) }
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityElement(true); setAccessibilityRole(.cell)
        setAccessibilityLabel([candidate.title, detailText, artwork.presence ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Search's accent selection, always drawn as active: the composer keeps
/// focus while its keys move the selection, so the list is never first
/// responder and would otherwise show the gray inactive selection.
@MainActor private final class MentionRowView: SearchRowView {
    override var isEmphasized: Bool { get { true } set {} }
}
