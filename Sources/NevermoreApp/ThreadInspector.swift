import AppKit
import RavenProtocol
import NevermoreCore

@MainActor final class ThreadInspector: NSViewController {
    /// Below this window width the shell hides the pane without releasing it.
    static let minimumWindowWidth: CGFloat = 1000
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
    /// Page sizes for the newest window and a window the reader paged back.
    private static let newestPageSize = 500
    /// One server page in `Session.load`; a full page implies older history.
    private static let serverPageSize = 100
    /// The oldest reply in a paged window; nil means the live newest window.
    private var oldestLoaded: RavenMessage?
    /// A refresh failure latched so a later cached render cannot hide it.
    private var refreshError: String?
    private var loadingEarlier = false
    private var hasOlder = true
    /// Pages the reader has gone back, so the render window grows with them.
    private var pagedPages = 0
    private let earlierButton = NSButton(title: "Load Earlier", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    /// The owning window forgets this pane when it discards private content.
    var onInvalidated: (@MainActor () -> Void)?
    var isDetached: Bool { detached }
    var hasAccess: Bool {
        !session.stopped && !session.deletedIDs.contains(rootMessage.id)
            && !ChannelPolicy.isRevoked(channelID: rootMessage.id, revoked: session.revokedChannels, threadParents: session.threadParents)
            && !ChannelPolicy.isRevoked(channelID: rootMessage.channelID, revoked: session.revokedChannels, threadParents: session.threadParents)
    }
    private var following = true
    /// A render found the transcript under a press; see `LiveResizeTextView`.
    private var renderAfterPress = false
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
        earlierButton.target = self; earlierButton.action = #selector(loadEarlier); earlierButton.toolTip = "Load the previous page of replies"
        retryButton.target = self; retryButton.action = #selector(retryRefresh); retryButton.toolTip = "Try the thread request again"
        for button in [earlierButton, retryButton] { button.setAccessibilityLabel(button.title) }
        let header = NSStackView(views: [title, NSView(), earlierButton, retryButton, close]); header.orientation = .horizontal
        context.maximumNumberOfLines = 6; context.isSelectable = true; context.setAccessibilityLabel("Thread root message")
        // Same truncation idiom as the other labels: wrap to six lines,
        // ellipsize the last visible one.
        context.lineBreakMode = .byTruncatingTail
        showRootHeader(for: rootMessage)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = true; transcript.drawsBackground = false; transcript.delegate = conversation
        transcript.textContainerInset = NSSize(width: 8, height: 12); transcript.isVerticallyResizable = true; transcript.autoresizingMask = .width; transcript.textContainer?.widthTracksTextView = true
        transcript.minSize = .zero; transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); transcript.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 300)
        transcript.setAccessibilityLabel("Thread replies")
        transcript.pressDidEnd = { [weak self] in
            guard let self, self.renderAfterPress else { return }
            self.renderAfterPress = false; self.render()
        }
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let parent = NSButton(title: "Show in Channel", target: self, action: #selector(showParent)); parent.toolTip = "Scroll the conversation to this thread’s first message"
        let reply = NSButton(title: "Open in Window", target: self, action: #selector(openWindow)); reply.toolTip = "Open this thread in its own window to reply"
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
        updateControls()
        startRefresh()
    }

    /// The root header follows edits and renames; the snapshot is only the
    /// fallback when the newest row is not cached yet. Every render calls
    /// this, so the root parses through the session's bounded document
    /// cache rather than once per render, and the hover text that reveals
    /// what the 6-line/800-character cap clipped follows the same root.
    private func showRootHeader(for message: RavenMessage) {
        let fullText: String
        if case .parsed(let document) = session.messageDocument(for: message) { fullText = RichTextCodec.plainText(document) } else { fullText = "Root message" }
        let text = NSMutableAttributedString(string: "\(session.authorName(message))\n", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: String(fullText.prefix(800)), attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        context.attributedStringValue = text
        context.toolTip = String(fullText.prefix(2000))
    }

    private func startRefresh() {
        refreshTask?.cancel()
        if !detached { status.stringValue = "Loading thread…" }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.load(channelID: self.rootMessage.id)
                let rows = try await self.session.store.messages(channelID: self.rootMessage.id, limit: Self.newestPageSize)
                guard !Task.isCancelled, !self.detached else { return }
                self.oldestLoaded = nil
                self.pagedPages = 0
                self.refreshError = nil
                self.hasOlder = rows.count >= Self.serverPageSize
                self.rows = rows
                self.updateControls()
                self.render()
            } catch {
                if !Task.isCancelled, !self.detached {
                    self.refreshError = error.localizedDescription
                    self.status.stringValue = error.localizedDescription
                    self.updateControls()
                }
            }
        }
    }

    @objc private func retryRefresh() {
        guard !detached, refreshError != nil else { return }
        refreshError = nil
        updateControls()
        startRefresh()
    }

    /// Fetches the page before the oldest loaded reply and keeps the window
    /// from that reply forward, so newer replies still arrive.
    @objc private func loadEarlier() {
        // The viewport-bounded rows can trim above the oldest loaded reply,
        // so prefer the recorded boundary as the fetch cursor.
        guard !loadingEarlier, !detached, hasOlder, let oldest = oldestLoaded ?? rows.first else { return }
        loadingEarlier = true
        status.stringValue = "Loading earlier replies…"
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingEarlier = false; self.updateControls(); self.render() }
            do {
                try await self.session.load(channelID: self.rootMessage.id, olderThan: oldest.id)
                guard !Task.isCancelled, !self.detached else { return }
                let older = try await self.session.store.messages(
                    channelID: self.rootMessage.id, limit: Self.serverPageSize,
                    before: MessageBoundary(creation: oldest.creation, id: oldest.id))
                guard let boundary = older.first else {
                    self.hasOlder = false
                    self.refreshError = nil
                    return
                }
                self.oldestLoaded = boundary
                self.pagedPages += 1
                self.hasOlder = older.count >= Self.serverPageSize
                self.refreshError = nil
            } catch {
                if !Task.isCancelled, !self.detached { self.refreshError = error.localizedDescription }
            }
        }
    }


    private func updateControls() {
        earlierButton.isEnabled = !loadingEarlier && !detached && hasOlder && !rows.isEmpty
        retryButton.isEnabled = !detached && refreshError != nil
    }
    func waitUntilLoaded() async { await refreshTask?.value; await renderTask?.value }
    func render() {
        guard !detached else { return }
        guard hasAccess else { detach(); return }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The window grows by one server page per page-back so the
                // recorded boundary stays inside it.
                let windowSize = Self.newestPageSize + pagedPages * Self.serverPageSize
                async let rowFetch = session.cachedMessages(channelID: rootMessage.id, limit: windowSize)
                async let rootFetch = session.cachedMessage(id: rootMessage.id, channelID: rootMessage.channelID)
                var rows = try await rowFetch
                if let oldest = oldestLoaded {
                    if let index = rows.firstIndex(where: { $0.id == oldest.id }) {
                        rows = Array(rows[index...])
                    } else {
                        // The boundary aged out of the cached window; stop
                        // offering pages instead of moving the cursor forward.
                        oldestLoaded = nil
                        hasOlder = false
                    }
                }
                // The default 500-row bound would trim a paged window back to
                // its newest rows and drop the page just fetched; the byte
                // budget still applies.
                rows = MessageWindow.bounded(rows, anchorID: following ? nil : messageRanges.first { rect($0.0).maxY >= scroll.contentView.bounds.minY }?.1.id, maxRows: max(MessageWindow.maximumRows, windowSize))
                let root = (try? await rootFetch) ?? rootMessage
                guard !Task.isCancelled, !detached, !session.stopped else { return }
                showRootHeader(for: root)
                if transcript.isTrackingPress { renderAfterPress = true; return }
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
                status.stringValue = session.demo ? "Local demo thread" : "\(rows.count) cached replies · \(refreshError ?? session.state)"
                seenVisible(); viewportKeeper?.capture()
            } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
        }
    }
    /// The reply range containing a y offset, by binary search over the
    /// top-to-bottom ranges. Pointer moves and scroll steps no longer measure
    /// every reply to find the one under the caret.
    private func messageRange(atY y: CGFloat) -> (NSRange, RavenMessage)? {
        var low = 0, high = messageRanges.count
        while low < high {
            let middle = (low + high) / 2
            if rect(messageRanges[middle].0).maxY <= y { low = middle + 1 } else { high = middle }
        }
        guard low < messageRanges.count, rect(messageRanges[low].0).minY <= y else { return nil }
        return messageRanges[low]
    }
    private func rect(_ range: NSRange) -> NSRect {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer else { return .zero }
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container); rect.origin.y += transcript.textContainerInset.height; return rect
    }
    private func seenVisible() {
        following = scroll.contentView.bounds.maxY >= transcript.bounds.maxY - 20
        let band = scroll.contentView.bounds
        guard !detached, NSApp.isActive, view.window?.isKeyWindow == true, !view.isHidden,
              let seen = messageRange(atY: max(band.minY, min(band.maxY - 1, transcript.bounds.maxY)))?.1
                  ?? messageRanges.last(where: { band.intersects(rect($0.0)) })?.1 else { return }
        Task { await session.markSeen(channelID: rootMessage.id, timestamp: seen.creation) }
    }
    func detach() {
        guard !detached else { return }
        detached = true; refreshTask?.cancel(); renderTask?.cancel(); session.attach(window: subscriptionID, channelID: nil)
        viewportKeeper?.invalidate(); viewportKeeper = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        context.stringValue = ""; transcript.clearText(); rows = []; messageRanges = []; status.stringValue = "Thread closed"
        refreshError = nil; oldestLoaded = nil; loadingEarlier = false; hasOlder = true; pagedPages = 0
        let invalidated = onInvalidated; onInvalidated = nil; invalidated?()
    }
    @objc private func closeInspector() { conversation?.closeThreadInspector() }
    @objc func openWindow() {
        guard hasAccess else { detach(); return }
        conversation?.app.open(session: session, channel: RavenChannel(raw: .object(["name":.string(rootMessage.id), "channel_name":.string("Thread · \(rootMessage.owner)"), "is_thread":.bool(true), "parent_channel_id":.string(rootMessage.channelID)])))
    }
    @objc func showParent() {
        guard let parent = session.channels.first(where: { $0.id == rootMessage.channelID }) else { return }
        conversation?.select(parent, anchor: rootMessage.id)
    }
}
