import AppKit
import NevermoreCore
import RavenProtocol

/// How the window enters, leaves and moves through search. The toolbar
/// field searches as you type; results replace the conversation pane and
/// take a place in Back and Forward, so ⌘[ returns to them.
extension ConversationWindow {
    /// Shows the results screen for `criteria`. `record` adds it to Back
    /// and Forward; restoring from there does not.
    func showSearch(_ criteria: SearchCriteria, record: Bool = true, immediately: Bool, origin: RavenChannel? = nil) {
        guard let session, !session.stopped else { return }
        let origin = origin ?? channel
        if channel != nil {
            if window?.isVisible == true { app.interfaceSounds.play(.selection) }
            leaveConversation()
        }
        if record { navigation.visitSearch(criteria) }
        isSearching = true
        if search.stringValue != criteria.query { search.stringValue = criteria.query }
        searchView.begin(criteria, origin: origin, immediately: immediately)
        refreshSidebar()
        updateWindowTitle(); updateContext(); updateAttachmentChips()
    }

    /// Esc: back to where the search began, or Home.
    func leaveSearch() {
        guard isSearching else { return }
        searchView.attachments.cancel()
        search.stringValue = ""
        if navigation.canGoBack, case .search = navigation.currentEntry, let entry = navigation.back() { restore(entry); return }
        showHome()
    }

    /// Keeps the Back entry for the results in step with the search.
    func recordSearch(_ criteria: SearchCriteria) {
        guard isSearching else { return }
        navigation.visitSearch(criteria)
    }

    func focusSearchField() {
        if window?.toolbar?.isVisible == false { window?.toolbar?.isVisible = true }
        window?.makeFirstResponder(search)
    }

    /// The search a new query starts from: refining the search that
    /// opened this conversation keeps its filters; otherwise an open
    /// conversation scopes the search to itself.
    private func searchStartingPoint() -> SearchCriteria {
        if isSearching { return searchView.criteria }
        if channel != nil, let previous = resultOfSearch { return previous }
        if let channel, !channel.raw["is_thread"].bool { return SearchCriteria(scope: .conversation(channel.id)) }
        if let parent = channel?.raw["parent_channel_id"].string { return SearchCriteria(scope: .conversation(parent)) }
        return SearchCriteria()
    }

    /// Typing in the toolbar field: search after a pause.
    func searchFieldChanged() {
        let text = search.stringValue
        if isSearching { searchView.queryChanged(text, immediately: false); return }
        guard SearchCriteria(query: text).query.count >= 2 else { return }
        var criteria = searchStartingPoint()
        criteria.query = SearchCriteria(query: text).query
        showSearch(criteria, immediately: false)
    }

    /// Return in the toolbar field: search now.
    @objc func performSearch() {
        guard session != nil else { return }
        let text = search.stringValue
        if isSearching { searchView.searchNow(text); return }
        guard !SearchCriteria(query: text).query.isEmpty else { return }
        var criteria = searchStartingPoint()
        criteria.query = SearchCriteria(query: text).query
        showSearch(criteria, immediately: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === search else { return }
        searchFieldChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            return isSearching && searchView.table.focusFirstResult()
        case #selector(NSResponder.cancelOperation(_:)):
            guard isSearching else {
                // Esc outside search clears the field and leaves it, as
                // the stock toolbar search item did.
                search.stringValue = ""; window?.makeFirstResponder(nil)
                return true
            }
            leaveSearch(); window?.makeFirstResponder(sidebar)
            return true
        default:
            return false
        }
    }

    /// Search This Account… (⇧⌘F).
    @objc func searchAccount(_ sender: Any?) {
        var criteria = isSearching ? searchView.criteria : SearchCriteria(query: search.stringValue)
        criteria.scope = .account
        showSearch(criteria, immediately: true)
        focusSearchField()
    }

    /// Search with Filters…: the results screen for this conversation,
    /// with keyboard focus on the field.
    @objc func advancedSearch(_ sender: Any?) {
        if !isSearching { showSearch(searchStartingPoint(), immediately: true) }
        focusSearchField()
    }

    /// Opens a result here; ⌘[ comes back to the results.
    func openSearchResult(channelID: String?, messageID: String?, parentID: String?) {
        openingSearchResult = true
        defer { openingSearchResult = false }
        resultOfSearch = searchView.criteria
        searchView.attachments.cancel()
        openMessage(channelID: channelID, messageID: messageID, parentID: parentID)
    }

    /// Opens, or starts, the direct message with `user`.
    func openDirectMessage(with user: String) {
        guard let session else { return }
        if let existing = session.channels.first(where: { $0.isDM && $0.raw["peer_user_id"].string == user }) {
            openSearchResult(channelID: existing.id, messageID: nil, parentID: nil)
            return
        }
        guard !session.demo else { return }
        action {
            let response = try await session.mutate("raven.api.raven_channel.create_direct_message_channel", ["user_id": .string(user)])
            try await session.refresh()
            guard self.isCurrent(session) else { return }
            guard let id = response.string ?? response["name"].string, session.channels.contains(where: { $0.id == id }) else { throw AppError.message("The server did not return an accessible direct message.") }
            self.openSearchResult(channelID: id, messageID: nil, parentID: nil)
        }
    }

    /// Picks a conversation or person for a filter.
    func chooseSearchTarget(kind: MentionCandidate.Kind, completion: @escaping (MentionCandidate) -> Void) {
        guard let session, let window else { return }
        conversationChooser?.cancel()
        let chooser = ConversationChooser(session: session, only: kind)
        conversationChooser = chooser
        chooser.onClose = { [weak self] in self?.conversationChooser = nil }
        chooser.onPick = { [weak self] candidate, _ in
            guard let self, self.isCurrent(session) else { return }
            completion(candidate)
        }
        chooser.present(on: window)
    }

    func copySearchResultLink(messageID: String) {
        guard let session else { return }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        guard let encoded = messageID.addingPercentEncoding(withAllowedCharacters: allowed), let link = URL(string: "/raven/message/" + encoded, relativeTo: session.account.origin)?.absoluteURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    @objc func saveSearch(_ sender: Any?) {
        guard isSearching else { return }
        searchView.saveCurrentSearch()
    }

    /// Find ▸ Saved Searches ▸ a search.
    @objc func showSavedSearch(_ sender: NSMenuItem) {
        guard let session, let id = sender.representedObject as? UUID, let saved = SavedSearchStore.load(session.account.id).first(where: { $0.id == id }) else { return }
        showSearch(saved.criteria, immediately: true)
    }
}

/// Find ▸ Saved Searches, rebuilt from the key window's account each time
/// it opens.
@MainActor final class SavedSearchMenu: NSObject, NSMenuDelegate {
    static let shared = SavedSearchMenu()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let window = NSApp.keyWindow.flatMap { ($0 as? ConversationNativeWindow)?.conversation }
        let saved = window?.session.map { SavedSearchStore.load($0.account.id) } ?? []
        if saved.isEmpty {
            let empty = NSMenuItem(title: "No Saved Searches", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for item in saved {
            let entry = NSMenuItem(title: item.title, action: #selector(ConversationWindow.showSavedSearch(_:)), keyEquivalent: "")
            entry.representedObject = item.id
            menu.addItem(entry)
        }
    }
}
