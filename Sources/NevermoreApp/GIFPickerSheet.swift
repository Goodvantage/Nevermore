import AppKit
import NevermoreCore

/// Searches the reader's GIF service and returns the GIF they choose.
///
/// Results come from one service only and in the order it gives (both
/// services' terms ask for that). Previews play while the sheet is open,
/// except under Reduce Motion, and are loaded from the service's media
/// hosts through the same checked transport as GIFs in messages.
@MainActor final class GIFPickerSheet: NSObject, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    /// What the sheet needs from the conversation, so self-checks can
    /// substitute fixtures.
    struct Sources {
        /// Nil when the reader has no key for the chosen service.
        let search: (any GIFSearching)?
        let provider: GIFProvider
        let media: any GIFMediaLoading
    }

    static let maximumItems = 192
    static let itemSize = NSSize(width: 136, height: 102)
    private nonisolated static let previewPixelSide = 272

    private weak var parent: NSWindow?
    private let sources: Sources
    private let active: () -> Bool
    let panel: NSPanel
    let search = NSSearchField()
    let grid = GIFGridView()
    private let scroll = NSScrollView()
    let status = NSTextField(wrappingLabelWithString: "")
    private let attribution = NSTextField(labelWithString: "")
    let choose = NSButton(title: "Send GIF", target: nil, action: nil)
    let openSettings = NSButton(title: "GIF Settings…", target: nil, action: nil)
    private(set) var items: [GIFItem] = []
    private var next: Int?
    private var loading = false
    private var finished = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    /// Compressed previews of the current results, so a scrolled-away
    /// preview decodes again without another request. At most
    /// `maximumPreviewBytes` in all; later ones are fetched again.
    private(set) var previewData: [String: Data] = [:]
    static let maximumPreviewBytes = 32 * 1024 * 1024
    let previews = AnimatedImageCache(budget: 64 * 1024 * 1024)
    private var previewRequests = Set<String>()
    private var previewQueue: [GIFItem] = []
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<GIFPickerResult, Never>?

    enum GIFPickerResult: Sendable { case chosen(GIFItem), settings, cancelled }

    /// The sheet that is open, for self-checks.
    private(set) static weak var current: GIFPickerSheet?

    static func pick(on parent: NSWindow, sources: Sources, active: @escaping () -> Bool) async throws -> GIFPickerResult {
        guard parent.attachedSheet == nil else { throw AppError.message("Finish the current sheet before choosing a GIF.") }
        let controller = GIFPickerSheet(parent: parent, sources: sources, active: active)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { controller.finish(.cancelled); return .cancelled }
            return await withCheckedContinuation { controller.present($0) }
        } onCancel: { Task { @MainActor in controller.finish(.cancelled) } }
    }

    private init(parent: NSWindow, sources: Sources, active: @escaping () -> Bool) {
        self.parent = parent; self.sources = sources; self.active = active
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Send a GIF"
        panel.isReleasedWhenClosed = false
        // KLIPY's terms ask for exactly this placeholder.
        search.placeholderString = "Search \(sources.provider.name)"
        search.delegate = self; search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        search.setAccessibilityLabel("Search \(sources.provider.name)")
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize; layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.isSelectable = true; grid.allowsEmptySelection = true; grid.allowsMultipleSelection = false
        grid.backgroundColors = [.clear]
        grid.register(GIFPickerItem.self, forItemWithIdentifier: GIFPickerItem.identifier)
        grid.dataSource = self; grid.delegate = self
        grid.setAccessibilityLabel("GIF results")
        grid.onOpen = { [weak self] in self?.accept() }
        grid.onClose = { [weak self] in self?.cancel() }
        scroll.documentView = grid; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.contentView.postsBoundsChangedNotifications = true
        status.textColor = .secondaryLabelColor; status.setAccessibilityLabel("GIF search status")
        attribution.stringValue = sources.provider.attribution
        attribution.font = .systemFont(ofSize: 11, weight: .semibold); attribution.textColor = .secondaryLabelColor
        attribution.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [status, attribution]); footer.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        choose.target = self; choose.action = #selector(accept); choose.keyEquivalent = "\r"
        openSettings.target = self; openSettings.action = #selector(showSettings)
        openSettings.isHidden = sources.search != nil
        let buttons = NSStackView(views: [openSettings, NSView(), cancel, choose]); buttons.spacing = 8
        let stack = NSStackView(views: [search, scroll, footer, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), // Equal, so the panel fits its content instead of leaving a gap.
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ])
            for view in [search, scroll, footer, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        panel.initialFirstResponder = search
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        updateControls()
    }

    private func present(_ continuation: CheckedContinuation<GIFPickerResult, Never>) {
        guard let parent, !finished, active() else { finish(.cancelled); continuation.resume(returning: .cancelled); return }
        self.continuation = continuation
        Self.current = self
        parent.beginSheet(panel) { [weak self] _ in self?.finish(.cancelled) }
        guard sources.search != nil else {
            status.stringValue = GIFSearchError.missingKey.localizedDescription
            return
        }
        load(reset: true)
    }

    private var selectedIndex: Int? { grid.selectionIndexPaths.first.map(\.item).flatMap { items.indices.contains($0) ? $0 : nil } }

    private func updateControls() {
        choose.isEnabled = !finished && active() && selectedIndex != nil
    }

    // MARK: Results

    private func load(reset: Bool, delayed: Bool = false) {
        guard !finished, active() else { finish(.cancelled); return }
        guard let searcher = sources.search else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1; let request = generation
        loadTask?.cancel(); loadTask = nil
        if reset { items.removeAll(); next = nil; previewQueue.removeAll(); previewData.removeAll(); grid.reloadData() }
        guard reset || (next != nil && items.count < Self.maximumItems) else { return }
        let cursor = reset ? nil : next
        loading = true
        if reset { status.stringValue = query.isEmpty ? "Loading trending GIFs…" : "Searching…" }
        loadTask = Task { [weak self] in
            if delayed { try? await Task.sleep(for: .milliseconds(300)) }
            guard let self, !Task.isCancelled, request == self.generation else { return }
            do {
                let page = try await searcher.page(query: query, cursor: cursor)
                guard !Task.isCancelled, request == self.generation, !self.finished else { return }
                let known = Set(self.items.map(\.id))
                let fresh = page.items.filter { !known.contains($0.id) }.prefix(Self.maximumItems - self.items.count)
                let start = self.items.count
                self.items.append(contentsOf: fresh)
                self.next = page.next
                if reset { self.grid.reloadData() }
                else if !fresh.isEmpty { self.grid.insertItems(at: Set((start..<self.items.count).map { IndexPath(item: $0, section: 0) })) }
                if reset, !self.items.isEmpty { self.grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
                self.status.stringValue = self.items.isEmpty ? (query.isEmpty ? "No trending GIFs right now." : "No GIFs match “\(query)”.") : ""
                self.loading = false
                self.updateControls()
                self.queuePreviews()
            } catch {
                guard !(error is CancellationError), request == self.generation, !self.finished else { return }
                self.loading = false
                self.status.stringValue = (error as? GIFSearchError ?? .unavailable).localizedDescription
                self.openSettings.isHidden = !((error as? GIFSearchError) == .rejectedKey)
                self.updateControls()
            }
        }
    }

    /// Loads the next page once the reader nears the end of the results.
    private func scrolled() {
        queuePreviews()
        guard !loading, next != nil, items.count < Self.maximumItems else { return }
        let visible = scroll.contentView.bounds
        if visible.maxY >= grid.bounds.maxY - Self.itemSize.height * 2 { load(reset: false) }
    }

    // MARK: Previews

    /// Fetches previews for items in or near view, six at a time.
    private func queuePreviews() {
        let band = scroll.contentView.bounds.insetBy(dx: 0, dy: -Self.itemSize.height * 2)
        let wanted = grid.indexPathsForVisibleItems().map(\.item).sorted()
            + items.indices.filter { grid.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.intersects(band) == true }
        var seen = Set<String>()
        previewQueue = wanted.compactMap { items.indices.contains($0) ? items[$0] : nil }.filter { seen.insert($0.id).inserted && !previews.contains($0.id) }
        while previewRequests.count < 6, !previewQueue.isEmpty { startPreview(previewQueue.removeFirst()) }
    }

    private func startPreview(_ item: GIFItem) {
        guard !previewRequests.contains(item.id) else { return }
        previewRequests.insert(item.id)
        let media = sources.media, cached = previewData[item.id], request = generation
        Task { [weak self] in
            let data: Data?
            if let cached { data = cached } else { data = await media.mediaData(for: item.preview.url) }
            let image = await Task.detached(priority: .utility) { data.flatMap { Self.decodePreview($0) } }.value
            guard let self, !self.finished else { return }
            self.previewRequests.remove(item.id)
            if let data, cached == nil, data.count <= 1024 * 1024, self.items.contains(where: { $0.id == item.id }),
               self.previewData.values.reduce(data.count, { $0 + $1.count }) <= Self.maximumPreviewBytes { self.previewData[item.id] = data }
            if let image, request == self.generation || self.items.contains(where: { $0.id == item.id }) {
                self.previews.insert(image, for: item.id)
                if let index = self.items.firstIndex(where: { $0.id == item.id }), let cell = self.grid.item(at: IndexPath(item: index, section: 0)) as? GIFPickerItem {
                    cell.show(image, animates: Self.animates)
                }
            }
            self.queuePreviews()
        }
    }

    nonisolated static func decodePreview(_ data: Data) -> AnimatedImage? {
        var limits = AnimatedImageDecoder.Limits.standard
        limits.encodedBytes = GIFMediaPolicy.maximumMediaBytes
        limits.decodedBytes = 3 * 1024 * 1024
        limits.minimumSide = 96
        return AnimatedImageDecoder.decode(data, maxPixelSide: previewPixelSide, limits: limits)
    }

    static var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Collection view

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GIFPickerItem.identifier, for: indexPath)
        guard let cell = cell as? GIFPickerItem, items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        cell.configure(title: item.title, image: previews[item.id], animates: Self.animates)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateControls() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateControls() }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) { queuePreviews() }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === search, (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        load(reset: true, delayed: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if command == #selector(NSResponder.moveDown(_:)), !items.isEmpty {
            if selectedIndex == nil { grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
            panel.makeFirstResponder(grid); updateControls(); return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) { accept(); return true }
        return false
    }

    // MARK: Ending

    @objc func accept() {
        guard !finished, active(), (panel.firstResponder as? NSTextView)?.hasMarkedText() != true, let index = selectedIndex else { return }
        finish(.chosen(items[index]))
    }

    @objc func cancel() { finish(.cancelled) }
    @objc private func showSettings() { finish(.settings) }

    private func finish(_ result: GIFPickerResult) {
        guard !finished else { return }
        finished = true; generation += 1
        loadTask?.cancel(); loadTask = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        if let parent, parent.attachedSheet === panel { parent.endSheet(panel) }
        panel.orderOut(nil)
        items.removeAll(); grid.reloadData(); previews.removeAll(); previewData.removeAll(); previewQueue.removeAll()
        if Self.current === self { Self.current = nil }
        let pending = continuation; continuation = nil
        pending?.resume(returning: result)
    }
}

/// Return chooses, Escape cancels, a double-click chooses.
@MainActor final class GIFGridView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 53: onClose?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, !selectionIndexPaths.isEmpty { onOpen?() }
    }
}

/// One result: the preview, playing, with a ring when selected.
@MainActor final class GIFPickerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GIFPickerItem")
    private var player: AnimatedImageView?

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.image)
        view = box
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.setAccessibilitySelected(isSelected)
        }
    }

    func configure(title: String, image: AnimatedImage?, animates: Bool) {
        view.setAccessibilityLabel(title.isEmpty ? "GIF" : title)
        view.toolTip = title.isEmpty ? nil : title
        if let image { show(image, animates: animates) } else { player?.removeFromSuperview(); player = nil }
    }

    func show(_ image: AnimatedImage, animates: Bool) {
        if let player { player.show(image, animates: animates); return }
        let made = AnimatedImageView(key: "", image: image, frame: view.bounds)
        made.autoresizingMask = [.width, .height]
        made.layer?.contentsGravity = .resizeAspectFill
        view.addSubview(made)
        made.setPlaying(animates)
        player = made
    }

    var isPlaying: Bool { player?.isPlaying == true }
    var hasPreview: Bool { player != nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        player?.removeFromSuperview(); player = nil
    }
}
