import AppKit
import RavenProtocol
import NevermoreCore
// See App.swift: UNNotification* are non-Sendable before newer SDKs.
@preconcurrency import UserNotifications
import ImageIO

extension Notification.Name {
    static let sessionChanged = Notification.Name("NevermoreSessionChanged")
    static let draftChanged = Notification.Name("NevermoreDraftChanged")
    static let sessionStatusAttentionChanged = Notification.Name("NevermoreSessionStatusAttentionChanged")
    /// A profile photo arrived; transcripts redraw without re-rendering.
    static let sessionAvatarsChanged = Notification.Name("NevermoreSessionAvatarsChanged")
}

private enum OutboxTargetError: LocalizedError {
    case archived, accessChanged
    var errorDescription: String? {
        switch self {
        case .archived: return StatusLocalization.text(.outboxArchived)
        case .accessChanged: return StatusLocalization.text(.outboxAccessChanged)
        }
    }
}

/// NotificationCenter permits removal from any thread. The tokens are immutable
/// after initialization; releasing this bag unregisters them even on failed setup.
private final class TimestampEnvironmentObservation: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    init(changed: @escaping @Sendable () -> Void) {
        // A new day turns "Today" into "Yesterday" in transcript dividers.
        tokens = [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
        }
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor final class AccountSession {
    private(set) var account: Account
    let store: AccountStore
    var client: RavenClient
    var channels: [RavenChannel] = []
    var userNames: [String: String] = [:]
    var directory: [String: JSONValue] = [:]
    var workingHours: RavenQuietHoursConfig?
    var userPreferences: RavenUserPreferences?
    var roles = Set<String>()
    var favoriteIDs: Set<String> { Set(userPreferences?.raw["pinned_channels"].array.compactMap { $0["channel_id"].string } ?? []) }
    var activeUsers = Set<String>()
    var lastPresenceRefresh = Date.distantPast
    var lastPresenceAttempt = Date.distantPast
    var presenceUnavailable = false
    var knownThreads = Set<String>()
    var threadParents: [String: String] = [:]
    var threadCreations: [String: Task<RavenChannel, Error>] = [:]
    private let timestamps: MessageTimestampFormatter
    private var timestampEnvironmentObservation: TimestampEnvironmentObservation?
    private var messageDocuments = MessageDocumentCache()
    let sentLinkPreviews = SentLinkPreviews()
    var state = StatusLocalization.text(.connecting)
    private(set) var statusAttention: StatusAnnouncement?
    var readOnly = false
    var realtime: RavenRealtime?
    var interests: [UUID: String] = [:]
    var generation = 0
    var deletedIDs = Set<String>() {
        didSet { if deletedIDs.count > oldValue.count || !deletedIDs.isSubset(of: oldValue) { clearMessageDocuments(); pruneTranscriptChannelState() } }
    }
    var revokedChannels = Set<String>() {
        didSet { if revokedChannels.count > oldValue.count || !revokedChannels.isSubset(of: oldValue) { clearMessageDocuments(); pruneTranscriptChannelState() } }
    }
    var flushing = false
    var lastSeen: [String: String] = [:]
    private var transcriptChannelState = TranscriptChannelStateCache()
    var intentionallyUnread = Set<String>()
    var approvedOldSends = Set<UUID>()
    var preparingChannels = Set<String>()
    var acceptingChannels = Set<String>()
    var pendingFileReceipts: [UUID: String] = [:]
    var draftPersistenceFailures: [String: String] = [:]
    var unpersistedDraftRevisions: [String: Int] = [:]
    var recoverableDrafts: [String: Draft] = [:]
    var invalidDraftChannels = Set<String>()
    var draftRevisions: [String: Int] = [:]
    // Recovery state tracks the latest revision only; an older save can
    // still be suspended after that revision has finished persisting.
    private var draftSavesInFlight: [String: Int] = [:]
    var sharedTextStorage: [String: NSTextStorage] = [:]
    var draftUndoManagers: [String: UndoManager] = [:]
    var composerModes: [String: DraftEditorState.Mode] = [:]
    var flushAgain = false
    var realtimeToken: String?
    var realtimeLive = false
    var thumbnails: [String: NSImage] = [:]
    var thumbnailOrder: [String] = []
    var thumbnailRequests = Set<String>()
    /// Profile photos by user ID; absent until loaded, then drawn in place
    /// of generated ravens. `avatarFailures` stops retrying broken images until
    /// the connection returns or the user directory changes.
    var avatars: [String: NSImage] = [:]
    /// Least recently shown photos go first; what any window shows stays.
    private var avatarLastUse: [String: Int] = [:]
    private var avatarClock = 0
    var avatarRequests = Set<String>()
    var avatarFailures = Set<String>()
    private var avatarQueue: [String] = []
    private var avatarWorker: Task<Void, Never>?
    // Separate from downloaded photos so a fallback never suppresses a fetch.
    // Account-owned, memory-only and bounded; stop() drops names and images.
    private let generatedAvatars: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private let generatedChannelAvatars: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    var memoryMessages: [String: [RavenMessage]] = [:]
    let quickReactionUsage = QuickReactionUsage()
    /// Every window shares message snapshots, so refresh coverage must include
    /// toggles accepted from any window, not only the one asking for a reload.
    private(set) var reactionsAccepted = 0
    var retainHistory: Bool { UserDefaults.standard.object(forKey: "retainHistory") as? Bool != false }
    var stopped = false
    var refreshTask: Task<Void, Never>?
    var reconciliationTask: Task<Void, Never>?
    var reconcileRequested = false
    private var lastLiveRefresh = Date()
    var notificationChannels = Set<String>()
    var notifiedIDs = Set<String>()
    var unread: JSONValue = .null
    var unreadNotificationIDs = Set<String>()
    /// Unread conversations in which a mention arrived while the app was
    /// running. Their sidebar raven has a lit eye. Mentions from before
    /// launch are not known here: the server reports those per message,
    /// not per conversation.
    var mentionedChannels = Set<String>()
    let demo: Bool
    /// Stands in for the server in the interactive demo, so sending can be
    /// tried without an account. Nil in self-checks and for real accounts.
    var demoWire: DemoWire?
    enum Authentication: Equatable { case keychain, loopbackFixture }
    init(account: Account, directory: URL, demo: Bool = false, authentication: Authentication = .keychain) throws {
        // Reject invalid fixture origins before store, download or credential IO.
        if authentication == .loopbackFixture {
            guard !demo, account.user == "performance-fixture@example.invalid", account.clientID == "performance-loopback" else { throw PerformanceMetrics.OptionsError.invalid }
            _ = try PerformanceMetrics.loopbackOrigin(account.origin.absoluteString)
        }
        self.account = account; self.demo = demo
        timestamps = MessageTimestampFormatter(siteTimeZone: TimeZone(identifier: account.timezone) ?? .gmt)
        store = try AccountStore(directory: directory)
        // The exclusive store lock prevents deleting another process's active
        // previews. Successful startup clears this account's crash leftovers.
        if !demo && authentication == .keychain { try DownloadedAttachment.purgeDownloads(accountID: account.id, in: FileManager.default.temporaryDirectory) }
        client = RavenClient(origin: account.origin, tokens: demo || authentication == .loopbackFixture ? nil : try KeychainTokenStore.load(accountID: account.id), clientID: account.clientID, accountID: account.id)
        timestampEnvironmentObservation = TimestampEnvironmentObservation { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.timestamps.updateDisplay(locale: .current, timeZone: .current)
                self.notify()
            }
        }
    }
    func recordAcceptedReaction() {
        reactionsAccepted += 1
        quickReactionUsage.invalidate()
    }
    func displayTimestamp(_ raw: String) -> String { timestamps.string(from: raw) }
    func displayTime(_ raw: String) -> String { timestamps.time(from: raw) }
    func compactTime(_ raw: String) -> String { timestamps.compactTime(from: raw) }
    func messageDate(_ raw: String) -> Date? { timestamps.date(from: raw) }
    func dayLabel(for date: Date) -> String { timestamps.dayLabel(for: date) }
    var displayCalendar: Calendar { timestamps.calendar }
    func authorName(_ message: RavenMessage) -> String { userNames[message.authorID] ?? message.authorID }
    /// Frappe's site-local datetime for `date`, as the server would write it.
    func serverTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: account.timezone) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter.string(from: date)
    }
    /// The message an accepted send will become, for laying it out before
    /// the server has answered. Its ID is local; it is never cached.
    func pendingMessage(for operation: SendOperation) -> RavenMessage {
        var fields: [String: JSONValue] = [
            "name": .string("outbox-\(operation.id.uuidString)"), "channel_id": .string(operation.channelID), "owner": .string(account.user),
            "creation": .string(serverTimestamp(operation.createdAt)), "text": .string(operation.html),
            // Without text there is no body to render, only staged files.
            "message_type": .string(operation.html.isEmpty ? "File" : "Text"), "message_batch_id": .string(operation.id.uuidString)
        ]
        if let reply = operation.replyTo { fields["is_reply"] = .bool(true); fields["linked_message"] = .string(reply) }
        return RavenMessage(raw: .object(fields))
    }
    func messageDocument(for message: RavenMessage) -> MessageDocumentResult {
        guard !stopped, !deletedIDs.contains(message.id), !deletedIDs.contains(message.channelID),
              !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: revokedChannels, threadParents: threadParents) else {
            clearMessageDocuments()
            return .failed
        }
        return messageDocuments.document(channelID: message.channelID, messageID: message.id, html: message.html)
    }
    func clearMessageDocuments() { messageDocuments.removeAll() }
    func transcriptVisit(for channelID: String) -> TranscriptReadPosition.Visit? { transcriptChannelState.visit(for: channelID) }
    func historicalMessageIDs(for channelID: String) -> TranscriptChannelStateCache.HistoricalPage? { transcriptChannelState.historicalPage(for: channelID) }
    func recordTranscriptVisit(_ visit: TranscriptReadPosition.Visit, channelID: String) {
        guard transcriptChannelIsEligible(channelID) else { return }
        transcriptChannelState.recordVisit(visit, channelID: channelID)
    }
    func recordHistoricalMessageIDs(_ ids: [String], channelID: String) {
        guard transcriptChannelIsEligible(channelID) else { return }
        transcriptChannelState.recordHistoricalPage(messageIDs: ids, channelID: channelID)
    }
    private func transcriptChannelIsEligible(_ channelID: String) -> Bool {
        !stopped && interests.values.contains(channelID) && !deletedIDs.contains(channelID) &&
        !ChannelPolicy.isRevoked(channelID: channelID, revoked: revokedChannels, threadParents: threadParents)
    }
    private func pruneTranscriptChannelState() {
        transcriptChannelState.retain { transcriptChannelIsEligible($0) }
    }
    func notify() { (NSApp.delegate as? AppDelegate)?.updateDockBadge(); NotificationCenter.default.post(name: .sessionChanged, object: self) }
    func setStatusAttention(_ attention: StatusAnnouncement?) {
        guard !stopped || attention == nil else { return }
        statusAttention = attention
        NotificationCenter.default.post(name: .sessionStatusAttentionChanged, object: self)
    }
    func threadChannel(for message: RavenMessage) async throws -> RavenChannel {
        guard !stopped, !revokedChannels.contains(message.channelID) else { throw AppError.message("This conversation is no longer accessible.") }
        func channel() -> RavenChannel { threadParents[message.id] = message.channelID; return RavenChannel(raw: .object(["name": .string(message.id), "channel_name": .string("Thread · \(authorName(message))"), "is_thread": .bool(true), "parent_channel_id": .string(message.channelID)])) }
        if message.raw["is_thread"].bool || knownThreads.contains(message.id) { return channel() }
        if let task = threadCreations[message.id] { return try await task.value }
        let task = Task { @MainActor in
            do {
                let result = try await mutate("raven.api.threads.create_thread", ["message_id": .string(message.id)])
                guard result["thread_id"].string == message.id else { throw AppError.message("The server did not return the expected thread identifier.") }
            } catch {
                // Creation has no retry key. Resolve an uncertain/duplicate response by reading,
                // never by submitting another creation request.
                let canonical = try? await client.resource("Raven Message", name: message.id, values: nil)
                guard canonical?["is_thread"].bool == true else { throw error }
            }
            guard !stopped, !revokedChannels.contains(message.channelID) else { throw AppError.message("Access changed while opening the thread.") }
            knownThreads.insert(message.id); return channel()
        }
        threadCreations[message.id] = task
        defer { threadCreations.removeValue(forKey: message.id) }
        return try await task.value
    }
    func presenceDescription(for userID: String) -> String? {
        let declared = directory[userID]?["availability_status"].string
        if declared == "Invisible" { return nil }
        if declared == "Do not disturb" || declared == "Away" { return declared }
        return activeUsers.contains(userID) ? "Active" : nil
    }
    func recordInteraction(now: Date = Date()) {
        guard !demo, !stopped, !readOnly, !presenceUnavailable, NSApp.isActive, now.timeIntervalSince(lastPresenceAttempt) >= 60 else { return }
        guard userPreferences?.availabilityStatus != "Invisible" else { return }
        lastPresenceAttempt = now
        Task {
            do { _ = try await client.rpc("raven.api.user_availability.refresh_user_active_state", arguments: ["deactivate": .bool(false)], mutation: true) }
            catch { if let failure = error as? RavenError, failure.isPermissionDenied || failure == .http(404, nil) { presenceUnavailable = true } }
        }
        // The server expires activity after 15 minutes. Do not send a global
        // deactivate on sleep/quit: that would also erase this user's phone activity.
    }
    func reauthenticate(clientID: String, tokens: OAuthTokens) async throws {
        await client.invalidate()
        try KeychainTokenStore.save(tokens, accountID: account.id)
        generation += 1; presenceUnavailable = false; account.clientID = clientID
        client = RavenClient(origin: account.origin, tokens: tokens, clientID: clientID, accountID: account.id)
        realtime?.disconnect(); realtime = nil; realtimeToken = nil
        setStatusAttention(nil)
        state = StatusLocalization.text(.reconnecting); notify()
        do { try await refresh(); ensureRealtime(); await flush() } catch { fail(error) }
    }
    func start() async {
        do {
            try await store.recoverInterruptedOperations()
            channels = try await store.channels()
            state = demo ? StatusLocalization.text(.demo) : StatusLocalization.text(.cachedConnecting); notify()
        } catch { fail(error) }
        if demo { return }
        do { try await refresh() } catch { fail(error) }
        ensureRealtime(); await flush()
        lastLiveRefresh = Date()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, !self.stopped else { break }
                self.reconciliationTick(now: Date(), isActive: NSApp.isActive)
            }
        }
    }
    func reconciliationTick(now: Date, isActive: Bool) {
        guard !demo, !stopped else { return }
        if !realtimeLive {
            if !interests.isEmpty { requestReconciliation() }
        } else if isActive, now.timeIntervalSince(lastLiveRefresh) >= 60 {
            requestReconciliation()
            lastLiveRefresh = now
        }
    }
    func refresh() async throws {
        guard !stopped else { return }
        let boot = try await client.rpc("raven.api.native.boot")
        guard !stopped else { return }
        readOnly = boot["read_only"].bool
        roles = Set(boot["user"]["roles"].array.compactMap(\.string))
        workingHours = boot["quiet_hours"] == .null ? nil : RavenQuietHoursConfig(raw: boot["quiet_hours"])
        if userPreferences == nil, let raw = try? await client.rpc("raven.api.raven_users.get_current_raven_user"), raw["user"].string == account.user || raw["name"].string == account.user { userPreferences = RavenUserPreferences(raw: raw) }
        if userNames.isEmpty, let directory = try? await client.rpc("raven.api.raven_users.get_list") {
            for user in directory.array { if let id = user["name"].string { userNames[id] = user["full_name"].string ?? id; self.directory[id] = user } }
        }
        if Date().timeIntervalSince(lastPresenceRefresh) >= 60, !presenceUnavailable {
            lastPresenceRefresh = Date()
            if let active = try? await client.rpc("raven.api.user_availability.get_active_users") { activeUsers = Set(active.array.compactMap(\.string)) }
        }
        let value = try await client.rpc("raven.api.raven_channel.get_all_channels", arguments: ["hide_archived": .bool(false)])
        guard case .array = value["channels"], case .array = value["dm_channels"] else { throw AppError.message("The server returned an unsupported channel contract. Open Raven in your browser.") }
        let items = (value["channels"].array + value["dm_channels"].array).map { raw -> RavenChannel in
            var fields = raw.object
            if raw["is_direct_message"].bool, raw["channel_name_for_current_user"].string == nil, let peer = raw["peer_user_id"].string {
                fields["channel_name_for_current_user"] = .string(peer == account.user ? "You" : userNames[peer] ?? peer)
            }
            return RavenChannel(raw: .object(fields))
        }
        guard !stopped else { return }
        let allowed = Set(items.map(\.id))
        // Thread rooms are separately authorized by their history endpoint.
        let threads = Set(interests.values).subtracting(channels.map(\.id))
        let revoked = Set(channels.map(\.id)).subtracting(allowed)
        revokedChannels.formUnion(revoked); revokedChannels.subtract(allowed)
        for id in revoked { memoryMessages.removeValue(forKey: id) }
        if !revoked.isEmpty { generation += 1; thumbnails.removeAll(); thumbnailOrder.removeAll() }
        try await store.removeRevokedChannels(allowed: allowed.union(threads))
        try await store.cacheChannels(items)
        channels = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        unread = (try? await client.rpc("raven.api.raven_message.get_unread_count_for_channels")) ?? .null
        if let attention = try? await client.rpc("raven.api.notifications.get_unread_notification_message_ids") {
            unreadNotificationIDs = Set(attention.array.compactMap(\.string))
        } else {
            // Older deployments lack the ID endpoint. A bounded inbox page is
            // sufficient for an attention dot, never advertised as a count.
            let attention = try? await client.rpc("raven.api.notifications.get_notifications", arguments: ["unread_only": .bool(true), "limit": .number(100)])
            // Mention rows use their own name; only message_id identifies
            // the underlying message in both notification variants.
            unreadNotificationIDs = Set((attention?.array ?? []).compactMap { $0["message_id"].string })
        }
        guard !stopped else { return }
        mentionedChannels.formIntersection(UnreadFlock.perching(channels: channels, unread: unread).keys)
        setStatusAttention(nil)
        state = readOnly ? StatusLocalization.text(.maintenance) : realtimeLive ? StatusLocalization.text(.live) : StatusLocalization.text(.httpOnly)
        notify()
    }
    func attach(window: UUID, channelID: String?) {
        interests[window] = channelID
        pruneTranscriptChannelState()
        if retainHistory { let active = Set(interests.values); memoryMessages = memoryMessages.filter { active.contains($0.key) } }
        updateRooms()
    }
    func ensureRealtime() {
        guard !demo, !stopped, let tokens = try? KeychainTokenStore.load(accountID: account.id) else { return }
        if realtime == nil || realtimeToken != tokens.accessToken {
            realtime?.disconnect(); realtimeToken = tokens.accessToken
            realtime = RavenRealtime(account: account, accessToken: tokens.accessToken) { [weak self] event, payload in self?.event(event, payload) }
            realtime?.connect(); updateRooms()
        }
    }
    func updateRooms() { realtime?.setChannels(Set(interests.values).subtracting(revokedChannels)) }
    func event(_ name: String, _ payload: JSONValue) {
        if name == "raven:user_active_state_updated", let user = payload["user"].string {
            if payload["active"].bool { activeUsers.insert(user) } else { activeUsers.remove(user) }
            notify(); return
        }
        if payload["doctype"].string == "Raven User" { userNames.removeAll(); directory.removeAll(); userPreferences = nil; avatars.removeAll(); avatarLastUse.removeAll(); avatarFailures.removeAll(); avatarRequests.subtract(avatarQueue); avatarQueue.removeAll() }
        if name == "connect" { realtimeLive = true; avatarFailures.removeAll(); updateRooms(); state = readOnly ? StatusLocalization.text(.maintenance) : StatusLocalization.text(.live) }
        if name == "disconnect" || name == "error" { realtimeLive = false; ensureRealtime(); state = StatusLocalization.text(.realtimeUnavailable) }
        if name == "raven_mention", let channel = payload["channel_id"].string, mentionedChannels.count < 512 { mentionedChannels.insert(channel) }
        if ["message_deleted", "disconnect"].contains(name) { generation += 1 }
        if name == "message_deleted" {
            let id = payload["message_id"].string ?? payload["name"].string
            if let id { deletedIDs.insert(id); thumbnails.removeValue(forKey: id); for channel in memoryMessages.keys { memoryMessages[channel]?.removeAll { $0.id == id } }; Task { try? await store.deleteMessages(ids: [id]); notify() } }
        }
        if ["message_created", "raven_mention", "raven_reaction_notification", "raven:unread_channel_count_updated"].contains(name),
           let channel = payload["channel_id"].string,
           (payload["sender"].string ?? payload["sent_by"].string ?? "") != account.user,
           payload["event_type"].string != "message_deleted", notificationChannels.count < 10 { notificationChannels.insert(channel) }
        notify()
        requestReconciliation()
    }

    /// All triggers share one worker so activation, polling and socket bursts
    /// cannot start overlapping refreshes for the same account.
    func requestReconciliation() {
        guard !demo, !stopped else { return }
        reconcileRequested = true
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.reconciliationTask = nil
                // A request can arrive while notification delivery is suspended.
                if self.reconcileRequested && !self.stopped && !Task.isCancelled { self.requestReconciliation() }
            }
            while self.reconcileRequested, !Task.isCancelled, !self.stopped {
                self.reconcileRequested = false
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !self.stopped else { return }
                do { try await self.refresh(); self.ensureRealtime() } catch { self.fail(error) }
                for channel in Set(self.interests.values) {
                    guard !Task.isCancelled, !self.stopped else { return }
                    try? await self.load(channelID: channel)
                }
                if NSApp.isActive { await self.flush() }
            }
            let pending = self.notificationChannels; self.notificationChannels.removeAll()
            for channel in pending { await self.deliverNotification(channelID: channel) }
        }
    }
    func load(channelID: String, olderThan: String? = nil, anchor: String? = nil) async throws {
        if demo { notify(); return }
        let epoch = generation
        var args: [String: JSONValue] = ["channel_id": .string(channelID), "limit": .number(100), "update_last_visit": .bool(false)]
        var method = "raven.api.chat_stream.get_messages"
        if let olderThan { method = "raven.api.chat_stream.get_older_messages"; args["from_message"] = .string(olderThan); args.removeValue(forKey: "update_last_visit") }
        if let anchor { args["base_message"] = .string(anchor) }
        do {
            let result = try await client.rpc(method, arguments: args)
            guard !stopped, epoch == generation else { return }
            guard case .array = result["messages"] else { throw AppError.message("Unsupported message history response.") }
            // The history contract returns the caller's watermark even when
            // update_last_visit=false. Missing optional fields stay unknown.
            if result.object.keys.contains("last_visit") {
                switch result["last_visit"] {
                case .null: recordTranscriptVisit(.neverVisited, channelID: channelID)
                case .string(let value): recordTranscriptVisit(.timestamp(value), channelID: channelID)
                default: break
                }
            }
            sentLinkPreviews.ingest(result["previews"])
            let rows = result["messages"].array.map(RavenMessage.init(raw:)).filter { !deletedIDs.contains($0.id) && $0.channelID == channelID }
            if olderThan != nil, transcriptChannelIsEligible(channelID) {
                recordHistoricalMessageIDs(rows.map(\.id), channelID: channelID)
            }
            if olderThan == nil && anchor == nil {
                let existing = try await store.messages(channelID: channelID, limit: 5000)
                let absent = MessageReconciliation.observedDeletions(existing: existing, snapshot: rows, channelID: channelID, authoritative: true)
                if !absent.isEmpty { clearMessageDocuments() }
                try await store.deleteMessages(ids: absent)
                let removed = Set(absent); memoryMessages[channelID]?.removeAll { removed.contains($0.id) }
            }
            if retainHistory { try await store.cacheMessages(rows) }
            var merged = Dictionary(uniqueKeysWithValues: (memoryMessages[channelID] ?? []).map { ($0.id, $0) })
            for row in rows { merged[row.id] = row }
            let ordered = merged.values.sorted(by: Self.order)
            memoryMessages[channelID] = olderThan == nil ? Array(ordered.suffix(1500)) : Array(ordered.prefix(1500))
            notify()
        } catch {
            // An authoritative access denial invalidates private cached content.
            if let e = error as? RavenError, e.isPermissionDenied {
                revokedChannels.insert(channelID); memoryMessages.removeValue(forKey: channelID); thumbnails.removeAll(); updateRooms()
                let rows = try await store.messages(channelID: channelID, limit: 5000)
                try await store.deleteMessages(ids: rows.map(\.id)); notify()
            }
            throw error
        }
    }
    static func order(_ a: RavenMessage, _ b: RavenMessage) -> Bool { MessageReconciliation.ordered(a, b) }
    func save(_ draft: Draft, revision: Int? = nil) async throws {
        guard !stopped else { throw AppError.message("This account is no longer active.") }
        if let revision, draftRevisions[draft.channelID, default: 0] != revision { return }
        guard !acceptingChannels.contains(draft.channelID) else { throw AppError.message("This shared draft is being accepted for sending. Your current text is still in the editor.") }
        draftSavesInFlight[draft.channelID, default: 0] += 1
        defer {
            let remaining = draftSavesInFlight[draft.channelID, default: 0] - 1
            if remaining == 0 { draftSavesInFlight.removeValue(forKey: draft.channelID) }
            else { draftSavesInFlight[draft.channelID] = remaining }
        }
        if revision == nil { draftRevisions[draft.channelID, default: 0] += 1 }
        let savingRevision = draftRevisions[draft.channelID, default: 0]
        unpersistedDraftRevisions[draft.channelID] = savingRevision; recoverableDrafts[draft.channelID] = draft
        do { try await store.saveDraft(draft) }
        catch { if draftRevisions[draft.channelID, default: 0] == savingRevision { draftPersistenceFailures[draft.channelID] = error.localizedDescription }; throw error }
        guard !stopped, draftRevisions[draft.channelID, default: 0] == savingRevision else { return }
        draftPersistenceFailures.removeValue(forKey: draft.channelID); unpersistedDraftRevisions.removeValue(forKey: draft.channelID); recoverableDrafts.removeValue(forKey: draft.channelID); invalidDraftChannels.remove(draft.channelID)
        NotificationCenter.default.post(name: .draftChanged, object: self, userInfo: ["channel": draft.channelID])
    }
    @discardableResult func send(_ draft: Draft, sendSilently: Bool = false) async throws -> SendOperation {
        guard !stopped else { throw AppError.message("This account is no longer active.") }
        guard !demo || demoWire != nil else { throw AppError.message("Demo mode does not send messages. Add a Raven account to chat.") }
        guard !readOnly, !ChannelPolicy.isRevoked(channelID: draft.channelID, revoked: revokedChannels, threadParents: threadParents) else { throw AppError.message("This conversation is read only or access changed. Your draft is preserved.") }
        guard !ChannelPolicy.isArchived(channelID: draft.channelID, channels: channels, threadParents: threadParents) else { throw OutboxTargetError.archived }
        guard !acceptingChannels.contains(draft.channelID) else { throw AppError.message("This draft is already being sent in another window.") }
        acceptingChannels.insert(draft.channelID); notify(); defer { acceptingChannels.remove(draft.channelID); notify() }
        guard let persisted = try await store.draft(channelID: draft.channelID), persisted.html == draft.html, DraftEditorState.sameContent(persisted.editorState, draft.editorState),
              persisted.replyTo == draft.replyTo, persisted.attachments.map(\.id) == draft.attachments.map(\.id) else {
            throw AppError.message("The shared draft changed or was already sent in another window. Review the current draft before sending.")
        }
        guard !stopped, !readOnly, !ChannelPolicy.isRevoked(channelID: draft.channelID, revoked: revokedChannels, threadParents: threadParents), !ChannelPolicy.isArchived(channelID: draft.channelID, channels: channels, threadParents: threadParents) else { throw AppError.message("Conversation access changed before send acceptance. Your draft is preserved.") }
        let accepted = try await store.acceptDraft(channelID: draft.channelID, expected: draft, sendSilently: sendSilently)
        draftRevisions[draft.channelID, default: 0] += 1
        draftPersistenceFailures.removeValue(forKey: draft.channelID); unpersistedDraftRevisions.removeValue(forKey: draft.channelID); recoverableDrafts.removeValue(forKey: draft.channelID); invalidDraftChannels.remove(draft.channelID)
        sharedTextStorage[draft.channelID]?.setAttributedString(NSAttributedString(string: ""))
        NotificationCenter.default.post(name: .draftChanged, object: self, userInfo: ["channel": draft.channelID])
        notify()
        if let demoWire { demoWire.deliver() } else { Task { await flush() } }
        return accepted
    }
    /// Reserves the original shared composer before any suspension. Saves,
    /// sends and file receipts must settle first; the store then compares
    /// the persisted draft and restores/cancels atomically.
    func takeBack(id: UUID, channelID: String) async throws -> SendOperation? {
        guard !stopped else { throw AppError.message("This account is no longer active.") }
        guard !acceptingChannels.contains(channelID), !preparingChannels.contains(channelID),
              !pendingFileReceipts.values.contains(channelID), unpersistedDraftRevisions[channelID] == nil,
              draftSavesInFlight[channelID, default: 0] == 0 else {
            throw AppError.message("Wait for this shared draft to finish saving or receiving files before taking a message back.")
        }
        guard !invalidDraftChannels.contains(channelID), recoverableDrafts[channelID] == nil else {
            throw AppError.message("Save or clear this draft before taking a message back.")
        }
        acceptingChannels.insert(channelID); notify()
        defer { acceptingChannels.remove(channelID); notify() }
        let revision = draftRevisions[channelID, default: 0]
        let existing = try await store.draft(channelID: channelID)
        guard !stopped, draftRevisions[channelID, default: 0] == revision else {
            throw AppError.message("This shared draft changed. Review it before taking a message back.")
        }
        guard InkRules.canRestoreDraft(existing) else {
            throw AppError.message("Send or clear this draft before taking a message back.")
        }
        let operation: SendOperation
        switch try await store.takeBack(id: id, channelID: channelID, replacingDraft: existing) {
        case .unavailable: return nil
        case .draftChanged: throw AppError.message("This shared draft changed. Review it before taking a message back.")
        case .restored(let restored): operation = restored
        }
        guard !stopped else { return operation }
        // UI edits are disabled while reserved. Preserve even a programmatic
        // newer edit rather than clearing its recovery state on completion.
        guard draftRevisions[channelID, default: 0] == revision else {
            throw AppError.message("The message was taken back, but a newer draft is still in the editor. Review it before sending.")
        }
        draftRevisions[channelID, default: 0] += 1
        draftPersistenceFailures.removeValue(forKey: channelID)
        NotificationCenter.default.post(name: .draftChanged, object: self, userInfo: ["channel": channelID])
        return operation
    }

    func flush() async {
        guard !readOnly, !stopped, !demo else { return }
        if flushing { flushAgain = true; return }
        flushing = true; defer {
            flushing = false; notify()
            if flushAgain { flushAgain = false; Task { await flush() } }
        }
        do {
            let ops = try await store.operations()
            for var op in ops where op.state == .queued || op.state == .retryable {
                guard !stopped else { return }
                // `op` is a copy from the listing above; these go through the
                // store's own check so a send taken back since is left alone.
                if ChannelPolicy.isRevoked(channelID: op.channelID, revoked: revokedChannels, threadParents: threadParents) { _ = try await store.sendToReview(id: op.id, reason: StatusLocalization.text(.outboxPermissionReview)); continue }
                if Date().timeIntervalSince(op.createdAt) > 86400 && !approvedOldSends.contains(op.id) { _ = try await store.sendToReview(id: op.id, reason: StatusLocalization.text(.outboxOldReview)); continue }
                do {
                    if ChannelPolicy.isArchived(channelID: op.channelID, channels: channels, threadParents: threadParents) { throw OutboxTargetError.archived }
                    if op.attachments.contains(where: { $0.uploaded == nil }) { try await verifySendTarget(op.channelID) }
                    guard !stopped else { return }
                    // Claimed atomically: a send taken back since `ops`
                    // was read must not leave after all.
                    guard let claimed = try await store.beginAttempt(id: op.id) else { continue }
                    op = claimed; notify()
                    for i in op.attachments.indices where op.attachments[i].uploaded == nil {
                        guard !stopped else { return }
                        if ChannelPolicy.isArchived(channelID: op.channelID, channels: channels, threadParents: threadParents) { throw OutboxTargetError.archived }
                        op.attachments[i].uploaded = try await client.upload(file: URL(fileURLWithPath: op.attachments[i].localPath), filename: op.attachments[i].filename)
                        try await store.updateOperation(op)
                    }
                    var args: [String: JSONValue] = ["channel_id": .string(op.channelID), "content": .string(op.html), "files": .array(op.attachments.compactMap(\.uploaded)), "client_id": .string(op.id.uuidString)]
                    if op.sendSilently == true { args["send_silently"] = .bool(true) }
                    if let reply = op.replyTo { args["is_reply"] = .bool(true); args["linked_message"] = .string(reply) }
                    try await verifySendTarget(op.channelID)
                    guard !stopped else { return }
                    op.state = .sending; try await store.updateOperation(op); notify()
                    guard !stopped else { return }
                    guard !readOnly else { throw AppError.message("The site is read only. Your queued send is preserved.") }
                    if ChannelPolicy.isRevoked(channelID: op.channelID, revoked: revokedChannels, threadParents: threadParents) { throw OutboxTargetError.accessChanged }
                    if ChannelPolicy.isArchived(channelID: op.channelID, channels: channels, threadParents: threadParents) { throw OutboxTargetError.archived }
                    let result = try await client.rpc("raven.api.raven_message.send_message_with_attachments", arguments: args, mutation: true)
                    let rows = result.array.map(RavenMessage.init(raw:))
                    guard !rows.isEmpty, rows.allSatisfy({ $0.channelID == op.channelID && $0.owner == account.user && $0.batchID == op.id.uuidString }) else {
                        op.state = .needsReview; op.error = StatusLocalization.text(.outboxAcknowledgementReview); try await store.updateOperation(op); continue
                    }
                    try await store.acknowledge(id: op.id, messages: rows)
                    if !retainHistory { memoryMessages[op.channelID, default: []].append(contentsOf: rows); try await store.clearHistory(); clearMessageDocuments() }
                } catch {
                    guard !stopped else { return }
                    op.state = .retryable
                    if error is OutboxTargetError { op.state = .needsReview }
                    if let e = error as? RavenError, e.isPermanent { op.state = .rejected }
                    op.error = StatusLocalization.errorDescription(error)
                    // Undo may have won while an unclaimed attachment send
                    // awaited preflight. Its terminal row takes precedence.
                    guard try await store.updateOperation(op) else { continue }
                    fail(error); continue
                }
            }
            for visit in try await store.visitSnapshots() {
                let channel = visit.channelID, timestamp = visit.timestamp
                if intentionallyUnread.contains(channel) { continue }
                let result = try await client.rpc("raven.api.raven_channel_member.track_visit", arguments: ["channel_id": .string(channel), "last_visit": .string(timestamp)], mutation: true)
                if result.bool { try await store.completeVisit(channelID: channel, timestamp: timestamp, generation: visit.generation) }
            }
        } catch { fail(error) }
    }
    func cachedMessages(channelID: String, limit: Int = 500) async throws -> [RavenMessage] {
        var merged: [String: RavenMessage] = [:]
        if retainHistory || demo { for row in try await store.messages(channelID: channelID, limit: limit) { merged[row.id] = row } }
        for row in memoryMessages[channelID] ?? [] { merged[row.id] = row }
        return Array(merged.values.sorted(by: Self.order).suffix(limit))
    }
    func markSeen(channelID: String, timestamp: String) async {
        if let demoWire { demoWire.markSeen(channelID: channelID, timestamp: timestamp); return }
        guard !stopped, !demo, !readOnly, !intentionallyUnread.contains(channelID),
              ServerTimestampParser(siteTimeZone: .gmt).date(from: timestamp) != nil,
              timestamp > (lastSeen[channelID] ?? "") else { return }
        lastSeen[channelID] = timestamp
        do { try await store.pendingVisit(channelID: channelID, timestamp: timestamp); await flush() } catch { fail(error) }
    }
    func markUnread(channelID: String) async throws {
        intentionallyUnread.insert(channelID)
        lastSeen.removeValue(forKey: channelID)
        transcriptChannelState.removeVisit(for: channelID)
        // Let an already transmitted visit settle before the explicit backward mutation.
        while flushing { try await Task.sleep(for: .milliseconds(25)) }
        try await store.markUnread(channelID: channelID)
        _ = try await client.rpc("raven.api.raven_channel_member.mark_channel_as_unread", arguments: ["channel_id": .string(channelID)], mutation: true)
        try await refresh()
    }
    func requireWritableConversation(_ channelID: String) async throws {
        guard !demo else { throw AppError.message("Demo mode does not send changes to Raven.") }
        guard !stopped, !readOnly else { throw AppError.message("This account is unavailable or read only. Refresh it before making changes.") }
        if ChannelPolicy.isRevoked(channelID: channelID, revoked: revokedChannels, threadParents: threadParents) { throw AppError.message("Access to this conversation changed.") }
        if ChannelPolicy.isArchived(channelID: channelID, channels: channels, threadParents: threadParents) { throw AppError.message("This conversation or its parent is archived.") }
        do { try await verifySendTarget(channelID) }
        catch OutboxTargetError.archived { throw AppError.message("This conversation or its parent is archived.") }
        catch OutboxTargetError.accessChanged { throw AppError.message("Access to this conversation changed.") }
        catch is AppError { throw AppError.message("Conversation access changed. Refresh this account and try again.") }
        // Canonical preflight suspends; honor local archive invalidations
        // received while awaiting its response as well.
        if ChannelPolicy.isArchived(channelID: channelID, channels: channels, threadParents: threadParents) { throw AppError.message("This conversation or its parent is archived.") }
    }
    private func verifySendTarget(_ channelID: String) async throws {
        let context = try await client.channelWriteContext(channelID)
        guard !stopped, !readOnly, !revokedChannels.contains(channelID) else { throw AppError.message("Conversation access changed. Your queued send is preserved.") }
        let chain = [channelID] + context.parentChannelIDs
        for (child, parent) in zip(chain, chain.dropFirst()) { threadParents[child] = parent }
        if ChannelPolicy.isRevoked(channelID: channelID, revoked: revokedChannels, threadParents: threadParents) { throw OutboxTargetError.accessChanged }
        if let archived = context.archivedChannelID {
            if let index = channels.firstIndex(where: { $0.id == archived }) {
                var fields = channels[index].raw.object; fields["is_archived"] = .bool(true)
                channels[index] = RavenChannel(raw: .object(fields)); notify()
            }
            throw OutboxTargetError.archived
        }
    }
    func mutateResource(_ doctype: String, name: String, values: [String: JSONValue]?, delete: Bool = false) async throws -> JSONValue {
        guard !readOnly, !demo, !stopped else { throw AppError.message("This account is read only.") }
        do { return try await client.resource(doctype, name: name, values: values, delete: delete) }
        catch { try? await refresh(); for channel in Set(interests.values) { try? await load(channelID: channel) }; throw error }
    }
    func mutate(_ method: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard !readOnly, !demo, !stopped else { throw AppError.message("This account is read only.") }
        // Deliberately single attempt. An ambiguous toggle/action must be checked, never replayed.
        do { let value = try await client.rpc(method, arguments: args, mutation: true); notify(); return value }
        catch { try? await refresh(); for channel in Set(interests.values) { try? await load(channelID: channel) }; throw error }
    }
    func loadThumbnail(_ message: RavenMessage) {
        guard message.messageType == "Image", thumbnails[message.id] == nil, !thumbnailRequests.contains(message.id), thumbnailRequests.count < 2,
              let path = message.raw["file"].string, let url = try? RavenAttachmentURL.resolve(path, origin: account.origin),
              SiteOrigin.sameOrigin(url, account.origin), !demo, !stopped else { return }
        thumbnailRequests.insert(message.id)
        Task {
            defer { thumbnailRequests.remove(message.id) }
            do {
                let data = try await client.download(url, maximumBytes: 32 * 1024 * 1024)
                let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard data.count <= 32 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 40_000_000 else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                guard !stopped, let cgImage else { return }
                thumbnails[message.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)); thumbnailOrder.append(message.id)
                while thumbnailOrder.count > 20 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
                notify()
            } catch { /* The named file/Quick Look fallback remains visible. */ }
        }
    }
    /// Shared by the sidebar and transcript. Use the canonical Raven username,
    /// not a display label (notably "You"), so directory refreshes cannot change
    /// a person's generated identity. Rendering a fallback never starts I/O.
    func avatarImage(for userID: String) -> NSImage? {
        guard !stopped, !userID.isEmpty else { return nil }
        if let photo = avatars[userID] { return photo }
        let key = userID as NSString
        if let image = generatedAvatars.object(forKey: key) { return image }
        let image = RavenPortrait.image(named: userID)
        generatedAvatars.setObject(image, forKey: key)
        return image
    }

    /// Channel tiles never consult the user photo cache or start a download.
    /// Name/workspace, rather than row position or read state, determine the art.
    func channelAvatarImage(for channel: RavenChannel) -> NSImage? {
        guard !stopped, !channel.isDM, !channel.raw["is_thread"].bool, !channel.raw["is_archived"].bool else { return nil }
        let name = channel.raw["channel_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? channel.id
        guard !name.isEmpty else { return nil }
        let access: RavenPortrait.ChannelAccess = channel.raw["type"].string == "Private" ? .privateChannel : .standard
        let workspace = channel.workspace
        let key = "\(access.rawValue):\(workspace.utf8.count):\(workspace)\(name)" as NSString
        if let image = generatedChannelAvatars.object(forKey: key) { return image }
        let image = RavenPortrait.channelImage(named: name, workspace: workspace, access: access)
        generatedChannelAvatars.setObject(image, forKey: key)
        return image
    }

    /// Fetches profile photos for `userIDs` one at a time, from this site
    /// only. Each arrival updates transcripts and visible sidebar rows;
    /// generated ravens remain on failure.
    func loadAvatars(_ userIDs: Set<String>) {
        guard !demo, !stopped else { return }
        avatarClock += 1
        for id in userIDs where avatars[id] != nil { avatarLastUse[id] = avatarClock }
        for id in userIDs where avatars[id] == nil && !avatarFailures.contains(id) && !avatarRequests.contains(id) {
            guard let path = directory[id]?["user_image"].string, !path.isEmpty else { continue }
            avatarRequests.insert(id); avatarQueue.append(id)
        }
        guard avatarWorker == nil, !avatarQueue.isEmpty else { return }
        avatarWorker = Task { [weak self] in
            while let self, !self.stopped, !self.avatarQueue.isEmpty {
                let id = self.avatarQueue.removeFirst()
                // A directory reload in progress is not a broken photo; the
                // next render asks again.
                guard let path = self.directory[id]?["user_image"].string, !path.isEmpty else { self.avatarRequests.remove(id); continue }
                let image = await self.fetchAvatar(path)
                guard !self.stopped else { break }
                // A Raven User event can replace the directory during the
                // download. What arrived then is the old photo, or the
                // failure of a file that is gone: neither describes the
                // photo the directory names now.
                let current = self.directory[id]?["user_image"].string ?? ""
                guard current == path else {
                    if current.isEmpty { self.avatarRequests.remove(id) } else { self.avatarQueue.append(id) }
                    continue
                }
                if let image {
                    self.avatars[id] = image; self.avatarLastUse[id] = self.avatarClock
                    // About 64 KB each. The cap exceeds the senders two full
                    // transcripts can show, so eviction never fights a render.
                    if self.avatars.count > 1000, let stale = self.avatarLastUse.min(by: { $0.value < $1.value })?.key {
                        self.avatars.removeValue(forKey: stale); self.avatarLastUse.removeValue(forKey: stale)
                    }
                    NotificationCenter.default.post(name: .sessionAvatarsChanged, object: self)
                } else { self.avatarFailures.insert(id) }
                self.avatarRequests.remove(id)
            }
            self?.avatarWorker = nil
        }
    }
    private func fetchAvatar(_ path: String) async -> NSImage? {
        guard let url = try? RavenAttachmentURL.resolve(path, origin: account.origin),
              SiteOrigin.sameOrigin(url, account.origin), let data = try? await client.download(url, maximumBytes: 4 * 1024 * 1024) else { return nil }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8000, height <= 8000, width * height <= 16_000_000 else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
        return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
    func fail(_ error: Error) {
        guard !stopped, !Task.isCancelled, !(error is CancellationError) else { return }
        state = StatusLocalization.errorDescription(error); setStatusAttention(.accountAttention); notify()
    }
    func stop() { stopped = true; sentLinkPreviews.reset(); transcriptChannelState.removeAll(); clearMessageDocuments(); timestampEnvironmentObservation = nil; setStatusAttention(nil); threadParents.removeAll(); roles.removeAll(); unreadNotificationIDs.removeAll(); (NSApp.delegate as? AppDelegate)?.updateDockBadge(); pendingFileReceipts.removeAll(); userPreferences = nil; directory.removeAll(); userNames.removeAll(); activeUsers.removeAll(); workingHours = nil; thumbnails.removeAll(); avatars.removeAll(); generatedAvatars.removeAllObjects(); generatedChannelAvatars.removeAllObjects(); avatarLastUse.removeAll(); avatarQueue.removeAll(); avatarRequests.removeAll(); avatarWorker?.cancel(); memoryMessages.removeAll(); generation += 1; refreshTask?.cancel(); reconciliationTask?.cancel(); realtime?.disconnect(); realtime = nil }
    private func shouldDeliverNotification(channelID: String) -> Bool {
        guard !stopped, !revokedChannels.contains(channelID),
              let channel = channels.first(where: { $0.id == channelID }),
              !ChannelPolicy.isArchived(channelID: channelID, channels: channels, threadParents: threadParents), !channel.raw["muted"].bool,
              channel.raw["allow_notifications"] == .null || channel.raw["allow_notifications"].bool else { return false }
        let controller = (NSApp.keyWindow?.windowController ?? NSApp.keyWindow?.sheetParent?.windowController) as? ConversationWindow
        let reading = NSApp.isActive && controller?.session === self && (controller?.channel?.id == channelID || controller?.threadInspector?.rootMessage.id == channelID)
        return NotificationPolicy.shouldNotify(now: Date(), quietHours: NotificationPreferenceStore.quietHours(accountID: account.id), isForeground: reading, enabled: UserDefaults.standard.bool(forKey: "notifications"), muted: userPreferences?.availabilityStatus == "Do not disturb")
    }
    func deliverNotification(channelID: String) async {
        guard shouldDeliverNotification(channelID: channelID) else { return }
        do {
            let result = try await client.rpc("raven.api.chat_stream.get_messages", arguments: ["channel_id": .string(channelID), "limit": .number(1), "update_last_visit": .bool(false)])
            guard let raw = result["messages"].array.first else { return }
            let message = RavenMessage(raw: raw)
            let notificationID = message.batchID ?? message.id
            guard message.channelID == channelID, message.owner != account.user, !notifiedIDs.contains(notificationID), shouldDeliverNotification(channelID: channelID) else { return }
            notifiedIDs.insert(notificationID); if notifiedIDs.count > 1000 { notifiedIDs = [notificationID] }
            let content = UNMutableNotificationContent()
            content.title = account.displayName.isEmpty ? account.user : account.displayName
            content.body = "New activity in Raven"
            content.userInfo = ["account": account.id.uuidString, "channel": channelID, "message": message.id]
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(account.id)-\(notificationID)", content: content, trigger: nil))
        } catch { /* Notifications are hints. They never mark history read or expose a failed fetch. */ }
    }

}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
