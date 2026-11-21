import AppKit
import NevermoreCore
import RavenProtocol

/// Conversation Info ▸ Channel Details. A compact attached sheet of native,
/// selectable fields built from the channel snapshot the session already
/// holds. It makes no request, and a permission change while it is open
/// clears the fields instead of leaving stale facts on screen.
@MainActor final class ChannelDetailsSheet: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        var cancelHandler: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { cancelHandler?() }
    }

    /// A read-only text view remains selectable and is the only native text
    /// control that still accepts key focus, so the sheet's fields use it.
    private final class SelectableTextView: NSTextView {
        override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
        override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
        override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    }

    private static let panelWidth: CGFloat = 540
    private static let contentInsets: CGFloat = 16
    private static let sectionSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 10
    private static let maximumRowsHeight: CGFloat = 320
    private static var valueWidth: CGFloat { Self.panelWidth - Self.contentInsets * 2 - 6 }

    private let session: AccountSession
    private let channel: RavenChannel
    private weak var parent: NSWindow?
    private let panel: Panel
    private let heading = NSTextField(labelWithString: "Channel Details")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let rowsScroll = NSScrollView()
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var displayedRows: [ChannelDetailRow]?
    private var displayedFontSize: CGFloat?
    private var rowsHeight: NSLayoutConstraint?
    private var valueFields: [SelectableTextView] = []
    private var observer: NSObjectProtocol?
    private var closed = false
    private var tornDown = false
    var onClose: (() -> Void)?

    init(session: AccountSession, channel: RavenChannel) {
        self.session = session
        self.channel = channel
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Channel Details"
        panel.delegate = self
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: Self.panelWidth, height: 160)
        panel.cancelHandler = { [weak self] in self?.close() }

        heading.font = .preferredFont(forTextStyle: .headline)
        heading.textColor = .labelColor
        notice.font = .systemFont(ofSize: NSFont.systemFontSize)
        notice.textColor = .secondaryLabelColor
        notice.preferredMaxLayoutWidth = Self.valueWidth
        notice.setAccessibilityLabel("Channel details unavailable")

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Self.rowSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsScroll.hasVerticalScroller = true
        rowsScroll.hasHorizontalScroller = false
        rowsScroll.borderType = .bezelBorder
        rowsScroll.drawsBackground = true
        rowsScroll.documentView = rowsStack
        rowsScroll.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, notice, rowsScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.contentInsets),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.contentInsets),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentInsets),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.contentInsets),
                rowsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                rowsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                rowsStack.widthAnchor.constraint(equalTo: rowsScroll.contentView.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        panel.defaultButtonCell = closeButton.cell as? NSButtonCell
    }

    func present(on parent: NSWindow) {
        self.parent = parent
        apply()
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.session.stopped else { self.close(); return }
                self.apply()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose), name: NSWindow.willCloseNotification, object: parent)
        parent.beginSheet(panel) { [weak self] _ in self?.teardown() }
    }

    @objc func close() {
        guard !closed else { return }
        closed = true
        if let parent { parent.endSheet(panel) }
        panel.orderOut(nil)
        teardown()
    }

    private func apply() {
        // Prefer the session's current snapshot; the window's channel remains
        // the fallback for a thread that is authorized but not in the list.
        let current = session.channels.first { $0.id == channel.id } ?? channel
        let rows = ChannelDetails.rows(for: current, revoked: session.revokedChannels, threadParents: session.threadParents, deleted: session.deletedIDs)
        let fontSize = Self.valueFont().pointSize
        guard displayedRows != rows || displayedFontSize != fontSize else { return }
        displayedRows = rows
        displayedFontSize = fontSize
        rebuild(rows: rows, inaccessible: rows.isEmpty)
        layoutPanel()
    }

    private func rebuild(rows: [ChannelDetailRow], inaccessible: Bool) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        valueFields.removeAll()
        notice.isHidden = !inaccessible
        notice.stringValue = inaccessible ? "Access to this conversation changed. Refresh the account to clear it." : ""
        if inaccessible {
            closeButton.nextKeyView = nil
            panel.initialFirstResponder = closeButton
            if panel.sheetParent != nil { panel.makeFirstResponder(closeButton) }
            return
        }

        let font = Self.valueFont()
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel("\(row.label) label")

            let value = SelectableTextView()
            value.isEditable = false
            value.isSelectable = true
            value.isRichText = false
            value.allowsUndo = false
            value.font = font
            value.textColor = .labelColor
            value.textContainerInset = NSSize(width: 0, height: 1)
            value.isHorizontallyResizable = false
            value.isVerticallyResizable = true
            value.textContainer?.widthTracksTextView = true
            value.autoresizingMask = .width
            value.string = row.value
            value.frame = NSRect(x: 0, y: 0, width: Self.valueWidth, height: 10)
            value.sizeToFit()
            value.setAccessibilityLabel(row.label)
            value.setContentCompressionResistancePriority(.required, for: .vertical)
            value.setContentHuggingPriority(.required, for: .vertical)
            value.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(label)
            rowsStack.addArrangedSubview(value)
            valueFields.append(value)
            NSLayoutConstraint.activate([
                value.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
                value.heightAnchor.constraint(equalToConstant: value.frame.height)
            ])
        }

        for (index, field) in valueFields.enumerated() {
            field.nextKeyView = index + 1 < valueFields.count ? valueFields[index + 1] : closeButton
        }
        closeButton.nextKeyView = valueFields.first
        panel.initialFirstResponder = valueFields.first ?? closeButton
    }

    private func layoutPanel() {
        rowsStack.layoutSubtreeIfNeeded()
        let fittedRowsHeight = min(max(rowsStack.fittingSize.height, 56), Self.maximumRowsHeight)
        rowsHeight?.isActive = false
        let height = rowsScroll.heightAnchor.constraint(equalToConstant: fittedRowsHeight)
        height.isActive = true
        rowsHeight = height
        notice.layoutSubtreeIfNeeded()
        let noticeHeight = notice.isHidden ? 0 : notice.fittingSize.height
        let heightWithSpacing = Self.contentInsets * 2 + heading.fittingSize.height
            + (notice.isHidden ? 0 : Self.sectionSpacing + noticeHeight)
            + Self.sectionSpacing + fittedRowsHeight
            + Self.sectionSpacing + closeButton.fittingSize.height
        panel.setContentSize(NSSize(width: Self.panelWidth, height: min(heightWithSpacing, 560)))
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private static func valueFont() -> NSFont {
        let stored = UserDefaults.standard.double(forKey: "fontSize")
        let size = stored.isFinite && stored > 0 ? min(30, max(11, stored)) : 14
        return ThemeFonts.readingBody(ofSize: CGFloat(size))
    }

    @objc private func parentWillClose(_ notification: Notification) { close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let parent { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent) }
        let callback = onClose
        onClose = nil
        callback?()
    }
}
