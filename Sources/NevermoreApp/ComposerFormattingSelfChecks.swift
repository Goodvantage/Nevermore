import AppKit
import NevermoreCore
import RavenProtocol

@MainActor private final class ComposerClipboardProbe: NSView, NSUserInterfaceValidations {
    var commands: [String] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func copy(_ sender: Any?) { commands.append("copy") }
    @objc func cut(_ sender: Any?) { commands.append("cut") }
    @objc func paste(_ sender: Any?) { commands.append("paste") }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool { item.action == #selector(copy(_:)) }
}

@MainActor extension SelfCheck {
    static func composerFormattingChecks(in conversation: ConversationWindow) async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func require<T>(_ value: T?) throws -> T {
            guard let value else { throw AppError.message("Missing \(T.self) in formatting fixture.") }
            return value
        }
        func check(_ title: String, _ passed: Bool) { checks.append((title, passed)) }
        func descendants<T: NSView>(_ view: NSView?, as type: T.Type) -> [T] {
            guard let view else { return [] }
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
        }
        func button(_ title: String, in window: NSWindow) -> NSButton? { descendants(window.contentView, as: NSButton.self).first { $0.title == title } }
        func waitForSheet(_ parent: NSWindow) async throws -> NSWindow {
            for _ in 0..<200 {
                if let sheet = parent.attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded(); return sheet }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The formatting fixture did not present its sheet.")
        }
        let previewDirectory = (ProcessInfo.processInfo.environment["NEVERMORE_FORMATTING_SNAPSHOTS"] == "1" || ProcessInfo.processInfo.arguments.contains("--composer-self-check"))
            ? FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreFormattingPreview-\(UUID().uuidString)", isDirectory: true) : nil
        func snapshot(_ view: NSView?, name: String) throws {
            guard let directory = previewDirectory, let view else { return }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name + ".png")
            try data.write(to: url, options: .atomic)
            print("FORMATTING SNAPSHOT \(url.path)")
        }
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 180, width: 720, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.title = "Formatting Fixture"; parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { ComposerEditorLifetime.cancel(attachedTo: parent); parent.orderOut(nil); parent.close(); conversation.window?.makeKeyAndOrderFront(nil) }
        do {
            let previewRow: JSONValue = .object(["title": .string("Example"), "description": .string("Summary"), "site_name": .string("Example"), "image": .string("http://127.0.0.1/image")])
            let preview = SentLinkPreviews.decode(raw: "https://example.com/", row: previewRow)
            let retryCache = SentLinkPreviews()
            let now = Date(timeIntervalSince1970: 1_000)
            check("first preview lookup is allowed", retryCache.claimLookup("https://example.com/", at: now))
            retryCache.ingest(.null)
            check("empty sidecars do not restart failed lookups", !retryCache.claimLookup("https://example.com/", at: now.addingTimeInterval(60)))
            retryCache.ingest(.object(["https://other.example/": previewRow]))
            check("unrelated sidecars do not restart failed lookups", !retryCache.claimLookup("https://example.com/", at: now.addingTimeInterval(120)))
            check("a later refresh can retry a previously unavailable preview", retryCache.claimLookup("https://example.com/", at: now.addingTimeInterval(300)))
            let fullCache = SentLinkPreviews()
            for index in 0..<500 { _ = fullCache.claimLookup("https://example.com/\(index)", at: now) }
            check("preview lookup budget stays bounded", !fullCache.claimLookup("https://new.example/", at: now))
            check("expired lookup budget makes room for new URLs", fullCache.claimLookup("https://new.example/", at: now.addingTimeInterval(300)))
            let evictionCache = SentLinkPreviews()
            for index in 0...500 {
                evictionCache.ingest(.object(["https://example.com/\(index)": previewRow]))
            }
            check("preview cache evicts the oldest entry", evictionCache.preview(for: "https://example.com/0") == nil && evictionCache.preview(for: "https://example.com/1") != nil && evictionCache.preview(for: "https://example.com/500") != nil)
            check("sent preview decodes text but rejects unsafe image addresses", preview?.title == "Example" && preview?.imageURL == nil)
            check("missing and invalid sent previews are ignored", SentLinkPreviews.decode(raw: "https://example.com/", row: .null) == nil && SentLinkPreviews.decode(raw: "javascript:alert(1)", row: previewRow) == nil)
            let linkedDocument = try RichTextCodec.parse(#"<p><a href="https://example.com/">Example</a> <span data-spoiler="true"><a href="https://hidden.example/">hidden</a></span></p>"#)
            check("sent preview extraction skips links concealed by spoilers", SentLinkPreviewPresentation.links(in: linkedDocument) == ["https://example.com/"])
            if let preview {
                let card = SentLinkPreviewPresentation.card(preview, image: nil, size: 14)
                check("sent preview card presents its title, summary and site", card.string.contains("Example") && card.string.contains("Summary") && card.string.contains("example.com"))
            }
            let original = try RichTextCodec.parse("<p>before</p><table><tr><td>cell</td></tr></table><p>after</p>")
            let value = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: original, revealSpoilers: true))
            let index = (value.string as NSString).range(of: "cell").location
            let table = try require(NativeRichText.tableSelection(in: value, selection: NSRange(location: index, length: 0)))
            check("tables remain round-trippable beside ordinary paragraphs", try NativeRichText.document(from: value).nodes == original.nodes)
            let styledTable = try RichTextCodec.parse(#"<table style="width: 80px"><colgroup><col style="width: 80px"></colgroup><tr><td colwidth="80" style="text-align: right"><p>aligned</p></td></tr></table>"#)
            let styled = NativeRichText.attributedString(document: styledTable)
            check("native table editing preserves Raven column metadata and cell alignment", try NativeRichText.document(from: styled).nodes == styledTable.nodes && (styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right)
            check("partial table deletion is rejected but whole-table deletion is allowed", !NativeRichText.allowsTableChange(in: value, range: NSRange(location: index, length: 1), replacingText: true) && NativeRichText.allowsTableChange(in: value, range: table.range, replacingText: true))
            value.insert(NSAttributedString(string: "!", attributes: NativeRichText.plainTypingAttributes), at: 0)
            check("typing outside a table preserves its complete structure", try RichTextCodec.html(NativeRichText.document(from: value)).contains("<table><tbody><tr><td>cell</td></tr></tbody></table>"))
            let editor = ComposerView(frame: NSRect(x: 0, y: 0, width: 500, height: 140))
            editor.isRichText = true; editor.allowsUndo = true; editor.sharedUndoManager = UndoManager()
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>highlight me</p>")))
            parent.contentView?.addSubview(editor); parent.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: 9)); editor.toggleHighlight(nil)
            try await finishInputEvent(editor)
            check("highlight control creates a Raven mark", try RichTextCodec.html(NativeRichText.document(from: editor.attributedString())).contains("<mark>highlight</mark>"))
            editor.undo(nil)
            check("highlight formatting has native undo", try !RichTextCodec.html(NativeRichText.document(from: editor.attributedString())).contains("<mark>"))
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse(#"<p><s>strike</s> <a href="https://example.com"><strong>link</strong></a></p>"#)))
            let bar = ComposerFormattingBar(composer: editor)
            editor.setSelectedRange(NSRange(location: 0, length: 6))
            check("overflow shows the selection's strikethrough", bar.formattingMenu().items.first(where: { $0.title == "Strikethrough" })?.state == .on)
            editor.setSelectedRange(NSRange(location: 0, length: 7))
            check("mixed selections do not show strikethrough as active", bar.formattingMenu().items.first(where: { $0.title == "Strikethrough" })?.state == .off)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            let selection = editor.selectedRange()
            editor.undoManager?.removeAllActions()
            editor.clearFormatting(nil)
            try await finishInputEvent(editor)
            let cleared = try RichTextCodec.html(NativeRichText.document(from: editor.attributedString()))
            check("clear formatting preserves links and selection while removing styling", cleared.contains(#"<a href="https://example.com">link</a>"#) && !cleared.contains("<s>") && !cleared.contains("<strong>") && editor.selectedRange() == selection)
            editor.undo(nil)
            let restored = try RichTextCodec.html(NativeRichText.document(from: editor.attributedString()))
            check("clear formatting can be undone", restored.contains("<s>strike</s>") && restored.contains("<strong>link</strong>"))
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            check("clear formatting is unavailable without a selection", !editor.canClearFormatting())
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: original))
            editor.setSelectedRange(NSRange(location: index + 1, length: 0)); let before = NSAttributedString(attributedString: editor.attributedString())
            editor.insertText("bad", replacementRange: editor.selectedRange())
            check("native typing cannot split an atomic table", editor.attributedString().isEqual(to: before))
            editor.textStorage?.setAttributedString(NSAttributedString(string: ""))
            editor.typingAttributes = NativeRichText.plainTypingAttributes
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.formatCodeBlock(nil)
            editor.insertText("typed code", replacementRange: editor.selectedRange())
            let codeHTML = try RichTextCodec.html(NativeRichText.document(from: editor.attributedString()))
            check("Code Block on an empty composer puts the next text in code without a placeholder", codeHTML == "<pre><code>typed code</code></pre>")
            for (label, html) in [
                ("Code Block preserves existing language and code whitespace", "<pre><code class=\"language-swift\">let x = 1\n\n</code></pre>"),
                ("Code Block cannot flatten a mention or reveal a spoiler", "<p><span data-spoiler=\"true\">secret</span> <span data-type=\"userMention\" data-id=\"alex\">Alex</span></p>")
            ] {
                let protected = NativeRichText.attributedString(document: try RichTextCodec.parse(html), revealSpoilers: true)
                editor.textStorage?.setAttributedString(protected); editor.selectAll(nil); editor.formatCodeBlock(nil)
                check(label, editor.attributedString().isEqual(to: protected))
            }
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>keep\n\n</p>")))
            editor.selectAll(nil); editor.formatCodeBlock(nil)
            check("Code Block retains literal trailing blank lines", try RichTextCodec.html(NativeRichText.document(from: editor.attributedString())).contains("<code>keep\n\n</code>"))
            try await finishInputEvent(editor)
            editor.textStorage?.setAttributedString(NSAttributedString(string: ""))
            editor.typingAttributes = NativeRichText.plainTypingAttributes
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.bulletedList(nil)
            editor.insertText("item", replacementRange: editor.selectedRange())
            check("list toolbar starts an empty composer in a list", try RichTextCodec.html(NativeRichText.document(from: editor.attributedString())).contains("<ul><li>item</li></ul>"))
            try await finishInputEvent(editor)
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>before</p>")))
            editor.typingAttributes = NativeRichText.plainTypingAttributes
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.editTable(nil)
            let inlineSheet = try await waitForSheet(parent)
            let inlineCell = try require(descendants(inlineSheet.contentView, as: ComposerView.self).first)
            inlineCell.insertText("inline cell", replacementRange: inlineCell.selectedRange())
            button("Use Table", in: inlineSheet)?.performClick(nil)
            try await Task.sleep(for: .milliseconds(50))
            check("table toolbar commits a complete native table to the composer", try RichTextCodec.html(NativeRichText.document(from: editor.attributedString())).contains("<th><p>inline cell</p></th>"))
            try await finishInputEvent(editor)
            editor.undo(nil)
            check("table insertion is one undoable draft edit", try RichTextCodec.html(NativeRichText.document(from: editor.attributedString())) == "<p>before</p>")
            let tableWithFollowingText = try RichTextCodec.parse("<table><tbody><tr><td><p>cell</p></td></tr></tbody></table><p>after</p>")
            let tableBaseline = NativeRichText.attributedString(document: tableWithFollowingText)
            editor.textStorage?.setAttributedString(tableBaseline)
            for pass in 1...2 {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.editTable(nil)
                let unchangedTableSheet = try await waitForSheet(parent)
                button("Use Table", in: unchangedTableSheet)?.performClick(nil)
                try await Task.sleep(for: .milliseconds(50))
                let editedTableHTML = try RichTextCodec.html(NativeRichText.document(from: editor.attributedString()))
                check("table edit \(pass) preserves following text without extra blank paragraphs", editor.string == tableBaseline.string && editedTableHTML == RichTextCodec.html(tableWithFollowingText))
            }
            editor.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>before</p>")))
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.editTable(nil)
            let staleSheet = try await waitForSheet(parent)
            let pendingCell = try require(descendants(staleSheet.contentView, as: ComposerView.self).first)
            pendingCell.insertText("pending cell", replacementRange: pendingCell.selectedRange())
            let pendingSnapshot = NSAttributedString(attributedString: pendingCell.attributedString())
            editor.insertText("peer update", replacementRange: editor.selectedRange())
            button("Use Table", in: staleSheet)?.performClick(nil)
            print("DIAGNOSTIC stale cell native string: \(String(reflecting: pendingCell.string))")
            let pendingHTML = try RichTextCodec.html(NativeRichText.document(from: pendingCell.attributedString()))
            check("stale table commits retain both the changed draft and pending cell edits", parent.attachedSheet === staleSheet && editor.string.contains("peer update") && pendingCell.attributedString().isEqual(to: pendingSnapshot) && pendingHTML == "<p>pending cell</p>")
            button("Cancel", in: staleSheet)?.performClick(nil)
            try await finishInputEvent(editor)
            editor.editTable(nil)
            let movedSheet = try await waitForSheet(parent)
            let movedCell = try require(descendants(movedSheet.contentView, as: ComposerView.self).first)
            movedCell.insertText("original conversation only", replacementRange: movedCell.selectedRange())
            let equalDraft = NSAttributedString(attributedString: editor.attributedString())
            editor.useTextStorage(NSTextStorage(attributedString: equalDraft))
            button("Use Table", in: movedSheet)?.performClick(nil)
            check("table edits cannot cross to another equal-content draft storage", parent.attachedSheet === movedSheet && editor.attributedString().isEqual(to: equalDraft))
            button("Cancel", in: movedSheet)?.performClick(nil)
            try await finishInputEvent(editor)
            editor.removeFromSuperview()

            let initial = try EditableRichTable.make(rows: 2, columns: 2)
            let tableTask = Task { await TableEditorSheet.edit(initial, on: parent) }
            let tableSheet = try await waitForSheet(parent)
            let cell = try require(descendants(tableSheet.contentView, as: ComposerView.self).first)
            cell.insertText("table value", replacementRange: NSRange(location: 0, length: cell.string.utf16.count))
            cell.selectAll(nil); cell.toggleBoldface(nil)
            button("Add Row", in: tableSheet)?.performClick(nil)
            try snapshot(tableSheet.contentView, name: "table-editor")
            button("Use Table", in: tableSheet)?.performClick(nil)
            let edited = await tableTask.value
            check("table sheet edits rich cell text and adds a row", edited?.layout.rows == 3 && edited?.layout.columns == 2 && edited.map { RichTextCodec.html(RichDocument(nodes: [$0.node])).contains("<strong>table value</strong>") } == true)
            var tableCommitsAfterCancel = 0
            let cancelTask = Task { await TableEditorSheet.edit(initial, on: parent, commit: { _ in tableCommitsAfterCancel += 1 }) }
            let cancelSheet = try await waitForSheet(parent)
            let cancelledTableSave = try require(button("Use Table", in: cancelSheet)), cancelledTableOwner = cancelSheet.delegate
            button("Add Column", in: cancelSheet)?.performClick(nil)
            button("Cancel", in: cancelSheet)?.performClick(nil)
            check("cancelled table edits leave the caller's table intact", await cancelTask.value == nil && initial.layout.columns == 2)
            _ = NSApp.sendAction(cancelledTableSave.action!, to: cancelledTableOwner, from: cancelledTableSave)
            check("a late table save action cannot commit after cancellation", tableCommitsAfterCancel == 0)

            let sourceTask = Task { try await MessageEditorSheet.edit(html: "<p><strong>bold</strong></p>", title: "Markdown Fixture", on: parent, mode: .markdown) }
            let sourceSheet = try await waitForSheet(parent)
            var source: NSTextView?
            for _ in 0..<200 {
                source = descendants(sourceSheet.contentView, as: NSTextView.self).first { !($0 is ComposerView) && $0.string == "**bold**" }
                if source != nil { break }; try await Task.sleep(for: .milliseconds(10))
            }
            let markdown = try require(source)
            check("Markdown mode hosts Top Drawer's native source editor", markdown.textLayoutManager != nil && markdown.string == "**bold**")
            let sourceController = try require(sourceSheet.delegate as? MessageEditorSheet)
            sourceSheet.makeFirstResponder(markdown)
            let clipboard = NSPasteboard(name: NSPasteboard.Name("Nevermore-source-fixture-\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            let literal = "  literal\n\n\n![image](https://example.invalid/image.png)  "
            clipboard.setString(literal, forType: .string)
            markdown.selectAll(nil)
            _ = sourceController.handleSourceClipboard(.paste, pasteboard: clipboard)
            check("source paste preserves whitespace and literal image syntax", markdown.string == literal)
            clipboard.clearContents(); clipboard.setData(Data([1, 2, 3]), forType: .png)
            _ = sourceController.handleSourceClipboard(.paste, pasteboard: clipboard)
            let sheetComposer = try require(descendants(sourceSheet.contentView, as: ComposerView.self).first)
            let explanation = descendants(sourceSheet.contentView, as: NSTextField.self).contains { $0.stringValue == ComposerView.editingAttachmentMessage }
            check("scheduled Markdown editing explains rejected attachments without changing text", explanation && markdown.string == literal)
            check("scheduled visual editing also rejects attachments", sheetComposer.pasteAttachments(from: clipboard))
            markdown.selectAll(nil)
            _ = sourceController.handleSourceClipboard(.copy, pasteboard: clipboard)
            check("source copy exports text only without an HTML image importer", clipboard.string(forType: .string) == literal && clipboard.types?.allSatisfy({ $0 == .string || $0.rawValue == "NSStringPboardType" }) == true && !markdown.isRichText && !markdown.importsGraphics)
            let sourceMore = try require(descendants(sourceSheet.contentView, as: ComposerFormattingBar.self).first).formattingMenu()
            let codeAction = try require(sourceMore.items.first { $0.title == "Inline Code" })
            let multiline = "first\n\nlast"
            markdown.insertText(multiline, replacementRange: NSRange(location: 0, length: markdown.string.utf16.count)); markdown.selectAll(nil)
            _ = NSApp.sendAction(codeAction.action!, to: codeAction.target, from: codeAction)
            let multilineCode = (try? RavenMarkdown.document(from: markdown.string)).map(RichTextCodec.html)
            check("source inline code preserves blank lines inside the code mark", multilineCode?.contains("<code>first\n\nlast</code>") == true)
            let spoilerAction = try require(sourceMore.items.first { $0.title == "Spoiler" })
            markdown.insertText(multiline, replacementRange: NSRange(location: 0, length: markdown.string.utf16.count)); markdown.selectAll(nil)
            _ = NSApp.sendAction(spoilerAction.action!, to: spoilerAction.target, from: spoilerAction)
            check("inline source formatting refuses a cross-paragraph spoiler without changing text", markdown.string == multiline)
            let replacement = "**edited**\n\n| A | B |\n| --- | --- |\n| C | D |"
            markdown.insertText(replacement, replacementRange: NSRange(location: 0, length: markdown.string.utf16.count))
            try await Task.sleep(for: .milliseconds(30))
            try snapshot(sourceSheet.contentView, name: "markdown-editor")
            let modes = try require(descendants(sourceSheet.contentView, as: NSSegmentedControl.self).first)
            modes.selectedSegment = 0; _ = NSApp.sendAction(modes.action!, to: modes.target, from: modes)
            let visual = try require(descendants(sourceSheet.contentView, as: ComposerView.self).first)
            check("source edits switch to visual text and a native table", modes.selectedSegment == 0 && visual.string.contains("edited") && NativeRichText.containsTables(visual.attributedString()))
            try snapshot(sourceSheet.contentView, name: "visual-editor")
            visual.setSelectedRange(NSRange(location: visual.string.utf16.count, length: 0))
            visual.insertText("visual addition", replacementRange: visual.selectedRange())
            modes.selectedSegment = 1; _ = NSApp.sendAction(modes.action!, to: modes.target, from: modes)
            try await Task.sleep(for: .milliseconds(50))
            check("switching back to Markdown retains visual edits", markdown.string.contains("visual addition"))
            markdown.insertText("\n\nsource tail", replacementRange: NSRange(location: markdown.string.utf16.count, length: 0))
            button("Use Text", in: sourceSheet)?.performClick(nil)
            let saved = try await sourceTask.value
            check("expanded editor exports formatted Raven HTML rather than Markdown", saved?.contains("<strong>edited</strong>") == true && saved?.contains("<table>") == true)
            check("visual edits after switching from Markdown are not mistaken for the baseline", saved?.contains("visual addition") == true && saved?.contains("source tail") == true)

            let invalidTask = Task { try await MessageEditorSheet.edit(html: "<p>keep</p>", title: "Invalid Source Fixture", on: parent, mode: .markdown, commit: { _ in throw AppError.message("Fixture draft conflict") }) }
            let invalidSheet = try await waitForSheet(parent)
            try await Task.sleep(for: .milliseconds(100))
            let invalidSource = try require(descendants(invalidSheet.contentView, as: NSTextView.self).first { !($0 is ComposerView) })
            invalidSource.insertText("# unsupported heading", replacementRange: NSRange(location: 0, length: invalidSource.string.utf16.count))
            let invalidModes = try require(descendants(invalidSheet.contentView, as: NSSegmentedControl.self).first)
            invalidModes.selectedSegment = 0; _ = NSApp.sendAction(invalidModes.action!, to: invalidModes.target, from: invalidModes)
            check("failed conversion leaves Markdown source intact", invalidModes.selectedSegment == 1 && invalidSource.string == "# unsupported heading")
            invalidSource.insertText("**recoverable**", replacementRange: NSRange(location: 0, length: invalidSource.string.utf16.count))
            button("Use Text", in: invalidSheet)?.performClick(nil)
            check("rejected source commits keep the editor open for recovery", parent.attachedSheet === invalidSheet && invalidSource.string == "**recoverable**")
            button("Cancel", in: invalidSheet)?.performClick(nil)
            check("cancelled source edits never replace the original draft", try await invalidTask.value == nil)
            var sourceCommitsAfterCancel = 0
            let privateTask = Task { try await MessageEditorSheet.edit(html: "<p>private draft</p>", title: "Privacy Fixture", on: parent, commit: { _ in sourceCommitsAfterCancel += 1 }) }
            let privateSheet = try await waitForSheet(parent)
            let cancelledSourceSave = try require(button("Use Text", in: privateSheet)), cancelledSourceOwner = privateSheet.delegate
            let nestedTask = Task { await TableEditorSheet.edit(initial, on: privateSheet) }
            _ = try await waitForSheet(privateSheet)
            ComposerEditorLifetime.cancel(attachedTo: parent)
            let nestedResult = await nestedTask.value, privateResult = try await privateTask.value
            check("account and window cleanup dismiss nested private editors", nestedResult == nil && privateResult == nil && parent.attachedSheet == nil)
            _ = NSApp.sendAction(cancelledSourceSave.action!, to: cancelledSourceOwner, from: cancelledSourceSave)
            check("a late source save action cannot commit after cancellation", sourceCommitsAfterCancel == 0)
            check("editor transactions release their quit protection", ComposerEditorLifetime.activeCount == 0)
            check("formatting toolbar is part of the inline composer", conversation.composerFormatting.isDescendant(of: conversation.composerGlass))
            conversation.window?.appearance = NSAppearance(named: .aqua)
            try snapshot(conversation.composerGlass, name: "inline-toolbar")
            let oldSize = conversation.window?.frame.size
            conversation.window?.setContentSize(NSSize(width: 660, height: 620))
            conversation.window?.contentView?.layoutSubtreeIfNeeded()
            try snapshot(conversation.composerGlass, name: "inline-narrow")
            conversation.window?.appearance = NSAppearance(named: .darkAqua)
            try snapshot(conversation.composerGlass, name: "inline-dark-narrow")
            if let oldSize, let window = conversation.window { window.setFrame(NSRect(origin: window.frame.origin, size: oldSize), display: true) }
            conversation.window?.contentView?.layoutSubtreeIfNeeded()
            try snapshot(conversation.composerGlass, name: "inline-dark-wide")
            conversation.window?.appearance = nil
            let draftBefore = NSAttributedString(attributedString: conversation.composer.attributedString())
            let draftSelection = conversation.composer.selectedRange(), draftTyping = conversation.composer.typingAttributes
            defer {
                ComposerEditorLifetime.cancel(attachedTo: conversation.window)
                conversation.composer.textStorage?.setAttributedString(draftBefore)
                conversation.composer.setSelectedRange(draftSelection); conversation.composer.typingAttributes = draftTyping
            }
            conversation.composer.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>original draft</p>")))
            conversation.window?.makeKeyAndOrderFront(nil)
            conversation.editMarkdown(nil)
            try await Task.sleep(for: .milliseconds(100))
            try snapshot(conversation.composerGlass, name: "inline-markdown")
            check("Markdown mode stays in the conversation", conversation.window?.attachedSheet == nil && conversation.inlineComposer.mode == .markdown)
            let inlineSource = try require(conversation.inlineComposer.textView)
            inlineSource.insertText("**inline source**", replacementRange: NSRange(location: 0, length: inlineSource.string.utf16.count))
            try await finishInputEvent(conversation.composer)
            conversation.inlineComposer.switchMode(.visual)
            try await finishInputEvent(conversation.composer)
            check("inline source converts to the visual composer", conversation.composer.string.contains("inline source") && conversation.window?.attachedSheet == nil)
            conversation.composer.undoManager?.undo()
            try await finishInputEvent(conversation.composer)
            check("undo restores the source mode and text", conversation.inlineComposer.mode == .markdown && conversation.inlineComposer.source == "**inline source**")
            conversation.composer.undoManager?.redo()
            try await finishInputEvent(conversation.composer)
            check("redo restores the visual mode", conversation.inlineComposer.mode == .visual && conversation.composer.string.contains("inline source"))
            conversation.editMarkdown(nil)
            inlineSource.insertText("# unsupported", replacementRange: NSRange(location: 0, length: inlineSource.string.utf16.count))
            try await finishInputEvent(conversation.composer)
            conversation.inlineComposer.switchMode(.visual)
            check("invalid inline source is retained", conversation.inlineComposer.mode == .markdown && inlineSource.string == "# unsupported" && conversation.window?.attachedSheet == nil)
            inlineSource.insertText("recovered", replacementRange: NSRange(location: 0, length: inlineSource.string.utf16.count))
            try await finishInputEvent(conversation.composer)
            conversation.inlineComposer.switchMode(.visual)
            check("correcting source permits conversion", conversation.inlineComposer.mode == .visual && conversation.composer.string.contains("recovered"))
            let clipboardProbe = ComposerClipboardProbe(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            parent.contentView?.addSubview(clipboardProbe); parent.makeKeyAndOrderFront(nil); parent.makeFirstResponder(clipboardProbe)
            ComposerClipboard.shared.copyText(nil); ComposerClipboard.shared.cutText(nil); ComposerClipboard.shared.pasteText(nil)
            let copyItem = NSMenuItem(title: "Copy", action: #selector(ComposerClipboard.copyText(_:)), keyEquivalent: "")
            check("clipboard commands outside source mode retain native routing and validation", clipboardProbe.commands == ["copy", "cut", "paste"] && ComposerClipboard.shared.validateMenuItem(copyItem))
            clipboardProbe.removeFromSuperview()

            let pending = ConversationWindow(app: conversation.app, session: nil, lastFrameAutosaveName: nil)
            let pendingWindow = try require(pending.window)
            pending.showWindow(nil)
            defer { ComposerEditorLifetime.cancel(attachedTo: pendingWindow); pending.close() }
            pending.composer.isEditable = true
            pending.composer.string = ""
            pending.composer.formatLink(nil)
            let committedLinkSheet = try await waitForSheet(pendingWindow)
            let committedLinkField = try require(descendants(committedLinkSheet.contentView, as: NSTextField.self).first { $0.isEditable })
            committedLinkField.stringValue = "https://example.test/inserted"
            button("Insert", in: committedLinkSheet)?.performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            check("committing an inline link releases editor quit protection", pending.composer.string == "https://example.test/inserted" && pendingWindow.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)
            pending.composer.formatLink(nil)
            let cancelledLinkSheet = try await waitForSheet(pendingWindow)
            button("Cancel", in: cancelledLinkSheet)?.performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            check("cancelling an inline link preserves the draft and releases quit protection", pending.composer.string == "https://example.test/inserted" && pendingWindow.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)

            pending.composer.isEditable = true
            pending.composer.string = "private draft before link cleanup"
            pending.composer.formatLink(nil)
            let linkSheet = try await waitForSheet(pendingWindow)
            let privateLinkField = try require(descendants(linkSheet.contentView, as: NSTextField.self).first { $0.isEditable })
            privateLinkField.stringValue = "https://private.example.test/path"
            pending.use(nil)
            try await Task.sleep(for: .milliseconds(100))
            check("account cleanup dismisses a private inline link editor", pendingWindow.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)
            if pendingWindow.attachedSheet === linkSheet {
                pendingWindow.endSheet(linkSheet, returnCode: .cancel); linkSheet.orderOut(nil)
            }
            try await Task.sleep(for: .milliseconds(20))

            pending.composer.isEditable = true
            pending.composer.string = "private draft before account cleanup"
            pending.editMarkdown(nil)
            pending.use(nil)
            try await Task.sleep(for: .milliseconds(100))
            check("account cleanup clears the inline source editor", pendingWindow.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)
            ComposerEditorLifetime.cancel(attachedTo: pendingWindow)
            try await Task.sleep(for: .milliseconds(20))

            pending.composer.isEditable = true
            pending.composer.string = "private draft before window closure"
            pending.editMarkdown(nil)
            pending.close()
            try await Task.sleep(for: .milliseconds(100))
            check("window closure clears the inline source editor", pendingWindow.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)
            ComposerEditorLifetime.cancel(attachedTo: pendingWindow)
            try await Task.sleep(for: .milliseconds(20))

            let pendingTable = ComposerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            parent.contentView?.addSubview(pendingTable)
            pendingTable.isEditable = true
            pendingTable.editTable(nil)
            pendingTable.useTextStorage(NSTextStorage())
            try await Task.sleep(for: .milliseconds(100))
            check("draft replacement prevents a queued table editor from opening", parent.attachedSheet == nil && ComposerEditorLifetime.activeCount == 0)
            ComposerEditorLifetime.cancel(attachedTo: parent)
            try await Task.sleep(for: .milliseconds(20))
            pendingTable.removeFromSuperview()
        } catch {
            checks.append(("formatting fixture: \(error.localizedDescription)", false))
            // Unblock any suspended sheet task before closing the fixture.
            if let sheet = parent.attachedSheet { button("Cancel", in: sheet)?.performClick(nil) }
        }
        return checks
    }
}
