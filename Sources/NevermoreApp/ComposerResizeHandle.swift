import AppKit

@MainActor final class ComposerResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var previousY: CGFloat?
    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Composer height")
        setAccessibilityHelp("Drag to resize. Double-click to fit the text.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Increase height", target: self, selector: #selector(increase)),
            NSAccessibilityCustomAction(name: "Decrease height", target: self, selector: #selector(decrease)),
            NSAccessibilityCustomAction(name: "Fit text", target: self, selector: #selector(reset))
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1, width: 32, height: 2), xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); previousY = nil; return }
        previousY = event.locationInWindow.y
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousY else { return }
        onDrag?(event.locationInWindow.y - previousY)
        self.previousY = event.locationInWindow.y
    }
    override func mouseUp(with event: NSEvent) { previousY = nil }
    @objc private func increase() -> Bool { onDrag?(24); return true }
    @objc private func decrease() -> Bool { onDrag?(-24); return true }
    @objc private func reset() -> Bool { onReset?(); return true }
}
