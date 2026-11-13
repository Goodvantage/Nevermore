import AppKit
import UniformTypeIdentifiers
import RavenProtocol
import NevermoreCore

/// Toolbar item identifiers for conversation windows. The configuration is
/// autosaved under a versioned toolbar identifier, so adding or renaming an
/// item here must bump `ConversationToolbar.identifier`.
extension NSToolbarItem.Identifier {
    static let nevermoreNewMessage = Self("newMessage")
    static let nevermoreNavigation = Self("navigation")
    static let nevermoreInbox = Self("inbox")
    static let nevermoreThreads = Self("threads")
    static let nevermoreLater = Self("later")
    static let nevermoreConversation = Self("info")
    static let nevermoreAttach = Self("attach")
    static let nevermoreThreadInspector = Self("threadInspector")
    static let nevermoreOutbox = Self("outbox")
    static let nevermoreSearch = Self("search")
}

enum ConversationToolbar {
    static let identifier = "NevermoreToolbar.v3"
    /// Back/Forward is not a default item. In a chat window the sidebar and
    /// the conversation chooser do the switching; history is a secondary
    /// way back after following a mention, thread or search result, so it
    /// lives in the Go menu (⌘[ and ⌘]) and Customize Toolbar rather than
    /// in the slot before the conversation title. Leaving the identifier
    /// unbumped keeps toolbars people already customized as they are.
    static let defaultItems: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .flexibleSpace, .nevermoreNewMessage, .sidebarTrackingSeparator,
        .flexibleSpace, .nevermoreInbox, .nevermoreThreads, .nevermoreLater,
        .nevermoreConversation, .nevermoreSearch
    ]
    static let allowedItems: [NSToolbarItem.Identifier] = defaultItems + [
        .nevermoreNavigation, .nevermoreAttach, .nevermoreThreadInspector, .nevermoreOutbox, .space
    ]
    fileprivate static let backItem = NSToolbarItem.Identifier("navigation.back")
    fileprivate static let forwardItem = NSToolbarItem.Identifier("navigation.forward")
}

/// A label that reports text changes, so the shell can show or hide the row
/// that hosts it without every writer knowing about the layout.
@MainActor final class ObservedLabel: NSTextField {
    var onChange: (() -> Void)?
    override var stringValue: String { didSet { onChange?() } }
}

/// Hosts a view and reports layout passes. The conversation pane uses it to
/// keep transcript insets in step with the floating composer.
@MainActor final class LayoutReportingViewController: NSViewController {
    private let root: NSView
    var onLayout: (() -> Void)?
    init(view: NSView) { root = view; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = root }
    override func viewDidLayout() { super.viewDidLayout(); onLayout?() }
}

/// Source-list row for one conversation: photo/type symbol, title, unread count and
/// presence. Unread conversations use a semibold title, muted ones are dimmed.
/// An unread conversation that calls for attention has a raven beside its
/// count; `UnkindnessController` moves the birds.
@MainActor final class SidebarConversationCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarConversationCell")
    private let symbol = SidebarIconView()
    private static let iconSize: CGFloat = 18
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let presenceDot = NSView()
    private let muted = NSImageView()
    /// Where this row's raven stands, left of the count.
    let perch = RavenPerchView()
    private var perchWidth: NSLayoutConstraint!
    private var perchGap: NSLayoutConstraint!
    private var bird: Bird?
    private static let perchSpacing: CGFloat = 3

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
        imageView = symbol
        // Not the textField outlet: source lists reset that field's font for
        // the sidebar icon size, which would drop the unread weight. Selected
        // rows still get the selected text color via backgroundStyle below.
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        muted.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Muted")
        muted.contentTintColor = .tertiaryLabelColor
        muted.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        muted.setContentHuggingPriority(.required, for: .horizontal)
        presenceDot.wantsLayer = true
        presenceDot.layer?.cornerRadius = 3.5
        presenceDot.layer?.borderWidth = 1
        for view in [symbol, title, count, muted, presenceDot, perch] {
            view.translatesAutoresizingMaskIntoConstraints = false
            // The cell's own label already says "title, N unread, muted".
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: Self.iconSize),
            symbol.heightAnchor.constraint(equalToConstant: Self.iconSize),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            muted.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            muted.centerYAnchor.constraint(equalTo: centerYAnchor),
            perch.leadingAnchor.constraint(equalTo: muted.trailingAnchor, constant: 4),
            perch.heightAnchor.constraint(equalToConstant: RavenFigure.size.height),
            // The bird stands on the title's baseline, like a glyph.
            perch.bottomAnchor.constraint(equalTo: title.lastBaselineAnchor, constant: 1),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            presenceDot.widthAnchor.constraint(equalToConstant: 7),
            presenceDot.heightAnchor.constraint(equalToConstant: 7),
            presenceDot.trailingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 1),
            presenceDot.bottomAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 1)
        ])
        perchWidth = perch.widthAnchor.constraint(equalToConstant: 0)
        perchGap = count.leadingAnchor.constraint(equalTo: perch.trailingAnchor)
        NSLayoutConstraint.activate([perchWidth, perchGap])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var baseTitleColor: NSColor = .labelColor
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            title.textColor = emphasized ? .alternateSelectedControlTextColor : baseTitleColor
            count.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            tintBird()
        }
    }

    /// A raven on the row. `lit` marks a conversation that addresses the
    /// reader: a direct message or a mention. `away` hides the bird while
    /// it is in the air; its place in the layout stays.
    struct Bird: Equatable {
        var lit: Bool
        var away = false
    }
    private func tintBird() {
        guard let bird else { return }
        let emphasized = backgroundStyle == .emphasized
        // On a selected row the bird is white and its eye shows the
        // selection color through; elsewhere a lit eye is the accent.
        let eye: NSColor? = emphasized ? .selectedContentBackgroundColor : (bird.lit ? .themeAccent : nil)
        perch.tint(ink: emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor, eye: eye, lit: bird.lit)
    }

    struct Model {
        var title: String
        var symbolName: String
        var unread: Int
        var muted: Bool
        var archived: Bool
        var presence: String?
        var tooltip: String
        var bird: Bird?
        var photo: NSImage? = nil
        var channelAccess: RavenPortrait.ChannelAccess? = nil
    }

    func configure(_ model: Model, fontSize: CGFloat) {
        let weight: NSFont.Weight = model.unread > 0 && !model.muted ? .semibold : .regular
        title.font = .systemFont(ofSize: fontSize, weight: weight)
        title.stringValue = model.title
        baseTitleColor = model.archived || model.muted ? .secondaryLabelColor : .labelColor
        title.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : baseTitleColor
        symbol.photo = model.photo
        symbol.shape = model.channelAccess == nil ? .circle : .tile
        symbol.image = model.photo ?? NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil)
        symbol.symbolConfiguration = model.photo == nil ? .init(pointSize: fontSize, weight: .regular) : nil
        count.stringValue = model.unread > 0 ? (model.unread >= 9999 ? "9999+" : String(model.unread)) : ""
        muted.isHidden = !model.muted
        bird = model.bird
        perch.isHidden = model.bird == nil
        perchWidth.constant = model.bird == nil ? 0 : RavenFigure.size.width
        perchGap.constant = model.bird == nil ? 0 : Self.perchSpacing
        perch.isAway = model.bird?.away == true
        tintBird()
        let presenceColor: NSColor? = switch model.presence {
        case "Active": .systemGreen
        case "Away": .systemYellow
        case "Do not disturb": .systemRed
        default: nil
        }
        presenceDot.isHidden = presenceColor == nil
        presenceDot.layer?.backgroundColor = presenceColor?.cgColor
        presenceDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        toolTip = model.tooltip
        var label = model.title
        if model.channelAccess == .privateChannel { label += ", private channel" }
        if let presence = model.presence { label += ", \(presence)" }
        if model.unread > 0 { label += ", \(model.unread) unread" }
        if model.muted { label += ", muted" }
        if model.archived { label += ", archived" }
        setAccessibilityLabel(label)
    }
}

/// Draw full-color artwork ourselves so source-list selection never tints it.
@MainActor private final class SidebarIconView: NSImageView {
    enum Shape { case circle, tile }
    var shape: Shape = .circle { didSet { needsDisplay = true } }
    var photo: NSImage? { didSet { needsDisplay = true } }
    override var allowsVibrancy: Bool { photo == nil && super.allowsVibrancy }
    override func draw(_ dirtyRect: NSRect) {
        guard let photo else { super.draw(dirtyRect); return }
        switch shape {
        case .circle: ProfilePhoto.draw(photo, in: bounds)
        case .tile:
            photo.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}

/// The conversation list. Return moves focus into the conversation's
/// composer, the way Return enters a mailbox's message list in Mail.
@MainActor final class SidebarTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, selectedRow >= 0 { onActivate?(); return }
        super.keyDown(with: event)
    }
}

/// Section heading row in the conversation sidebar.
@MainActor final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One staged file in the composer, with its own remove button.
@MainActor final class AttachmentChip: NSView {
    init(filename: String, removeTarget: AnyObject?, removeAction: Selector?, tag: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: type))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: filename)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(filename)")!, target: removeTarget, action: removeAction)
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.tag = tag
        remove.toolTip = "Remove \(filename)"
        let stack = NSStackView(views: [icon, name, remove])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Attachment \(filename)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor }
    }
}

/// Floating actions for the message under the pointer, like Messages and
/// Slack. The buttons route through the same commands as the Message menu.
@MainActor final class MessageHoverBar: NSView {
    private let glass = NSGlassEffectView()
    let stack = NSStackView()
    /// Anchors the quick reaction row.
    var reactButton: NSButton?
    init() {
        super.init(frame: .zero)
        glass.cornerRadius = 9
        glass.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        glass.contentView = stack
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult func addButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = HoverHighlightButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.restingTint = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(button)
        return button
    }
    // The bar floats inside the transcript's text view, whose I-beam cursor
    // would otherwise hide that these are buttons.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Connection state shown at the foot of the sidebar, like Mail's activity
/// area: a small colored indicator plus the localized account state.
@MainActor final class ConnectionFooter: NSView {
    let indicator = NSImageView()
    let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        indicator.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [indicator, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(session: AccountSession?) {
        guard let session else {
            label.stringValue = "No account"
            indicator.contentTintColor = .tertiaryLabelColor
            setAccessibilityLabel("No account")
            return
        }
        label.stringValue = session.state
        let color: NSColor
        if session.statusAttention != nil { color = .systemRed }
        else if session.demo { color = .tertiaryLabelColor }
        else if session.realtimeLive && !session.readOnly { color = .systemGreen }
        else { color = .systemOrange }
        indicator.contentTintColor = color
        toolTip = "\(session.account.displayName.isEmpty ? session.account.user : session.account.displayName) · \(session.state)"
        setAccessibilityLabel("Connection: \(session.state)")
    }
}


// MARK: - Window structure

extension ConversationWindow {
    func buildUI() {
        guard let window else { return }
        let sidebarController = LayoutReportingViewController(view: buildSidebar())
        sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarSplitItem.minimumThickness = 200
        sidebarSplitItem.maximumThickness = 380
        sidebarSplitItem.canCollapse = true
        let chat = buildConversationPane()
        contentController = LayoutReportingViewController(view: chat)
        contentController.onLayout = { [weak self] in
            self?.updateComposerHeight()
            self?.updateTranscriptInsets()
            if self?.transcript.highlightRect != nil { self?.updateMessageHighlight() }
            self?.ink.layoutBlots()
            self?.stickers.transcriptDidLayout()
        }
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 380
        // The transcript scrolls beneath the toolbar and the floating
        // composer; its content insets keep text clear of both.
        contentItem.allowsFullHeightLayout = true
        contentItem.titlebarSeparatorStyle = .none
        splitController.splitViewItems = [sidebarSplitItem, contentItem]
        window.contentViewController = splitController
        // Tab cycles account menu → workspace filter → conversations →
        // transcript → composer; a new window starts in the composer.
        window.autorecalculatesKeyViewLoop = false
        // Buttons join the loop only with Full Keyboard Access enabled.
        accountPicker.nextKeyView = workspacePicker; workspacePicker.nextKeyView = sidebar
        sidebar.nextKeyView = transcript; transcript.nextKeyView = attachButton; attachButton.nextKeyView = composer
        composer.nextKeyView = emojiButton; emojiButton.nextKeyView = sendButton; sendButton.nextKeyView = accountPicker
        window.initialFirstResponder = composer
        applyTheme()
    }

    /// Forwards printable keystrokes from the read-only transcript to the
    /// composer. Command and Control chords keep their menu meaning, arrows
    /// and paging keep scrolling, and Space keeps Quick Look.
    func typeToCompose(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .function])
        guard modifiers.isEmpty, composer.isEditable, let characters = event.characters, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 || scalar.value > 0xF8FF, characters != " " else { return false }
        focusComposer()
        activeComposer.setSelectedRange(NSRange(location: (activeComposer.string as NSString).length, length: 0))
        activeComposer.keyDown(with: event)
        return true
    }

    private func buildSidebar() -> NSView {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel")); column.title = "Conversations"
        sidebar.addTableColumn(column); sidebar.headerView = nil; sidebar.style = .sourceList; sidebar.rowSizeStyle = .default
        sidebar.floatsGroupRows = false; sidebar.delegate = self; sidebar.dataSource = self; sidebar.target = self; sidebar.action = #selector(selectedSidebar)
        sidebar.doubleAction = #selector(openSidebarRowInNewWindow(_:))
        sidebar.onActivate = { [weak self] in guard let self, self.composer.isEditable else { return }; self.window?.makeFirstResponder(self.composer) }
        sidebar.setAccessibilityLabel("Conversations")
        let menu = NSMenu(title: "Sidebar"); menu.delegate = self; sidebar.menu = menu
        sidebarScroll.documentView = sidebar; sidebarScroll.hasVerticalScroller = true; sidebarScroll.autohidesScrollers = true; sidebarScroll.drawsBackground = false
        accountPicker.pullsDown = true; accountPicker.isBordered = false; accountPicker.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        accountPicker.setAccessibilityLabel("Account"); accountPicker.toolTip = "Switch account or manage this account"
        workspacePicker.target = self; workspacePicker.action = #selector(workspaceChanged); workspacePicker.setAccessibilityLabel("Workspace")
        workspacePicker.controlSize = .small; workspacePicker.toolTip = "Show conversations from one workspace"
        let header = NSStackView(views: [accountPicker, workspacePicker]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 4
        let footer = NSStackView(views: [connectionFooter])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 0
        if let app = NSApp.delegate as? AppDelegate {
            footer.insertArrangedSubview(UpdateNoticeView(updates: app.updates), at: 0)
        }
        // The birds' air is last, so flights pass over the rows and the footer.
        for view in [sidebarBackdrop, header, sidebarScroll, footer, unkindness.sidebarAir] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            unkindness.sidebarAir.topAnchor.constraint(equalTo: root.topAnchor),
            unkindness.sidebarAir.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            unkindness.sidebarAir.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            unkindness.sidebarAir.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebarBackdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            accountPicker.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
            workspacePicker.widthAnchor.constraint(equalTo: header.widthAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: sidebarScroll.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            connectionFooter.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
        return root
    }

    private func buildConversationPane() -> NSView {
        let chat = NSView()
        transcript.messageAccessibility = transcriptAccessibility
        transcript.setAccessibilityCustomRotors([transcriptAccessibility.rotor])
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = true; transcript.drawsBackground = false; transcript.textContainerInset = NSSize(width: transcript.readingColumnInset, height: 14); transcript.applyColumnInsets(); transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false; transcript.autoresizingMask = .width; transcript.textContainer?.widthTracksTextView = true; transcript.delegate = self; transcript.usesFindBar = true; transcript.isIncrementalSearchingEnabled = true; transcript.setAccessibilityLabel("Message transcript"); transcript.preview = { [weak self] in self?.readOn() }
        // A read-only NSTextView still registers as a drag destination.
        // Let file drops over the transcript reach the conversation window.
        transcript.unregisterDraggedTypes()
        transcript.onChipPress = { [weak self] event in self?.stickers.press(event) ?? false }
        // Lets stickers stand in for single glyphs; see TranscriptLayoutManager.
        transcript.textContainer?.replaceLayoutManager(TranscriptLayoutManager())
        transcript.codeMenuItems = { [weak self] in
            guard let self, let message = self.selectedMessage, let doc = try? RichTextCodec.parse(message.html), !CodeBlocks.extract(from: doc).isEmpty else { return [] }
            let item = NSMenuItem(title: "Open Code Reader…", action: #selector(ConversationWindow.openCodeReader(_:)), keyEquivalent: ""); item.target = self; return [item]
        }
        transcript.messageMenu = { [weak self] in self?.messageContextMenu() }
        transcript.onHover = { [weak self] point in self?.updateHover(at: point) }
        transcript.avatarImage = { [weak self] userID in self?.session?.avatarImage(for: userID) }
        quickReactions.onChoose = { [weak self] emoji, messageID in self?.toggleQuickReaction(emoji, messageID: messageID) }
        quickReactions.onCarry = { [weak self] emoji, origin in self?.stickers.carry(emoji, from: origin) }
        transcript.onChipHover = { [weak self] point in self?.stickers.isOverChip(point) ?? false }
        // One undo stack per conversation: Undo Send and Undo Reaction also
        // work while the transcript has the focus.
        transcript.borrowedUndoManager = { [weak self] in self?.composer.undoManager }
        quickReactions.onMore = { [weak self] messageID in
            guard let self, let message = self.messageRanges.first(where: { $0.1.id == messageID })?.1 else { return }
            self.chooseReaction(for: message)
        }
        transcript.onUserSelection = { [weak self] in self?.updateMessageHighlight() }
        transcript.onTypeToCompose = { [weak self] event in self?.typeToCompose(event) ?? false }
        transcriptScroll.documentView = transcript; transcriptScroll.hasVerticalScroller = true; transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = true; transcriptScroll.backgroundColor = .textBackgroundColor
        transcriptScroll.automaticallyAdjustsContentInsets = false
        transcript.minSize = NSSize(width: 0, height: 0); transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The scroll view has no width until Auto Layout runs. Starting its
        // autoresizing document at an arbitrary width adds that width again
        // when the clip view first grows, leaving wrapped text off screen.
        transcript.frame = NSRect(x: 0, y: 0, width: transcriptScroll.contentSize.width, height: 300)
        configureComposer()
        let bar = buildComposerBar()
        jumpLatestButton.target = self; jumpLatestButton.action = #selector(jumpToLatest(_:))
        jumpLatestButton.bezelStyle = .glass; jumpLatestButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil); jumpLatestButton.imagePosition = .imageLeading
        jumpLatestButton.setAccessibilityLabel("Jump to latest messages")
        jumpLatestButton.toolTip = "Show the latest loaded messages and refresh this conversation."
        jumpLatestButton.isHidden = true
        earlierProgress.style = .spinning; earlierProgress.controlSize = .small; earlierProgress.isDisplayedWhenStopped = false
        earlierProgress.setAccessibilityLabel("Loading earlier messages")
        let emptyTitle = NSTextField(labelWithString: "No Conversation Selected"); emptyTitle.font = .preferredFont(forTextStyle: .title2); emptyTitle.textColor = .tertiaryLabelColor
        let emptyDetail = NSTextField(labelWithString: "Choose a conversation in the sidebar, or press ⌘O."); emptyDetail.textColor = .tertiaryLabelColor
        emptyConversation.setViews([emptyTitle, emptyDetail], in: .center); emptyConversation.orientation = .vertical; emptyConversation.spacing = 6
        // The ink overlay is last: words in flight pass over the composer glass.
        for view in [themeBackdrop, transcriptScroll, bar, jumpLatestButton, earlierProgress, emptyConversation, ink.overlay, stickers.overlay] { view.translatesAutoresizingMaskIntoConstraints = false; chat.addSubview(view) }
        NSLayoutConstraint.activate([
            stickers.overlay.topAnchor.constraint(equalTo: chat.topAnchor),
            stickers.overlay.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
            stickers.overlay.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
            stickers.overlay.bottomAnchor.constraint(equalTo: chat.bottomAnchor),
            ink.overlay.topAnchor.constraint(equalTo: chat.topAnchor),
            ink.overlay.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
            ink.overlay.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
            ink.overlay.bottomAnchor.constraint(equalTo: chat.bottomAnchor),
            themeBackdrop.topAnchor.constraint(equalTo: chat.topAnchor),
            themeBackdrop.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
            themeBackdrop.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
            themeBackdrop.bottomAnchor.constraint(equalTo: chat.bottomAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: chat.topAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: chat.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: chat.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: chat.trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: chat.bottomAnchor, constant: -14),
            jumpLatestButton.centerXAnchor.constraint(equalTo: chat.centerXAnchor),
            jumpLatestButton.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            emptyConversation.centerXAnchor.constraint(equalTo: chat.centerXAnchor),
            emptyConversation.centerYAnchor.constraint(equalTo: chat.centerYAnchor),
            earlierProgress.centerXAnchor.constraint(equalTo: chat.centerXAnchor),
            earlierProgress.topAnchor.constraint(equalTo: chat.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
        return chat
    }

    private func configureComposer() {
        composer.isRichText = true; composer.importsGraphics = false; composer.isAutomaticSpellingCorrectionEnabled = false; composer.isContinuousSpellCheckingEnabled = true; composer.allowsUndo = true; composer.font = ComposerMetrics.font; composer.textColor = .labelColor; composer.drawsBackground = false; composer.textContainerInset = ComposerMetrics.textInset; composer.isVerticallyResizable = true; composer.autoresizingMask = .width; composer.textContainer?.widthTracksTextView = true; composer.delegate = self; composer.setAccessibilityLabel("Message composer")
        composer.minSize = NSSize(width: 0, height: 0); composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.registerForDraggedTypes([.fileURL] + PromisedFileReceiver.draggedTypes); composer.onPromisedFiles = { [weak self] sources in self?.receivePromisedFiles(sources) }; composer.onSend = { [weak self] in self?.send(nil) }; composer.onFiles = { [weak self] urls in self?.stage(urls) }; composer.onEscape = { [weak self] in self?.cancelContext() }
        composer.onCompletionKey = { [weak self] event in self?.mentionPopover.handle(event) ?? false }
        composer.onEditLast = { [weak self] in self?.editLastOwnMessage() ?? false }
        composer.onAttachmentRequest = { [weak self] in
            guard let self else { return false }
            guard self.editing == nil else { self.status.stringValue = ComposerView.editingAttachmentMessage; return false }
            return true
        }
        composer.onPasteError = { [weak self] message in self?.status.stringValue = message }
        mentionPopover.onChoose = { [weak self] candidate, query in self?.insertMention(candidate, query: query) }
        linkPreview.onChange = { [weak self] in self?.showLinkPreview() }
        composer.onImage = { [weak self] data, ext in
            guard let self, self.composer.isEditable, self.editing == nil, self.session != nil, self.channel != nil else { return }
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("NevermorePaste-\(UUID().uuidString).\(ext)")
                // Register the import before the paste handler returns, so an
                // immediate Send cannot overtake a pasted image.
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]); self.stage([url])
            } catch { self.app.showError(error) }
        }
        composerScroll.documentView = composer; composerScroll.hasVerticalScroller = true; composerScroll.autohidesScrollers = true; composerScroll.drawsBackground = false; composerScroll.borderType = .noBorder
        composerHeight = composerEditorContainer.heightAnchor.constraint(equalToConstant: ComposerMetrics.minimumHeight); composerHeight.isActive = true
        composer.frame = NSRect(x: 0, y: 0, width: composerScroll.contentSize.width, height: ComposerMetrics.minimumHeight)
        composer.postsFrameChangedNotifications = true
    }

    private func buildComposerBar() -> NSView {
        func iconButton(_ button: NSButton, size: CGFloat, tint: NSColor, tip: String, action: Selector) {
            button.isBordered = false; button.symbolConfiguration = .init(pointSize: size, weight: .regular); button.contentTintColor = tint
            button.target = self; button.action = action; button.toolTip = tip
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        iconButton(attachButton, size: 15, tint: .secondaryLabelColor, tip: "Attach files (⇧⌘A)", action: #selector(attachFiles(_:)))
        iconButton(emojiButton, size: 15, tint: .secondaryLabelColor, tip: "Emoji & Symbols (⌃⌘Space)", action: #selector(showEmojiPalette(_:)))
        iconButton(sendButton, size: 22, tint: .themeAccent, tip: "Send (Return)", action: #selector(send(_:)))
        sendButton.setAccessibilityLabel("Send")
        let input = NSStackView(views: [attachButton, NSView(), emojiButton, sendButton])
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composerEditorContainer.addSubview(composerScroll)
        NSLayoutConstraint.activate([
            composerScroll.leadingAnchor.constraint(equalTo: composerEditorContainer.leadingAnchor, constant: 8),
            composerScroll.trailingAnchor.constraint(equalTo: composerEditorContainer.trailingAnchor, constant: -8),
            composerScroll.topAnchor.constraint(equalTo: composerEditorContainer.topAnchor),
            composerScroll.bottomAnchor.constraint(equalTo: composerEditorContainer.bottomAnchor)
        ])
        inlineComposer.install(in: composerEditorContainer)
        composerResizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.manualComposerHeight = self.composerHeight.constant + delta
            self.updateComposerHeight()
        }
        composerResizeHandle.onReset = { [weak self] in
            self?.manualComposerHeight = nil; self?.updateComposerHeight()
        }
        input.orientation = .horizontal; input.alignment = .bottom; input.spacing = 6; input.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 5, right: 6)
        for button in [attachButton, emojiButton, sendButton] { button.heightAnchor.constraint(equalToConstant: ComposerMetrics.buttonHeight).isActive = true }
        let statusIcon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!); statusIcon.contentTintColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel("Conversation status")
        statusRow.setViews([statusIcon, status], in: .leading); statusRow.spacing = 5; statusRow.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 1, right: 12)
        contextIcon.contentTintColor = .secondaryLabelColor
        context.font = .systemFont(ofSize: NSFont.smallSystemFontSize); context.textColor = .secondaryLabelColor; context.lineBreakMode = .byTruncatingTail; context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextCancel.isBordered = false; contextCancel.contentTintColor = .tertiaryLabelColor; contextCancel.target = self; contextCancel.action = #selector(cancelComposerContext(_:)); contextCancel.toolTip = "Cancel (Escape)"
        contextRow.setViews([contextIcon, context], in: .leading); contextRow.setViews([contextCancel], in: .trailing); contextRow.spacing = 6; contextRow.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 1, right: 10)
        attachmentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize); attachmentLabel.textColor = .secondaryLabelColor
        attachmentsRow.orientation = .horizontal; attachmentsRow.spacing = 6; attachmentsRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 2, right: 12)
        composerStack.orientation = .vertical; composerStack.alignment = .leading; composerStack.spacing = 2
        // The card keeps its width where there is room and narrows with the
        // conversation. Its width is the weakest wish in the window, so it
        // never decides how wide the conversation is.
        linkPreviewCard.translatesAutoresizingMaskIntoConstraints = false; linkPreviewRow.addSubview(linkPreviewCard)
        let cardWidth = linkPreviewCard.widthAnchor.constraint(equalToConstant: ComposerMetrics.linkPreviewWidth); cardWidth.priority = LinkPreviewCard.widthPriority
        NSLayoutConstraint.activate([
            cardWidth,
            linkPreviewCard.leadingAnchor.constraint(equalTo: linkPreviewRow.leadingAnchor, constant: 12), linkPreviewCard.trailingAnchor.constraint(lessThanOrEqualTo: linkPreviewRow.trailingAnchor, constant: -12),
            linkPreviewCard.topAnchor.constraint(equalTo: linkPreviewRow.topAnchor, constant: 10), linkPreviewCard.bottomAnchor.constraint(equalTo: linkPreviewRow.bottomAnchor, constant: -5),
        ])
        composerStack.setViews([composerResizeHandle, composerFormatting, statusRow, contextRow, attachmentsRow, linkPreviewRow, composerEditorContainer, input], in: .top)
        for row in [composerResizeHandle, statusRow, contextRow, attachmentsRow, linkPreviewRow, composerFormatting, composerEditorContainer, input] { row.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true }
        status.onChange = { [weak self] in self?.updateComposerRows() }
        context.onChange = { [weak self] in self?.updateComposerRows() }
        composerGlass.cornerRadius = 18
        composerGlass.contentView = composerStack
        updateComposerRows()
        return composerGlass
    }

    // MARK: Layout

    /// The clip view's top-most origin: the transcript scrolls under the
    /// toolbar, so its first line rests at -contentInsets.top, not 0.
    var minimumTranscriptOrigin: CGFloat { -transcriptScroll.contentInsets.top }

    var readableTranscriptRect: NSRect {
        var rect = transcriptScroll.contentView.bounds
        let insets = transcriptScroll.contentInsets
        rect.origin.y += insets.top
        rect.size.height = max(0, rect.height - insets.top - insets.bottom)
        return rect
    }

    func updateTranscriptInsets() {
        guard let contentController, contentController.isViewLoaded else { return }
        let top = contentController.view.safeAreaInsets.top
        let bottom = composerGlass.frame.height + 22
        let current = transcriptScroll.contentInsets
        guard abs(current.top - top) > 0.5 || abs(current.bottom - bottom) > 0.5 else { return }
        transcriptScroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        transcriptScroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom - 8, right: 0)
        // Nothing announces new insets. The keeper keeps the reader's line
        // above a composer that grew, or the newest message when following.
        viewportKeeper.viewportDidChange()
    }

    func updateComposerHeight() {
        guard composerHeight != nil else { return }
        let content: CGFloat
        if inlineComposer.mode == .markdown, let text = inlineComposer.textView {
            // Measuring plain source avoids forcing the engine's TextKit 2
            // editor into TextKit 1 compatibility mode.
            let width = text.bounds.width - text.textContainerInset.width * 2 - (text.textContainer?.lineFragmentPadding ?? 0) * 2
            guard width > 0, let font = text.font else { return }
            content = (text.string as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height + text.textContainerInset.height * 2
        } else {
            guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
            layout.ensureLayout(for: container)
            content = layout.usedRect(for: container).height + composer.textContainerInset.height * 2
        }
        let chrome = max(0, composerGlass.frame.height - composerHeight.constant)
        let available = contentController?.view.bounds.height ?? 760
        let limit = max(ComposerMetrics.minimumHeight, available * 0.6 - chrome)
        let target = min(max(manualComposerHeight ?? min(content.rounded(.up), ComposerMetrics.maximumHeight), ComposerMetrics.minimumHeight), limit)
        guard abs(composerHeight.constant - target) > 0.5 else { return }
        composerHeight.constant = target
        contentController?.view.needsLayout = true
    }

    func updateComposerRows() {
        let statusText = status.stringValue
        let healthy = session.map { statusText == $0.state && $0.statusAttention == nil && ($0.demo || $0.realtimeLive) } ?? true
        statusRow.isHidden = statusText.isEmpty || healthy || statusText == "Add an account to get started"
        contextRow.isHidden = context.stringValue.isEmpty
        contextCancel.isHidden = editing == nil && replyTo == nil
        attachmentsRow.isHidden = attachmentsRow.arrangedSubviews.isEmpty
        linkPreviewRow.isHidden = linkPreview.content == nil
        contentController?.view.needsLayout = true
    }

    /// Looks at the draft's links again. Demo sessions get a fixture, so
    /// they never reach the network; without a session there is no card.
    func updateLinkPreview() {
        var loader = linkPreviewLoaderOverride
        if loader == nil, let session { loader = session.demo ? DemoLinkPreviews() : app.linkPreviews }
        let value = inlineComposer.mode == .markdown
            ? (try? NativeRichText.attributedString(document: inlineComposer.currentDocument())) ?? NSAttributedString(string: "")
            : composer.attributedString()
        let links = channel == nil ? [] : NativeRichText.previewableLinks(in: value)
        let draft = [session?.account.id.uuidString, channel?.id, editing?.id].map { $0 ?? "" }.joined(separator: "/")
        linkPreview.update(links: links, loader: loader, draft: draft)
    }

    func showLinkPreview() {
        if let content = linkPreview.content { linkPreviewCard.show(content) }
        updateComposerRows()
    }

    func updateAttachmentChips() {
        for view in attachmentsRow.arrangedSubviews { attachmentsRow.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, attachment) in attachments.enumerated() {
            attachmentsRow.addArrangedSubview(AttachmentChip(filename: attachment.filename, removeTarget: self, removeAction: #selector(removeAttachment(_:)), tag: index))
        }
        if !attachmentLabel.stringValue.isEmpty {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPromisedFiles(_:))); cancel.controlSize = .small; cancel.bezelStyle = .push
            let receiving = NSStackView(views: [spinner, attachmentLabel, cancel]); receiving.spacing = 6
            attachmentsRow.addArrangedSubview(receiving)
        }
        updateComposerRows()
    }

    @objc func removeAttachment(_ sender: NSButton) {
        guard composer.isEditable, attachments.indices.contains(sender.tag) else { return }
        let removed = attachments.remove(at: sender.tag)
        updateContext(); textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        Task { await saveTask?.value; try? await session?.store.pruneStaging(discarding: [removed.id]) }
    }

    @objc func cancelComposerContext(_ sender: Any?) { cancelContext() }
    @objc func showEmojiPalette(_ sender: Any?) {
        guard prepareEmojiPalette() else { return }
        NSApp.orderFrontCharacterPalette(sender)
    }

    /// Focuses the composer and points the palette about to open at the
    /// emoji button. False when the composer cannot take a character: it
    /// is read-only, or another view kept the focus and the palette would
    /// type into that view instead.
    func prepareEmojiPalette() -> Bool {
        guard composer.isEditable else { return false }
        focusComposer()
        guard window?.firstResponder === activeComposer else { return false }
        composer.anchorNextCharacterPalette(to: emojiButton)
        return true
    }

    func updateWindowTitle() {
        guard let window else { return }
        let account = session.map { $0.account.displayName.isEmpty ? $0.account.user : $0.account.displayName }
        emptyConversation.isHidden = channel != nil
        composerGlass.isHidden = channel == nil
        guard let channel else {
            window.title = "Nevermore"; window.subtitle = account ?? ""
            return
        }
        window.title = channel.title
        var parts: [String] = []
        if channel.raw["is_thread"].bool { parts.append("Thread") }
        if !channel.isDM, !channel.workspace.isEmpty { parts.append(channel.workspace) }
        if isArchivedConversation { parts.append("Archived") }
        if app.sessions.filter({ !$0.stopped }).count > 1 || parts.isEmpty, let account { parts.append(account) }
        window.subtitle = parts.joined(separator: " · ")
        composer.placeholder = channel.raw["is_thread"].bool ? "Reply in thread" : channel.isDM ? "Message \(channel.title)" : "Message #\(channel.title)"
        inlineComposer.configureSource()
    }

    // MARK: Sidebar

    func sidebarAvatarUserID(for channel: RavenChannel) -> String? {
        // Keep the type icon for threads and archived conversations.
        guard channel.isDM, !channel.raw["is_thread"].bool, !channel.raw["is_archived"].bool,
              let peer = channel.raw["peer_user_id"].string, !peer.isEmpty else { return nil }
        return peer
    }

    func refreshSidebarAvatars() {
        // Include AppKit's prefetched rows: scrolling them into view may not
        // call viewFor again. Do not materialize more rows or reset the table.
        sidebar.enumerateAvailableRowViews { [self] _, row in
            guard sidebarItems.indices.contains(row), let channel = sidebarItems[row].1,
                  let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarConversationCell else { return }
            cell.configure(sidebarModel(for: channel, unread: unreadCount(channel.id)), fontSize: sidebarFontSize)
        }
    }

    func sidebarModel(for channel: RavenChannel, unread: Int) -> SidebarConversationCell.Model {
        let presence = channel.raw["peer_user_id"].string.flatMap { session?.presenceDescription(for: $0) }
        let symbol: String
        if channel.raw["is_thread"].bool { symbol = "bubble.left.and.text.bubble.right" }
        else if channel.raw["is_archived"].bool { symbol = "archivebox" }
        else if channel.isDM { symbol = "person.crop.circle" }
        else if channel.raw["type"].string == "Private" { symbol = "lock" }
        else { symbol = "number" }
        let access: RavenPortrait.ChannelAccess? = channel.isDM || channel.raw["is_thread"].bool ? nil : (channel.raw["type"].string == "Private" ? .privateChannel : .standard)
        let tooltip = [access == .privateChannel ? "Private channel" : nil, presence, channel.workspace.isEmpty ? nil : channel.workspace, channel.raw["channel_description"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let portrait = sidebarAvatarUserID(for: channel).flatMap { session?.avatarImage(for: $0) } ?? session?.channelAvatarImage(for: channel)
        return .init(title: channel.title, symbolName: symbol, unread: unread, muted: channel.raw["muted"].bool, archived: channel.raw["is_archived"].bool, presence: presence, tooltip: tooltip, bird: unkindness.bird(for: channel), photo: portrait, channelAccess: access)
    }

    func unreadCount(_ channelID: String) -> Int {
        guard let value = session?.unread.array.first(where: { $0["name"].string == channelID })?["unread_count"], case .number(let number) = value, number.isFinite, number >= 1 else { return 0 }
        return Int(min(number, 9999))
    }

    var sidebarFontSize: CGFloat {
        switch sidebar.effectiveRowSizeStyle {
        case .small: return 11
        case .large: return 15
        default: return 13
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == Self.conversationMenuIdentifier {
            populateConversationMenu(menu)
            // Rebuilt while opening, the menu is treated as a pull-down whose
            // item 0 is a hidden title, so keep a placeholder there.
            menu.insertItem(NSMenuItem(title: "Conversation", action: nil, keyEquivalent: ""), at: 0)
            return
        }
        guard menu === sidebar.menu else { return }
        menu.removeAllItems()
        let row = sidebar.clickedRow
        guard sidebarItems.indices.contains(row), let target = sidebarItems[row].1 else { return }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = target
        }
        add("Open in New Window", #selector(openSidebarRowInNewWindow(_:)))
        add("Open in New Tab", #selector(openSidebarRowInNewTab(_:)))
        menu.addItem(.separator())
        add(session?.favoriteIDs.contains(target.id) == true ? "Remove from Favorites" : "Add to Favorites", #selector(toggleSidebarRowFavorite(_:)))
        if ChannelPolicy.canMute(target) { add(target.raw["muted"].bool ? "Unmute" : "Mute", #selector(toggleSidebarRowMute(_:))) }
        add("Mark as Unread", #selector(markSidebarRowUnread(_:)))
        menu.addItem(.separator())
        add("Copy Link", #selector(copySidebarRowLink(_:)))
    }

    private func sidebarTarget(_ sender: Any?) -> RavenChannel? {
        if let item = sender as? NSMenuItem, let channel = item.representedObject as? RavenChannel { return channel }
        let row = sidebar.clickedRow >= 0 ? sidebar.clickedRow : sidebar.selectedRow
        return sidebarItems.indices.contains(row) ? sidebarItems[row].1 : nil
    }
    @objc func openSidebarRowInNewWindow(_ sender: Any?) { guard let session, let target = sidebarTarget(sender) else { return }; app.open(session: session, channel: target) }
    @objc func openSidebarRowInNewTab(_ sender: Any?) { guard let session, let target = sidebarTarget(sender) else { return }; app.openTab(beside: self, session: session, channel: target) }
    @objc func toggleSidebarRowFavorite(_ sender: Any?) { guard let target = sidebarTarget(sender) else { return }; toggleFavorite(for: target) }
    @objc func toggleSidebarRowMute(_ sender: Any?) { guard let target = sidebarTarget(sender) else { return }; toggleMute(for: target) }
    @objc func markSidebarRowUnread(_ sender: Any?) { guard let session, let target = sidebarTarget(sender) else { return }; action { try await session.markUnread(channelID: target.id) } }
    @objc func copySidebarRowLink(_ sender: Any?) { guard let target = sidebarTarget(sender) else { return }; copyChannelLink(target) }

    func copyChannelLink(_ target: RavenChannel) {
        guard let session else { return }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        guard let encoded = target.id.addingPercentEncoding(withAllowedCharacters: allowed), let link = URL(string: "/raven/channel/" + encoded, relativeTo: session.account.origin)?.absoluteURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    /// Selects the next or previous conversation in sidebar order, optionally
    /// skipping read ones (Go ▸ Next Unread Conversation).
    func selectAdjacentConversation(forward: Bool, unreadOnly: Bool) {
        let candidates = sidebarItems.indices.filter { index in
            guard let channel = sidebarItems[index].1 else { return false }
            return !unreadOnly || unreadCount(channel.id) > 0
        }
        guard !candidates.isEmpty else { NSSound.beep(); return }
        let current = sidebarItems.firstIndex { $0.1?.id == channel?.id }
        let next: Int?
        if let current { next = forward ? candidates.first { $0 > current } ?? (unreadOnly ? candidates.first : nil) : candidates.last { $0 < current } }
        else { next = forward ? candidates.first : candidates.last }
        guard let next, let destination = sidebarItems[next].1 else { NSSound.beep(); return }
        sidebar.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); sidebar.scrollRowToVisible(next)
        select(destination)
    }
    @objc func nextConversation(_ sender: Any?) { selectAdjacentConversation(forward: true, unreadOnly: false) }
    @objc func previousConversation(_ sender: Any?) { selectAdjacentConversation(forward: false, unreadOnly: false) }
    @objc func nextUnreadConversation(_ sender: Any?) { selectAdjacentConversation(forward: true, unreadOnly: true) }

    /// Space in the transcript. On a message with a file it opens Quick
    /// Look, as before. Otherwise it reads on, as Space does in Mail and
    /// in feed readers: a page down, and from the end of the conversation
    /// to the next unread one. With nothing left to read it does nothing.
    func readOn() {
        if let file = selectedMessage?.raw["file"].string, !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { previewAttachment(); return }
        // Against the farthest the transcript scrolls: a short conversation
        // ends above the composer and is at its end without scrolling.
        let clip = transcriptScroll.contentView
        let farthest = max(minimumTranscriptOrigin, transcript.frame.maxY + transcriptScroll.contentInsets.bottom - clip.bounds.height)
        if clip.bounds.origin.y < farthest - 2 { transcriptScroll.pageDown(nil); return }
        // On to the next conversation a raven waits on: muted ones have
        // unread counts and no claim on the reader.
        let waiting = sidebarItems.indices.filter { index in sidebarItems[index].1.map { $0.id != channel?.id && unkindness.bird(for: $0) != nil } == true }
        let current = sidebarItems.firstIndex { $0.1?.id == channel?.id } ?? -1
        guard let next = waiting.first(where: { $0 > current }) ?? waiting.first, let destination = sidebarItems[next].1 else { return }
        sidebar.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); sidebar.scrollRowToVisible(next)
        select(destination)
    }

    // MARK: Transcript interaction

    func messageRange(at point: NSPoint) -> (NSRange, RavenMessage)? {
        messageRanges.first { entry in
            let rect = highlightRect(for: entry.0)
            return point.y >= rect.minY && point.y < rect.maxY
        }
    }

    /// The message rectangle without its trailing separator lines, widened to
    /// the reading column so highlights and hover targets line up.
    func highlightRect(for range: NSRange) -> NSRect {
        let text = transcript.string as NSString
        var trimmed = range
        while trimmed.length > 0, NSMaxRange(trimmed) <= text.length, text.character(at: NSMaxRange(trimmed) - 1) == 10 { trimmed.length -= 1 }
        var rect = rect(for: trimmed)
        // From the avatar column to the right edge of the text.
        let inset = transcript.readingColumnInset
        rect.origin.x = inset - 10
        rect.size.width = max(0, transcript.bounds.width - inset * 2 + 20)
        return rect.insetBy(dx: 0, dy: -5)
    }

    func updateMessageHighlight() {
        let selection = transcript.selectedRange()
        guard selection.length == 0, selection.location != NSNotFound, let entry = messageRanges.first(where: { NSLocationInRange(selection.location, $0.0) }) else { transcript.highlightRect = nil; transcript.caretMessageLocation = nil; return }
        transcript.highlightRect = highlightRect(for: entry.0)
        transcript.caretMessageLocation = entry.0.location
    }

    func updateHover(at point: NSPoint?) {
        // An open reaction row points at its message; keep the bar there.
        guard !quickReactions.isShown else { return }
        // The bar straddles its message's top edge, over the previous
        // message. Reaching for a button must not move the bar away.
        if let point, !hoverBar.isHidden, hoverBar.superview === transcript, hoverBar.frame.contains(point) { return }
        // Messages under the toolbar or the floating composer are not
        // hover targets; the pointer is over glass there.
        guard let point, readableTranscriptRect.contains(NSPoint(x: readableTranscriptRect.midX, y: point.y)), let entry = messageRange(at: point), !isUpdatingTranscript, session?.stopped == false else { hideHoverBar(); return }
        guard hoveredMessageID != entry.1.id || hoverBar.superview == nil else { return }
        guard placeHoverBar(over: entry.0) else { hideHoverBar(); return }
        hoveredMessageID = entry.1.id
        // Load the account's most-used reactions before the React click.
        session.map { $0.quickReactionUsage.prefetch(for: $0) }
    }

    /// Puts the hover bar at the top trailing corner of a message, below the
    /// toolbar's glass. Returns false when too little of the message shows.
    @discardableResult func placeHoverBar(over range: NSRange) -> Bool {
        if hoverBar.stack.arrangedSubviews.isEmpty {
            hoverBar.reactButton = hoverBar.addButton(symbol: "face.smiling", label: "React…", target: self, action: #selector(hoverReact(_:)))
            hoverBar.addButton(symbol: "arrowshape.turn.up.left", label: "Reply", target: self, action: #selector(hoverReply(_:)))
            hoverBar.addButton(symbol: "bubble.left.and.bubble.right", label: "Reply in Thread", target: self, action: #selector(hoverThread(_:)))
            hoverBar.addButton(symbol: "ellipsis", label: "More Actions", target: self, action: #selector(hoverMore(_:)))
        }
        if hoverBar.superview !== transcript { hoverBar.translatesAutoresizingMaskIntoConstraints = true; transcript.addSubview(hoverBar) }
        let size = hoverBar.fittingSize
        let rect = highlightRect(for: range)
        let readable = readableTranscriptRect
        guard rect.maxY >= readable.minY + size.height, rect.minY <= readable.maxY - size.height else { return false }
        hoverBar.frame = NSRect(x: rect.maxX - size.width - 4, y: max(rect.minY - size.height / 2, readable.minY + 2, transcript.bounds.minY), width: size.width, height: size.height)
        hoverBar.isHidden = false
        transcript.hoverMessageLocation = range.location
        // The reaction row anchors to a button inside the bar.
        hoverBar.layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: hoverBar)
        return true
    }

    func hideHoverBar() {
        quickReactions.close()
        hoveredMessageID = nil
        hoverBar.isHidden = true
        transcript.hoverMessageLocation = nil
    }

    /// Scrolling moves messages under a still pointer. An open reaction row
    /// follows its message instead, and closes once the message leaves view.
    func transcriptDidScroll() {
        ink.transcriptDidScroll()
        stickers.transcriptDidScroll()
        guard quickReactions.isShown else { hideHoverBar(); return }
        repositionQuickReactions()
    }

    /// Keeps an open reaction row on its message after scrolling or a
    /// re-render, so its arrow never points at a different message.
    func repositionQuickReactions() {
        guard quickReactions.isShown else { return }
        guard let id = quickReactions.messageID, let range = messageRanges.first(where: { $0.1.id == id })?.0,
              placeHoverBar(over: range), let button = hoverBar.reactButton else { hideHoverBar(); return }
        hoveredMessageID = id
        quickReactions.reposition(to: button.convert(button.bounds, to: transcript))
    }

    private func focusHoveredMessage() -> Bool {
        guard let id = hoveredMessageID, let range = messageRanges.first(where: { $0.1.id == id })?.0 else { return false }
        transcript.setSelectedRange(NSRange(location: range.location, length: 0))
        updateMessageHighlight()
        return true
    }
    @objc func hoverReact(_ sender: Any?) { guard focusHoveredMessage(), let message = selectedMessage else { return }; showQuickReactions(for: message, focus: .none) }
    @objc func hoverReply(_ sender: Any?) { guard focusHoveredMessage() else { return }; reply(sender) }
    @objc func hoverThread(_ sender: Any?) { guard focusHoveredMessage() else { return }; openThread(sender) }
    @objc func hoverMore(_ sender: NSButton) {
        guard focusHoveredMessage(), let menu = messageContextMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    /// Context menu for the message at the caret, showing only commands that
    /// apply to that message's type and ownership.
    func messageContextMenu() -> NSMenu? {
        guard let message = selectedMessage, let session else { return nil }
        let menu = NSMenu(title: "Message")
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        if transcript.selectedRange().length > 0 { menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""); menu.addItem(.separator()) }
        add("Reply", #selector(reply(_:)))
        add("Reply in Thread", #selector(openThread(_:)))
        add("Open Thread in New Window", #selector(openThreadWindow(_:)))
        add("React…", #selector(react(_:)))
        menu.addItem(.separator())
        add("Save for Later", #selector(saveForLater(_:)))
        add("Pin / Unpin", #selector(pin(_:)))
        add("Remind Me…", #selector(remind(_:)))
        add("Forward…", #selector(forward(_:)))
        add("Copy Link", #selector(copyMessageLink(_:)))
        if message.raw["file"].string?.isEmpty == false {
            menu.addItem(.separator())
            add("Quick Look Attachment", #selector(quickLook(_:)))
            add("Save Attachment As…", #selector(saveAttachment(_:)))
        }
        if message.messageType == "Poll" { menu.addItem(.separator()); add("View / Vote in Poll…", #selector(vote(_:))) }
        if let extra = transcript.codeMenuItems?(), !extra.isEmpty { menu.addItem(.separator()); for item in extra { menu.addItem(item) } }
        if message.raw["link_doctype"].string?.isEmpty == false { add("Linked Document…", #selector(linkedDocument(_:))) }
        menu.addItem(.separator())
        add("Who Has Read This?", #selector(readers(_:)))
        if message.owner == session.account.user {
            menu.addItem(.separator())
            add("Edit Message", #selector(editMessage(_:)))
            add("Delete Message…", #selector(deleteMessage(_:)))
        }
        menu.addItem(.separator())
        add("Copy Transcript", #selector(copyTranscript(_:)))
        return menu
    }

    /// Scrolls a message into the readable band between the toolbar and the
    /// floating composer, rather than merely somewhere inside the clip view.
    func scrollMessageIntoView(_ range: NSRange) {
        let target = highlightRect(for: range)
        let readable = readableTranscriptRect
        guard target.minY < readable.minY || target.maxY > readable.maxY else { return }
        let insets = transcriptScroll.contentInsets
        let y = target.height > readable.height ? target.minY - insets.top : target.minY - insets.top - max(0, (readable.height - target.height) / 3)
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(-insets.top, y)))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    func loadEarlierIfAtTop() {
        guard let first = messages.first, session?.stopped == false, autoEarlierFirstID != first.id else { return }
        let readable = readableTranscriptRect
        guard transcript.bounds.height > readable.height, readable.minY <= 24 else { return }
        autoEarlierFirstID = first.id
        loadEarlierMessages(automatic: true)
    }

    // MARK: Toolbar

    static let conversationMenuIdentifier = NSUserInterfaceItemIdentifier("NevermoreConversationActionsMenu")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ConversationToolbar.allowedItems }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ConversationToolbar.defaultItems }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: label) }
        switch id {
        case .nevermoreNavigation:
            // Two plain items rather than a segmented control: each validates
            // its own action, so Forward dims when nothing lies ahead. The
            // segments of a control-backed group inherit the group's single
            // action and validate as enabled together.
            let back = NSToolbarItem(itemIdentifier: ConversationToolbar.backItem)
            back.label = "Back"; back.image = symbol("chevron.backward", "Back"); back.target = self; back.action = #selector(goBack); back.toolTip = "Go back to the previous conversation (⌘[)"
            let forward = NSToolbarItem(itemIdentifier: ConversationToolbar.forwardItem)
            forward.label = "Forward"; forward.image = symbol("chevron.forward", "Forward"); forward.target = self; forward.action = #selector(goForward); forward.toolTip = "Go forward to the next conversation (⌘])"
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [back, forward]
            // Expanded keeps both chevrons as separate items; the automatic
            // representation can collapse the group into a menu when the
            // toolbar is tight, which would not show per-direction dimming.
            group.controlRepresentation = .expanded
            group.label = "Back/Forward"; group.paletteLabel = "Back/Forward"
            group.isNavigational = true
            return group
        case .nevermoreSearch:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            // The customization palette asks for its own copy; it must not
            // take the window's live search field out of the toolbar.
            guard flag else { item.label = "Search"; return item }
            search.placeholderString = "Search"; search.sendsWholeSearchString = true; search.target = self; search.action = #selector(performSearch); search.delegate = self
            search.setAccessibilityLabel("Search messages"); search.toolTip = "Search messages in this conversation (Return to search, ⌥⌘F)"
            item.searchField = search; item.label = "Search"; item.preferredWidthForSearchField = 200; item.resignsFirstResponderWithCancel = true
            return item
        case .nevermoreLater:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("bookmark", "Later"); item.label = "Later"; item.paletteLabel = "Later"; item.toolTip = "Saved messages, reminders and scheduled messages"
            let menu = NSMenu(title: "Later")
            for (title, action) in [("Saved Messages", #selector(showSavedMessages(_:))), ("Reminders", #selector(showReminders(_:))), ("Scheduled Messages", #selector(showScheduledMessages(_:)))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
            item.menu = menu; item.showsIndicator = true
            return item
        case .nevermoreConversation:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("info.circle", "Conversation"); item.label = "Conversation"; item.paletteLabel = "Conversation Actions"; item.toolTip = "Members, pinned messages, files and conversation settings"
            // Identified rather than stored: the customization palette builds
            // its own copies of this item.
            let menu = NSMenu(title: "Conversation"); menu.identifier = Self.conversationMenuIdentifier; menu.delegate = self; item.menu = menu; item.showsIndicator = true
            return item
        default: break
        }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.isBordered = true
        switch id {
        case .nevermoreNewMessage: item.label = "New Message"; item.image = symbol("square.and.pencil", "New Message"); item.action = #selector(chooseConversation(_:)); item.toolTip = "Open a conversation or message a person (⌘N)"
        case .nevermoreInbox: item.label = "Inbox"; item.image = symbol("tray", "Inbox"); item.action = #selector(inbox); item.toolTip = "Mentions and activity (⌘1)"
        case .nevermoreThreads: item.label = "Threads"; item.image = symbol("bubble.left.and.text.bubble.right", "Threads"); item.action = #selector(threads); item.toolTip = "Threads you follow (⌘2)"
        case .nevermoreAttach: item.label = "Attach Files"; item.image = symbol("paperclip", "Attach Files"); item.action = #selector(attachFiles(_:))
        case .nevermoreThreadInspector: item.label = "Thread"; item.image = symbol("sidebar.right", "Thread Inspector"); item.action = #selector(toggleThreadInspector(_:)); item.toolTip = "Show or hide the thread inspector (⌥⌘I)"
        case .nevermoreOutbox: item.label = "Outbox"; item.image = symbol("tray.and.arrow.up", "Outbox"); item.action = #selector(outbox); item.toolTip = "Queued sends (⌘6)"
        default: return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return validateMenuItem(NSMenuItem(title: item.label, action: action, keyEquivalent: ""))
    }
}

@MainActor enum ComposerMetrics {
    static let font = NSFont.systemFont(ofSize: 14)
    static let textInset = NSSize(width: 4, height: 7)
    static let minimumHeight = (NSLayoutManager().defaultLineHeight(for: font) * 3 + textInset.height * 2).rounded(.up)
    static let buttonHeight: CGFloat = 32
    static let maximumHeight: CGFloat = 200
    static let linkPreviewWidth: CGFloat = 440
}

// MARK: - Command validation

extension ConversationWindow {
    /// Titles, check marks and availability for shell commands; nil defers to
    /// the message and channel rules in `validateMenuItem`.
    func validateShellCommand(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action else { return nil }
        let hasSession = session.map { !$0.stopped } ?? false
        let writable = hasSession && session?.readOnly == false
        switch action {
        case #selector(goBack): return navigation.canGoBack
        case #selector(goForward): return navigation.canGoForward
        case #selector(inbox), #selector(threads), #selector(showSavedMessages(_:)), #selector(showReminders(_:)), #selector(showScheduledMessages(_:)), #selector(outbox):
            return hasSession
        case #selector(nextConversation(_:)), #selector(previousConversation(_:)), #selector(nextUnreadConversation(_:)):
            return sidebarItems.contains { $0.1 != nil }
        case #selector(toggleFavorite(_:)):
            item.title = channel.map { session?.favoriteIDs.contains($0.id) == true } == true ? "Remove from Favorites" : "Add to Favorites"
            return writable && channel != nil
        case #selector(markUnread(_:)): return writable && channel != nil
        case #selector(newConversationTab(_:)): return hasSession
        case #selector(attachFiles(_:)): return composer.isEditable && editing == nil && channel != nil && !isArchivedConversation
        case #selector(saveForLater(_:)), #selector(pin(_:)), #selector(remind(_:)), #selector(react(_:)), #selector(openThread(_:)), #selector(openThreadWindow(_:)), #selector(forward(_:)):
            return writable && selectedMessage != nil && (action == #selector(saveForLater(_:)) || action == #selector(remind(_:)) || action == #selector(forward(_:)) || !isArchivedConversation)
        case #selector(deleteMessage(_:)), #selector(editMessage(_:)):
            return writable && composer.isEditable && selectedMessage != nil && selectedMessage?.owner == session?.account.user && !isArchivedConversation
        case #selector(openSidebarRowInNewWindow(_:)), #selector(openSidebarRowInNewTab(_:)), #selector(copySidebarRowLink(_:)): return hasSession
        case #selector(toggleSidebarRowFavorite(_:)), #selector(toggleSidebarRowMute(_:)), #selector(markSidebarRowUnread(_:)): return writable
        case #selector(copyConversationLink(_:)), #selector(showInfo(_:)), #selector(showPinnedMessages(_:)), #selector(showChannelFiles(_:)), #selector(showMembers(_:)), #selector(openConversationWindow(_:)), #selector(openConversationTab(_:)), #selector(printTranscript(_:)), #selector(findInTranscript(_:)):
            return hasSession && channel != nil
        case #selector(leaveChannel(_:)):
            guard let channel else { return false }
            return writable && !channel.isDM && !channel.raw["is_thread"].bool && channel.raw["parent_channel_id"].string == nil
        case #selector(createChannel(_:)), #selector(setCustomStatus(_:)): return writable
        case #selector(showCurrentAccountPreferences(_:)), #selector(openBrowser(_:)), #selector(findMessages(_:)), #selector(searchAccount(_:)), #selector(advancedSearch(_:)): return hasSession
        case #selector(chooseConversation(_:)): return session.map { !$0.stopped } ?? true
        case #selector(toggleThreadInspector(_:)):
            item.title = threadInspector == nil ? "Show Thread Inspector" : "Hide Thread Inspector"
            return threadInspector != nil || selectedMessage != nil
        case #selector(toggleCompactMessages(_:)):
            item.state = UserDefaults.standard.bool(forKey: "compactMessages") ? .on : .off
            return true
        case #selector(actualTextSize(_:)):
            let size = UserDefaults.standard.double(forKey: "fontSize")
            return size != 0 && size != 14
        case #selector(largerText(_:)): return UserDefaults.standard.double(forKey: "fontSize") < 30
        case #selector(smallerText(_:)): let size = UserDefaults.standard.double(forKey: "fontSize"); return size == 0 || size > 11
        case #selector(loadEarlier): return hasSession && !messages.isEmpty
        case #selector(showInParentChannel(_:)): return channel?.raw["parent_channel_id"].string != nil
        case #selector(copyTranscript(_:)): return hasSession && !messages.isEmpty
        case #selector(clearAttachments): return composer.isEditable && (!attachments.isEmpty || !promisedReceives.isEmpty)
        case #selector(schedule(_:)): return writable && channel != nil && composer.isEditable && attachments.isEmpty && !activeComposer.string.isEmpty && !isArchivedConversation
        case #selector(createPoll(_:)): return writable && channel != nil && !isArchivedConversation && pollCreationTask == nil
        case #selector(copyMessageLink(_:)), #selector(readers(_:)): return hasSession && selectedMessage != nil
        case #selector(linkedDocument(_:)): return hasSession && selectedMessage?.raw["link_doctype"].string?.isEmpty == false
        default: return nil
        }
    }
}
