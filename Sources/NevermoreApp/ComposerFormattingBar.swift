import AppKit

@MainActor final class ComposerFormattingBar: NSStackView {
    enum Command: Int, CaseIterable {
        case bold, italic, underline, strike, highlight, spoiler, inlineCode, codeBlock, bullets, numbers, quote, rule, link, table, clearFormatting
        var title: String {
            switch self {
            case .bold: "Bold"
            case .italic: "Italic"
            case .underline: "Underline"
            case .strike: "Strikethrough"
            case .highlight: "Highlight"
            case .spoiler: "Spoiler"
            case .inlineCode: "Inline Code"
            case .codeBlock: "Code Block"
            case .bullets: "Bulleted List"
            case .numbers: "Numbered List"
            case .quote: "Block Quote"
            case .rule: "Horizontal Rule"
            case .link: "Link…"
            case .table: "Insert or Edit Table…"
            case .clearFormatting: "Clear Formatting"
            }
        }
        var selector: Selector {
            switch self {
            case .bold: #selector(ComposerView.toggleBoldface(_:))
            case .italic: #selector(ComposerView.toggleItalics(_:))
            case .underline: #selector(ComposerView.toggleUnderline(_:))
            case .strike: #selector(ComposerView.toggleStrikethrough(_:))
            case .highlight: #selector(ComposerView.toggleHighlight(_:))
            case .spoiler: #selector(ComposerView.toggleSpoiler(_:))
            case .inlineCode: #selector(ComposerView.toggleInlineCode(_:))
            case .codeBlock: #selector(ComposerView.formatCodeBlock(_:))
            case .bullets: #selector(ComposerView.bulletedList(_:))
            case .numbers: #selector(ComposerView.numberedList(_:))
            case .quote: #selector(ComposerView.blockquote(_:))
            case .rule: #selector(ComposerView.insertRule(_:))
            case .link: #selector(ComposerView.formatLink(_:))
            case .table: #selector(ComposerView.editTable(_:))
            case .clearFormatting: #selector(ComposerView.clearFormatting(_:))
            }
        }
    }
    private weak var composer: ComposerView?
    var sourceAction: ((Command) -> Void)?
    var onModeChange: ((Int) -> Void)? { didSet { modes.isHidden = onModeChange == nil } }
    var selectedMode: Int = 0 { didSet { modes.selectedSegment = selectedMode } }
    private let modes = NSSegmentedControl(labels: ["Visual", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private let more = NSButton()
    private var tableButton: NSButton?
    private var includesTable = true
    var isEnabled = true {
        didSet { for case let control as NSControl in arrangedSubviews { control.isEnabled = isEnabled } }
    }
    init(composer: ComposerView, includesTable: Bool = true) {
        self.composer = composer; self.includesTable = includesTable
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 4
        edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        setAccessibilityLabel("Message formatting")
        for (command, symbol, shortcut) in [(Command.bold, "bold", "⌘B"), (.italic, "italic", "⌘I"), (.underline, "underline", "⌘U")] {
            let button = makeButton(symbol: symbol, label: command.title, action: #selector(performCommand(_:)))
            button.tag = command.rawValue; button.toolTip = "\(command.title) (\(shortcut))"; addArrangedSubview(button)
        }
        if includesTable {
            let table = makeButton(symbol: "tablecells", label: "Insert or Edit Table", action: #selector(performCommand(_:)))
            table.tag = Command.table.rawValue; tableButton = table; addArrangedSubview(table)
        }
        more.tag = -1
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More formatting")
        more.isBordered = false; more.target = self; more.action = #selector(showMore(_:))
        more.toolTip = "More formatting"; more.setAccessibilityLabel("More formatting")
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 28), more.heightAnchor.constraint(equalToConstant: 28)])
        addArrangedSubview(more); addArrangedSubview(NSView())
        modes.controlSize = .small; modes.segmentStyle = .rounded; modes.selectedSegment = 0
        // The theme accent, not the system blue, marks the selected mode.
        modes.selectedSegmentBezelColor = .themeAccent
        modes.target = self; modes.action = #selector(changeMode(_:)); modes.isHidden = true
        modes.setAccessibilityLabel("Writing mode")
        modes.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(modes)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = FormattingIconButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.contentTintColor = .secondaryLabelColor; button.toolTip = label; button.setAccessibilityLabel(label)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
        return button
    }
    func updateSelection() {
        guard let composer else { return }
        for case let button as NSButton in arrangedSubviews {
            guard let command = Command(rawValue: button.tag) else { continue }
            button.state = sourceAction == nil && isActive(command, composer: composer) ? .on : .off
        }
    }
    private func isActive(_ command: Command, composer: ComposerView) -> Bool {
        func active(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            switch command {
            case .bold: return traits.contains(.boldFontMask)
            case .italic: return traits.contains(.italicFontMask)
            case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strike: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            case .highlight: return attributes[.highlight] as? Bool == true
            case .spoiler: return NativeRichText.isSpoiler(attributes)
            case .inlineCode: return traits.contains(.fixedPitchFontMask) && attributes[.blockKind] as? String != "pre"
            default: return false
            }
        }
        let range = composer.selectedRange(), text = composer.attributedString()
        guard range.location != NSNotFound, range.location <= text.length, range.length <= text.length - range.location else { return false }
        if range.length == 0 { return active(composer.typingAttributes) }
        var all = true
        text.enumerateAttributes(in: range) { attrs, _, stop in
            if !active(attrs) { all = false; stop.pointee = true }
        }
        return all
    }
    override func layout() {
        let hideTable = onModeChange != nil && bounds.width < 400
        if tableButton?.isHidden != hideTable { tableButton?.isHidden = hideTable }
        super.layout()
    }
    @objc private func changeMode(_ sender: NSSegmentedControl) { guard isEnabled else { return }; onModeChange?(sender.selectedSegment) }
    func formattingMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for command in Command.allCases where command.rawValue >= Command.strike.rawValue && (command != .table || (includesTable && tableButton?.isHidden == true)) {
            let item = NSMenuItem(title: command.title, action: #selector(performCommand(_:)), keyEquivalent: "")
            item.tag = command.rawValue; item.target = self
            if command == .clearFormatting {
                item.isEnabled = isEnabled && sourceAction == nil && (composer?.canClearFormatting() ?? false)
            } else {
                item.isEnabled = isEnabled
                if sourceAction == nil, let composer, isActive(command, composer: composer) { item.state = .on }
            }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func showMore(_ sender: NSButton) {
        formattingMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }
    @objc private func performCommand(_ sender: AnyObject) {
        guard isEnabled, let command = Command(rawValue: (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? -1) else { return }
        if let sourceAction { sourceAction(command); return }
        guard let composer, composer.isEditable, !composer.hasMarkedText() else { return }
        composer.window?.makeFirstResponder(composer)
        _ = composer.tryToPerform(command.selector, with: sender)
        updateSelection()
    }
}

@MainActor private final class FormattingIconButton: NSButton {
    private var hovering = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovering || state == .on) {
            NSColor.labelColor.withAlphaComponent(state == .on ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
