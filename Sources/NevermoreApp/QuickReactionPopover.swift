import AppKit
import NevermoreCore

/// A borderless button that shows a rounded highlight under the pointer and
/// the arrow cursor, so controls floating over selectable text read as
/// clickable rather than as text.
@MainActor class HoverHighlightButton: NSButton {
    /// Pointer hover, drawn as a subtle fill.
    var isHovered = false { didSet { if oldValue != isHovered { hoverChanged() } } }
    /// Keyboard focus inside the quick reaction row, drawn like hover.
    var isKeyboardFocused = false { didSet { if oldValue != isKeyboardFocused { refreshAppearance() } } }
    /// A reaction the user already added, drawn with an accent tint.
    var isChosen = false { didSet { if oldValue != isChosen { needsDisplay = true } } }
    /// The tint at rest; hover raises it to the primary label color.
    var restingTint: NSColor? { didSet { contentTintColor = restingTint } }
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Active-app rather than key-window tracking: a popover's window is
        // not always key while the pointer moves over it.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { isHovered = false } }
    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isHighlighted { fill = NSColor.labelColor.withAlphaComponent(0.2) }
        else if isChosen { fill = NSColor.themeAccent.withAlphaComponent(isHovered || isKeyboardFocused ? 0.35 : 0.22) }
        else if isHovered || isKeyboardFocused { fill = NSColor.labelColor.withAlphaComponent(0.1) }
        else { fill = nil }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    private func hoverChanged() {
        refreshAppearance()
        onHover?(isHovered)
    }
    /// Hover and the keyboard share one appearance, as in menus.
    private func refreshAppearance() {
        if restingTint != nil { contentTintColor = (isHovered || isKeyboardFocused) ? .labelColor : restingTint }
        needsDisplay = true
    }
}

/// One-click reactions for a message, shown from the hover bar's React
/// button or the Message menu. The full picker stays one click away under
/// More Emoji…, and choosing anything closes the row.
///
/// Keyboard: Left and Right move between buttons, Return or Space chooses,
/// 1 to 8 choose directly, and Escape closes.
///
/// An emoji can also be dragged out of the row: after 6 points the row
/// closes and `onCarry` takes over the press (see `StickerController`).
@MainActor final class QuickReactionPopover: NSObject, NSPopoverDelegate {
    enum Focus { case none, first }

    let popover = NSPopover()
    private let content = QuickReactionContentView()
    private(set) var messageID: String?
    private(set) var emoji: [String] = []
    private(set) var buttons: [HoverHighlightButton] = []
    /// Called with the emoji and the screen rectangle of its button when
    /// the reader drags it out of the row. The mouse is still down.
    var onCarry: ((String, NSRect) -> Void)?
    /// The button behind the latest choice, in screen coordinates.
    private var choiceOrigin: NSRect?
    /// Where the chosen emoji starts its trip to the message; nil when
    /// the choice did not come from a button on screen. Read once.
    func takeChoiceOrigin() -> NSRect? { defer { choiceOrigin = nil }; return choiceOrigin }
    let moreButton = HoverHighlightButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More Emoji…")!, target: nil, action: nil)
    /// Called with the chosen emoji and the message it reacts to.
    var onChoose: ((String, String) -> Void)?
    /// Called with the message ID when the full picker is requested.
    var onMore: ((String) -> Void)?
    private var focusedIndex: Int? { didSet { updateFocus() } }

    var isShown: Bool { messageID != nil && popover.isShown }

    override init() {
        super.init()
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        // Appearing instantly keeps a one-click action feeling immediate.
        popover.animates = false
        popover.delegate = self
        content.owner = self
        moreButton.target = self; moreButton.action = #selector(more(_:))
        moreButton.isBordered = false; moreButton.toolTip = "More Emoji…"; moreButton.refusesFirstResponder = true
        moreButton.symbolConfiguration = .init(pointSize: 17, weight: .regular); moreButton.restingTint = .secondaryLabelColor
        moreButton.setAccessibilityLabel("More Emoji…")
        QuickReactionContentView.size(moreButton)
    }

    /// Shows the row for `messageID`, anchored to `rect` in `view`. `reacted`
    /// marks the user's existing reactions, which a click removes.
    func show(emoji: [String], reacted: Set<String>, messageID: String, relativeTo rect: NSRect, of view: NSView, focus: Focus) {
        close()
        self.emoji = emoji; self.messageID = messageID
        buttons = emoji.enumerated().map { index, value in
            let button = StickerSourceButton(title: value, target: self, action: #selector(choose(_:)))
            button.isBordered = false; button.font = .systemFont(ofSize: Stickers.pointSize); button.tag = index; button.refusesFirstResponder = true
            button.onDrag = { [weak self] in self?.carry(index) }
            button.isChosen = reacted.contains(value)
            button.setAccessibilityLabel(button.isChosen ? "Remove your \(value) reaction" : "React with \(value)")
            if button.isChosen { button.toolTip = "Remove your reaction" }
            button.onHover = { [weak self] hovered in self?.pointer(over: index, hovered) }
            return button
        }
        moreButton.onHover = { [weak self, count = buttons.count] hovered in self?.pointer(over: count, hovered) }
        content.setButtons(buttons, more: moreButton)
        focusedIndex = focus == .first && !buttons.isEmpty ? 0 : nil
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        // Take key focus so arrow keys reach the row, not the transcript.
        content.window?.makeKey()
        content.window?.makeFirstResponder(content)
    }

    /// Moves the arrow to the target message after scrolling or re-rendering.
    func reposition(to rect: NSRect) { if isShown { popover.positioningRect = rect } }

    func close() {
        guard messageID != nil else { return }
        messageID = nil; focusedIndex = nil
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        // A close callback for the previous presentation can arrive after
        // show(…) has already displayed a new row; don't tear that down.
        guard !popover.isShown else { return }
        close()
    }

    @objc private func choose(_ sender: NSButton) { activate(sender.tag) }
    @objc private func more(_ sender: Any?) {
        guard let messageID else { return }
        close(); onMore?(messageID)
    }
    private func activate(_ index: Int) {
        guard let messageID, emoji.indices.contains(index) else { return }
        let value = emoji[index]
        choiceOrigin = screenRect(of: index)
        close(); onChoose?(value, messageID)
    }
    private func screenRect(of index: Int) -> NSRect? {
        guard buttons.indices.contains(index), let window = buttons[index].window else { return nil }
        return window.convertToScreen(buttons[index].convert(buttons[index].bounds, to: nil))
    }
    private func carry(_ index: Int) {
        guard messageID != nil, emoji.indices.contains(index), let origin = screenRect(of: index) else { return }
        let value = emoji[index]
        // Out of sight while the emoji is in the hand, and closed after:
        // closing now would discard the mouse-up queued for this window.
        let row = content.window
        row?.alphaValue = 0
        onCarry?(value, origin)
        row?.alphaValue = 1
        close()
    }
    /// Hover and the keyboard share one highlight, as in menus, so Return
    /// chooses the emoji under the pointer.
    private func pointer(over index: Int, _ hovered: Bool) {
        if hovered { focusedIndex = index } else if focusedIndex == index { focusedIndex = nil }
    }
    private func updateFocus() {
        for (index, button) in buttons.enumerated() { button.isKeyboardFocused = index == focusedIndex }
        moreButton.isKeyboardFocused = focusedIndex == buttons.count
    }

    /// Returns true when the row handled `event`.
    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        guard isShown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let last = buttons.count  // The More button follows the emoji.
        switch event.keyCode {
        case 123: focusedIndex = max(0, (focusedIndex ?? 1) - 1); return true
        case 124: focusedIndex = min(last, (focusedIndex ?? -1) + 1); return true
        case 36, 76, 49:
            guard let focusedIndex else { return true }
            if focusedIndex == last { more(nil) } else { activate(focusedIndex) }
            return true
        case 53: close(); return true
        default: break
        }
        // An empty row would make `1...buttons.count` an invalid ClosedRange.
        if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1, digit <= buttons.count { activate(digit - 1); return true }
        return false
    }
}

/// An emoji in the quick reaction row. A click chooses it, as any button
/// does; a press that moves 6 points picks it up instead.
@MainActor final class StickerSourceButton: HoverHighlightButton {
    var onDrag: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard let onDrag, isEnabled, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        while true {
            let step = PressTracking.next()
            if step == .cancelled { return }
            let point = window.mouseLocationOutsideOfEventStream
            let inside = bounds.contains(convert(point, from: nil))
            if step == .released {
                if inside { highlight(false); sendAction(action, to: target) }
                return
            }
            if StickerRules.isDrag(from: start, to: point) { highlight(false); onDrag(); return }
            highlight(inside)
        }
    }
}

/// The popover's content: the emoji row, a divider and More Emoji…. It stays
/// first responder so arrow keys work without Full Keyboard Access.
@MainActor private final class QuickReactionContentView: NSView {
    weak var owner: QuickReactionPopover?
    private let stack = NSStackView()
    init() {
        super.init(frame: .zero)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quick reactions")
    }
    required init?(coder: NSCoder) { fatalError() }
    func setButtons(_ buttons: [HoverHighlightButton], more: HoverHighlightButton) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let divider = NSBox(); divider.boxType = .separator
        // Emoji buttons are new on every show; More is reused and sized once.
        for button in buttons { Self.size(button) }
        for view in buttons as [NSView] + [divider, more] { stack.addArrangedSubview(view) }
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.setCustomSpacing(6, after: buttons.last ?? divider)
        stack.setCustomSpacing(6, after: divider)
    }
    static func size(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if owner?.handleKey(event) != true { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { owner?.close() }
}
