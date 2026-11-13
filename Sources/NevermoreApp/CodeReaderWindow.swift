import AppKit
import NevermoreCore
import RavenProtocol

/// An auxiliary reading window. The transcript retains native cross-message selection.
@MainActor final class CodeReaderWindow: NSWindowController, NSWindowDelegate {
    let session: AccountSession
    private(set) var reference: CodeReference?
    let text = NSTextView()
    let scroll = NSScrollView()
    let wrapping = NSButton(checkboxWithTitle: "Wrap Lines", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var validation: Task<Void, Never>?
    private var closed = false
    init(session: AccountSession, reference: CodeReference) {
        self.session = session; self.reference = reference
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Code · \(reference.block.language ?? "Plain Text") · \(session.account.user)"; window.minSize = NSSize(width: 420, height: 260); window.center(); window.delegate = self
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.allowsUndo = false; text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.textColor = .labelColor; text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = NSRect(x: 0, y: 0, width: 760, height: 420); text.autoresizingMask = [.width]
        text.string = reference.block.text; text.setAccessibilityLabel("Code block, \(reference.block.language ?? "plain text"), \(reference.block.lineCount) lines")
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        wrapping.target = self; wrapping.action = #selector(changeWrapping)
        let copy = NSButton(title: "Copy Code", target: self, action: #selector(copyCode)); copy.setAccessibilityLabel("Copy entire code block")
        let buttons = NSStackView(views: [wrapping, NSView(), copy]); buttons.orientation = .horizontal; buttons.spacing = 10
        status.stringValue = "Read only · \(reference.block.lineCount) lines"; status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [buttons, scroll, status]); stack.orientation = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        if let view = window.contentView { view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)]) }
        window.initialFirstResponder = text; changeWrapping()
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] note in
            let account = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, account === self.session else { return }; self.validate() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) { guard !closed, isAuthorized else { close(); return }; super.showWindow(sender); window?.makeFirstResponder(text); validate() }
    private var isAuthorized: Bool {
        guard let reference else { return false }
        return !session.stopped && !session.revokedChannels.contains(reference.channelID) && reference.parentChannelID.map(session.revokedChannels.contains) != true && !session.deletedIDs.contains(reference.messageID) && !(reference.parentChannelID != nil && session.deletedIDs.contains(reference.channelID))
    }
    func validate() {
        guard !closed else { return }
        guard isAuthorized, let reference else { close(); return }
        validation?.cancel()
        validation = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await session.cachedMessages(channelID: reference.channelID, limit: 1000)
                guard !Task.isCancelled, !closed else { return }
                guard isAuthorized, let message = rows.first(where: { $0.id == reference.messageID }), let document = try? RichTextCodec.parse(message.html), CodeBlocks.extract(from: document).contains(where: { $0.id == reference.block.id }) else { close(); return }
            } catch { if !Task.isCancelled { close() } }
        }
    }
    func waitUntilValidated() async { await validation?.value }
    @objc func changeWrapping() {
        let wrap = wrapping.state == .on
        text.isHorizontallyResizable = !wrap; text.textContainer?.widthTracksTextView = wrap
        text.textContainer?.containerSize = NSSize(width: wrap ? max(1, scroll.contentSize.width - 24) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = !wrap
        window?.contentView?.layoutSubtreeIfNeeded()
        if wrap { text.setFrameSize(NSSize(width: max(1, scroll.contentSize.width), height: text.frame.height)) }
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            text.setFrameSize(NSSize(width: wrap ? max(1, scroll.contentSize.width) : max(scroll.contentSize.width, used.maxX + 24), height: max(scroll.contentSize.height, used.maxY + 24)))
        }
    }
    func windowDidResize(_ notification: Notification) { changeWrapping() }
    func copy(to pasteboard: NSPasteboard) {
        guard !closed, isAuthorized, let reference else { return }
        pasteboard.clearContents(); pasteboard.setString(reference.block.text, forType: .string)
    }
    @objc func largerText(_ sender: Any?) { resizeFont(1) }
    @objc func smallerText(_ sender: Any?) { resizeFont(-1) }
    private func resizeFont(_ delta: CGFloat) { text.font = .monospacedSystemFont(ofSize: min(36, max(10, (text.font?.pointSize ?? 13) + delta)), weight: .regular); changeWrapping() }
    @objc func copyCode(_ sender: Any?) { copy(to: .general) }
    @objc func findMessages(_ sender: Any?) { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; text.performTextFinderAction(item) }
    @objc func findNext(_ sender: Any?) { let item = NSMenuItem(); item.tag = NSTextFinder.Action.nextMatch.rawValue; text.performTextFinderAction(item) }
    private func discard() {
        guard !closed else { return }; closed = true; validation?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        text.string = ""; status.stringValue = ""; window?.title = "Code Reader"; reference = nil
        let callback = onClose; onClose = nil; callback?()
    }
    override func close() { discard(); super.close() }
    func windowWillClose(_ notification: Notification) { discard() }
}
