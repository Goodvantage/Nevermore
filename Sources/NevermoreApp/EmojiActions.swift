import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum EmojiInsertion {
    static func context(_ source: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        source.filter { !$0.key.rawValue.hasPrefix("Nevermore.") || ["Nevermore.BlockKind", "Nevermore.ListType", "Nevermore.ListNumber", "Nevermore.MarkerLength", "Nevermore.Paragraph", "Nevermore.Spoiler", "Nevermore.SpoilerTint"].contains($0.key.rawValue) }
    }
    static func value(_ emoji: RavenCustomEmoji, context: [NSAttributedString.Key: Any]) throws -> NSAttributedString {
        guard NativeRichText.canAuthorSpoiler(context) else { throw RichTextError.unsafeEdit }
        let document = try RichTextCodec.parse("<p><img data-type=\"customEmoji\" src=\"\(RichTextCodec.escape(emoji.imagePath))\" alt=\"\(RichTextCodec.escape(EmojiPickerSheet.shortcode(emoji)))\"></p>")
        guard document.canEdit else { throw AppError.message("This emoji cannot be safely inserted. Choose another emoji.") }
        let source = NativeRichText.attributedString(document: document, revealSpoilers: true)
        let rendered = NSMutableAttributedString(attributedString: source)
        let semantic = NSAttributedString.Key("Nevermore.SemanticNode")
        // Keep the current paragraph's identity, rather than the standalone
        // render's identity, when inserting into a list item or quote.
        source.enumerateAttribute(semantic, in: NSRange(location: 0, length: source.length)) { marker, range, _ in
            var attributes = context; attributes[semantic] = marker
            rendered.setAttributes(attributes, range: range)
        }
        return rendered
    }
}

@MainActor extension ConversationWindow {
    /// Stops choosing an emoji: the picker sheet and the reaction row. A
    /// reaction that was already chosen is still sent; see `reactionSends`.
    func cancelEmojiPicker() { emojiSelectionTask?.cancel(); quickReactions.close() }

    @objc func insertCustomEmoji(_ sender: Any?) {
        guard let session, let channel, let parent = window, activeComposer.isEditable, !activeComposer.hasMarkedText(),
              inlineComposer.mode == .markdown || NativeRichText.canAuthorSpoiler(composer.typingAttributes), emojiSelectionTask == nil else { return }
        emojiSelectionTask = Task { [weak self] in
            guard let self else { return }; defer { self.emojiSelectionTask = nil }
            do {
                let result = try await EmojiPickerSheet.pick(on: parent, session: session, purpose: .compose, active: { [weak self] in self?.isCurrent(session, channelID: channel.id) == true && self?.activeComposer.isEditable == true })
                guard case .custom(let emoji) = result, !Task.isCancelled, self.isCurrent(session, channelID: channel.id), self.activeComposer.isEditable, !self.activeComposer.hasMarkedText() else { return }
                let typing = self.inlineComposer.mode == .markdown ? NativeRichText.plainTypingAttributes : EmojiInsertion.context(self.composer.typingAttributes)
                let rendered = try EmojiInsertion.value(emoji, context: typing)
                if self.inlineComposer.mode == .markdown {
                    try self.inlineComposer.insertInlineDocument(NativeRichText.document(from: rendered), replacing: self.activeComposer.selectedRange())
                } else { self.composer.insertText(rendered, replacementRange: self.composer.selectedRange()) }
                if self.inlineComposer.mode == .visual { self.composer.typingAttributes = typing }
                self.composer.undoManager?.setActionName("Insert Custom Emoji")
                self.focusComposer()
            } catch {
                if !Task.isCancelled, self.isCurrent(session, channelID: channel.id) { self.app.showError(error) }
            }
        }
    }
    /// Opens the one-click reaction row for `message`, anchored to the hover
    /// bar's React button over it. The full picker is the row's More Emoji….
    func showQuickReactions(for message: RavenMessage, focus: QuickReactionPopover.Focus) {
        guard let session, let range = messageRanges.first(where: { $0.1.id == message.id })?.0 else { return }
        // A message with a toggle in flight, an open picker or sheet, and a
        // read-only conversation cannot take a reaction now.
        guard reactionSends[message.id] == nil, emojiSelectionTask == nil, window?.attachedSheet == nil, canReact(in: message.channelID, session: session) else { NSSound.beep(); return }
        quickReactions.close()
        if !placeHoverBar(over: range) {
            // A keyboard-chosen message can be scrolled away; bring its top
            // into view below the toolbar.
            transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(minimumTranscriptOrigin, highlightRect(for: range).minY - transcriptScroll.contentInsets.top - 24)))
            transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
            guard placeHoverBar(over: range) else { return }
        }
        guard let button = hoverBar.reactButton else { return }
        hoveredMessageID = message.id
        session.quickReactionUsage.prefetch(for: session)
        // The row is built from what is known now and never reorders while
        // open, so a click always lands on the emoji that was under it.
        quickReactions.show(emoji: QuickReactions.slots(mostUsed: session.quickReactionUsage.mostUsed),
                            reacted: QuickReactions.reacted(by: session.account.user, in: message.raw["message_reactions"]),
                            messageID: message.id, relativeTo: button.convert(button.bounds, to: transcript), of: transcript, focus: focus)
    }
    /// Toggles one reaction chosen from the quick reaction row.
    func toggleQuickReaction(_ emoji: String, messageID: String) {
        guard let message = messageRanges.first(where: { $0.1.id == messageID })?.1 else { return }
        // The emoji travels from the row to its chip; the toggle is the same.
        stickers.toss(emoji, from: quickReactions.takeChoiceOrigin(), to: message)
    }
    /// Whether the current account may react in `channelID` right now.
    func canReact(in channelID: String, session: AccountSession) -> Bool {
        isCurrent(session, channelID: channelID) && !session.readOnly
            && !ChannelPolicy.isRevoked(channelID: channelID, revoked: session.revokedChannels, threadParents: session.threadParents)
            && !ChannelPolicy.isArchived(channelID: channelID, channels: session.channels, threadParents: session.threadParents)
    }
    /// The full reaction picker for the message at the caret.
    @objc func chooseReaction(_ sender: Any?) { guard let message = selectedMessage else { return }; chooseReaction(for: message) }
    func chooseReaction(for message: RavenMessage) {
        guard let session, let parent = window, emojiSelectionTask == nil, reactionSends[message.id] == nil else { return }
        let existing = message.raw["message_reactions"].nested.object.prefix(500).compactMap { id, value -> RavenCustomEmoji? in
            guard value["is_custom"].bool, let image = value["reaction"].string else { return nil }
            return try? RavenCustomEmoji(raw: .object(["name": .string(id), "emoji_name": .string(id), "image": .string(image), "keywords": .string("Used in this message")]), origin: session.account.origin)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        emojiSelectionTask = Task { [weak self] in
            guard let self else { return }; defer { self.emojiSelectionTask = nil }
            let result: EmojiSelection?
            do {
                result = try await EmojiPickerSheet.pick(on: parent, session: session, purpose: .reaction, existing: existing, active: { [weak self] in
                    self?.canReact(in: message.channelID, session: session) == true
                })
            } catch {
                if !Task.isCancelled, self.isCurrent(session, channelID: message.channelID) { self.app.showError(error) }
                return
            }
            guard let result else { return }
            self.beginReactionSend(result, to: message, session: session)
        }
    }
    /// Toggles one reaction from a chip or sticker through the same durable
    /// task as the picker. The callback reports server acceptance, not motion.
    func toggleReaction(_ selection: EmojiSelection, on message: RavenMessage, undoable: Bool = true, then completion: ((Bool) -> Void)? = nil) {
        guard let session, canReact(in: message.channelID, session: session) else { completion?(false); return }
        beginReactionSend(selection, to: message, session: session, undoable: undoable, then: completion)
    }
    /// Sends a chosen reaction in a task of its own, which nothing cancels:
    /// someone who reacts and moves straight on still means the reaction.
    private func beginReactionSend(_ selection: EmojiSelection, to message: RavenMessage, session: AccountSession, undoable: Bool = true, then completion: ((Bool) -> Void)? = nil) {
        // One toggle per message at a time: a second one would act on
        // reactions that the first is about to change.
        guard reactionSends[message.id] == nil else { NSSound.beep(); completion?(false); return }
        // The task holds its window on purpose: a window closed in the same
        // instant as the click has no other owner left, and a weak reference
        // would drop the reaction. Removing the entry ends the hold.
        reactionSends[message.id] = Task {
            defer { self.reactionSends[message.id] = nil }
            let accepted = await self.sendReaction(selection, to: message, session: session, undoable: undoable)
            completion?(accepted)
        }
    }
    /// True when the server accepted the toggle.
    @discardableResult private func sendReaction(_ selection: EmojiSelection, to message: RavenMessage, session: AccountSession, undoable: Bool = true) async -> Bool {
        var attempted = false, accepted = false
        // Adding a Unicode reaction can be taken back with Undo.
        var added: String?
        if undoable, case .unicode(let value) = selection, !QuickReactions.reacted(by: session.account.user, in: message.raw["message_reactions"]).contains(value) { added = value }
        defer { if accepted, let added, isCurrent(session, channelID: message.channelID) { stickers.registerUndo(added, on: message) } }
        do {
            if let wire = session.demoWire {
                // The interactive demo keeps reactions on this Mac.
                guard case .unicode(let value) = selection else { throw AppError.message("The demo has no custom emoji to react with.") }
                attempted = true
                try await wire.toggleReaction(value, on: message.id, in: message.channelID, by: session.account.user)
                accepted = true
                session.recordAcceptedReaction()
                return true
            }
            try await session.requireWritableConversation(message.channelID)
            var arguments: [String: JSONValue] = ["message_id": .string(message.id)]
            switch selection {
            case .unicode(let value): arguments["reaction"] = .string(value); arguments["is_custom"] = .bool(false)
            case .custom(let emoji): arguments["reaction"] = .string(emoji.imagePath); arguments["is_custom"] = .bool(true); arguments["emoji_name"] = .string(emoji.id)
            }
            // Raven toggles the current user's reaction. An uncertain POST
            // must be checked, never automatically replayed.
            attempted = true
            _ = try await session.mutate("raven.api.reactions.react", arguments)
            accepted = true
            session.recordAcceptedReaction()
            // Toggles on other messages run alongside this one. An answer
            // asked for before one of them was accepted lacks its result
            // and can still arrive last, so ask again until an answer
            // covers every toggle accepted so far.
            var covered: Int
            repeat {
                // After the user has moved on there is no transcript here to
                // refresh; the conversation reloads when it is shown again.
                guard isCurrent(session, channelID: message.channelID) else { return accepted }
                covered = session.reactionsAccepted
                try await session.load(channelID: message.channelID)
            } while covered != session.reactionsAccepted
        } catch {
            // An alert about a conversation the user has left would arrive
            // out of context. That conversation reloads from the server
            // when shown again, so there is no stale state to warn about.
            guard isCurrent(session, channelID: message.channelID) else { return accepted }
            if accepted { app.showError(AppError.message("Your reaction was accepted, but the conversation could not be refreshed. Refresh it to see the result.")) }
            else if attempted { app.showError(AppError.message("The reaction result is uncertain. Refresh and check your reaction before trying again.")) }
            else { app.showError(error) }
        }
        return accepted
    }
}
