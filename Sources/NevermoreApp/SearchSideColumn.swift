import AppKit
import NevermoreCore
import RavenProtocol

/// The search screen's right column: Top hits and saved searches while no
/// result is selected, then a preview of the selected result with a few
/// messages around it.
@MainActor final class SearchSideColumn: NSView {
    weak var owner: ConversationWindow?
    weak var view: SearchView?
    private let scroll = NSScrollView()
    private let document = HomeDocumentView()
    private let stack = NSStackView()
    /// What the column shows, for self-checks.
    private(set) var showsPreviewOf: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func set(_ views: [NSView]) {
        stack.setViews(views, in: .top)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        scroll.contentView.scroll(to: .zero)
        markThemeSubtreeNeedsDisplay()
    }

    private func heading(_ title: String) -> NSView {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.themeSecondaryText, .kern: 0.6]))
        let stack = NSStackView(views: [label])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 2, right: 0)
        return stack
    }

    // MARK: Top hits

    func showTopHits(query: String, session: AccountSession, saved: [SavedSearch], current: SearchCriteria) {
        showsPreviewOf = nil
        setAccessibilityLabel("Top hits and saved searches")
        guard let owner else { return }
        let cells = SearchCells(owner: owner, session: session, flat: false)
        var views: [NSView] = []
        let channels = SearchView.conversations(query, session: session, limit: 4)
        let people = SearchTopHits.people(query, names: session.userNames, limit: 4)
        if !channels.isEmpty || !people.isEmpty {
            views.append(heading("Top Hits"))
            for channel in channels {
                let row = pressable(cells.channel(channel)) { [weak owner] in owner?.openSearchResult(channelID: channel.id, messageID: nil, parentID: nil) }
                views.append(row)
            }
            for user in people {
                views.append(pressable(cells.person(user)) { [weak owner] in owner?.openDirectMessage(with: user) })
            }
        }
        views.append(heading("Saved Searches"))
        if saved.isEmpty { views.append(HomeText.note("Searches you save appear here, for this account only.")) }
        for item in saved {
            let row = HomeRow(icon: HomeSymbol("magnifyingglass"), title: HomeText.title(item.title), detail: HomeText.detail(summary(item.criteria, session: session)), trailing: nil)
            row.setAccessibilityLabel("Saved search \(item.title)")
            row.onPress = { [weak view] in view?.apply(saved: item) }
            let menu = NSMenu(title: item.title)
            menu.addItem(SearchMenuItem("Remove “\(item.title)”", on: false) { [weak view] in view?.remove(saved: item) })
            row.menu = menu
            views.append(row)
        }
        if !current.query.isEmpty || current.hasFilters, saved.count < SavedSearchStore.limit {
            let save = HomeLinkButton("Save This Search…") { [weak view] in view?.saveCurrentSearch() }
            let line = NSStackView(views: [save])
            line.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 0, right: 0)
            views.append(line)
        }
        set(views)
    }

    private func pressable(_ cell: NSView, action: @escaping () -> Void) -> NSView {
        let press = HomePressable()
        cell.translatesAutoresizingMaskIntoConstraints = false
        press.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: press.topAnchor), cell.bottomAnchor.constraint(equalTo: press.bottomAnchor),
            cell.leadingAnchor.constraint(equalTo: press.leadingAnchor), cell.trailingAnchor.constraint(equalTo: press.trailingAnchor),
            press.heightAnchor.constraint(equalToConstant: 44)
        ])
        press.setAccessibilityLabel(cell.accessibilityLabel())
        cell.setAccessibilityElement(false)
        press.onPress = action
        return press
    }

    /// "In # design · From Mara · Last 7 Days".
    private func summary(_ criteria: SearchCriteria, session: AccountSession) -> String {
        var parts: [String] = []
        if !criteria.query.isEmpty { parts.append("“\(criteria.query)”") }
        switch criteria.scope {
        case .account: break
        case .conversation(let id): parts.append("in " + (session.channels.first { $0.id == id }.map { $0.isDM ? $0.title : "# " + $0.title } ?? "a conversation"))
        case .workspace(let workspace): parts.append("in " + workspace)
        }
        if let author = criteria.author { parts.append("from " + (author == session.account.user ? "me" : session.userNames[author] ?? author)) }
        if let date = criteria.date { parts.append(SearchView.dateTitle(date)) }
        if criteria.tab != .messages { parts.append(criteria.tab.title) }
        return parts.joined(separator: " · ")
    }

    // MARK: Preview

    func showPreview(_ hit: SearchHit, context: [RavenMessage], loading: Bool) {
        showsPreviewOf = hit.id
        setAccessibilityLabel("Preview")
        guard let owner, let session = owner.session else { return }
        let cells = SearchCells(owner: owner, session: session, flat: false)
        var views: [NSView] = []
        let place = cells.conversationTitle(hit.conversationID)
        views.append(heading(hit.isThreadReply ? (place.isEmpty ? "Thread" : "\(place) · Thread") : (place.isEmpty ? "Conversation" : place)))
        if context.isEmpty {
            views.append(previewMessage(author: cells.name(hit.authorID), time: cells.when(hit.creation), text: hit.snippet.text.isEmpty ? (hit.fileName?.text ?? "") : hit.snippet.text, isHit: true, user: hit.authorID, session: session))
            if loading { views.append(HomeText.note("Loading the messages around it…")) }
        } else {
            for message in context {
                let plain = (try? RichTextCodec.parse(message.html)).map { RichTextCodec.plainText($0) } ?? ""
                let file = ["File", "Image"].contains(message.messageType) ? message.raw["file"].string.map { "📎 " + ($0.split(separator: "/").last.map(String.init) ?? $0) } : nil
                let text = [file, plain.isEmpty ? nil : String(plain.prefix(600))].compactMap { $0 }.joined(separator: "\n")
                views.append(previewMessage(author: cells.name(message.authorID), time: cells.when(message.creation), text: text.isEmpty ? "Message" : text, isHit: message.id == hit.id, user: message.authorID, session: session))
            }
        }
        let open = NSButton(title: "Open in Conversation", target: self, action: #selector(openSelected))
        open.bezelStyle = .glass
        open.keyEquivalent = ""
        var buttons: [NSView] = [open]
        if hit.isFile {
            let look = NSButton(title: "Quick Look", target: self, action: #selector(quickLookResult))
            look.bezelStyle = .glass
            buttons.append(look)
        }
        let copy = HomeLinkButton("Copy Link") { [weak owner] in owner?.copySearchResultLink(messageID: hit.id) }
        buttons.append(copy)
        let row = NSStackView(views: buttons)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        views.append(row)
        views.append(HomeText.quietLine(symbol: "eye.slash", "Previewing does not mark anything read."))
        set(views)
    }

    @objc private func openSelected() { view?.openSelected() }
    @objc private func quickLookResult() { view?.quickLookSelected() }

    private func previewMessage(author: String, time: String, text: String, isHit: Bool, user: String, session: AccountSession) -> NSView {
        let avatar = HomeAvatar(size: 24, shape: .circle)
        avatar.image = user.isEmpty ? nil : session.avatarImage(for: user)
        avatar.symbol = "person.crop.circle"
        let name = HomeText.label(author, font: .systemFont(ofSize: 12, weight: .semibold), color: .themeText)
        let stamp = HomeText.label(time, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .themeTertiaryText)
        let top = NSStackView(views: [name, stamp])
        top.spacing = 6
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = isHit ? .themeText : .themeSecondaryText
        body.maximumNumberOfLines = isHit ? 12 : 4
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [top, body])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        body.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
        let stack = NSStackView(views: [avatar, lines])
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let container = SearchPreviewMessage(highlighted: isHit)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel("\(isHit ? "Result: " : "")\(author), \(time), \(text)")
        return container
    }
}

/// One message in the preview; the result itself sits on a soft panel.
@MainActor final class SearchPreviewMessage: NSView {
    private let highlighted: Bool
    init(highlighted: Bool) {
        self.highlighted = highlighted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = highlighted ? NSColor.themeAccent.withAlphaComponent(0.16).cgColor : nil
    }
}

/// Quick Look and Save As for file results. Search rows only locate a
/// file: the permission-checked message supplies its URL right before the
/// download, and the window closes when the selection moves on.
@MainActor final class SearchAttachmentReader {
    /// Self-checks replace the server with a fixture.
    var transport: CollectionAttachmentActions.Transport?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private(set) var windows: [AttachmentWindow] = []
    private(set) var status = "" { didSet { onStatus?(status) } }

    var isReading: Bool { task != nil }

    func cancel() {
        revision = UUID(); task?.cancel(); task = nil
        if status == Self.downloading { status = "" }
        let open = windows; windows.removeAll()
        for window in open { window.close() }
    }

    static let downloading = "Downloading the file…"

    func read(_ hit: SearchHit, session: AccountSession, owner: ConversationWindow, save: Bool, current: @escaping () -> Bool) {
        guard let identity = SearchAttachment(hit.raw), !session.stopped, !session.deletedIDs.contains(identity.messageID), !session.deletedIDs.contains(identity.channelID),
              identity.parentChannelID.map(session.revokedChannels.contains) != true,
              !ChannelPolicy.isRevoked(channelID: identity.channelID, revoked: session.revokedChannels, threadParents: session.threadParents),
              !session.demo || transport != nil else { return }
        cancel()
        let revision = self.revision
        let transport = self.transport ?? CollectionAttachmentActions.transport(session)
        func live() -> Bool {
            self.revision == revision && current() && !session.stopped && owner.isCurrent(session)
                && !session.deletedIDs.contains(identity.messageID) && !session.deletedIDs.contains(identity.channelID) && !ChannelPolicy.isRevoked(channelID: identity.channelID, revoked: session.revokedChannels, threadParents: session.threadParents)
        }
        status = Self.downloading
        task = Task { [weak self] in
            defer { if self?.revision == revision { self?.task = nil; if self?.status == Self.downloading { self?.status = "" } } }
            do {
                guard live() else { return }
                let message = try await transport.message(identity.messageID)
                guard live() else { return }
                let context = try await transport.channelContext(identity.channelID)
                guard live(), context.channelID == identity.channelID else { if live() { throw RavenError.invalidResponse }; return }
                // Keep the server's ancestry, as send preflight does, so a
                // later revocation of the parent also closes the file.
                let chain = [identity.channelID] + context.parentChannelIDs
                for (child, parent) in zip(chain, chain.dropFirst()) { session.threadParents[child] = parent }
                guard context.parentChannelIDs.allSatisfy({ !session.revokedChannels.contains($0) && !session.deletedIDs.contains($0) }) else { return }
                let url = try identity.canonicalURL(message, origin: session.account.origin)
                let attachment = try await transport.download(url)
                guard live(), let self else { return }
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
                let link = identity.messageID.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "/raven/message/" + $0, relativeTo: session.account.origin)?.absoluteURL }
                let presentation: AttachmentPresentation = save ? .window : owner.window.map { .quickLook(over: $0) } ?? .window
                let controller = AttachmentWindow(attachment: attachment, messageLink: link, presentation: presentation, active: { live() }, reportError: { error in
                    guard live() else { return }; owner.app.showError(error)
                })
                controller.didClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
                self.windows.append(controller)
                self.status = ""
                controller.present(save: save)
            } catch {
                guard live(), !(error is CancellationError) else { return }
                self?.status = "File unavailable: \(StatusLocalization.errorDescription(error))"
            }
        }
    }
}
