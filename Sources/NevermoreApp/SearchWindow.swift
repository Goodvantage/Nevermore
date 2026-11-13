import AppKit
import NevermoreCore
import RavenProtocol

struct SavedSearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var criteria: SearchCriteria
}

@MainActor enum SavedSearchStore {
    private static func key(_ account: UUID) -> String { "savedSearches.\(account.uuidString)" }
    static func load(_ account: UUID) -> [SavedSearch] {
        guard let data = UserDefaults.standard.data(forKey: key(account)), data.count <= 256 * 1024,
              let items = try? JSONDecoder().decode([SavedSearch].self, from: data), items.count <= 30 else { return [] }
        return items
    }
    static func save(_ items: [SavedSearch], account: UUID) throws {
        guard items.count <= 30 else { throw AppError.message("You can save up to 30 searches per account. Remove an old search first.") }
        let data = try JSONEncoder().encode(items)
        guard data.count <= 256 * 1024 else { throw AppError.message("Saved searches exceed the local size limit.") }
        UserDefaults.standard.set(data, forKey: key(account))
    }
    static func clear(_ account: UUID) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

@MainActor final class SearchWindow: NSWindowController, NSWindowDelegate {
    private weak var conversationOwner: ConversationWindow?
    private let session: AccountSession
    let query = NSSearchField()
    let scope = NSPopUpButton()
    let kind = NSPopUpButton()
    let author = NSTextField(string: "")
    let savedOnly = NSButton(checkboxWithTitle: "Saved by me", target: nil, action: nil)
    let mentionsMe = NSButton(checkboxWithTitle: "Mentions me", target: nil, action: nil)
    private let saved = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var scopes: [SearchCriteria.Scope] = []
    private let kinds: [SearchCriteria.Kind] = [.all, .text, .files, .images, .polls, .links]
    private var savedItems: [SavedSearch] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private weak var results: CollectionWindow?

    init(owner: ConversationWindow, session: AccountSession, initial: SearchCriteria.Scope) {
        self.conversationOwner = owner; self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Search · \(session.account.displayName) · \(session.account.origin.host ?? "")"; window.center(); window.delegate = self
        query.placeholderString = "Search messages, or leave blank to list matching items"
        query.setAccessibilityLabel("Search query"); query.target = self; query.action = #selector(runSearch)
        scopes = [.account]; scope.addItem(withTitle: "This account")
        if let channel = owner.channel { scopes.append(.conversation(channel.id)); scope.addItem(withTitle: "Conversation · \(channel.title)") }
        for workspace in Set(session.channels.filter { !$0.isDM && !$0.workspace.isEmpty }.map(\.workspace)).sorted() { scopes.append(.workspace(workspace)); scope.addItem(withTitle: "Workspace channels · \(workspace)") }
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.selectItem(at: scopes.firstIndex(of: initial) ?? -1); scope.setAccessibilityLabel("Search scope")
        kind.addItems(withTitles: ["All message types", "Text", "Files and images", "Images", "Polls", "Links"]); kind.setAccessibilityLabel("Message type filter"); kind.target = self; kind.action = #selector(scopeChanged)
        author.placeholderString = "Author’s Raven user ID (optional)"; author.setAccessibilityLabel("Search author user ID")
        let filters = NSStackView(views: [scope, kind]); filters.orientation = .horizontal; filters.spacing = 10
        let flags = NSStackView(views: [savedOnly, mentionsMe]); flags.orientation = .horizontal; flags.spacing = 20
        let search = NSButton(title: "Search", target: self, action: #selector(runSearch)); search.keyEquivalent = "\r"
        let save = NSButton(title: "Save Search…", target: self, action: #selector(saveSearch))
        let remove = NSButton(title: "Remove Saved Search", target: self, action: #selector(removeSavedSearch))
        saved.target = self; saved.action = #selector(restoreSavedSearch); saved.setAccessibilityLabel("Saved searches for this account")
        let actions = NSStackView(views: [search, save, remove]); actions.orientation = .horizontal; actions.spacing = 8
        status.stringValue = "Server results are limited to 100 and may lag indexing. Cached results are incomplete. Saved/mention filters need explicit metadata in the cache."
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        let content = NSStackView(views: [query, filters, author, flags, saved, actions, status]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18)])
        for view in [query, author, status] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        window.initialFirstResponder = query; reloadSaved(); scopeChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var active: Bool { !closed && conversationOwner?.isCurrent(session) == true }
    @objc private func scopeChanged() {
        status.stringValue = kinds.indices.contains(kind.indexOfSelectedItem) && kinds[kind.indexOfSelectedItem] == .links ? "Links search loads 50 links per page. Account or Conversation scope only. No complete cached link index; older sites may not support this endpoint." : "Server results are limited to 100 and may lag indexing. Cached results are incomplete."
        if kinds.indices.contains(kind.indexOfSelectedItem), kinds[kind.indexOfSelectedItem] != .links, scopes.indices.contains(scope.indexOfSelectedItem), case .workspace = scopes[scope.indexOfSelectedItem] {
            status.stringValue += " Workspace scope searches channel messages. Choose This account to include thread replies."
        }
    }
    func criteria() throws -> SearchCriteria {
        guard scopes.indices.contains(scope.indexOfSelectedItem), kinds.indices.contains(kind.indexOfSelectedItem) else { throw AppError.message("Choose an accessible search scope.") }
        return SearchCriteria(query: query.stringValue, scope: scopes[scope.indexOfSelectedItem], kind: kinds[kind.indexOfSelectedItem], author: author.stringValue.isEmpty ? nil : author.stringValue, savedOnly: savedOnly.state == .on, mentionsMe: mentionsMe.state == .on)
    }
    private func reloadSaved() {
        savedItems = SavedSearchStore.load(session.account.id); saved.removeAllItems(); saved.addItem(withTitle: "Saved searches…"); saved.addItems(withTitles: savedItems.map(\.title))
    }
    @objc private func restoreSavedSearch() {
        let index = saved.indexOfSelectedItem - 1
        guard savedItems.indices.contains(index) else { return }
        let item = savedItems[index].criteria
        query.stringValue = item.query; scope.selectItem(at: scopes.firstIndex(of: item.scope) ?? -1)
        kind.selectItem(at: kinds.firstIndex(of: item.kind) ?? 0); author.stringValue = item.author ?? ""
        savedOnly.state = item.savedOnly ? .on : .off; mentionsMe.state = item.mentionsMe ? .on : .off
        scopeChanged()
        if scope.indexOfSelectedItem < 0 { status.stringValue = "This saved search’s scope is no longer available. Choose an accessible scope before searching." }
    }
    @objc private func saveSearch() {
        guard active, let owner = conversationOwner else { return }
        do {
            let criteria = try criteria()
            if criteria.kind == .links { _ = try LinkSearch.source(criteria) }
            else { _ = try criteria.filters(channels: session.channels) }
            _ = owner
            Task { [weak self] in
                guard let self, let window = self.window else { return }
                guard let title = await SheetPrompt.text("Save Search", placeholder: "Search name", value: String(criteria.query.prefix(80)), confirm: "Save", on: window), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.active else { return }
                do {
                    var items = SavedSearchStore.load(self.session.account.id); items.append(SavedSearch(title: String(title.prefix(100)), criteria: criteria))
                    try SavedSearchStore.save(items, account: self.session.account.id); self.reloadSaved()
                } catch { self.status.stringValue = error.localizedDescription }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func removeSavedSearch() {
        let index = saved.indexOfSelectedItem - 1
        guard active, savedItems.indices.contains(index) else { return }
        do { var items = savedItems; items.remove(at: index); try SavedSearchStore.save(items, account: session.account.id); reloadSaved() }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc func runSearch() {
        guard active, let owner = conversationOwner else { return }
        do {
            let criteria = try criteria()
            let source: CollectionSource
            if criteria.kind == .links { source = try LinkSearch.source(criteria) }
            else {
                let filters = try criteria.filters(channels: session.channels)
                let filterJSON = String(decoding: try JSONEncoder().encode(JSONValue.object(filters)), as: UTF8.self)
                source = CollectionSource(method: "raven.api.search.sqlite_search", arguments: ["query": .string(criteria.query), "filters": .string(filterJSON)], strategy: .none, pageSize: 100)
            }
            task?.cancel(); results?.close(); generation = UUID(); let attempt = generation
            let list = CollectionWindow(owner: owner, title: "Search · loading", records: [], kind: .search, source: source)
            list.isLoading = true; owner.collectionWindows.append(list); results = list; list.showWindow(nil)
            let page = list.pager.beginRefresh()
            task = Task { [weak self] in
                guard let self else { return }
                if criteria.kind != .links, !criteria.query.isEmpty, let cached = try? await session.store.search(criteria.query), self.active, self.generation == attempt {
                    let allowed = Set(session.channels.map(\.id))
                    let rows = cached.filter { message in
                        let parent = message.raw["parent_channel_id"].string ?? message.channelID
                        return allowed.contains(parent) && criteria.matches(message, channels: session.channels, currentUser: session.account.user)
                    }.map(\.raw)
                    _ = list.apply(rows: rows, generation: page, refresh: true)
                    list.window?.title = "Cached Search · incomplete · updating"
                }
                do {
                    let response = try await session.client.rpc(source.method, arguments: CollectionPaging.pageArguments(source, offset: 0))
                    guard self.active, self.generation == attempt, !Task.isCancelled else { return }
                    _ = list.apply(rows: try CollectionPaging.decodeRows(response), generation: page, refresh: true)
                    list.window?.title = criteria.kind == .links ? "Links Search · loaded results" : "Server Search · up to 100 results"
                    if session.retainHistory { try? await session.store.cacheProjection(key: source.cacheKey, value: response) }
                } catch {
                    guard self.active, self.generation == attempt, !Task.isCancelled else { return }
                    if (error as? RavenError)?.isPermissionDenied == true { list.pager.records.removeAll(); list.records.removeAll(); list.table.reloadData() }
                    list.window?.title = criteria.kind == .links ? "Links Search · unavailable" : "Cached Search · incomplete"
                    list.statusMessage = criteria.kind == .links ? "Links search failed: \(error.localizedDescription). This site may not support link search. No complete cached link index is available; try a message search." : "Server search failed: \(error.localizedDescription). Cached results may omit saved/mention metadata."
                }
                list.isLoading = false; list.updateChrome()
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; generation = UUID(); task?.cancel()
        if conversationOwner?.searchWindow === self { conversationOwner?.searchWindow = nil }
        if let results, results.isLoading { results.isLoading = false; results.statusMessage = "Search cancelled"; results.updateChrome() }
    }
}

extension ConversationWindow {
    @objc func advancedSearch(_ sender: Any?) { showSearch(scope: channel.map { .conversation($0.id) } ?? .account) }
    @objc func searchAccount(_ sender: Any?) { showSearch(scope: .account) }
    private func showSearch(scope: SearchCriteria.Scope) {
        guard let session, !session.stopped else { return }
        searchWindow?.close()
        let controller = SearchWindow(owner: self, session: session, initial: scope); searchWindow = controller; controller.query.stringValue = search.stringValue; controller.showWindow(nil)
    }
}
