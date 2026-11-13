import AppKit
import RavenProtocol
import NevermoreCore

@MainActor final class ThreadInspector: NSViewController {
    let session: AccountSession
    let rootMessage: RavenMessage
    weak var conversation: ConversationWindow?
    let subscriptionID = UUID()
    let transcript = LiveResizeTextView()
    let scroll = NSScrollView()
    let context = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(labelWithString: "Loading thread…")
    private(set) var rows: [RavenMessage] = []
    private var messageRanges: [(NSRange, RavenMessage)] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var detached = false
    private var following = true
    /// Keeps the bottom of the replies in place while the inspector changes shape.
    private var viewportKeeper: TranscriptViewportKeeper?
    init(session: AccountSession, rootMessage: RavenMessage, conversation: ConversationWindow) {
        self.session = session; self.rootMessage = rootMessage; self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
        session.threadParents[rootMessage.id] = rootMessage.channelID
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Thread"); title.font = .preferredFont(forTextStyle: .headline)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Thread Inspector")!, target: self, action: #selector(closeInspector))
        close.isBordered = false; close.contentTintColor = .tertiaryLabelColor; close.symbolConfiguration = .init(pointSize: 14, weight: .regular); close.toolTip = "Close Thread (⌥⌘I)"
        let header = NSStackView(views: [title, NSView(), close]); header.orientation = .horizontal
        let rootText = NSMutableAttributedString(string: "\(session.authorName(rootMessage))\n", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
        rootText.append(NSAttributedString(string: String((try? RichTextCodec.plainText(RichTextCodec.parse(rootMessage.html)))?.prefix(800) ?? "Root message"), attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        context.attributedStringValue = rootText
        context.maximumNumberOfLines = 6; context.isSelectable = true; context.setAccessibilityLabel("Thread root message")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = true; transcript.drawsBackground = false; transcript.delegate = conversation
        transcript.textContainerInset = NSSize(width: 8, height: 12); transcript.isVerticallyResizable = true; transcript.autoresizingMask = .width; transcript.textContainer?.widthTracksTextView = true
        transcript.minSize = .zero; transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); transcript.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 300)
        transcript.setAccessibilityLabel("Thread replies")
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let reply = NSButton(title: "Open in Window", target: self, action: #selector(openWindow)); reply.toolTip = "Open this thread in its own window to reply"
        let parent = NSButton(title: "Show in Channel", target: self, action: #selector(showParent)); parent.toolTip = "Scroll the conversation to this thread’s first message"
        let buttons = NSStackView(views: [parent, NSView(), reply]); buttons.orientation = .horizontal; buttons.spacing = 8
        let divider = NSBox(); divider.boxType = .separator
        let stack = NSStackView(views: [header, context, status, divider, scroll, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        for view in [divider, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12), header.widthAnchor.constraint(equalTo: stack.widthAnchor), context.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
    }
    func start() {
        loadViewIfNeeded()
        session.attach(window: subscriptionID, channelID: rootMessage.id)
        observers.append(NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, source === self.session else { return }; self.render() }
        })
        let keeper = TranscriptViewportKeeper(scrollView: scroll, textView: transcript)
        keeper.isFollowing = { [weak self] in self?.following ?? false }
        keeper.onMove = { [weak self] in self?.seenVisible() }
        viewportKeeper = keeper
        render()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.session.load(channelID: self.rootMessage.id) }
            catch { if !Task.isCancelled && !self.detached { self.status.stringValue = error.localizedDescription } }
        }
    }
    func waitUntilLoaded() async { await refreshTask?.value; await renderTask?.value }
    func render() {
        guard !detached else { return }
        if session.stopped || session.deletedIDs.contains(rootMessage.id) || session.revokedChannels.contains(rootMessage.channelID) || session.revokedChannels.contains(rootMessage.id) { detach(); return }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = MessageWindow.bounded(try await session.cachedMessages(channelID: rootMessage.id, limit: 500), anchorID: following ? nil : messageRanges.first { rect($0.0).maxY >= scroll.contentView.bounds.minY }?.1.id)
                guard !Task.isCancelled, !detached, !session.stopped else { return }
                self.rows = rows
                let anchor = messageRanges.first { rect($0.0).maxY >= scroll.contentView.bounds.minY }.map { ($0.1.id, rect($0.0).minY - scroll.contentView.bounds.minY) }
                let output = NSMutableAttributedString(string: ""); messageRanges = []
                let storedSize = UserDefaults.standard.double(forKey: "fontSize")
                let fontSize = CGFloat(storedSize.isFinite && storedSize > 0 ? min(30, max(11, storedSize)) : 14)
                for message in rows {
                    let start = output.length
                    output.append(NSAttributedString(string: "\(session.authorName(message)) · \(session.displayTimestamp(message.creation))\n", attributes: [.font:NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor:NSColor.secondaryLabelColor]))
                    if let doc = try? RichTextCodec.parse(message.html) { output.append(NativeRichText.readingString(document: doc, fontSize: fontSize)) }
                    if let file = message.raw["file"].string { output.append(NSAttributedString(string: "\n📎 \(URL(string: file)?.lastPathComponent ?? "Attachment") · open the thread window to preview")) }
                    output.append(NSAttributedString(string: UserDefaults.standard.bool(forKey: "compactMessages") ? "\n" : "\n\n")); messageRanges.append((NSRange(location: start, length: output.length - start), message))
                }
                let selection = transcript.selectedRange()
                viewportKeeper?.isReplacingText = true
                transcript.textStorage?.setAttributedString(output)
                if NSMaxRange(selection) <= output.length { transcript.setSelectedRange(selection) }
                transcript.layoutManager?.ensureLayout(for: transcript.textContainer!)
                if following { transcript.scrollToEndOfDocument(nil) }
                else if let anchor, let range = messageRanges.first(where: { $0.1.id == anchor.0 })?.0 { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect(range).minY - anchor.1))); scroll.reflectScrolledClipView(scroll.contentView) }
                viewportKeeper?.isReplacingText = false
                status.stringValue = session.demo ? "Local demo thread" : "\(rows.count) cached replies · \(session.state)"
                seenVisible(); viewportKeeper?.capture()
            } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
        }
    }
    private func rect(_ range: NSRange) -> NSRect {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer else { return .zero }
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container); rect.origin.y += transcript.textContainerInset.height; return rect
    }
    private func seenVisible() {
        following = scroll.contentView.bounds.maxY >= transcript.bounds.maxY - 20
        guard !detached, NSApp.isActive, view.window?.isKeyWindow == true, !view.isHidden,
              let seen = messageRanges.last(where: { scroll.contentView.bounds.intersects(rect($0.0)) })?.1 else { return }
        Task { await session.markSeen(channelID: rootMessage.id, timestamp: seen.creation) }
    }
    func detach() {
        guard !detached else { return }
        detached = true; refreshTask?.cancel(); renderTask?.cancel(); session.attach(window: subscriptionID, channelID: nil)
        viewportKeeper?.invalidate(); viewportKeeper = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        context.stringValue = ""; transcript.string = ""; rows = []; messageRanges = []; status.stringValue = "Thread closed"
    }
    @objc private func closeInspector() { conversation?.closeThreadInspector() }
    @objc func openWindow() {
        guard !session.stopped, !session.revokedChannels.contains(rootMessage.channelID) else { return }
        conversation?.app.open(session: session, channel: RavenChannel(raw: .object(["name":.string(rootMessage.id), "channel_name":.string("Thread · \(rootMessage.owner)"), "is_thread":.bool(true), "parent_channel_id":.string(rootMessage.channelID)])))
    }
    @objc func showParent() {
        guard let parent = session.channels.first(where: { $0.id == rootMessage.channelID }) else { return }
        conversation?.select(parent, anchor: rootMessage.id)
    }
}
