import AppKit
import RavenProtocol
import NevermoreCore
// See App.swift: UNNotification* are non-Sendable before newer SDKs.
@preconcurrency import UserNotifications
import ImageIO

extension Notification.Name {
    static let sessionChanged = Notification.Name("NevermoreSessionChanged")
    static let draftChanged = Notification.Name("NevermoreDraftChanged")
    /// `AccountSession.draftChannelIDs` gained or lost a conversation.
    static let sessionDraftMarksChanged = Notification.Name("NevermoreSessionDraftMarksChanged")
    static let sessionStatusAttentionChanged = Notification.Name("NevermoreSessionStatusAttentionChanged")
    /// A profile photo arrived; transcripts redraw without re-rendering.
    static let sessionAvatarsChanged = Notification.Name("NevermoreSessionAvatarsChanged")
    /// Someone became active or inactive. Presence shows on sidebar rows,
    /// Home and People results, never in a transcript, so it does not post
    /// `sessionChanged`, which re-renders every open transcript.
    static let sessionPresenceChanged = Notification.Name("NevermoreSessionPresenceChanged")
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
    /// Reads used by history loads and membership refreshes. Self-checks
    /// substitute deterministic responses; production calls go to the
    /// account's client.
    var readRPC: (@MainActor (String, [String: JSONValue]) async throws -> JSONValue)?
    var channels: [RavenChannel] = []
    /// Bumped whenever `channels` is replaced, so mention pools and other
    /// channel-derived caches can invalidate without rebuilding per keystroke.
    var channelsVersion = 0
    var userNames: [String: String] = [:]
    var directory: [String: JSONValue] = [:]
    /// Bumped whenever the user directory is replaced or cleared.
    var directoryVersion = 0
    var workingHours: RavenQuietHoursConfig?
    var userPreferences: RavenUserPreferences?
    var roles = Set<String>()
    var favoriteIDs: Set<String> { Set(userPreferences?.raw["pinned_channels"].array.compactMap { $0["channel_id"].string } ?? []) }
    var activeUsers = Set<String>()
    var lastPresenceRefresh = Date.distantPast
    var lastPresenceAttempt = Date.distantPast
    var presenceUnavailable = false
    /// When the last presence refusal arrived. A refusal is a circuit
    /// breaker, not a life sentence: after this delay one request may
    /// retry, so a transient 403/404 self-heals without a per-minute storm.
    var presenceFailedAt: Date?
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
    /// Per-channel authorization epochs. A load captures its channel's epoch
    /// before requesting history. Revoking or restoring a channel advances
    /// its epoch, and the epochs of threads under it, so an in-flight response
    /// cannot publish a page that is no longer authorized and a denial cannot
    /// purge a channel that is authorized again.
    private var historyWrite: Task<Void, Error>?
    private var channelAccessEpochs: [String: Int] = [:]
    var deletedIDs = Set<String>() {
        didSet { if deletedIDs.count > oldValue.count || !deletedIDs.isSubset(of: oldValue) { clearMessageDocuments(); pruneTranscriptChannelState() } }
    }
    var revokedChannels = Set<String>() {
        didSet {
            let added = revokedChannels.subtracting(oldValue)
            let removed = oldValue.subtracting(revokedChannels)
            guard !added.isEmpty || !removed.isEmpty else { return }
            clearMessageDocuments()
            pruneTranscriptChannelState()
            for id in historyChannels(under: added.union(removed)) {
                channelAccessEpochs[id, default: 0] += 1
            }
            // A revocation withdraws private content from memory at once; the
            // durable purge belongs to the caller that owns the store write.
            for id in historyChannels(under: added) { memoryMessages.removeValue(forKey: id) }
            // Rooms follow access both ways: a conversation whose access
            // returns while a window shows it joins its room again, instead
            // of staying silent until the socket reconnects.
            updateRooms()
        }
    }
    var flushing = false
    var lastSeen: [String: String] = [:]
    private struct VisitObservation: Hashable {
        let timestamp: String
        let generation: Int
    }
    /// Main-actor state shared by outstanding writes to a channel. Mark as
    /// Unread advances the generation without losing track of writes that
    /// still need to drain, even if the user cancels and tries again.
    private final class VisitWrites {
        var generation = 0
        var observations = Set<VisitObservation>()
    }
    private var pendingVisitWrites: [String: VisitWrites] = [:]
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
    /// Frames of animated images (GIF uploads and GIFs embedded in message
    /// bodies), by `AnimatedImageKey`. Thumbnails keep the first frame.
    let animatedImages = AnimatedImageCache()
    /// Where each animated image came from, so one the cache let go can be
    /// decoded again when it is shown.
    var animatedSources: [String: URL] = [:]
    var animatedRequests = Set<String>()
    /// Fetches GIFs embedded in message bodies from GIF services, without
    /// Raven credentials. Self-checks substitute a fixture.
    var gifMedia: any GIFMediaLoading = LinkPreviewLoader()
    /// When an animated image last failed to load, by key; it is retried
    /// after a while. A GIF embedded in a message shows its text meanwhile,
    /// an uploaded one its still.
    var inlineImageFailures: [String: Date] = [:]
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
    /// Home's server modules; see `HomeFeed`.
    lazy var home = HomeFeed(session: self)
    /// Every window shares message snapshots, so refresh coverage must include
    /// toggles accepted from any window, not only the one asking for a reload.
    private(set) var reactionsAccepted = 0
    var retainHistory: Bool { UserDefaults.standard.object(forKey: "retainHistory") as? Bool != false }
    var stopped = false
    var refreshTask: Task<Void, Never>?
    var reconciliationTask: Task<Void, Never>?
    var reconcileRequested = false
    /// Internal rather than private so the self-check can pin the live tick.
    var lastLiveRefresh = Date()
    var notificationChannels = Set<String>()
    /// Messages and batches already notified, newest kept.
    var notifiedIDs = RecentIdentifiers(capacity: 1000)
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
    private func read(_ method: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        if let readRPC { return try await readRPC(method, arguments) }
        return try await client.rpc(method, arguments: arguments)
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
        // A deletion or revocation already cleared the cache when it was
        // recorded. Looking up a deleted row must not drop every other
        // conversation's parsed documents and force them to parse again.
        guard !stopped, !deletedIDs.contains(message.id), !deletedIDs.contains(message.channelID),
              !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: revokedChannels, threadParents: threadParents) else {
            return .failed
        }
        return messageDocuments.document(channelID: message.channelID, messageID: message.id, html: message.html)
    }
    func clearMessageDocuments() { messageDocuments.removeAll() }
    private func channelAccessEpoch(_ channelID: String) -> Int { channelAccessEpochs[channelID, default: 0] }
    func channelIsRevoked(_ channelID: String) -> Bool {
        ChannelPolicy.isRevoked(channelID: channelID, revoked: revokedChannels, threadParents: threadParents)
    }
    private func historyChannels(under roots: Set<String>) -> Set<String> {
        guard !roots.isEmpty else { return [] }
        return roots.union(threadParents.keys.filter {
            ChannelPolicy.isRevoked(channelID: $0, revoked: roots, threadParents: threadParents)
        })
    }
    /// Keep a purge in order with earlier and later page writes across actor
    /// suspensions. A successful rejoin can then safely publish fresh history.
    private func writeHistory(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = historyWrite
        let next = Task { @MainActor in
            _ = await previous?.result
            try await operation()
        }
        historyWrite = next
        try await next.value
    }
    /// True while a load's captured generation and channel epoch still
    /// describe a channel whose history it may publish.
    private func loadCanPublish(_ channelID: String, epoch: Int, access: Int) -> Bool {
        !stopped && epoch == generation && access == channelAccessEpoch(channelID) && !channelIsRevoked(channelID)
    }
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
        let retryAvailable = !presenceUnavailable || now.timeIntervalSince(presenceFailedAt ?? .distantPast) >= Self.presenceRetryDelay
        guard !demo, !stopped, !readOnly, retryAvailable, NSApp.isActive, now.timeIntervalSince(lastPresenceAttempt) >= 60 else { return }
        guard userPreferences?.availabilityStatus != "Invisible" else { return }
        lastPresenceAttempt = now
        Task {
            do { _ = try await client.rpc("raven.api.user_availability.refresh_user_active_state", arguments: ["deactivate": .bool(false)], mutation: true); presenceUnavailable = false; presenceFailedAt = nil }
            catch { if let failure = error as? RavenError, failure.isPermissionDenied || failure == .http(404, nil) { presenceUnavailable = true; presenceFailedAt = Date() } }
        }
        // The server expires activity after 15 minutes. Do not send a global
        // deactivate on sleep/quit: that would also erase this user's phone activity.
    }
    func reauthenticate(clientID: String, tokens: OAuthTokens) async throws {
        await client.invalidate()
        try KeychainTokenStore.save(tokens, accountID: account.id)
        generation += 1; presenceUnavailable = false; presenceFailedAt = nil; account.clientID = clientID
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
            await loadDraftMarks()
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
                self.reconciliationTick(now: Date())
            }
        }
    }
    func reconciliationTick(now: Date) {
        guard !demo, !stopped else { return }
        guard !interests.isEmpty || !notificationChannels.isEmpty else { return }
        if !realtimeLive {
            requestReconciliation()
        } else if now.timeIntervalSince(lastLiveRefresh) >= 60 {
            // A "live" socket can silently stop delivering (a rejected room
            // join emits nothing, and a wedged transport may not fault).
            // Reconcile open conversations and notification state every
            // minute regardless of app focus so state can never go stale
            // indefinitely.
            requestReconciliation()
            lastLiveRefresh = now
        }
    }
    func refresh() async throws {
        guard !stopped else { return }
        let boot = try await read("raven.api.native.boot")
        guard !stopped else { return }
        readOnly = boot["read_only"].bool
        roles = Set(boot["user"]["roles"].array.compactMap(\.string))
        workingHours = boot["quiet_hours"] == .null ? nil : RavenQuietHoursConfig(raw: boot["quiet_hours"])
        if userPreferences == nil, let raw = try? await read("raven.api.raven_users.get_current_raven_user"), raw["user"].string == account.user || raw["name"].string == account.user { userPreferences = RavenUserPreferences(raw: raw) }
        if userNames.isEmpty, let directory = try? await read("raven.api.raven_users.get_list") {
            for user in directory.array { if let id = user["name"].string { userNames[id] = user["full_name"].string ?? id; self.directory[id] = user } }
            directoryVersion += 1
        }
        if Date().timeIntervalSince(lastPresenceRefresh) >= 60,
           !presenceUnavailable || Date().timeIntervalSince(presenceFailedAt ?? .distantPast) >= Self.presenceRetryDelay {
            lastPresenceRefresh = Date()
            do {
                let active = try await read("raven.api.user_availability.get_active_users")
                if let users = PresenceRead.activeUsers(from: active) { activeUsers = users }
                presenceUnavailable = false; presenceFailedAt = nil
            } catch {
                if let failure = error as? RavenError, failure.isPermissionDenied || failure == .http(404, nil) {
                    presenceUnavailable = true; presenceFailedAt = Date()
                }
            }
        }
        let value = try await read("raven.api.raven_channel.get_all_channels", ["hide_archived": .bool(false)])
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
        // Thread rooms follow their parent's access: a thread whose parent is
        // revoked is not allowed, even though its own history endpoint is
        // separately authorized.
        let threads = Set(interests.values).subtracting(channels.map(\.id))
        let revoked = Set(channels.map(\.id)).subtracting(allowed)
        revokedChannels.formUnion(revoked); revokedChannels.subtract(allowed)
        if !revoked.isEmpty { generation += 1; thumbnails.removeAll(); thumbnailOrder.removeAll(); forgetAnimatedImages() }
        let permitted = allowed.union(threads.filter { !channelIsRevoked($0) })
        let withdrawn = historyChannels(under: revoked)
        try await writeHistory { [store] in
            try await store.removeRevokedChannels(allowed: permitted, withdrawnHistory: withdrawn)
            try await store.cacheChannels(items)
        }
        guard !stopped else { return }
        channels = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        channelsVersion += 1
        // Failed and malformed snapshots leave the last known values intact.
        if case let .array(counts)? = try? await read("raven.api.raven_message.get_unread_count_for_channels"),
           counts.allSatisfy({ row in
               guard let id = row["name"].string, !id.isEmpty, case .number(let count) = row["unread_count"] else { return false }
               return count.isFinite && count >= 0
           }) {
            unread = .array(counts)
        }
        guard !stopped else { return }
        if let response = try? await read("raven.api.notifications.get_unread_notification_message_ids") {
            if case let .array(ids) = response, ids.allSatisfy({ $0.string?.isEmpty == false }) {
                unreadNotificationIDs = Set(ids.compactMap(\.string))
            }
        } else if !stopped, case let .array(rows)? = try? await read("raven.api.notifications.get_notifications", ["unread_only": .bool(true), "limit": .number(100)]) {
            // Older deployments expose only the inbox page. Its message_id
            // identifies the underlying message for both notification types.
            unreadNotificationIDs = Set(rows.compactMap { $0["message_id"].string })
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
    func updateRooms() { realtime?.setChannels(Set(interests.values.filter { !channelIsRevoked($0) })) }
    func event(_ name: String, _ payload: JSONValue) {
        if name == "raven:user_active_state_updated", let user = payload["user"].string {
            let changed = payload["active"].bool ? activeUsers.insert(user).inserted : activeUsers.remove(user) != nil
            if changed { NotificationCenter.default.post(name: .sessionPresenceChanged, object: self) }
            return
        }
        if payload["doctype"].string == "Raven User" { userNames.removeAll(); directory.removeAll(); directoryVersion += 1; userPreferences = nil; avatars.removeAll(); avatarLastUse.removeAll(); avatarFailures.removeAll(); avatarRequests.subtract(avatarQueue); avatarQueue.removeAll() }
        // A live socket is the evidence an earlier 403/404 is stale, so
        // presence refreshes resume without waiting for a re-login.
        if name == "connect" { realtimeLive = true; avatarFailures.removeAll(); presenceUnavailable = false; presenceFailedAt = nil; updateRooms(); state = readOnly ? StatusLocalization.text(.maintenance) : StatusLocalization.text(.live) }
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
        let access = channelAccessEpoch(channelID)
        var args: [String: JSONValue] = ["channel_id": .string(channelID), "limit": .number(100), "update_last_visit": .bool(false)]
        var method = "raven.api.chat_stream.get_messages"
        if let olderThan { method = "raven.api.chat_stream.get_older_messages"; args["from_message"] = .string(olderThan); args.removeValue(forKey: "update_last_visit") }
        if let anchor { args["base_message"] = .string(anchor) }
        do {
            let result = try await read(method, args)
            guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
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
            // Recheck at the storage boundary: a revocation while the durable
            // page was read must not be followed by this page's commits.
            guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
            if olderThan != nil, transcriptChannelIsEligible(channelID) {
                recordHistoricalMessageIDs(rows.map(\.id), channelID: channelID)
            }
            try await writeHistory { [self] in
                guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
                if olderThan == nil && anchor == nil {
                    let existing = try await store.messages(channelID: channelID, limit: 5000)
                    guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
                    let absent = MessageReconciliation.observedDeletions(existing: existing, snapshot: rows, channelID: channelID, authoritative: true)
                    if !absent.isEmpty {
                        try await store.deleteMessages(ids: absent)
                        guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
                        clearMessageDocuments()
                        let removed = Set(absent)
                        memoryMessages[channelID]?.removeAll { removed.contains($0.id) }
                    }
                }
                if retainHistory { try await store.cacheMessages(rows) }
            }
            guard loadCanPublish(channelID, epoch: epoch, access: access) else { return }
            var merged = Dictionary(uniqueKeysWithValues: (memoryMessages[channelID] ?? []).map { ($0.id, $0) })
            for row in rows { merged[row.id] = row }
            let ordered = merged.values.sorted(by: Self.order)
            memoryMessages[channelID] = olderThan == nil ? Array(ordered.suffix(1500)) : Array(ordered.prefix(1500))
            notify()
        } catch {
            // Only a denial from the current authorization epoch is
            // authoritative. A stale denial must not purge a channel that has
            // since been authorized again.
            if let e = error as? RavenError, e.isPermissionDenied {
                guard !stopped, access == channelAccessEpoch(channelID) else { throw error }
                revokedChannels.insert(channelID)
                thumbnails.removeAll(); forgetAnimatedImages(); updateRooms()
                let targets = historyChannels(under: [channelID])
                let deniedAccess = channelAccessEpoch(channelID)
                notify()
                try await writeHistory { [self] in
                    guard !stopped, channelAccessEpoch(channelID) == deniedAccess, channelIsRevoked(channelID) else { return }
                    try await store.withdrawHistory(channelIDs: targets.filter { channelIsRevoked($0) })
                }
            }
            throw error
        }
    }
    static func order(_ a: RavenMessage, _ b: RavenMessage) -> Bool { MessageReconciliation.ordered(a, b) }
    /// Clear only the scheduled revision. A failed cleanup keeps that
    /// original draft in the same recovery path as a failed editor save.
    func clearScheduledDraft(_ original: Draft, revision: Int) async throws -> Bool {
        let id = original.channelID
        guard !stopped, draftRevisions[id, default: 0] == revision else { return false }
        let clearingRevision = revision + 1
        draftRevisions[id] = clearingRevision
        do {
            try await save(Draft(channelID: id), revision: clearingRevision)
        } catch {
            if !stopped, draftRevisions[id] == clearingRevision { recoverableDrafts[id] = original }
            throw error
        }
        return !stopped && draftRevisions[id] == clearingRevision
    }

    /// Conversations whose saved draft holds text or files, for the
    /// sidebar's pencil. Filled from the store at start, then kept in step
    /// one conversation at a time as drafts change.
    private(set) var draftChannelIDs = Set<String>() {
        didSet { if draftChannelIDs != oldValue { NotificationCenter.default.post(name: .sessionDraftMarksChanged, object: self) } }
    }
    /// The newest read per conversation; an older read that finishes late
    /// must not undo a newer one.
    private var draftMarkReads: [String: Int] = [:]

    /// - Parameter saved: the draft now in the store, when the caller has it;
    ///   otherwise the store is read. Saves pass it, as they run per keystroke.
    private func draftDidChange(_ channelID: String, saved: Draft? = nil) {
        NotificationCenter.default.post(name: .draftChanged, object: self, userInfo: ["channel": channelID])
        let read = draftMarkReads[channelID, default: 0] + 1
        draftMarkReads[channelID] = read
        if let saved {
            if Self.holdsContent(saved) { draftChannelIDs.insert(channelID) } else { draftChannelIDs.remove(channelID) }
            return
        }
        Task { [weak self] in
            guard let self, !self.stopped else { return }
            let draft: Draft?
            do { draft = try await self.store.draft(channelID: channelID) }
            catch { return } // A failed read changes nothing; the next draft change reconciles.
            guard !self.stopped, self.draftMarkReads[channelID] == read else { return }
            if let draft, Self.holdsContent(draft) { self.draftChannelIDs.insert(channelID) } else { self.draftChannelIDs.remove(channelID) }
        }
    }

    func loadDraftMarks() async {
        guard let drafts = try? await store.drafts(), !stopped else { return }
        draftChannelIDs = Set(drafts.filter(Self.holdsContent).map(\.channelID))
    }

    /// Text, or staged files without text. A draft that cannot be parsed
    /// still holds something the reader wrote.
    static func holdsContent(_ draft: Draft) -> Bool {
        !draft.attachments.isEmpty || ((try? ConversationWindow.hasText(draft)) ?? true)
    }

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
        draftDidChange(draft.channelID, saved: draft)
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
        draftDidChange(draft.channelID)
        notify()
        if let demoWire { demoWire.deliver() } else { Task { await flush() } }
        return accepted
    }
    /// Sends a GIF picked in a conversation as its own message, through the
    /// outbox like a typed message, so it survives a lost connection and
    /// shows at once. The conversation's draft stays as it is.
    @discardableResult func sendGIF(_ item: GIFItem, channelID: String, replyTo: String?, sendSilently: Bool = false) async throws -> SendOperation {
        guard !stopped else { throw AppError.message("This account is no longer active.") }
        guard !demo || demoWire != nil else { throw AppError.message("Demo mode does not send messages. Add a Raven account to chat.") }
        guard !readOnly, !ChannelPolicy.isRevoked(channelID: channelID, revoked: revokedChannels, threadParents: threadParents) else { throw AppError.message("This conversation is read only or access changed.") }
        guard !ChannelPolicy.isArchived(channelID: channelID, channels: channels, threadParents: threadParents) else { throw OutboxTargetError.archived }
        let accepted = try await store.acceptGIF(channelID: channelID, html: GIFMessage.html(for: item), replyTo: replyTo, sendSilently: sendSilently)
        notify()
        if let demoWire { demoWire.deliver() } else { Task { await flush() } }
        return accepted
    }
    /// Raven's idempotent send refuses a body without text, so a GIF goes
    /// through `send_message`, which has no client ID. A lost answer may
    /// still have been delivered, so the caller parks an uncertain attempt
    /// for review instead of replaying it; a deliberate retry posts again.
    private func deliverGIF(_ operation: SendOperation) async throws -> RavenMessage? {
        var args: [String: JSONValue] = ["channel_id": .string(operation.channelID), "text": .string(operation.html)]
        if operation.sendSilently == true { args["send_silently"] = .bool(true) }
        if let reply = operation.replyTo { args["is_reply"] = .bool(true); args["linked_message"] = .string(reply) }
        let row = Self.gifRow(try await client.rpc("raven.api.raven_message.send_message", arguments: args, mutation: true))
        guard !row.id.isEmpty, row.channelID == operation.channelID, row.owner == account.user,
              GIFMessage.source(in: row.html) == GIFMessage.source(in: operation.html),
              Self.replyTarget(in: row) == operation.replyTo else { return nil }
        return row
    }
    /// The reply a message row answers, if any. An empty field is no reply.
    private static func replyTarget(in row: RavenMessage) -> String? {
        row.raw["linked_message"].string.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// A message from `send_message`. These sends have no batch, and an
    /// empty batch field would read as another send's.
    private static func gifRow(_ value: JSONValue) -> RavenMessage {
        var fields = value.object
        if fields["message_batch_id"]?.string?.isEmpty == true { fields.removeValue(forKey: "message_batch_id") }
        return RavenMessage(raw: .object(fields))
    }
    /// Cancels a queued GIF that was never attempted. A GIF never was the
    /// draft, so the composer and its draft stay as they are. Nil when the
    /// GIF has already left.
    func takeBackGIF(id: UUID) async throws -> SendOperation? {
        guard !stopped else { throw AppError.message("This account is no longer active.") }
        guard let taken = try await store.takeBack(id: id) else { return nil }
        notify()
        return taken
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
        case .cancelled(let cancelled): return cancelled
        }
        guard !stopped else { return operation }
        // UI edits are disabled while reserved. Preserve even a programmatic
        // newer edit rather than clearing its recovery state on completion.
        guard draftRevisions[channelID, default: 0] == revision else {
            throw AppError.message("The message was taken back, but a newer draft is still in the editor. Review it before sending.")
        }
        draftRevisions[channelID, default: 0] += 1
        draftPersistenceFailures.removeValue(forKey: channelID)
        draftDidChange(channelID)
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
                    if op.isGIF {
                        try await verifySendTarget(op.channelID)
                        guard !stopped else { return }
                        op.state = .sending; try await store.updateOperation(op); notify()
                        guard !readOnly else { throw AppError.message("The site is read only. Your queued send is preserved.") }
                        if ChannelPolicy.isRevoked(channelID: op.channelID, revoked: revokedChannels, threadParents: threadParents) { throw OutboxTargetError.accessChanged }
                        if ChannelPolicy.isArchived(channelID: op.channelID, channels: channels, threadParents: threadParents) { throw OutboxTargetError.archived }
                        let row: RavenMessage?
                        do {
                            row = try await deliverGIF(op)
                        } catch {
                            // The plain GIF POST may have reached the server.
                            // A permanent refusal certainly was not delivered;
                            // anything else waits for a deliberate review.
                            guard !stopped else { return }
                            let refused = (error as? RavenError)?.definitivelyRefusedMutation == true
                            op.state = refused ? .rejected : .needsReview
                            op.error = refused ? StatusLocalization.errorDescription(error) : StatusLocalization.text(.outboxGifReview)
                            try await store.updateOperation(op)
                            fail(error)
                            continue
                        }
                        guard let row else {
                            op.state = .needsReview; op.error = StatusLocalization.text(.outboxGifReview); try await store.updateOperation(op); continue
                        }
                        try await store.acknowledge(id: op.id, messages: [row])
                        if !retainHistory { memoryMessages[op.channelID, default: []].append(row); try await store.clearHistory(); clearMessageDocuments() }
                        continue
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
    func cachedMessage(id: String, channelID: String) async throws -> RavenMessage? {
        if let row = memoryMessages[channelID]?.last(where: { $0.id == id }) { return row }
        guard retainHistory || demo else { return nil }
        let stored = try await store.message(id: id, channelID: channelID)
        // An in-memory edit may have arrived while the disk read was suspended.
        return memoryMessages[channelID]?.last(where: { $0.id == id }) ?? ((retainHistory || demo) ? stored : nil)
    }

    func markSeen(channelID: String, timestamp: String) async {
        if let demoWire { demoWire.markSeen(channelID: channelID, timestamp: timestamp); return }
        guard !stopped, !demo, !readOnly, !intentionallyUnread.contains(channelID),
              ServerTimestampParser(siteTimeZone: .gmt).date(from: timestamp) != nil,
              timestamp > (lastSeen[channelID] ?? "") else { return }
        let writes = pendingVisitWrites[channelID] ?? VisitWrites()
        let observation = VisitObservation(timestamp: timestamp, generation: writes.generation)
        guard writes.observations.insert(observation).inserted else { return }
        pendingVisitWrites[channelID] = writes
        defer {
            writes.observations.remove(observation)
            if writes.observations.isEmpty, pendingVisitWrites[channelID] === writes {
                pendingVisitWrites.removeValue(forKey: channelID)
            }
        }
        do {
            try await store.pendingVisit(channelID: channelID, timestamp: timestamp)
            guard !stopped, writes.generation == observation.generation else { return }
            lastSeen[channelID] = max(lastSeen[channelID] ?? "", timestamp)
            await flush()
        } catch { fail(error) }
    }
    func markUnread(channelID: String) async throws {
        intentionallyUnread.insert(channelID)
        let earlierWrites = pendingVisitWrites[channelID]
        let priorGeneration = earlierWrites?.generation ?? 0
        earlierWrites?.generation += 1
        lastSeen.removeValue(forKey: channelID)
        transcriptChannelState.removeVisit(for: channelID)
        // Drain earlier local writes as well as transmitted visits before the
        // backwards mutation. Their completions cannot repopulate lastSeen.
        let deadline = ContinuousClock.now + .seconds(5)
        while flushing || earlierWrites?.observations.contains(where: { $0.generation <= priorGeneration }) == true {
            guard !stopped else { throw CancellationError() }
            guard ContinuousClock.now < deadline else {
                throw AppError.message("The read receipt is still syncing. Try again to mark this conversation unread.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !stopped else { throw CancellationError() }
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
        let generation = self.generation
        Task {
            defer { thumbnailRequests.remove(message.id) }
            do {
                let data = try await client.download(url, maximumBytes: Self.imageDownloadBytes)
                let decoded = await Task.detached(priority: .utility) { () -> (CGImage, AnimatedImage?)? in
                    guard data.count <= Self.imageDownloadBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 40_000_000,
                          let still = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                    // Only an image with several frames keeps them all.
                    let animated = CGImageSourceGetCount(source) > 1 ? Self.decodeAnimated(data) : nil
                    return (still, animated)
                }.value
                // A conversation whose access was lost keeps none of its images.
                guard !stopped, let (still, animated) = decoded,
                      !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: revokedChannels, threadParents: threadParents) else { return }
                thumbnails[message.id] = NSImage(cgImage: still, size: NSSize(width: still.width, height: still.height)); thumbnailOrder.append(message.id)
                while thumbnailOrder.count > 20 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
                if let animated, self.generation == generation {
                    let key = AnimatedImageKey.message(message.id)
                    animatedSources[key] = url
                    animatedImages.insert(animated, for: key)
                }
                notify()
            } catch { /* The named file/Quick Look fallback remains visible. */ }
        }
    }
    nonisolated static let imageDownloadBytes = 32 * 1024 * 1024
    /// Animated frames are decoded for the transcript's largest image, 320
    /// points, on a Retina display.
    nonisolated static let animatedPixelSide = 640
    nonisolated static func decodeAnimated(_ data: Data) -> AnimatedImage? {
        var limits = AnimatedImageDecoder.Limits.standard
        limits.encodedBytes = imageDownloadBytes
        guard let image = AnimatedImageDecoder.decode(data, maxPixelSide: animatedPixelSide, limits: limits), image.isAnimated else { return nil }
        return image
    }
    /// Decodes an animated image again after the cache let it go, when the
    /// transcript shows it.
    func requestAnimatedImage(_ key: String) {
        guard let url = animatedSources[key] else { return }
        if key == AnimatedImageKey.remote(url) { requestInlineImage(url); return }
        // A file that failed is not asked for again on every scroll; its still stays.
        guard !animatedImages.contains(key), !animatedRequests.contains(key), animatedRequests.count < 2, !demo, !stopped,
              inlineImageFailures[key].map({ Date().timeIntervalSince($0) >= Self.inlineImageRetryDelay }) ?? true else { return }
        animatedRequests.insert(key)
        let generation = self.generation
        Task {
            defer { animatedRequests.remove(key) }
            let data = try? await client.download(url, maximumBytes: Self.imageDownloadBytes)
            let image = await Task.detached(priority: .utility) { data.flatMap(Self.decodeAnimated) }.value
            // Sources forgotten meanwhile, as when access is lost, take
            // what was fetched for them along.
            guard !stopped, self.generation == generation, animatedSources[key] == url else { return }
            guard let image else { inlineImageFailures[key] = Date(); return }
            inlineImageFailures.removeValue(forKey: key)
            animatedImages.insert(image, for: key)
            notify()
        }
    }
    /// Drops decoded GIFs and their addresses; fetches still under way
    /// then keep nothing.
    func forgetAnimatedImages() { animatedImages.removeAll(); animatedSources.removeAll(); inlineImageFailures.removeAll() }
    static let inlineImageRetryDelay: TimeInterval = 300
    /// How long a presence refusal is respected before one retry.
    static let presenceRetryDelay: TimeInterval = 300
    /// Whether a GIF embedded in a message failed recently; it then shows
    /// its text fallback.
    func inlineImageFailed(_ url: URL) -> Bool {
        inlineImageFailures[AnimatedImageKey.remote(url)].map { Date().timeIntervalSince($0) < Self.inlineImageRetryDelay } ?? false
    }
    /// Names the address of a GIF embedded in a message body, so the
    /// transcript can ask for it by key once it comes into view.
    func noteInlineImage(_ url: URL) { animatedSources[AnimatedImageKey.remote(url)] = url }
    /// Loads a GIF embedded in a message body. The address must be a GIF
    /// service's (`GIFMediaPolicy`); the request carries no Raven
    /// credentials and goes through the link preview transport's checks.
    private func requestInlineImage(_ url: URL) {
        let key = AnimatedImageKey.remote(url)
        guard GIFMediaPolicy.isServiceMedia(url), !animatedImages.contains(key), !animatedRequests.contains(key), animatedRequests.count < 4,
              !inlineImageFailed(url), !stopped else { return }
        animatedRequests.insert(key)
        animatedSources[key] = url
        let generation = self.generation, loader = gifMedia
        Task {
            defer { animatedRequests.remove(key) }
            let data = await loader.mediaData(for: url)
            let image = await Task.detached(priority: .utility) { data.flatMap(Self.decodeInlineImage) }.value
            guard !stopped, self.generation == generation, animatedSources[key] == url else { return }
            if let image { animatedImages.insert(image, for: key); inlineImageFailures.removeValue(forKey: key) }
            else { inlineImageFailures[key] = Date() }
            notify()
        }
    }
    /// A still GIF decodes to one frame and is shown like any other.
    nonisolated static func decodeInlineImage(_ data: Data) -> AnimatedImage? {
        var limits = AnimatedImageDecoder.Limits.standard
        limits.encodedBytes = GIFMediaPolicy.maximumMediaBytes
        return AnimatedImageDecoder.decode(data, maxPixelSide: animatedPixelSide, limits: limits)
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
    func stop() { stopped = true; home.cancel(); sentLinkPreviews.reset(); transcriptChannelState.removeAll(); clearMessageDocuments(); timestampEnvironmentObservation = nil; setStatusAttention(nil); threadParents.removeAll(); roles.removeAll(); unreadNotificationIDs.removeAll(); (NSApp.delegate as? AppDelegate)?.updateDockBadge(); pendingFileReceipts.removeAll(); userPreferences = nil; directory.removeAll(); userNames.removeAll(); activeUsers.removeAll(); workingHours = nil; thumbnails.removeAll(); forgetAnimatedImages(); avatars.removeAll(); generatedAvatars.removeAllObjects(); generatedChannelAvatars.removeAllObjects(); avatarLastUse.removeAll(); avatarQueue.removeAll(); avatarRequests.removeAll(); avatarWorker?.cancel(); memoryMessages.removeAll(); generation += 1; refreshTask?.cancel(); reconciliationTask?.cancel(); realtime?.disconnect(); realtime = nil }
    private func shouldDeliverNotification(channelID: String) -> Bool {
        guard !stopped, !revokedChannels.contains(channelID),
              let channel = channels.first(where: { $0.id == channelID }),
              !ChannelPolicy.isArchived(channelID: channelID, channels: channels, threadParents: threadParents), !channel.raw["muted"].bool,
              channel.raw["allow_notifications"] == .null || channel.raw["allow_notifications"].bool else { return false }
        let controller = (NSApp.keyWindow?.windowController ?? NSApp.keyWindow?.sheetParent?.windowController) as? ConversationWindow
        let reading = NSApp.isActive && controller?.session === self && controller?.displaysConversation(channelID) == true
        return NotificationPolicy.shouldNotify(now: Date(), quietHours: NotificationPreferenceStore.quietHours(accountID: account.id), isForeground: reading, enabled: UserDefaults.standard.bool(forKey: "notifications"), muted: userPreferences?.availabilityStatus == "Do not disturb")
    }
    /// What a notification shows. By default the body stays generic for
    /// privacy; Settings ▸ Notifications can add the sender and conversation,
    /// or the message itself with spoilers masked. The thread identifier
    /// lets Notification Center stack a conversation's notifications
    /// without revealing anything.
    func notificationContent(for message: RavenMessage, level: NotificationPreview = .current()) -> UNMutableNotificationContent {
        let channelID = message.channelID
        let channel = channels.first { $0.id == channelID }
        let accountName = account.displayName.isEmpty ? account.user : account.displayName
        var text: String?
        if level == .message, !message.html.isEmpty, case .parsed(let document) = messageDocument(for: message) { text = RichTextCodec.plainText(document) }
        else if level == .message, message.html.isEmpty, ["File", "Image", "Poll"].contains(message.messageType) { text = NotificationText.structuredTeaser(message.raw["content"].string) }
        let file = message.raw["file"].string.flatMap { URL(string: $0)?.lastPathComponent }
        // A conversation not in the list yet has no title or kind to show;
        // its raw ID is no name, and a direct message must not read as a channel.
        let preview = NotificationText.make(level: channel == nil ? .generic : level, account: accountName, multipleAccounts: (NSApp.delegate as? AppDelegate).map { $0.sessions.filter { !$0.stopped }.count > 1 } ?? false,
                                            conversation: channel?.title ?? channelID, isDirect: channel?.isDM ?? false, sender: authorName(message), text: text, file: file)
        let content = UNMutableNotificationContent()
        content.title = preview.title
        content.subtitle = preview.subtitle
        content.body = preview.body
        content.threadIdentifier = "\(account.id.uuidString)-\(channelID)"
        content.userInfo = ["account": account.id.uuidString, "channel": channelID, "message": message.id]
        return content
    }
    func deliverNotification(channelID: String) async {
        guard shouldDeliverNotification(channelID: channelID) else { return }
        do {
            let result = try await client.rpc("raven.api.chat_stream.get_messages", arguments: ["channel_id": .string(channelID), "limit": .number(1), "update_last_visit": .bool(false)])
            guard let raw = result["messages"].array.first else { return }
            let message = RavenMessage(raw: raw)
            let notificationID = message.batchID ?? message.id
            guard message.channelID == channelID, message.owner != account.user, !notifiedIDs.contains(notificationID), shouldDeliverNotification(channelID: channelID) else { return }
            // Claimed before the await, so a concurrent delivery for the same
            // batch stops at the check above.
            notifiedIDs.insert(notificationID)
            let content = notificationContent(for: message)
            do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(account.id)-\(notificationID)", content: content, trigger: nil)) }
            // Not shown (for instance before permission was granted): the
            // batch may notify on its next message.
            catch { notifiedIDs.remove(notificationID) }
        } catch { /* Notifications are hints. They never mark history read or expose a failed fetch. */ }
    }

}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
