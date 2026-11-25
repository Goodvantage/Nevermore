import AppKit
import SwiftUI
import NevermoreCore

/// The source surface shares the conversation's lifetime, rather than opening
/// a second transaction. All persistence still goes through the draft service.
@MainActor final class InlineComposer {
    weak var owner: ConversationWindow?
    let state = MarkdownEditorState()
    lazy var host = NSHostingView(rootView: MarkdownEditorSurface(state: state))
    var mode = DraftEditorState.Mode.visual
    var savedSource = ""
    var sourceSelection = NSRange(location: 0, length: 0)
    var visualSelection = NSRange(location: 0, length: 0)
    var visualOrigin = NSPoint.zero
    var sourceOrigin = NSPoint.zero
    var visualBaseline: NSAttributedString?
    var applying = false
    private var observer: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?
    private var keys: Any?

    init(owner: ConversationWindow) { self.owner = owner }

    var textView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host)
    }
    var source: String { textView?.string ?? state.text }
    var activeTextView: NSTextView? { mode == .visual ? owner?.composer : textView }
    var draftEditorState: DraftEditorState? {
        mode == .visual && savedSource.isEmpty ? nil : editorState
    }
    var editorState: DraftEditorState {
        let range = mode == .markdown ? textView?.selectedRange() ?? sourceSelection : sourceSelection
        return DraftEditorState(mode: mode, source: mode == .markdown ? source : savedSource,
                                selection: range.location, selectionLength: range.length)
    }

    func install(in container: NSView) {
        state.owner = owner
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor), host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        host.isHidden = true
        host.setAccessibilityLabel("Markdown message source")
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            let object = note.object as? NSTextView
            MainActor.assumeIsolated {
                guard let self, !self.applying, self.mode == .markdown, object === self.textView else { return }
                self.sourceChanged()
            }
        }
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] note in
            let object = note.object as? NSTextView
            MainActor.assumeIsolated {
                guard let self, !self.applying, self.mode == .markdown, object === self.textView else { return }
                self.owner?.updateCompletions()
            }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let owner = self.owner, self.mode == .markdown,
                  event.window === owner.window, owner.window?.firstResponder === self.textView,
                  let text = self.textView, text.isEditable, !text.hasMarkedText() else { return event }
            if owner.handleCompletionKey(event) { return nil }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if event.keyCode == 36 || event.keyCode == 76 {
                if flags.contains(.command) || (!UserDefaults.standard.bool(forKey: ComposerSendKey.defaultsKey) && flags.isEmpty) { owner.send(nil); return nil }
            }
            if event.keyCode == 53 { owner.cancelContext(); return nil }
            if event.keyCode == 126, text.string.isEmpty, owner.editLastOwnMessage() { return nil }
            if flags == .command || flags == [.command, .shift] {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "z": self.performUndo(redo: flags.contains(.shift)); return nil
                case "b": self.format(.bold); return nil
                case "i": self.format(.italic); return nil
                case "u": self.format(.underline); return nil
                case "k" where flags.contains(.shift): self.format(.inlineCode); return nil
                case "c": _ = owner.handleSourceClipboard(.copy, pasteboard: .general); return nil
                case "x" where flags.contains(.shift): self.format(.strike); return nil
                case "x": _ = owner.handleSourceClipboard(.cut, pasteboard: .general); return nil
                case "v": _ = owner.handleSourceClipboard(.paste, pasteboard: .general); return nil
                default: break
                }
            }
            return event
        }
    }

    func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver); self.selectionObserver = nil }
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
    }

    func configureSource() {
        guard let text = textView, let owner else { return }
        if state.isEditable != owner.composer.isEditable { state.isEditable = owner.composer.isEditable }
        if state.placeholder != owner.composer.placeholder { state.placeholder = owner.composer.placeholder }
        text.isRichText = false; text.importsGraphics = false; text.allowsUndo = false
        text.isEditable = owner.composer.isEditable
        text.drawsBackground = false; text.enclosingScrollView?.drawsBackground = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.unregisterDraggedTypes(); text.registerForDraggedTypes([.string])
    }

    func setSource(_ value: String, selection: NSRange) {
        state.text = value
        if let text = textView, text.string != value { text.string = value }
        sourceSelection = NSRange(location: min(max(0, selection.location), value.utf16.count), length: 0)
        sourceSelection.length = min(max(0, selection.length), value.utf16.count - sourceSelection.location)
        textView?.setSelectedRange(sourceSelection)
        savedSource = value
    }

    struct Snapshot {
        let editor: DraftEditorState
        let visual: NSAttributedString
        let visualSelection: NSRange
    }
    func snapshot() -> Snapshot? {
        guard let owner else { return nil }
        return Snapshot(editor: editorState, visual: NSAttributedString(attributedString: owner.composer.attributedString()), visualSelection: owner.composer.selectedRange())
    }
    func registerUndo(_ snapshot: Snapshot, name: String) {
        guard let owner else { return }
        let session = owner.session, channelID = owner.channel?.id, editID = owner.editing?.id
        let app = owner.app
        owner.composer.undoManager?.registerUndo(withTarget: owner) { original in
            let target = !original.isClosed && original.session === session && original.channel?.id == channelID && original.editing?.id == editID ? original : app.windows.first { !$0.isClosed && $0.session === session && $0.channel?.id == channelID && $0.editing?.id == editID }
            target?.inlineComposer.restore(snapshot, undoName: name)
        }
        owner.composer.undoManager?.setActionName(name)
    }
    private func restore(_ value: Snapshot, undoName: String) {
        guard let owner, let inverse = snapshot() else { return }
        registerUndo(inverse, name: undoName)
        applying = true
        owner.composer.textStorage?.setAttributedString(value.visual)
        owner.composer.setSelectedRange(value.visualSelection)
        mode = value.editor.mode
        setSource(value.editor.source, selection: NSRange(location: value.editor.selection, length: value.editor.selectionLength))
        applying = false
        updateSurface(focus: true)
        owner.persistActiveDraft()
    }
    func performUndo(redo: Bool) {
        guard owner?.composer.isEditable == true, activeTextView?.hasMarkedText() != true, let undo = owner?.composer.undoManager else { return }
        if redo { undo.redo() } else { undo.undo() }
    }

    func switchMode(_ next: DraftEditorState.Mode) {
        guard let owner, owner.composer.isEditable, !owner.isClosed, mode != next,
              activeTextView?.hasMarkedText() != true else { updateSurface(); return }
        do {
            if mode == .visual { owner.composer.flushPendingShortcut() }
            guard let before = snapshot() else { return }
            let document = try currentDocument()
            let value = next == .markdown ? try RavenMarkdown.source(from: document) : ""
            registerUndo(before, name: "Change Writing Mode")
            applying = true
            if next == .markdown {
                visualSelection = owner.composer.selectedRange()
                visualOrigin = owner.composerScroll.contentView.bounds.origin
                let unchanged = visualBaseline?.isEqual(to: owner.composer.attributedString()) == true
                setSource(unchanged ? savedSource : value, selection: unchanged ? sourceSelection : NSRange(location: value.utf16.count, length: 0))
            } else {
                sourceSelection = textView?.selectedRange() ?? sourceSelection
                sourceOrigin = textView?.enclosingScrollView?.contentView.bounds.origin ?? .zero
                savedSource = source
                let visual = NativeRichText.attributedString(document: document, revealSpoilers: true)
                owner.composer.textStorage?.setAttributedString(visual)
                visualBaseline = NSAttributedString(attributedString: visual)
                owner.composer.typingAttributes = NativeRichText.plainTypingAttributes
                owner.composer.setSelectedRange(NSRange(location: min(visualSelection.location, visual.length), length: 0))
            }
            mode = next; applying = false
            owner.shortcutPopover.reset()
            updateSurface(focus: true)
            owner.persistActiveDraft()
        } catch { owner.status.stringValue = error.localizedDescription; updateSurface() }
    }

    func currentDocument() throws -> RichDocument {
        guard let owner else { throw RichTextError.unsafeEdit }
        return try mode == .markdown ? RavenMarkdown.document(from: source) : NativeRichText.document(from: owner.composer.attributedString())
    }

    func sourceChanged() {
        guard let owner, source != savedSource else { return }
        var previous = editorState; previous.source = savedSource
        previous.selection = sourceSelection.location; previous.selectionLength = sourceSelection.length
        registerUndo(Snapshot(editor: previous, visual: NSAttributedString(attributedString: owner.composer.attributedString()), visualSelection: owner.composer.selectedRange()), name: "Typing")
        savedSource = source; state.text = source
        sourceSelection = textView?.selectedRange() ?? sourceSelection
        owner.persistActiveDraft(); owner.updateCompletions(); owner.updateComposerHeight(); owner.updateLinkPreview()
    }

    func load(_ value: DraftEditorState?, focus: Bool = false) {
        // A save acknowledgement or an unchanged peer snapshot must not move
        // this window's caret back to the selection captured when typing.
        if let value, mode == .markdown, value.mode == mode, source == value.source {
            updateSurface(focus: focus)
            return
        }
        applying = true
        mode = value?.mode ?? .visual
        if let value { setSource(value.source, selection: NSRange(location: value.selection, length: value.selectionLength)) }
        else { setSource("", selection: NSRange(location: 0, length: 0)); visualBaseline = nil }
        applying = false
        updateSurface(focus: focus)
    }
    func updateSurface(focus: Bool = false) {
        guard let owner else { return }
        host.isHidden = mode != .markdown; owner.composerScroll.isHidden = mode != .visual
        owner.composerFormatting.selectedMode = mode == .visual ? 0 : 1
        owner.composerFormatting.sourceAction = mode == .markdown ? { [weak self] in self?.format($0) } : nil
        configureSource(); owner.composerFormatting.updateSelection()
        if focus {
            owner.window?.makeFirstResponder(activeTextView)
            if mode == .visual { owner.composerScroll.contentView.scroll(to: visualOrigin) }
            else { textView?.enclosingScrollView?.contentView.scroll(to: sourceOrigin) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.configureSource()
                self.owner?.window?.makeFirstResponder(self.activeTextView)
            }
        }
        owner.updateComposerHeight()
    }
    func insertInlineDocument(_ document: RichDocument, replacing range: NSRange) throws {
        guard let text = activeTextView, text.isEditable, !text.hasMarkedText() else { return }
        guard document.canEdit, document.nodes.count == 1,
              case .element("p", let attributes, let children) = document.nodes[0], attributes.isEmpty else { throw RichTextError.unsafeEdit }
        if mode == .markdown {
            // The native adapter wraps inline insertions in a paragraph.
            // Keep only its contents when inserting into an existing source line.
            let fragment = RichTextCodec.html(RichDocument(nodes: children))
                .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
            text.insertText(fragment, replacementRange: range)
        }
        else { text.insertText(NativeRichText.attributedString(document: document, revealSpoilers: true), replacementRange: range) }
    }

    func format(_ command: ComposerFormattingBar.Command) {
        guard let text = textView, let owner else { return }
        do {
            try MarkdownSourceFormatting.apply(command: command, to: text)
            owner.composer.undoManager?.setActionName(command.title)
            owner.window?.makeFirstResponder(text)
        }
        catch { owner.status.stringValue = error.localizedDescription }
    }
}
