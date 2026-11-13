import AppKit
import SwiftUI
import MarkdownEngine
import NevermoreCore

/// An isolated transaction. The caller only replaces its draft after Use/Save;
/// Cancel, conversion errors and stale-draft conflicts leave it untouched.
@MainActor final class MessageEditorSheet: NSObject, NSWindowDelegate, MarkdownClipboardOwner {
    enum Mode: Int { case visual, markdown }
    private let sheet: NSWindow
    private let composer = ComposerView()
    private let source = MarkdownEditorState()
    private let sourceHost: NSHostingView<MarkdownEditorSurface>
    private let visualScroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let modes = NSSegmentedControl(labels: ["Visual", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private var formatting: ComposerFormattingBar!
    private var mode = Mode.visual
    private var sourceBaseline = ""
    private var baselineDocument: RichDocument
    private var visualBaseline: NSAttributedString
    private var hasSource = false
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false
    private var commit: ((String) throws -> Void)?
    private var keyMonitor: Any?

    private init(document: RichDocument, title: String) {
        baselineDocument = document
        visualBaseline = NativeRichText.attributedString(document: document, revealSpoilers: true)
        sourceHost = NSHostingView(rootView: MarkdownEditorSurface(state: source))
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        source.owner = self
        sheet.title = title; sheet.delegate = self; sheet.isReleasedWhenClosed = false
        sheet.contentMinSize = NSSize(width: 500, height: 390)
        composer.isRichText = true; composer.importsGraphics = false
        composer.allowsUndo = true; composer.sharedUndoManager = UndoManager()
        composer.isAutomaticSpellingCorrectionEnabled = false; composer.isContinuousSpellCheckingEnabled = true
        composer.font = .systemFont(ofSize: 14); composer.textColor = .labelColor
        composer.textContainerInset = NSSize(width: 10, height: 10)
        composer.isVerticallyResizable = true; composer.autoresizingMask = .width
        composer.textContainer?.widthTracksTextView = true
        composer.alwaysInsertNewline = true
        composer.setAccessibilityLabel("Visual message editor")
        composer.textStorage?.setAttributedString(visualBaseline)
        visualScroll.documentView = composer; visualScroll.hasVerticalScroller = true; visualScroll.borderType = .bezelBorder
        formatting = ComposerFormattingBar(composer: composer)
        modes.target = self; modes.action = #selector(changeMode); modes.selectedSegment = mode.rawValue
        modes.setAccessibilityLabel("Editor mode")
        let header = NSStackView(views: [modes, NSView(), formatting]); header.spacing = 8
        sourceHost.isHidden = true
        sourceHost.setAccessibilityLabel("Markdown message source")
        let editors = NSView()
        for view in [visualScroll, sourceHost] {
            view.translatesAutoresizingMaskIntoConstraints = false; editors.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: editors.leadingAnchor), view.trailingAnchor.constraint(equalTo: editors.trailingAnchor), view.topAnchor.constraint(equalTo: editors.topAnchor), view.bottomAnchor.constraint(equalTo: editors.bottomAnchor)])
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        showHint()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Use Text", target: self, action: #selector(saveEdit))
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [NSView(), cancel, save]); buttons.spacing = 8
        let stack = NSStackView(views: [header, editors, status, buttons])
        stack.orientation = .vertical; stack.spacing = 8; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; sheet.contentView?.addSubview(stack)
        if let content = sheet.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
                header.widthAnchor.constraint(equalTo: stack.widthAnchor), editors.widthAnchor.constraint(equalTo: stack.widthAnchor),
                editors.heightAnchor.constraint(greaterThanOrEqualToConstant: 240), status.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        composer.onSend = { [weak self] in self?.saveEdit() }
        composer.onEscape = { [weak self] in self?.cancelEdit() }
        composer.onAttachmentRequest = { [weak self] in self?.show(AppError.message(ComposerView.editingAttachmentMessage)); return false }
        sheet.initialFirstResponder = composer
    }

    static func edit(html: String, title: String, on window: NSWindow, mode: Mode = .visual, commit: ((String) throws -> Void)? = nil) async throws -> String? {
        let document = try RichTextCodec.parse(html)
        guard document.canEdit else { throw RichTextError.unsafeEdit }
        let editor = MessageEditorSheet(document: document, title: title)
        editor.commit = commit
        if mode == .markdown { try editor.switchMode(to: mode) }
        ComposerEditorLifetime.register(editor.sheet) { [weak editor] in editor?.finish(nil) }
        return await withCheckedContinuation { continuation in
            editor.continuation = continuation
            window.beginSheet(editor.sheet) { _ in editor.finish(nil) }
            editor.installSourceKeys()
            DispatchQueue.main.async { [weak editor] in
                guard let editor, !editor.finished else { return }
                editor.sheet.makeFirstResponder(editor.mode == .visual ? editor.composer : editor.sourceTextView)
            }
        }
    }

    private func installSourceKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet, self.mode == .markdown,
                  let text = self.sourceTextView, self.sheet.firstResponder === text, !text.hasMarkedText() else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, event.keyCode == 36 { self.saveEdit(); return nil }
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k" {
                self.formatSource(.inlineCode); return nil
            }
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": _ = self.handleSourceClipboard(.copy); return nil
            case "x": _ = self.handleSourceClipboard(.cut); return nil
            case "v": _ = self.handleSourceClipboard(.paste); return nil
            default: break
            }
            let command: ComposerFormattingBar.Command?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": command = .bold
            case "i": command = .italic
            case "u": command = .underline
            default: command = nil
            }
            guard let command else { return event }
            self.formatSource(command); return nil
        }
    }

    private var sourceTextView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let text = find(sourceHost) else { return nil }
        text.isRichText = false; text.importsGraphics = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.unregisterDraggedTypes(); text.registerForDraggedTypes([.string])
        return text
    }

    func validateSourceClipboard(_ command: ComposerClipboard.Command) -> Bool? {
        guard mode == .markdown, let text = sourceTextView, sheet.firstResponder === text else { return nil }
        guard !text.hasMarkedText() else { return false }
        switch command {
        case .copy: return text.selectedRange().length > 0
        case .cut: return text.isEditable && text.selectedRange().length > 0
        case .paste, .pastePlain: return text.isEditable && (NSPasteboard.general.availableType(from: [.string]) != nil || ComposerView.hasAttachments(.general))
        }
    }

    @discardableResult
    func handleSourceClipboard(_ command: ComposerClipboard.Command, pasteboard: NSPasteboard = .general) -> Bool {
        guard mode == .markdown, let text = sourceTextView, sheet.firstResponder === text else { return false }
        guard !text.hasMarkedText() else { return true }
        let selected = text.selectedRange()
        guard selected.location != NSNotFound, NSMaxRange(selected) <= text.string.utf16.count else { return true }
        if command == .copy || command == .cut {
            guard selected.length > 0, command == .copy || text.isEditable else { return true }
            let raw = (text.string as NSString).substring(with: selected)
            pasteboard.clearContents(); pasteboard.setString(raw, forType: .string)
            if command == .copy { return true }
            text.breakUndoCoalescing(); text.insertText("", replacementRange: selected)
            text.undoManager?.setActionName("Cut"); text.breakUndoCoalescing()
            return true
        }
        guard text.isEditable else { return true }
        if composer.pasteAttachments(from: pasteboard) { return true }
        guard pasteboard.availableType(from: [.fileURL]) == nil, let raw = pasteboard.string(forType: .string) else {
            show(AppError.message("Paste Markdown as text. Attach files from the main composer.")); return true
        }
        guard raw.utf8.count <= RichTextCodec.maximumBytes,
              (text.string as NSString).replacingCharacters(in: selected, with: raw).utf8.count <= RichTextCodec.maximumBytes else { show(RichTextError.tooLarge); return true }
        text.breakUndoCoalescing(); text.insertText(raw, replacementRange: selected)
        text.undoManager?.setActionName("Paste"); text.breakUndoCoalescing()
        return true
    }

    private var sourceText: String { sourceTextView?.string ?? source.text }

    private func currentDocument() throws -> RichDocument {
        if mode == .visual { return try NativeRichText.document(from: composer.attributedString()) }
        return sourceText == sourceBaseline ? baselineDocument : try RavenMarkdown.document(from: sourceText)
    }

    private func switchMode(to next: Mode) throws {
        guard mode != next else { return }
        guard !composer.hasMarkedText(), sourceTextView?.hasMarkedText() != true else { throw AppError.message("Finish text composition before switching modes.") }
        composer.flushPendingShortcut()
        let document = try currentDocument()
        if next == .markdown {
            if !hasSource || !composer.attributedString().isEqual(to: visualBaseline) {
                source.text = try RavenMarkdown.source(from: document)
            }
            baselineDocument = document; sourceBaseline = source.text; hasSource = true
            source.documentID = UUID().uuidString
            formatting.sourceAction = { [weak self] command in self?.formatSource(command) }
        } else {
            source.text = sourceText
            baselineDocument = document; sourceBaseline = source.text
            composer.textStorage?.setAttributedString(NativeRichText.attributedString(document: document, revealSpoilers: true))
            composer.undoManager?.removeAllActions()
            composer.typingAttributes = NativeRichText.plainTypingAttributes
            visualBaseline = NSAttributedString(attributedString: composer.attributedString())
            formatting.sourceAction = nil
        }
        mode = next; modes.selectedSegment = next.rawValue
        visualScroll.isHidden = next != .visual; sourceHost.isHidden = next != .markdown
        sheet.makeFirstResponder(next == .visual ? composer : sourceTextView)
        showHint()
    }

    @objc private func changeMode() {
        guard let next = Mode(rawValue: modes.selectedSegment) else { return }
        do { try switchMode(to: next) }
        catch { modes.selectedSegment = mode.rawValue; show(error) }
    }

    private func formatSource(_ command: ComposerFormattingBar.Command) {
        guard let text = sourceTextView else { return }
        do { try MarkdownSourceFormatting.apply(command: command, to: text); sheet.makeFirstResponder(text); showHint() }
        catch { show(error) }
    }

    @objc private func saveEdit() {
        guard !finished else { return }
        guard sourceTextView?.hasMarkedText() != true, !composer.hasMarkedText() else { show(AppError.message("Finish text composition before saving.")); return }
        composer.flushPendingShortcut()
        if mode == .visual { composer.linkAllAddresses() }
        do {
            let document = try currentDocument()
            let html = RichTextCodec.html(document)
            guard document.canEdit, try RichTextCodec.parse(html).canEdit else { throw RichTextError.unsafeEdit }
            // Commit while this transaction is still open. A stale-draft
            // conflict leaves both versions available for copying/recovery.
            try commit?(html)
            finish(html)
        } catch { show(error) }
    }
    @objc private func cancelEdit() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func show(_ error: Error) { status.textColor = .systemRed; status.stringValue = error.localizedDescription }
    private func showHint() {
        status.textColor = .secondaryLabelColor
        status.stringValue = "Markdown keeps Raven-only formatting as HTML. Switching modes resets editor undo history. Cancel preserves your original text."
    }
    private func finish(_ result: String?) {
        guard !finished else { return }; finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        ComposerEditorLifetime.unregister(sheet)
        if let child = sheet.attachedSheet { sheet.endSheet(child, returnCode: .cancel); child.orderOut(nil) }
        sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil)
        continuation?.resume(returning: result); continuation = nil
    }
}
