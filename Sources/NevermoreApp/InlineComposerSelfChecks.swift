import AppKit
import NevermoreCore

@MainActor enum InlineComposerSelfChecks {
    static func run(in owner: ConversationWindow) async -> [(String, Bool)] {
        guard let session = owner.session, let channel = owner.channel else { return [("inline draft fixture has a conversation", false)] }
        var results: [(String, Bool)] = []
        let peer = ConversationWindow(app: owner.app, session: session, lastFrameAutosaveName: nil)
        owner.app.windows.append(peer)
        defer { peer.close() }
        do {
            let original = try await session.store.draft(channelID: channel.id)
            peer.select(channel); peer.showWindow(nil)
            await peer.loadTask?.value; await peer.renderTask?.value
            try await Task.sleep(for: .milliseconds(100))
            owner.window?.makeKeyAndOrderFront(nil)
            owner.inlineComposer.switchMode(.markdown)
            try await Task.sleep(for: .milliseconds(50))
            guard let source = owner.inlineComposer.textView else { return [("inline source is mounted", false)] }
            owner.focusComposer()
            source.insertText("**shared source**", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
            await owner.saveTask?.value
            try await Task.sleep(for: .milliseconds(50))
            results.append(("peer windows share inline Markdown and mode", peer.inlineComposer.mode == .markdown && peer.inlineComposer.source == source.string))
            if let peerSource = peer.inlineComposer.textView {
                peerSource.setMarkedText("composing", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
                let composition = peerSource.string
                source.insertText("peer update", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
                await owner.saveTask?.value
                try await Task.sleep(for: .milliseconds(50))
                results.append(("peer publication preserves active input composition", peerSource.hasMarkedText() && peerSource.string == composition))
                peerSource.unmarkText(); peer.persistActiveDraft()
                await peer.saveTask?.value
            }
            source.insertText("# unfinished heading", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
            await owner.saveTask?.value
            let saved = try await session.store.draft(channelID: channel.id)
            results.append(("invalid inline source is durably saved", saved?.editorState?.source == source.string && owner.draftEncodingFailure == nil))
            owner.send(nil); peer.send(nil)
            results.append(("both windows reject invalid source without opening a sheet", !owner.isAcceptingSend && !peer.isAcceptingSend && owner.window?.attachedSheet == nil && peer.window?.attachedSheet == nil))
            peer.inlineComposer.load(nil); peer.restoreDraft()
            try await Task.sleep(for: .milliseconds(100))
            results.append(("restoring a draft recovers invalid source in Markdown mode", peer.inlineComposer.mode == .markdown && peer.inlineComposer.source == "# unfinished heading"))
            let clipboard = NSPasteboard(name: NSPasteboard.Name("Nevermore-inline-source-\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            clipboard.setString("  literal\n\nsource  ", forType: .string)
            // Give Paste its own native event, as a menu or keyboard command
            // would. Earlier synthetic edits can share an open undo group.
            try await SelfCheck.finishInputEvent(owner.composer)
            source.selectAll(nil)
            _ = owner.handleSourceClipboard(.paste, pasteboard: clipboard)
            results.append(("inline clipboard preserves literal whitespace", source.string == "  literal\n\nsource  "))
            clipboard.clearContents(); clipboard.setData(Data([1, 2, 3]), forType: .png)
            let oldSource = source.string, oldAttachments = owner.attachments.count
            _ = owner.handleSourceClipboard(.paste, pasteboard: clipboard)
            await owner.waitForPromisedFiles(); await owner.saveTask?.value
            results.append(("inline Markdown image paste stages a file and preserves source", source.string == oldSource && owner.attachments.count == oldAttachments + 1))
            owner.clearAttachments(); await owner.saveTask?.value
            source.setSelectedRange(NSRange(location: 2, length: 0))
            var acknowledged = owner.inlineComposer.editorState; acknowledged.selection = 0
            owner.inlineComposer.load(acknowledged)
            results.append(("unchanged draft acknowledgements preserve the caret", source.selectedRange().location == 2))
            await owner.saveTask?.value
            try await SelfCheck.finishInputEvent(owner.composer)
            let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposerView.undo(_:)), keyEquivalent: "z")
            let undoTarget = NSApp.target(forAction: undoItem.action!, to: nil, from: undoItem)
            let undoEnabled = (undoTarget as? NSUserInterfaceValidations)?.validateUserInterfaceItem(undoItem)
                ?? (undoTarget as? NSMenuItemValidation)?.validateMenuItem(undoItem) ?? false
            results.append(("Edit menu enables Undo for source changes", undoEnabled))
            owner.composer.undoManager?.undo()
            results.append(("source paste participates in draft undo", owner.inlineComposer.source == "# unfinished heading"))
            owner.composer.undoManager?.redo()
            results.append(("source paste participates in draft redo", owner.inlineComposer.source == "  literal\n\nsource  "))
            await owner.saveTask?.value
            source.setMarkedText("composing", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
            owner.inlineComposer.switchMode(.visual)
            results.append(("mode conversion waits for source input composition", owner.inlineComposer.mode == .markdown && source.hasMarkedText()))
            source.unmarkText(); owner.persistActiveDraft()
            await owner.saveTask?.value
            source.insertText("before after", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
            let emoji = try RichTextCodec.parse("<p><img data-type=\"customEmoji\" src=\"/files/wave.png\" alt=\":wave:\"></p>")
            try owner.inlineComposer.insertInlineDocument(emoji, replacing: NSRange(location: 7, length: 0))
            let withEmoji = try owner.inlineComposer.currentDocument()
            results.append(("source emoji insertion keeps surrounding text in one paragraph", withEmoji.nodes.count == 1 && RichTextCodec.html(withEmoji).contains("customEmoji")))
            source.insertText("before after", replacementRange: NSRange(location: 0, length: source.string.utf16.count))
            let mention = try RichTextCodec.parse("<p><span data-type=\"userMention\" data-id=\"alex@example.com\">@Alex</span> </p>")
            try owner.inlineComposer.insertInlineDocument(mention, replacing: NSRange(location: 7, length: 0))
            let withMention = try owner.inlineComposer.currentDocument()
            results.append(("source menu mention insertion keeps surrounding text in one paragraph", withMention.nodes.count == 1 && RichTextCodec.html(withMention).contains("alex@example.com")))
            owner.composer.typingAttributes[NSAttributedString.Key("Nevermore.BlockKind")] = "pre"
            owner.insertCustomEmoji(nil)
            for _ in 0..<100 {
                if owner.window?.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            results.append(("source emoji picker ignores hidden visual code attributes", owner.window?.attachedSheet != nil))
            owner.cancelEmojiPicker(); await owner.emojiSelectionTask?.value
            owner.composer.typingAttributes = NativeRichText.plainTypingAttributes
            await owner.saveTask?.value
            let legacy = Draft(channelID: channel.id, html: "<p>legacy draft</p>")
            try await session.save(legacy)
            owner.inlineComposer.load(nil); owner.displayedHTML = ""; owner.restoreDraft()
            try await Task.sleep(for: .milliseconds(100))
            results.append(("legacy visual drafts need no edit before sending", try owner.currentDraft().editorState == nil && owner.currentDraft().html == legacy.html))
            try await session.save(original ?? Draft(channelID: channel.id))
            owner.restoreDraft()
        } catch { results.append(("inline draft fixture: \(error.localizedDescription)", false)) }
        return results
    }
}
