import AppKit
import RavenProtocol
import NevermoreCore

extension ConversationWindow {
    @objc func forward(_ sender: Any?) {
        guard let session, let message = selectedMessage, let window else { return }
        let destinations = Array(rows.filter { !session.revokedChannels.contains($0.id) }.prefix(500))
        action {
            let choices = destinations.map { ChoiceSheet.Choice(id: $0.id, title: $0.title, detail: $0.isDM ? "Direct message" : $0.workspace) }
            guard let picked = try await ChoiceSheet.choose(title: "Forward Message", prompt: "The server forwards the whole message batch, including any attachments, to the conversation you choose.", choices: choices, allowsMultiple: false, on: window),
                  let id = picked.first, let destination = destinations.first(where: { $0.id == id }), self.isCurrent(session) else { return }
            _ = try await session.mutate("raven.api.raven_message.forward_message", ["message_id": .string(message.id), "message_receivers": .array([.object(["type": .string("Channel"), "name": .string(destination.id)])])])
            try await session.load(channelID: destination.id)
        }
    }
    @objc func readers(_ sender: Any?) {
        guard let session, let message = selectedMessage else { return }
        action {
            let response = try await session.client.rpc("raven.api.raven_message.get_message_readers", arguments: ["message_id": .string(message.id)])
            guard self.isCurrent(session, channelID: message.channelID) else { return }
            let names = response.array.compactMap { reader -> String? in
                guard let id = reader["user"].string ?? reader["user_id"].string ?? reader["name"].string else { return nil }
                return reader["full_name"].string ?? session.userNames[id] ?? id
            }
            let detail = response.array.isEmpty ? "No readers reported." : names.count == response.array.count ? names.joined(separator: "\n") : self.summary(response)
            await SheetPrompt.inform("Who Has Read This?", message: detail + "\n\nReader lists reflect channel watermarks, not exact reading times.", on: self.window)
        }
    }
    @objc func copyMessageLink(_ sender: Any?) {
        guard let message = selectedMessage, let session else { return }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        guard let encoded = message.id.addingPercentEncoding(withAllowedCharacters: allowed), let link = URL(string: "/raven/message/" + encoded, relativeTo: session.account.origin)?.absoluteURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
    @objc func linkedDocument(_ sender: Any?) {
        guard let session, let message = selectedMessage, let doctype = message.raw["link_doctype"].string, let name = message.raw["link_document"].string else { return }
        action {
            let value = try await session.client.rpc("raven.api.document_link.get_preview_data", arguments: ["doctype": .string(doctype), "docname": .string(name)])
            guard self.isCurrent(session, channelID: message.channelID) else { return }
            guard value != .null else { throw AppError.message("This document is unavailable or you no longer have permission to preview it.") }
            let alert = NSAlert(); alert.messageText = "\(doctype) · \(name)"
            alert.informativeText = try value.object.keys.sorted().filter { !["preview_image", "raven_document_link"].contains($0) }.map { key in
                let raw = self.summary(value[key]); return "\(key): " + RichTextCodec.plainText(try RichTextCodec.parse(raw))
            }.joined(separator: "\n")
            alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Open in Browser"); alert.addButton(withTitle: "Workflow Actions…")
            let result = await SheetPrompt.run(alert, on: self.window)
            if result == .alertSecondButtonReturn, let link = value["raven_document_link"].string, let url = URL(string: link, relativeTo: session.account.origin)?.absoluteURL, ["https","http"].contains(url.scheme ?? ""), url.user == nil { NSWorkspace.shared.open(url) }
            if result == .alertThirdButtonReturn {
                let doc = try await session.client.resource(doctype, name: name, values: nil)
                guard self.isCurrent(session, channelID: message.channelID) else { return }
                let serialized = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
                let transitions = try await session.client.rpc("frappe.model.workflow.get_transitions", arguments: ["doc": .string(serialized)])
                guard self.isCurrent(session, channelID: message.channelID) else { return }
                guard let index = await self.choose("Server Workflow Actions", items: transitions.array.map { $0["action"].string ?? "Action" }, confirm: "Continue"), let selected = transitions.array[index]["action"].string, self.isCurrent(session, channelID: message.channelID) else { return }
                let confirmed = await SheetPrompt.confirm("Apply \(selected) to \(doctype) \(name)?", message: "This changes the server document and may trigger consequential business actions. An uncertain result must be checked on the server before repeating.", confirm: "Apply Action", on: self.window)
                if confirmed, self.isCurrent(session, channelID: message.channelID) { _ = try await session.mutate("frappe.model.workflow.apply_workflow", ["doc": .string(serialized), "action": .string(selected)]) }
            }
        }
    }
    @objc func inbox() { showCollection(title: "Inbox", method: "raven.api.notifications.get_notifications", kind: .inbox) }
    @objc func threads() { showCollection(title: "Threads", method: "raven.api.threads.get_all_threads", kind: .threads) }
    @objc func showSavedMessages(_ sender: Any?) { showCollection(title: "Saved Messages", method: "raven.api.raven_message.get_saved_messages", kind: .saved) }
    @objc func showReminders(_ sender: Any?) { showCollection(title: "Reminders", method: "raven.api.reminders.get_reminders", kind: .reminders) }
    @objc func showScheduledMessages(_ sender: Any?) { showCollection(title: "Scheduled Messages", method: "raven.api.scheduled_message.get_scheduled_messages", kind: .scheduled) }
    func showCollection(title: String, method: String, kind: CollectionWindow.Kind) {
        guard let session else { return }
        // One window per collection: a second request brings it forward and
        // refreshes it, as Mail does with its auxiliary windows.
        if let existing = collectionWindows.first(where: { $0.kind == kind && $0.source?.method == method && !$0.isClosed }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); existing.refresh()
            return
        }
        // The local demo has no server; show the empty window it would fill.
        if session.demo {
            let list = CollectionWindow(owner: self, title: title, records: [], kind: kind)
            list.emptyMessage = "The local demo has no server collections."
            collectionWindows.append(list); list.showWindow(nil); list.updateChrome()
            return
        }
        action {
            let strategy: CollectionSource.Strategy = kind == .threads ? .offset(parameter: "start_after") : [.saved, .inbox].contains(kind) ? .offset(parameter: "start") : .none
            let source = CollectionSource(method: method, strategy: strategy)
            let response = try await session.client.rpc(method, arguments: source.supportsPaging ? CollectionPaging.pageArguments(source) : [:])
            let rows = response.array.isEmpty ? response["messages"].array : response.array
            if session.retainHistory { try? await session.store.cacheProjection(key: source.cacheKey, value: response) }
            guard self.isCurrent(session) else { return }
            let list = CollectionWindow(owner: self, title: title, records: rows, kind: kind, source: source)
            self.collectionWindows.append(list); list.showWindow(nil)
        }
    }
    @objc func outbox() {
        // One Outbox per account, shared by all of its windows, so a send
        // cannot be retried or cancelled from two tables at once.
        if let existing = app.windows.compactMap(\.outboxWindow).first(where: { !$0.isClosed && $0.session === session }) { existing.showWindow(nil); existing.reload(); return }
        guard let controller = OutboxWindow(owner: self) else { return }
        controller.didClose = { [weak self, weak controller] in if self?.outboxWindow === controller { self?.outboxWindow = nil } }
        outboxWindow = controller
        controller.showWindow(nil)
    }
    func pickDate(_ title: String, confirm: String = "Create", on parent: NSWindow? = nil) async -> Date? {
        let zone = session?.account.timezone ?? "UTC"
        return await SheetPrompt.date(title, message: "Site timezone: \(zone). Scheduled messages use five-minute slots; the accepted server time is authoritative.", timeZone: TimeZone(identifier: zone) ?? .gmt, confirm: confirm, on: parent ?? window)
    }
    func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: session?.account.timezone ?? "UTC") ?? .gmt; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; return formatter.string(from: date)
    }
    func scheduledTimestamp(_ selection: Date) throws -> String {
        let zone = TimeZone(identifier: session?.account.timezone ?? "UTC") ?? .gmt
        guard let slot = ScheduledMessagePolicy.slot(for: selection, in: zone) else {
            throw AppError.message("Choose a scheduled time in the future.")
        }
        return timestamp(slot)
    }
    @objc func remind(_ sender: Any?) {
        guard let session, let message = selectedMessage else { return }
        action {
            guard let date = await self.pickDate("Remind Me About This Message", confirm: "Remind Me"), self.isCurrent(session) else { return }
            _ = try await session.mutate("raven.api.reminders.create_reminder", ["message_id": .string(message.id), "remind_at": .string(self.timestamp(date))]); self.status.stringValue = "Reminder accepted by the server"
        }
    }
    @objc func schedule(_ sender: Any?) {
        guard let session, let channel, attachments.isEmpty, !activeComposer.string.isEmpty else { return }
        // The draft is shared with other windows on this conversation; it is
        // fixed before the date sheet and must be unchanged when it closes.
        let draft: Draft
        if inlineComposer.mode == .visual { composer.flushPendingShortcut(); composer.linkAllAddresses() }
        do {
            draft = try currentDraft()
            guard try ConversationWindow.hasText(draft) else { status.stringValue = "Write a message before scheduling it."; return }
        } catch { status.stringValue = error.localizedDescription; return }
        let draftRevision = session.draftRevisions[channel.id, default: 0]
        action {
            guard let date = await self.pickDate("Schedule Message", confirm: "Schedule"), self.isCurrent(session, channelID: channel.id) else { return }
            guard (try? self.currentDraft()) == draft, session.draftRevisions[channel.id, default: 0] == draftRevision else { throw AppError.message("The message changed while you chose a time. Nothing was scheduled; check the draft and schedule it again.") }
            let scheduledTime = try self.scheduledTimestamp(date)
            guard !session.readOnly, !session.demo else { throw AppError.message("This account is read only.") }
            let response: JSONValue
            do {
                response = try await session.mutate("raven.api.scheduled_message.create_scheduled_message", ["channel_id": .string(channel.id), "text": .string(draft.html), "scheduled_time": .string(scheduledTime)])
            } catch {
                // Creation is deliberately attempted once. An ambiguous answer
                // may already exist on the server, so review it there instead of
                // posting the same message a second time.
                if ScheduledMessagePolicy.completion(for: error) == .indeterminate, self.isCurrentAccount(session) {
                    self.status.stringValue = "The scheduled message result is uncertain. Check Go ▸ Scheduled Messages before scheduling it again."
                    return
                }
                throw error
            }
            // The server accepted the row even when the draft cannot be cleared
            // or this window now shows another conversation of the same account.
            // A different account owns the window, so it receives nothing.
            guard self.isCurrentAccount(session) else { return }
            var feedback = "Scheduled on server: \(response["scheduled_time"].string ?? scheduledTime). Manage it in Go ▸ Scheduled Messages."
            let visible = self.isCurrent(session, channelID: channel.id)
            let revisionUnchanged = session.draftRevisions[channel.id, default: 0] == draftRevision
            let draftUnchanged = visible && (try? self.currentDraft()) == draft
            switch ScheduledMessagePolicy.clearance(originatingConversationVisible: visible, revisionUnchanged: revisionUnchanged, draftUnchanged: draftUnchanged) {
            case .clear:
                do {
                    if try await session.clearScheduledDraft(draft, revision: draftRevision) {
                        session.sharedTextStorage[channel.id]?.setAttributedString(NSAttributedString(string: ""))
                        if self.isCurrent(session, channelID: channel.id) {
                            self.displayedHTML = ""
                            self.restoreDraft()
                        }
                    } else { feedback += " Your newer draft was preserved." }
                } catch {
                    feedback += " Your draft was kept because it could not be cleared: \(error.localizedDescription)"
                }
            case .newerRevision: feedback += " Your newer draft was preserved."
            case .changedDraft: feedback += " Your edited draft was preserved."
            case .differentContext: break
            }
            if self.isCurrentAccount(session) { self.status.stringValue = feedback }
        }
    }
    @objc func createPoll(_ sender: Any?) {
        guard let session, let channel, let parent = window, pollCreationTask == nil else { return }
        pollCreationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pollCreationTask = nil }
            var submitted = false
            do {
                guard let draft = try await PollEditorSheet.create(on: parent, timeZone: TimeZone(identifier: session.account.timezone) ?? .gmt), !Task.isCancelled, self.isCurrent(session, channelID: channel.id) else { return }
                try await session.requireWritableConversation(channel.id)
                guard !Task.isCancelled, self.isCurrent(session, channelID: channel.id) else { return }
                let arguments = try draft.arguments(channelID: channel.id, siteTimeZone: TimeZone(identifier: session.account.timezone) ?? .gmt)
                submitted = true
                _ = try await session.mutate("raven.api.raven_poll.create_poll", arguments)
                try await session.load(channelID: channel.id)
            } catch {
                guard !Task.isCancelled, self.isCurrent(session) else { return }
                if submitted { self.app.showError(AppError.message("The poll result is uncertain. Refresh the conversation and check for it before creating another poll.")) }
                else { self.app.showError(error) }
            }
        }
    }
    @objc func vote(_ sender: Any?) {
        guard let session, let message = selectedMessage, message.messageType == "Poll", isCurrent(session) else { return }
        showPoll(message)
    }
    @discardableResult func showPoll(_ message: RavenMessage) -> PollWindow {
        if pollWindows.count >= 4 { pollWindows.first?.close() }
        let controller = PollWindow(owner: self, message: message)
        pollWindows.append(controller)
        controller.didClose = { [weak self, weak controller] in self?.pollWindows.removeAll { $0 === controller } }
        controller.showWindow(nil)
        controller.refresh()
        return controller
    }
    func closePollWindows() { pollCreationTask?.cancel(); for controller in Array(pollWindows) { controller.close() }; pollWindows.removeAll() }
    /// Conversation ▸ Conversation Info: opens the conversation actions menu
    /// from its toolbar item, or beneath the window title when the item is
    /// hidden, so the same commands stay one click or keystroke away.
    @objc func showInfo(_ sender: Any?) {
        guard session != nil, channel != nil, let content = window?.contentView else { return }
        let menu = NSMenu(title: "Conversation"); populateConversationMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 260, y: content.bounds.maxY - content.safeAreaInsets.top - 4), in: content)
    }
    func populateConversationMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        if channel != nil { add("Channel Details", #selector(showChannelDetails(_:))) }
        add("Members…", #selector(showMembers(_:)))
        add("Pinned Messages", #selector(showPinnedMessages(_:)))
        add("Files", #selector(showChannelFiles(_:)))
        menu.addItem(.separator())
        add(channel.map { session?.favoriteIDs.contains($0.id) == true } == true ? "Remove from Favorites" : "Add to Favorites", #selector(toggleFavorite(_:)))
        add(channel?.raw["muted"].bool == true ? "Unmute Conversation" : "Mute Conversation", #selector(toggleChannelMute(_:)))
        add("Mark as Unread", #selector(markUnread(_:)))
        add("Copy Link to Conversation", #selector(copyConversationLink(_:)))
        menu.addItem(.separator())
        add("Join Channel", #selector(joinChannel(_:)))
        add("Add Members…", #selector(addChannelMember(_:)))
        add("Remove Member…", #selector(removeChannelMember(_:)))
        add(channel?.raw["is_archived"].bool == true ? "Unarchive Conversation…" : "Archive Conversation…", #selector(toggleChannelArchive(_:)))
        add("Leave Channel…", #selector(leaveChannel(_:)))
        menu.addItem(.separator())
        add("Open in New Window", #selector(openConversationWindow(_:)))
        add("Open in New Tab", #selector(openConversationTab(_:)))
    }
    /// Conversation Info ▸ Channel Details: the name, channel ID, type,
    /// workspace and description the session already has for this
    /// conversation. It is scoped to the open channel and performs no request.
    @objc func showChannelDetails(_ sender: Any?) {
        guard let session, let channel, let window, window.attachedSheet == nil else { return }
        let details = ChannelDetailsSheet(session: session, channel: channel)
        channelDetailsSheet = details
        details.onClose = { [weak self, weak details] in
            if self?.channelDetailsSheet === details { self?.channelDetailsSheet = nil }
        }
        details.present(on: window)
    }
    @objc func copyConversationLink(_ sender: Any?) { if let channel { copyChannelLink(channel) } }
    @objc func showMembers(_ sender: Any?) {
        guard memberRoster == nil, let session, let channel, let parent = window, parent.attachedSheet == nil else { return }
        action { [weak self] in
            guard let self else { return }
            let value = try await session.client.rpc("raven.api.raven_channel_member.get_channel_members", arguments: ["channel_id": .string(channel.id)])
            guard self.isCurrent(session, channelID: channel.id), self.memberRoster == nil, parent.attachedSheet == nil else { return }
            guard case .object = value else { throw AppError.message("The server returned an unsupported channel member contract.") }
            let roster = MemberRosterWindow(owner: self, session: session, channel: channel, response: value)
            self.presentMemberRoster(roster, on: parent)
        }
    }
    func presentMemberRoster(_ roster: MemberRosterWindow, on parent: NSWindow) {
        roster.onClose = { [weak self, weak roster] in if self?.memberRoster === roster { self?.memberRoster = nil } }
        roster.onMessage = { [weak self] userID in self?.openDirectMessage(with: userID) }
        memberRoster = roster
        roster.present(on: parent)
    }
    @objc func showPinnedMessages(_ sender: Any?) {
        guard let session, let channel else { return }
        action { let value = try await session.client.rpc("raven.api.raven_message.get_pinned_messages", arguments: ["channel_id": .string(channel.id)]); self.presentCollection(title: "Pinned Messages · \(channel.title)", records: value.array, kind: .messages, session: session) }
    }
    @objc func showChannelFiles(_ sender: Any?) {
        guard let session, let channel else { return }
        action { let value = try await session.client.rpc("raven.api.search.get_channel_files", arguments: ["channel_id": .string(channel.id), "limit": .number(100)]); self.presentCollection(title: "Files · \(channel.title)", records: value.array, kind: .messages, session: session) }
    }
    @objc func createChannel(_ sender: Any?) {
        guard let session else { return }
        let workspaces = Set(session.channels.filter { !$0.isDM }.map(\.workspace)).filter { !$0.isEmpty }.sorted()
        let current = channel?.workspace ?? ""
        action {
            var workspace = current
            if workspace.isEmpty {
                guard !workspaces.isEmpty else { throw AppError.message("This account has no workspace to create a channel in.") }
                if workspaces.count == 1 { workspace = workspaces[0] }
                else {
                    guard let index = await self.choose("Choose a Workspace", message: "The new channel belongs to this workspace.", items: workspaces, confirm: "Continue"), self.isCurrent(session) else { return }
                    workspace = workspaces[index]
                }
            }
            guard let rawName = await self.prompt("New Channel", message: workspace.isEmpty ? nil : "The channel is created in \(workspace).", placeholder: "Channel name", confirm: "Continue"), self.isCurrent(session) else { return }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            guard let type = await self.choose("Channel Visibility", message: "Open channels admit everyone in the workspace; public channels can be joined; private channels are invitation only.", items: ["Open", "Public", "Private"], confirm: "Create Channel"), self.isCurrent(session) else { return }
            _ = try await session.mutate("raven.api.raven_channel.create_channel", ["channel_name": .string(name), "channel_description": .string(""), "type": .string(["Open","Public","Private"][type]), "workspace": .string(workspace)]); try await session.refresh()
        }
    }
    @objc func leaveChannel(_ sender: Any?) {
        guard let session, let channel else { return }
        action {
            guard await SheetPrompt.confirm("Leave \(channel.title)?", message: "You stop receiving its messages. Rejoining may require an invitation.", confirm: "Leave", destructive: true, on: self.window) else { return }
            _ = try await session.mutate("raven.api.raven_channel.leave_channel", ["channel_id": .string(channel.id)]); try await session.refresh()
        }
    }
    @objc func setCustomStatus(_ sender: Any?) {
        guard let session else { return }
        action {
            guard let status = await self.prompt("Set Status", message: "Your status is visible to people on \(session.account.origin.host ?? "this site").", placeholder: "What’s happening?", value: session.directory[session.account.user]?["custom_status"].string ?? "", confirm: "Set Status"), self.isCurrent(session) else { return }
            _ = try await session.mutate("raven.api.raven_users.update_raven_user", ["custom_status": .string(status.trimmingCharacters(in: .whitespacesAndNewlines))])
        }
    }
    func presentCollection(title: String, records: [JSONValue], kind: CollectionWindow.Kind, session expected: AccountSession? = nil) { if let expected, !isCurrent(expected) { return }; let list = CollectionWindow(owner: self, title: title, records: records, kind: kind); collectionWindows.append(list); list.showWindow(nil) }
    @objc func code(_ sender: Any?) {
        guard composer.isEditable else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let range = composer.selectedRange()
        if range.length > 0 {
            let coded = NSMutableAttributedString(attributedString: composer.attributedString().attributedSubstring(from: range))
            coded.addAttribute(.font, value: font, range: NSRange(location: 0, length: coded.length))
            composer.replaceFormatting(range, with: coded)
            composer.undoManager?.setActionName("Code")
        }
        composer.typingAttributes[.font] = font
    }
    @objc func insertLink(_ sender: Any?) {
        if inlineComposer.mode == .markdown { inlineComposer.format(.link); return }
        guard composer.isEditable else { return }
        let range = composer.selectedRange()
        let channelID = channel?.id, editTarget = editing?.id
        let selectedText = (composer.string as NSString).substring(with: range)
        action {
            // The range belongs to this conversation's draft (or the message
            // being edited); drop the link if either changed meanwhile.
            guard let value = await self.prompt("Insert Link", placeholder: "https://…", confirm: "Insert"), self.composer.isEditable, self.channel?.id == channelID, self.editing?.id == editTarget, NSMaxRange(range) <= (self.composer.string as NSString).length, (self.composer.string as NSString).substring(with: range) == selectedText, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), ["https","http","mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, NSMaxRange(range) <= self.composer.string.utf16.count else { return }
            self.window?.makeFirstResponder(self.composer)
            if range.length == 0 { self.composer.insertText(NSAttributedString(string: url.absoluteString, attributes: [.link: url]), replacementRange: range) }
            else { self.composer.setLink(url, on: range) }
            self.composer.undoManager?.setActionName("Insert Link")
        }
    }
    @objc func mention(_ sender: Any?) {
        guard composer.isEditable, let session else { return }
        action {
            let users = try await session.client.rpc("raven.api.raven_users.get_list")
            guard self.isCurrent(session), self.composer.isEditable else { return }
            guard let i = await self.choose("Mention Person", items: users.array.map { $0["full_name"].string ?? $0["name"].string ?? "User" }, confirm: "Mention"), let id = users.array[i]["name"].string else { return }
            guard self.isCurrent(session), self.composer.isEditable else { return }
            let text = users.array[i]["full_name"].string ?? id
            let doc = try RichTextCodec.parse("<p><span data-type=\"userMention\" data-id=\"\(RichTextCodec.escape(id))\">@\(RichTextCodec.escape(text))</span> </p>")
            if self.inlineComposer.mode == .markdown { try self.inlineComposer.insertInlineDocument(doc, replacing: self.activeComposer.selectedRange()) }
            else { self.composer.insertText(NativeRichText.attributedString(document: doc), replacementRange: self.composer.selectedRange()) }
        }
    }
}
