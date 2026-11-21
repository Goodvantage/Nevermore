import AppKit
import NevermoreCore
import RavenProtocol
import SQLite3

/// Hidden-window checks using disposable stores. No live account registration
/// or text-input event is used; receipt transports are stopped or invalidated
/// before calls, so these persistence regressions cannot reach a server.
@MainActor enum UnreadAffordanceSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreUnreadCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "unread-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("unread-fixture"), "channel_name": .string("Unread fixture")]))
        session.channels = [channel]
        func row(_ index: Int) -> RavenMessage {
            let time = min(index, 599) // The new arrival deliberately ties the prior newest timestamp.
            return RavenMessage(raw: .object(["name": .string("unread-\(index)"), "channel_id": .string(channel.id), "owner": .string("other-fixture@example.invalid"), "creation": .string(String(format: "2026-11-08 12:%02d:%02d.000000", time / 60, time % 60)), "text": .string("<p>Fixture message \(index), with enough text for native layout.</p>"), "message_type": .string("Text")]))
        }
        try await session.store.cacheMessages((0..<600).map(row))
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        session.recordTranscriptVisit(.timestamp("2026-11-08 12:00:30"), channelID: channel.id)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        check("unread divider uses the captured server visit without inventing a count", controller.transcript.string.contains("Unread messages\n") && !controller.readPosition.hasNewMessages)
        let firstVisible = controller.messageRanges.first { $0.1.id == "unread-100" }
        let initialOrigin = firstVisible.map { controller.rect(for: $0.0).minY + 1 } ?? 0
        controller.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: initialOrigin))
        controller.transcriptScroll.reflectScrolledClipView(controller.transcriptScroll.contentView)
        controller.seenVisible()
        let before = controller.transcriptScroll.contentView.bounds.origin
        let anchor = controller.messageRanges.first { controller.rect(for: $0.0).maxY >= before.y }
        let anchorOffset = anchor.map { controller.rect(for: $0.0).minY - before.y }
        let composerRange = controller.composer.selectedRange()
        try await session.store.cacheMessages([row(600)])
        controller.render(); await controller.renderTask?.value
        let retainedAnchor = anchor.flatMap { original in controller.messageRanges.first { $0.1.id == original.1.id } }
        let preservedOffset = retainedAnchor.map { abs(controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY - (anchorOffset ?? .infinity)) < 1 } == true
        check("new inbound messages preserve a scrolled-away native transcript", !controller.isFollowing && controller.readPosition.hasNewMessages && !controller.jumpLatestButton.isHidden && controller.messages.count <= 500 && preservedOffset)
        let neighbor = controller.messageRanges.first { $0.1.id == "unread-101" }
        let neighborOffset = neighbor.map { controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY }
        session.deletedIDs.insert("unread-100")
        controller.render(); await controller.renderTask?.value
        let survivingNeighbor = controller.messageRanges.first { $0.1.id == "unread-101" }
        let keptNeighbor = survivingNeighbor.map { abs(controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY - (neighborOffset ?? .infinity)) < 1 } == true
        check("deleting the first visible message preserves its surviving neighbor", keptNeighbor && controller.messages.count <= 500 && !controller.transcript.string.contains("Fixture message 100,"))
        // The transcript scrolls under the toolbar, so its top rests at
        // -contentInsets.top; a re-render there must not clamp to 0.
        if controller.transcriptScroll.contentInsets.top < 1 { controller.transcriptScroll.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: controller.transcriptScroll.contentInsets.bottom, right: 0) }
        let topOrigin = -controller.transcriptScroll.contentInsets.top
        controller.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: topOrigin))
        controller.transcriptScroll.reflectScrolledClipView(controller.transcriptScroll.contentView)
        controller.seenVisible()
        controller.render(); await controller.renderTask?.value
        check("re-rendering at the very top keeps the first message below the toolbar", !controller.isFollowing && abs(controller.transcriptScroll.contentView.bounds.minY - topOrigin) < 1)
        controller.transcript.scrollToEndOfDocument(nil)
        controller.seenVisible()
        check("a truncated away projection cannot claim the canonical live edge", !controller.isFollowing && controller.readPosition.hasNewMessages && controller.canJumpToLatest && !controller.jumpLatestButton.isHidden)
        if let range = controller.messageRanges.first(where: { $0.1.id == "unread-101" })?.0 {
            controller.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: controller.rect(for: range).minY + 1))
            controller.transcriptScroll.reflectScrolledClipView(controller.transcriptScroll.contentView)
            controller.seenVisible()
        }
        session.deletedIDs.insert("unread-600")
        controller.render(); await controller.renderTask?.value
        check("deleting an unseen arrival clears its new-message indication", !controller.readPosition.hasNewMessages && !controller.transcript.string.contains("Fixture message 600,"))
        session.deletedIDs.remove("unread-600")
        controller.render(); await controller.renderTask?.value
        controller.jumpToLatest(nil)
        await controller.latestReadTask?.value; await controller.renderTask?.value
        check("Jump to Latest clears the indication and keeps composer selection", controller.isFollowing && !controller.readPosition.hasNewMessages && controller.jumpLatestButton.isHidden && controller.composer.selectedRange() == composerRange && !controller.transcript.string.contains("Unread messages\n"))
        check("the live transcript supplies an actually visible read-receipt candidate", controller.visibleMessageForReadReceipt != nil)
        for historyCursor in [false, true] {
            let cursor = historyCursor ? "unread-40" : "unread-20"
            controller.select(channel, anchor: historyCursor ? nil : cursor)
            await controller.loadTask?.value; await controller.renderTask?.value
            if historyCursor {
                controller.isFollowing = false; controller.historyUpperID = cursor
                controller.render(); await controller.renderTask?.value
            }
            if let range = controller.messageRanges.first(where: { $0.1.id == "unread-20" })?.0 {
                controller.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: controller.rect(for: range).minY + 1))
                controller.transcriptScroll.reflectScrolledClipView(controller.transcriptScroll.contentView)
                controller.seenVisible()
            }
            let hasVisibleRows = controller.messageRanges.contains { controller.transcriptScroll.contentView.bounds.intersects(controller.rect(for: $0.0)) }
            check(historyCursor ? "historical pages do not supply read-receipt candidates" : "requested contexts do not supply read-receipt candidates", hasVisibleRows && controller.visibleMessageForReadReceipt == nil)
            let neighborID = historyCursor ? "unread-20" : "unread-21"
            let oldNeighbor = controller.messageRanges.first { $0.1.id == neighborID }
            let offset = oldNeighbor.map { controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY }
            session.deletedIDs.insert(cursor)
            try await session.store.deleteMessages(ids: [cursor])
            controller.render(); await controller.renderTask?.value
            let newNeighbor = controller.messageRanges.first { $0.1.id == neighborID }
            let preserved = newNeighbor.map { abs(controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY - (offset ?? .infinity)) < 1 } == true
            check(historyCursor ? "deleted history cursors retain the reader outside the latest page" : "deleted requested anchors retain a surviving context neighbor", preserved && !controller.isFollowing && controller.canJumpToLatest && controller.messages.count <= 500)
            session.deletedIDs.remove(cursor)
            try await session.store.cacheMessages([row(historyCursor ? 40 : 20)])
        }
        // A cache-retention loss is not an authoritative server deletion.
        // Keep the requested cursor while preserving its surviving viewport.
        controller.select(channel, anchor: "unread-500")
        await controller.loadTask?.value; await controller.renderTask?.value
        if let range = controller.messageRanges.first(where: { $0.1.id == "unread-500" })?.0 {
            // Keep the neighbor's old offset representable after older rows
            // leave the store; only the cursor's final pixels remain visible.
            controller.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: controller.rect(for: range).maxY - 2))
            controller.transcriptScroll.reflectScrolledClipView(controller.transcriptScroll.contentView)
            controller.seenVisible()
        }
        let cachedNeighbor = controller.messageRanges.first { $0.1.id == "unread-501" }
        let cachedOffset = cachedNeighbor.map { controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY }
        try await session.store.cacheMessages((501..<1501).map(row))
        let cachedRows = try await session.store.messages(channelID: channel.id, limit: 5000)
        let evictedCursor = cachedRows.count == 1000 && !cachedRows.contains { $0.id == "unread-500" } && cachedRows.contains { $0.id == "unread-501" }
        controller.render(); await controller.renderTask?.value
        let cachedSurvivor = controller.messageRanges.first { $0.1.id == "unread-501" }
        let cachedPreserved = cachedSurvivor.map { abs(controller.rect(for: $0.0).minY - controller.transcriptScroll.contentView.bounds.minY - (cachedOffset ?? .infinity)) < 1 } == true
        check("cache-evicted resolved cursors preserve viewport and unresolved navigation intent", evictedCursor && !session.deletedIDs.contains("unread-500") && controller.requestedAnchor == "unread-500" && cachedPreserved && !controller.isFollowing && controller.canJumpToLatest)
        controller.select(channel, anchor: "initially-uncached-context-target")
        await controller.loadTask?.value; await controller.renderTask?.value
        check("uncached context intent survives until resolved or authoritatively deleted", controller.requestedAnchor == "initially-uncached-context-target" && !controller.isFollowing)
        controller.isFollowing = false; controller.requestedAnchor = "unread-20"
        controller.seenVisible()
        check("a historical context window retains Jump to Latest even at its bottom", !controller.isFollowing && controller.canJumpToLatest)
        session.recordTranscriptVisit(.timestamp("2026-11-08 12:00:30"), channelID: channel.id)
        session.recordHistoricalMessageIDs(["revoked-private-id"], channelID: channel.id)
        session.revokedChannels.insert(channel.id)
        controller.render(); await controller.renderTask?.value
        check("revocation clears unread controls and private transcript state", controller.jumpLatestButton.isHidden && !controller.readPosition.hasNewMessages && !controller.canJumpToLatest && controller.transcript.string.isEmpty)
        check("revocation prunes transcript visit and historical identity metadata", session.transcriptVisit(for: channel.id) == nil && session.historicalMessageIDs(for: channel.id)?.ids.isEmpty == true && session.historicalMessageIDs(for: channel.id)?.complete == false)
        session.revokedChannels.remove(channel.id)
        session.recordTranscriptVisit(.timestamp("2026-11-08 12:00:30"), channelID: channel.id)
        session.recordHistoricalMessageIDs(["detached-private-id"], channelID: channel.id)
        controller.use(nil)
        check("detaching the final reader prunes account transcript metadata", session.transcriptVisit(for: channel.id) == nil && session.historicalMessageIDs(for: channel.id)?.ids.isEmpty == true && session.historicalMessageIDs(for: channel.id)?.complete == false)
        controller.jumpToLatest(nil)
        check("account switching rejects stale Jump to Latest callbacks", controller.session == nil && controller.jumpLatestButton.isHidden && controller.latestReadTask == nil)
        // A stopped account cannot emit HTTP. For active malformed-input
        // checks, invalidate the fresh transport before any receipt attempt.
        func receiptSession(_ name: String) throws -> AccountSession {
            let account = Account(origin: URL(string: "http://127.0.0.1:12345")!, user: "performance-fixture@example.invalid", siteName: "Receipt fixture", clientID: "performance-loopback")
            return try AccountSession(account: account, directory: directory.appendingPathComponent(name), authentication: .loopbackFixture)
        }
        let stoppedReceipt = try receiptSession("StoppedReceipt")
        stoppedReceipt.stop()
        await stoppedReceipt.markSeen(channelID: "receipt-fixture-channel", timestamp: "2026-11-08 12:00:00")
        let stoppedVisits = try await stoppedReceipt.store.visits()
        check("stopped accounts reject late read receipts before memory or store writes", stoppedReceipt.lastSeen.isEmpty && stoppedVisits.isEmpty)
        let invalidReceipt = try receiptSession("InvalidReceipt")
        defer { invalidReceipt.stop() }
        await invalidReceipt.client.invalidate()
        for (index, timestamp) in ["not-a-server-timestamp", String(repeating: "x", count: 100_000)].enumerated() {
            await invalidReceipt.markSeen(channelID: "invalid-receipt-\(index)", timestamp: timestamp)
        }
        let invalidVisits = try await invalidReceipt.store.visits()
        check("malformed and response-sized read timestamps never enter memory or pending visits", invalidReceipt.lastSeen.isEmpty && invalidVisits.isEmpty)
        // A local watermark write can fail. The observation must stay
        // retryable: arm a trigger that aborts visits writes, then drop it, so
        // the same disposable store is failed and restored without credentials.
        let retryDirectory = directory.appendingPathComponent("VisitRetry")
        let retryAccount = Account(origin: URL(string: "http://127.0.0.1:12345")!, user: "performance-fixture@example.invalid", siteName: "Receipt fixture", clientID: "performance-loopback")
        let retryReceipt = try AccountSession(account: retryAccount, directory: retryDirectory, authentication: .loopbackFixture)
        defer { retryReceipt.stop() }
        func setVisitFailure(_ timestamp: String?) throws {
            var db: OpaquePointer?
            let path = retryDirectory.appendingPathComponent(AccountStore.databaseFileName).path
            let opened = sqlite3_open(path, &db)
            defer { sqlite3_close(db) }
            guard opened == SQLITE_OK else { throw AppError.message("Could not open the visit fixture store.") }
            let sql = timestamp.map { "CREATE TRIGGER fail_visits BEFORE INSERT ON visits WHEN NEW.timestamp = '\($0)' BEGIN SELECT RAISE(ABORT, 'simulated local write failure'); END" } ?? "DROP TRIGGER IF EXISTS fail_visits"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not change the visit fixture store.") }
        }
        let retryChannel = "visit-retry-fixture"
        func queuedVisit() async throws -> String? { try await retryReceipt.store.visits()[retryChannel] }
        try setVisitFailure(nil)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:00:00")
        let durableVisit = try await queuedVisit()
        check("a durable visit watermark queues before the store can fail", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:00:00" && durableVisit == "2026-11-08 12:00:00")
        try setVisitFailure("2026-11-08 12:01:00")
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:01:00")
        let failedVisit = try await queuedVisit()
        check("a failed local watermark write leaves the same message observable", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:00:00" && failedVisit == "2026-11-08 12:00:00")
        try setVisitFailure(nil)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:01:00")
        let retriedVisit = try await queuedVisit()
        check("a restored store queues the retried watermark", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:01:00" && retriedVisit == "2026-11-08 12:01:00")
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 11:59:00")
        let olderVisit = try await queuedVisit()
        check("an older observation never moves the queued watermark back", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:01:00" && olderVisit == "2026-11-08 12:01:00")
        // A newer observation after the failure still advances, and an older
        // one stays rejected.
        try setVisitFailure("2026-11-08 12:02:00")
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:02:00")
        try setVisitFailure(nil)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:03:00")
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:02:00")
        let newerVisit = try await queuedVisit()
        check("a failed older write does not block a newer observation", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:03:00" && newerVisit == "2026-11-08 12:03:00")
        // Explicit Mark as Unread invalidates the queued watermark and the
        // in-memory one, and is not undone by the earlier failed write.
        try? await retryReceipt.markUnread(channelID: retryChannel)
        let unreadVisit = try await queuedVisit()
        check("explicit Mark as Unread invalidates the queued and remembered watermark", retryReceipt.intentionallyUnread.contains(retryChannel) && retryReceipt.lastSeen[retryChannel] == nil && unreadVisit == nil)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:03:00")
        let rejectedVisit = try await queuedVisit()
        check("an explicitly unread conversation rejects a late read receipt", retryReceipt.lastSeen[retryChannel] == nil && rejectedVisit == nil)
        retryReceipt.intentionallyUnread.remove(retryChannel)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:03:00")
        let settledVisit = try await queuedVisit()
        check("reopening the conversation lets the watermark settle again", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:03:00" && settledVisit == "2026-11-08 12:03:00")
        // Mark as Unread can land while a write is still failing. Its
        // invalidation must survive the failure report.
        try setVisitFailure("2026-11-08 12:04:00")
        let failingWhileUnread = Task { await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:04:00") }
        await Task.yield()
        try? await retryReceipt.markUnread(channelID: retryChannel)
        await failingWhileUnread.value
        let unreadDuringFailure = try await queuedVisit()
        check("an explicit Mark as Unread during a failed write is not undone", retryReceipt.intentionallyUnread.contains(retryChannel) && retryReceipt.lastSeen[retryChannel] == nil && unreadDuringFailure == nil)
        // A newer observation that lands while an older write is failing must
        // keep its own watermark.
        try setVisitFailure(nil)
        retryReceipt.intentionallyUnread.remove(retryChannel)
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:04:00")
        try setVisitFailure("2026-11-08 12:05:00")
        let failingOlder = Task { await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:05:00") }
        await Task.yield()
        await retryReceipt.markSeen(channelID: retryChannel, timestamp: "2026-11-08 12:06:00")
        await failingOlder.value
        let newerDuringFailure = try await queuedVisit()
        check("a newer observation during a failed write keeps its watermark", retryReceipt.lastSeen[retryChannel] == "2026-11-08 12:06:00" && newerDuringFailure == "2026-11-08 12:06:00")

        // Hold the writer until two observations have entered markSeen. If
        // both fail, neither provisional timestamp can become a watermark.
        var locked: OpaquePointer?
        let database = retryDirectory.appendingPathComponent(AccountStore.databaseFileName).path
        let opened = sqlite3_open(database, &locked)
        defer { sqlite3_close(locked) }
        guard opened == SQLITE_OK else { throw AppError.message("Could not open the overlap fixture.") }
        func waitForStart(_ started: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !started() {
                guard ContinuousClock.now < deadline else { throw AppError.message("The read receipt fixture did not start in time.") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let rejectBoth = "CREATE TRIGGER fail_overlap BEFORE INSERT ON visits WHEN NEW.channelID = 'overlap' BEGIN SELECT RAISE(ABORT, 'unavailable'); END"
        guard sqlite3_exec(locked, rejectBoth, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(locked, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not hold the overlap fixture.") }
        var started = 0
        let writes = ["2026-11-08 13:00:00", "2026-11-08 13:01:00"].map { timestamp in
            Task { @MainActor in
                started += 1
                await retryReceipt.markSeen(channelID: "overlap", timestamp: timestamp)
            }
        }
        try await waitForStart { started == writes.count }
        // These transactions only hold a writer lock. Rollback releases it
        // even when a competing receipt still holds a shared read lock.
        guard sqlite3_exec(locked, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not release the overlap fixture.") }
        for write in writes { await write.value }
        let overlappingVisits = try await retryReceipt.store.visits()
        check("two overlapping failed writes leave neither watermark in memory or on disk",
              retryReceipt.lastSeen["overlap"] == nil && overlappingVisits["overlap"] == nil)
        guard sqlite3_exec(locked, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not hold the unread fixture.") }
        var beganVisit = false
        let beforeUnread = Task { @MainActor in
            beganVisit = true
            await retryReceipt.markSeen(channelID: "barrier", timestamp: "2026-11-08 14:00:00")
        }
        try await waitForStart { beganVisit }
        let unread = Task { try? await retryReceipt.markUnread(channelID: "barrier") }
        try await waitForStart { retryReceipt.intentionallyUnread.contains("barrier") }
        guard sqlite3_exec(locked, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not release the unread fixture.") }
        await beforeUnread.value
        await unread.value
        let afterUnread = try await retryReceipt.store.visits()
        check("explicit Mark as Unread drains an earlier successful local watermark write",
              afterUnread["barrier"] == nil && retryReceipt.lastSeen["barrier"] == nil)
        retryReceipt.flushing = true
        let stalled = Task {
            do { try await retryReceipt.markUnread(channelID: "stalled"); return "" }
            catch { return error.localizedDescription }
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(7))
            stalled.cancel()
        }
        let explanation = await stalled.value
        watchdog.cancel()
        retryReceipt.flushing = false
        check("Mark as Unread reports a stalled read receipt and permits retry",
              explanation.contains("Try again") && !explanation.isEmpty)
        return checks
    }
}
