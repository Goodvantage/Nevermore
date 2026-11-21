import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum CodeReadingSelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, let channel = owner.channel else { return [("code-reader fixture has an account", false)] }
        var results: [(String, Bool)] = []
        let code = "\n  " + String(repeating: "long_identifier_", count: 100) + " END\n" + (0..<20).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let html = "<p>Before code</p><pre><code class=\"language-swift\">\(RichTextCodec.escape(code))</code></pre><p><span data-spoiler=\"true\">hiddenClipboardFixture</span> After code</p>"
        let message = RavenMessage(raw: .object(["name": .string("code-reader-fixture"), "channel_id": .string(channel.id), "owner": .string("fixture@example.com"), "creation": .string("2026-11-07 15:00:00.000001"), "message_type": .string("Text"), "text": .string(html)]))
        let document = try RichTextCodec.parse(html)
        let reading = NativeRichText.readingString(document: document)
        var hasPrivateMetadata = false
        reading.enumerateAttributes(in: NSRange(location: 0, length: reading.length)) { attributes, _, _ in
            if attributes.keys.contains(where: { $0.rawValue.hasPrefix("Nevermore.") }) { hasPrivateMetadata = true }
        }
        let rtf = try reading.data(from: NSRange(location: 0, length: reading.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        results.append(("reading/copying strips editor metadata and hidden spoiler content", !hasPrivateMetadata && !reading.string.contains("hiddenClipboardFixture") && !String(decoding: rtf, as: UTF8.self).contains("hiddenClipboardFixture")))
        let blockSpoiler = try RichTextCodec.parse("<p data-spoiler=\"true\">hiddenBlockFixture</p>")
        results.append(("spoilers on block elements remain masked in native reading", !NativeRichText.readingString(document: blockSpoiler).string.contains("hiddenBlockFixture")))
        let unsupportedSpoiler = try RichTextCodec.parse("<div data-spoiler=\"true\">hiddenUnsupportedFixture</div>")
        let unsupportedReading = NativeRichText.readingString(document: unsupportedSpoiler).string, unsupportedEditing = NativeRichText.attributedString(document: unsupportedSpoiler).string
        results.append(("spoilers on unsupported tags remain masked in native reading and rendering", !unsupportedReading.contains("hiddenUnsupportedFixture") && unsupportedReading.contains("[Spoiler]") && !unsupportedEditing.contains("hiddenUnsupportedFixture")))
        let wrappedSpoiler = try RichTextCodec.parse("<pre><code data-spoiler>hiddenCodeWrapperFixture</code></pre>")
        let wrappedReading = NativeRichText.readingString(document: wrappedSpoiler)
        results.append(("code-wrapper spoilers stay masked before native rendering and copying", !wrappedSpoiler.canEdit && !wrappedReading.string.contains("hiddenCodeWrapperFixture") && wrappedReading.string.contains("[Spoiler]")))
        let unsafeEditor = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: blockSpoiler, revealSpoilers: true)); unsafeEditor.insert(NSAttributedString(string: "!"), at: 0)
        do { _ = try NativeRichText.document(from: unsafeEditor); results.append(("read-only spoiler combinations reject edited reconstruction", false)) }
        catch { results.append(("read-only spoiler combinations reject edited reconstruction", true)) }
        let tableStyle = NSMutableParagraphStyle()
        tableStyle.textBlocks = [NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)]
        let pastedTable = NSAttributedString(string: "native table cell", attributes: [.paragraphStyle: tableStyle])
        do { _ = try NativeRichText.document(from: pastedTable); results.append(("unsupported native RTF tables cannot silently flatten on send", false)) }
        catch { results.append(("unsupported native RTF tables cannot silently flatten on send", true)) }
        let block = CodeBlocks.extract(from: document)[0]
        let reference = CodeReference(messageID: message.id, channelID: channel.id, block: block)
        let collapsed = CodePresentation.render(document, message: message, fontSize: 14, expanded: [])
        let expanded = CodePresentation.render(document, message: message, fontSize: 14, expanded: [reference.key])
        results.append(("long-code collapse is explicit and expansion preserves exact text", collapsed.text.string.contains("Code collapsed") && !collapsed.text.string.contains("long_identifier_") && expanded.text.string.contains(code) && expanded.text.string.contains("Before code") && expanded.text.string.contains("After code")))
        try await session.store.cacheMessages([message]); owner.render(); await owner.renderTask?.value
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let selectionView = TranscriptView()
        selectionView.textStorage?.setAttributedString(expanded.text); selectionView.selectAll(nil)
        pasteboard.clearContents()
        let wrotePlain = selectionView.writeSelection(to: pasteboard, type: .string)
        let wroteRich = selectionView.writeSelection(to: pasteboard, type: .rtf)
        let selectedText = pasteboard.string(forType: .string) ?? ""
        let selectedRTF = pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self) } ?? ""
        results.append(("native transcript Copy preserves code without copying presentation controls", wrotePlain && wroteRich && selectedText.contains(code) && !selectedText.contains("Open Reader") && !selectedText.contains("Copy Code") && !selectedRTF.contains("nevermore-code:") && !selectedRTF.contains("hiddenClipboardFixture")))
        owner.copyFullTranscript(to: pasteboard)
        results.append(("Copy Transcript includes full collapsed code and keeps spoilers masked", pasteboard.string(forType: .string)?.contains(code.trimmingCharacters(in: .newlines)) == true && pasteboard.string(forType: .string)?.contains("hiddenClipboardFixture") == false))
        owner.executeCode(CodeCommand(reference: reference, action: .copy), pasteboard: pasteboard)
        results.append(("Copy Code preserves leading and trailing whitespace", pasteboard.string(forType: .string) == code))
        owner.executeCode(CodeCommand(reference: reference, action: .open))
        if let reader = owner.codeReaders[reference.key] {
            await reader.waitUntilValidated(); reader.window?.contentView?.layoutSubtreeIfNeeded()
            if let container = reader.text.textContainer { reader.text.layoutManager?.ensureLayout(for: container) }
            results.append(("code reader uses selectable native text with horizontal scrolling", !reader.text.isEditable && reader.text.isSelectable && reader.scroll.hasHorizontalScroller && reader.text.textContainer?.widthTracksTextView == false))
            let usedWidth = reader.text.layoutManager.flatMap { layout in reader.text.textContainer.map { layout.usedRect(for: $0).width } } ?? 0
            reader.scroll.contentView.scroll(to: NSPoint(x: 200, y: 0)); reader.scroll.reflectScrolledClipView(reader.scroll.contentView)
            results.append(("long code can actually scroll horizontally beyond the viewport", usedWidth > reader.scroll.contentSize.width && reader.text.frame.width >= usedWidth && reader.scroll.contentView.bounds.minX > 0))
            reader.copy(to: pasteboard)
            results.append(("native code reader copies the entire original block", pasteboard.string(forType: .string) == code))
            reader.wrapping.state = .on; reader.changeWrapping()
            results.append(("code reader can opt into native line wrapping", reader.text.textContainer?.widthTracksTextView == true && !reader.scroll.hasHorizontalScroller))
            var raw = message.raw.object; raw["text"] = .string("<pre>edited code</pre>")
            try await session.store.cacheMessages([RavenMessage(raw: .object(raw))]); session.notify(); await reader.waitUntilValidated(); await owner.renderTask?.value
            results.append(("canonical message edits close stale code readers and clear private text", reader.reference == nil && reader.text.string.isEmpty && owner.codeReaders[reference.key] == nil))
            pasteboard.clearContents(); pasteboard.setString("unchanged sentinel", forType: .string)
            owner.executeCode(CodeCommand(reference: reference, action: .copy), pasteboard: pasteboard)
            results.append(("stale code links cannot copy an earlier message version", pasteboard.string(forType: .string) == "unchanged sentinel"))
        } else { results.append(("native code reader opens", false)) }
        // The in-memory history window can hold more messages than the disk cache.
        let historyChannel = "code-reader-history"
        var oldFields = message.raw.object; oldFields["channel_id"] = .string(historyChannel)
        let old = RavenMessage(raw: .object(oldFields))
        let newer = (0..<1_000).map { index in
            RavenMessage(raw: .object(["name": .string("newer-\(index)"), "channel_id": .string(historyChannel),
                                      "creation": .string("2026-11-08 15:00:00.000001")]))
        }
        session.memoryMessages[historyChannel] = [old] + newer
        let oldReader = CodeReaderWindow(session: session, reference: CodeReference(messageID: old.id, channelID: historyChannel, block: block))
        defer { oldReader.close(); session.memoryMessages.removeValue(forKey: historyChannel) }
        oldReader.validate()
        await oldReader.waitUntilValidated()
        results.append(("Code Reader keeps a cached message older than the latest 1,000", oldReader.reference != nil && oldReader.text.string == code))
        session.memoryMessages[historyChannel] = newer
        oldReader.validate()
        await oldReader.waitUntilValidated()
        results.append(("Code Reader clears a message once it is actually evicted", oldReader.reference == nil && oldReader.text.string.isEmpty))

        // Separate thread rooms must still inherit parent-channel authorization.
        let threadMessage = RavenMessage(raw: .object(["name": .string("thread-code-fixture"), "channel_id": .string("code-thread"), "owner": .string("fixture@example.com"), "creation": .string("2026-11-07 15:00:00.000002"), "text": .string("<pre>thread code</pre>")]))
        try await session.store.cacheMessages([threadMessage])
        let threadBlock = CodeBlocks.extract(from: try RichTextCodec.parse(threadMessage.html))[0]
        let threadReader = CodeReaderWindow(session: session, reference: CodeReference(messageID: threadMessage.id, channelID: threadMessage.channelID, block: threadBlock, parentChannelID: channel.id))
        session.revokedChannels.insert(channel.id); threadReader.validate()
        results.append(("code readers clear thread content when parent permission is revoked", threadReader.reference == nil && threadReader.text.string.isEmpty))
        session.revokedChannels.remove(channel.id)
        try await session.store.deleteMessages(ids: [message.id, threadMessage.id]); session.notify(); await owner.renderTask?.value
        return results
    }
}
