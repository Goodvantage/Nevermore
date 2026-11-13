import AppKit
import RavenProtocol
import NevermoreCore

/// The server's side of the interactive demo (`--demo`).
///
/// Sends go through the same draft acceptance and outbox as a real
/// account. This object then plays the network: it claims each queued
/// send after a delay, acknowledges it with the message a Raven server
/// would return, and now and then has a teammate answer or react. It also
/// keeps unread counts and takes reactions, so the sidebar's ravens and
/// the reaction stickers have something to do. Nothing leaves the Mac. Self-checks and performance runs do not create one, so the
/// demo they measure still refuses to send.
@MainActor final class DemoWire {
    enum Network: Int, CaseIterable {
        case fast, slow, unreliable, offline
        var title: String {
            switch self {
            case .fast: return "Fast Network"
            case .slow: return "Slow Network (4 Seconds)"
            case .unreliable: return "Unreliable Network (First Try Fails)"
            case .offline: return "Offline (Hold Sends)"
            }
        }
        /// Time a send stays queued before the wire picks it up.
        var latency: TimeInterval {
            switch self {
            case .fast, .unreliable: return 0.9
            case .slow: return 4
            case .offline: return .infinity
            }
        }
    }

    static let conversationID = "launch"

    unowned let session: AccountSession
    var network: Network = .fast { didSet { if oldValue != network { networkChanged() } } }
    private var delivering = false
    private var sends = 0
    private var replies = 0
    private var elsewhere = 0
    private var reactions = 0

    init(session: AccountSession) { self.session = session }

    private func networkChanged() {
        updateState()
        if network != .offline { deliver() }
    }

    func updateState() {
        session.state = network == .offline ? "Demo · offline, sends are held" : "Demo · messages stay on this Mac"
        session.notify()
    }

    // MARK: Delivery

    /// Starts working through the outbox, oldest first, if not already.
    func deliver() {
        guard !delivering, network != .offline else { return }
        delivering = true
        Task { @MainActor [weak self] in
            await self?.run()
            self?.delivering = false
        }
    }

    private func run() async {
        do {
            while !session.stopped, network != .offline {
                guard let next = try await session.store.operations().first(where: { $0.state == .queued || $0.state == .retryable }) else { return }
                // Sends held while offline have waited long enough; they
                // still leave one at a time, in order.
                // Slow-motion study (`inkTimeScale`) slows the wire as well.
                let wait = next.attempts > 0 ? 0.3 : max(0.3, network.latency * Ink.timeScale - Date().timeIntervalSince(next.createdAt))
                try await Task.sleep(for: .seconds(wait))
                guard !session.stopped, network != .offline else { return }
                // Nil: taken back while it waited.
                guard var claimed = try await session.store.beginAttempt(id: next.id) else { continue }
                if network == .unreliable, claimed.attempts == 1 {
                    // What a timeout looks like: the outbox keeps the send
                    // and tries again a few seconds later.
                    try await Task.sleep(for: .seconds(0.6))
                    claimed.state = .retryable
                    claimed.error = "The server did not answer."
                    try await session.store.updateOperation(claimed)
                    session.notify()
                    try await Task.sleep(for: .seconds(3))
                    continue
                }
                claimed.state = .sending
                try await session.store.updateOperation(claimed)
                session.notify()
                try await Task.sleep(for: .milliseconds(120))
                try await session.store.acknowledge(id: claimed.id, messages: [acknowledgement(for: claimed)])
                session.notify()
                answer(in: claimed.channelID)
                applaud(claimed)
            }
        } catch {
            session.fail(error)
        }
    }

    private func acknowledgement(for operation: SendOperation) -> RavenMessage {
        let text = operation.html.isEmpty ? "<p>\(operation.attachments.map(\.filename).joined(separator: ", "))</p>" : operation.html
        var fields: [String: JSONValue] = [
            "name": .string("demo-sent-\(operation.id.uuidString.prefix(8))"), "channel_id": .string(operation.channelID),
            "owner": .string(session.account.user), "creation": .string(session.serverTimestamp(Date())), "text": .string(text),
            "message_type": .string("Text"), "message_batch_id": .string(operation.id.uuidString)
        ]
        if let reply = operation.replyTo { fields["is_reply"] = .bool(true); fields["linked_message"] = .string(reply) }
        return RavenMessage(raw: .object(fields))
    }

    // MARK: Teammates

    private static let answers: [(author: String, html: String)] = [
        ("morgan@example.com", "<p>Works for me.</p>"),
        ("priya@example.com", "<p>Good. I will tell support it goes out at two.</p>"),
        ("jonas@example.com", "<p>Deploy is queued behind the migration check, about ten minutes.</p>"),
        ("alex@example.com", "<p>Thanks. I will link it from the release notes.</p>"),
        ("morgan@example.com", "<p>Can you also mention the export fix? People asked about it twice this week.</p>"),
        ("priya@example.com", "<p>Agreed, and keep it short. Nobody reads past the second paragraph.</p>"),
        ("jonas@example.com", "<p>Rolling out now. The first region is healthy.</p>"),
        ("alex@example.com", "<p>Saw it. Looks right to me.</p>")
    ]

    /// Every other send gets an answer, a couple of seconds later.
    private func answer(in channelID: String) {
        sends += 1
        guard sends % 2 == 1 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4 * Ink.timeScale))
            await self?.receive(in: channelID)
        }
    }

    /// A teammate posts in `channelID`, as a realtime event would deliver it.
    func receive(in channelID: String) async {
        guard !session.stopped else { return }
        var (author, html) = Self.answers[replies % Self.answers.count]
        replies += 1
        // In a direct message only the other person can answer.
        if let peer = session.channels.first(where: { $0.id == channelID })?.raw["peer_user_id"].string { author = peer }
        let message = RavenMessage(raw: .object([
            "name": .string("demo-reply-\(UUID().uuidString.prefix(8))"), "channel_id": .string(channelID), "owner": .string(author),
            "creation": .string(session.serverTimestamp(Date())), "text": .string(html), "message_type": .string("Text")
        ]))
        do { try await session.store.cacheMessages([message]); await recount(channelID); session.notify() } catch { session.fail(error) }
    }

    private static let asides: [(channel: String, author: String, html: String, mention: Bool)] = [
        ("design", "priya@example.com", "<p>The new icons are in the shared folder. The raven is the one on the left.</p>", false),
        ("dm-morgan", "morgan@example.com", "<p>Lunch at one?</p>", false),
        ("design", "alex@example.com", "<p>@Sam can you look at the empty state before Thursday?</p>", true),
        ("engineering", "jonas@example.com", "<p>CI is green on main again.</p>", false),
        ("dm-morgan", "morgan@example.com", "<p>Also, thanks for covering the release notes.</p>", false)
    ]

    /// A teammate posts in a conversation other than `front`, so it
    /// becomes unread.
    func receiveElsewhere(than front: String?) async {
        guard !session.stopped else { return }
        var aside = Self.asides[elsewhere % Self.asides.count]
        elsewhere += 1
        if aside.channel == front { aside = Self.asides[elsewhere % Self.asides.count]; elsewhere += 1 }
        let message = RavenMessage(raw: .object([
            "name": .string("demo-reply-\(UUID().uuidString.prefix(8))"), "channel_id": .string(aside.channel), "owner": .string(aside.author),
            "creation": .string(session.serverTimestamp(Date())), "text": .string(aside.html), "message_type": .string("Text")
        ]))
        do {
            try await session.store.cacheMessages([message])
            if aside.mention { session.mentionedChannels.insert(aside.channel) }
            await recount(aside.channel)
            session.notify()
        } catch { session.fail(error) }
    }

    // MARK: Reading

    /// Reading up to `timestamp` moves the visit, as on a server, and the
    /// conversation's unread count follows from it.
    func markSeen(channelID: String, timestamp: String) {
        guard !session.stopped, timestamp > (session.lastSeen[channelID] ?? "") else { return }
        session.lastSeen[channelID] = timestamp
        Task { @MainActor [weak self] in
            await self?.recount(channelID)
            self?.session.notify()
        }
    }

    /// Unread count of one conversation: other people's messages after
    /// the last visit.
    private func recount(_ channelID: String) async {
        guard let messages = try? await session.store.messages(channelID: channelID, limit: 5000) else { return }
        let visit = session.lastSeen[channelID] ?? ""
        let count = messages.filter { $0.owner != session.account.user && $0.messageType != "System" && $0.creation > visit }.count
        var rows = session.unread.array.filter { $0["name"].string != channelID }
        if count > 0 { rows.append(.object(["name": .string(channelID), "unread_count": .number(Double(count))])) }
        else { session.mentionedChannels.remove(channelID) }
        session.unread = .array(rows)
    }

    /// The state a returning reader finds: everything read except what
    /// arrived in two conversations since the last visit.
    func settleUnread() async {
        let now = session.serverTimestamp(Date())
        for channel in session.channels { session.lastSeen[channel.id] = now }
        session.lastSeen["design"] = Self.lastDesignVisit
        session.lastSeen["dm-morgan"] = Self.lastDesignVisit
        for channel in session.channels { await recount(channel.id) }
        session.notify()
    }
    private static let lastDesignVisit = "2026-11-07 11:00:00.000000"

    // MARK: Reactions

    /// Toggles `user`'s reaction, as Raven's `react` does, in the shape
    /// Raven stores: `{emoji: {count, users, reaction}}`.
    func toggleReaction(_ emoji: String, on messageID: String, in channelID: String, by user: String) async throws {
        guard let message = try await session.store.messages(channelID: channelID, limit: 5000).first(where: { $0.id == messageID }) else {
            throw AppError.message("That message is no longer in this conversation.")
        }
        var reactions = message.raw["message_reactions"].nested.object
        var users = reactions[emoji]?["users"].array.compactMap(\.string) ?? []
        if let index = users.firstIndex(of: user) { users.remove(at: index) } else { users.append(user) }
        if users.isEmpty { reactions.removeValue(forKey: emoji) }
        else { reactions[emoji] = .object(["count": .number(Double(users.count)), "users": .array(users.map { .string($0) }), "reaction": .string(emoji)]) }
        var fields = message.raw.object
        fields["message_reactions"] = .string(String(decoding: try JSONEncoder().encode(JSONValue.object(reactions)), as: UTF8.self))
        try await session.store.cacheMessages([RavenMessage(raw: .object(fields))])
        session.notify()
    }

    private static let cheers: [(author: String, emoji: String)] = [
        ("priya@example.com", "👍"), ("jonas@example.com", "🎉"), ("morgan@example.com", "👍"), ("alex@example.com", "🔥"), ("morgan@example.com", "❤️")
    ]

    /// A teammate reacts to `messageID`, as a realtime event would show it.
    func cheer(_ messageID: String, in channelID: String) async {
        guard !session.stopped else { return }
        // The first two cheers are the same emoji from different people,
        // so a count can be seen to roll.
        let cheer = Self.cheers[reactions % Self.cheers.count]
        reactions += 1
        do { try await toggleReaction(cheer.emoji, on: messageID, in: channelID, by: cheer.author) } catch { session.fail(error) }
    }

    /// Every third send is applauded a moment after it arrives.
    private func applaud(_ operation: SendOperation) {
        guard sends % 3 == 1 else { return }
        let messageID = "demo-sent-\(operation.id.uuidString.prefix(8))"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.3 * Ink.timeScale))
            await self?.cheer(messageID, in: operation.channelID)
        }
    }

    // MARK: Content

    static let people = ["alex@example.com": "Alex Rivera", "morgan@example.com": "Morgan Lee", "priya@example.com": "Priya Nair", "jonas@example.com": "Jonas Weber"]

    /// A release-day conversation, dated up to a few minutes ago so new
    /// messages continue it. Messages sent in earlier demo runs are
    /// removed first; they would otherwise sort into the middle.
    func seed() async throws {
        let channel = RavenChannel(raw: .object(["name": .string(Self.conversationID), "channel_name": .string("launch"), "workspace": .string("Acme")]))
        try await session.store.cacheChannels([channel])
        for existing in try await session.store.channels() {
            let stale = try await session.store.messages(channelID: existing.id, limit: 5000).map(\.id).filter { $0.hasPrefix("demo-sent-") || $0.hasPrefix("demo-reply-") }
            if !stale.isEmpty { try await session.store.deleteMessages(ids: stale) }
        }
        let now = Date()
        let calendar = session.displayCalendar
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        func yesterdayAt(_ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: yesterday) ?? yesterday }
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let script: [(String, Date, String, String?)] = [
            ("priya@example.com", yesterdayAt(16, 42), "<p>Release candidate <strong>2.4.0-rc2</strong> is on staging. The changelog is in the usual document.</p>", nil),
            ("jonas@example.com", yesterdayAt(16, 44), "<p>Smoke tests are green except the CSV export, which times out on the big tenant again.</p>", nil),
            ("jonas@example.com", yesterdayAt(16, 45), "<p>Same query as last time, I think. Looking.</p>", nil),
            ("morgan@example.com", yesterdayAt(16, 51), "<p>If it is the same one, the index from the March fix never made it to staging. I can run the migration tonight.</p>", nil),
            ("priya@example.com", yesterdayAt(16, 53), "<p>Please do. I would rather not ship on Thursday with a known timeout.</p>", nil),
            ("morgan@example.com", ago(48), "<p>Migration ran at 07:10. The export on the big tenant takes 4 seconds now, down from 70.</p>", #"{"🎉": {"count": 2, "users": ["priya@example.com", "jonas@example.com"], "reaction": "🎉"}}"#),
            ("alex@example.com", ago(44), "<p>I updated the release notes: <strong>faster CSV export</strong>, the new audit log filter and the fix for duplicate invoices.</p>", nil),
            ("alex@example.com", ago(43), "<p>Can someone read them before they go to support? I always miss something.</p>", nil),
            ("priya@example.com", ago(31), "<p>Read them. Two things: the audit log filter is for admins only, so say that. And <em>duplicate invoices</em> undersells it, three customers hit that one.</p>", #"{"👍": {"count": 2, "users": ["alex@example.com", "you@example.com"], "reaction": "👍"}}"#),
            ("jonas@example.com", ago(12), "<p>Staging is clean. I am fine to ship whenever you are.</p>", nil),
            ("morgan@example.com", ago(6), "<p>Then the only open question is who posts the announcement. You wrote most of it.</p>", nil)
        ]
        var messages: [RavenMessage] = []
        for (index, line) in script.enumerated() {
            var fields: [String: JSONValue] = ["name": .string("demo-launch-\(index)"), "channel_id": .string(Self.conversationID), "owner": .string(line.0), "creation": .string(session.serverTimestamp(line.1)), "text": .string(line.2), "message_type": .string("Text")]
            if let reactions = line.3 { fields["message_reactions"] = .string(reactions) }
            messages.append(RavenMessage(raw: .object(fields)))
        }
        // Two more in #design since the last visit, so it opens on an
        // unread divider with three messages below it.
        messages.append(RavenMessage(raw: .object(["name": .string("demo-design-1"), "channel_id": .string("design"), "owner": .string("priya@example.com"), "creation": .string(session.serverTimestamp(ago(95))), "text": .string("<p>Round two of the sidebar icons is up. I dropped the outlined set, it disappeared at small sizes.</p>"), "message_type": .string("Text")])))
        messages.append(RavenMessage(raw: .object(["name": .string("demo-design-2"), "channel_id": .string("design"), "owner": .string("alex@example.com"), "creation": .string(session.serverTimestamp(ago(20))), "text": .string("<p>The filled ones read better. Can we see them on the dark theme before we pick?</p>"), "message_type": .string("Text")])))
        try await session.store.cacheMessages(messages)
    }
}

/// The Demo menu: choose how the simulated network behaves, or have a
/// teammate post. Shown only when a demo wire can exist.
@MainActor final class DemoMenu: NSObject, NSMenuDelegate {
    static let shared = DemoMenu()
    static var isAvailable: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--demo") && !arguments.contains("--self-check") && !arguments.contains("--performance-check")
    }

    private var wire: DemoWire? { (NSApp.delegate as? AppDelegate)?.sessions.compactMap(\.demoWire).first }

    func install(in bar: NSMenu) {
        let menu = NSMenu(title: "Demo")
        menu.delegate = self
        for network in DemoWire.Network.allCases {
            let item = menu.addItem(withTitle: network.title, action: #selector(chooseNetwork(_:)), keyEquivalent: network == .offline ? "o" : "")
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self; item.tag = network.rawValue
        }
        menu.addItem(.separator())
        let receive = menu.addItem(withTitle: "Receive a Message", action: #selector(receive(_:)), keyEquivalent: "m")
        receive.keyEquivalentModifierMask = [.command, .control]; receive.target = self
        let elsewhere = menu.addItem(withTitle: "Receive a Message in Another Conversation", action: #selector(receiveElsewhere(_:)), keyEquivalent: "u")
        elsewhere.keyEquivalentModifierMask = [.command, .control]; elsewhere.target = self
        let cheer = menu.addItem(withTitle: "Receive a Reaction", action: #selector(receiveReaction(_:)), keyEquivalent: "r")
        cheer.keyEquivalentModifierMask = [.command, .control]; cheer.target = self
        let item = NSMenuItem(title: "Demo", action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(chooseNetwork(_:)) { item.state = wire?.network.rawValue == item.tag ? .on : .off }
    }

    /// Choosing Offline while offline goes back online, so ⌃⌘O toggles.
    @objc func chooseNetwork(_ sender: NSMenuItem) {
        guard let wire, let network = DemoWire.Network(rawValue: sender.tag) else { return }
        wire.network = network == .offline && wire.network == .offline ? .fast : network
    }

    private var frontWindow: ConversationWindow? {
        (NSApp.keyWindow?.windowController as? ConversationWindow) ?? (NSApp.delegate as? AppDelegate)?.windows.last
    }

    @objc func receive(_ sender: Any?) {
        guard let wire else { return }
        let front = frontWindow?.channel?.id ?? DemoWire.conversationID
        Task { await wire.receive(in: front) }
    }

    @objc func receiveElsewhere(_ sender: Any?) {
        guard let wire else { return }
        let front = frontWindow?.channel?.id
        Task { await wire.receiveElsewhere(than: front) }
    }

    /// A teammate reacts to the latest message of the front conversation.
    @objc func receiveReaction(_ sender: Any?) {
        guard let wire, let window = frontWindow, let message = window.messages.last(where: { $0.messageType != "System" }) else { return }
        Task { await wire.cheer(message.id, in: message.channelID) }
    }
}
