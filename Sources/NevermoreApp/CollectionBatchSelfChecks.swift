import AppKit
import RavenProtocol

@MainActor enum CollectionBatchSelfChecks {
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var calls: [[String]] = []
        private var released = false
        func submit(_ ids: [String]) async {
            calls.append(ids)
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo else { throw AppError.message("Batch checks require a demo account.") }
        let originalUnread = session.unreadNotificationIDs
        defer { session.unreadNotificationIDs = originalUnread; session.notify() }
        let isolated = ConversationWindow(app: owner.app, session: session)
        defer { isolated.close() }
        let rows: [JSONValue] = ["first", "second", "first"].enumerated().map { index, id in
            .object(["name": .string("mention-\(index)"), "message_id": .string(id), "channel_id": .string("batch-fixture")])
        }
        var results: [(String, Bool)] = []
        func check(_ label: String, _ result: Bool) { results.append((label, result)) }
        check("inbox batch IDs are immutable message IDs with stable deduplication", CollectionBatchActions.messageIDs(rows) == ["first", "second"])
        check("inbox batches reject missing message IDs and oversized selections",
              CollectionBatchActions.messageIDs([.object(["name": .string("mention-only")])]) == nil &&
              CollectionBatchActions.messageIDs(Array(repeating: rows[0], count: 101)) == nil)

        let gate = Gate()
        var reads = 0
        let transport = CollectionBatchActions.Transport(markRead: { await gate.submit($0) }, markAllRead: { }, unreadIDs: {
            reads += 1; return ["still-unread"]
        })
        let inbox = CollectionWindow(owner: isolated, title: "Batch fixture", records: rows, kind: .inbox, batchTransport: transport)
        defer { inbox.close() }
        inbox.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
        inbox.updateChrome()
        check("only inbox supports multiple selection and disables single-row actions", inbox.table.allowsMultipleSelection && inbox.markReadButton.isEnabled && !inbox.openButton.isEnabled && !inbox.manageButton.isEnabled && inbox.selected == nil)
        let search = CollectionWindow(owner: isolated, title: "Single selection fixture", records: rows, kind: .messages, batchTransport: transport)
        defer { search.close() }
        check("other collections keep single selection and hide the batch action", !search.table.allowsMultipleSelection && search.markReadButton.isHidden && !search.canMarkSelectedRead)
        let command = NSMenuItem(title: "Mark Selected Notifications Read", action: #selector(CollectionWindow.markSelectedRead), keyEquivalent: "")
        check("inbox batch menu validation follows the selected account and rows", inbox.validateMenuItem(command) && !search.validateMenuItem(command))
        let allCommand = NSMenuItem(title: "Mark All Notifications Read", action: #selector(CollectionWindow.markAllRead), keyEquivalent: "")
        check("mark all menu validation needs no selection and follows the account", inbox.validateMenuItem(allCommand) && !search.validateMenuItem(allCommand))
        inbox.markSelectedRead()
        for _ in 0..<100 { if gate.continuation != nil { break }; await Task.yield() }
        let suspended = inbox.isBatchRunning && !inbox.markReadButton.isEnabled && gate.calls == [["first", "second"]]
        inbox.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        inbox.markSelectedRead()
        let task = inbox.batchTask
        gate.release(); await task?.value
        check("suspended inbox batches send once using the captured selection", suspended && gate.calls == [["first", "second"]] && reads == 1)
        check("inbox batches reconcile the canonical attention set", !inbox.isBatchRunning && session.unreadNotificationIDs == ["still-unread"] && inbox.pager.records.allSatisfy { $0["is_read"].bool })

        // Completion after close or account replacement must neither update
        // private rows nor the old account's notification attention state.
        for switchAccount in [false, true] {
            let lateGate = Gate()
            var lateReads = 0
            let late = CollectionWindow(owner: isolated, title: "Late batch fixture", records: rows, kind: .inbox,
                batchTransport: .init(markRead: { await lateGate.submit($0) }, markAllRead: { }, unreadIDs: { lateReads += 1; return ["must-not-apply"] }))
            late.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            late.markSelectedRead()
            for _ in 0..<100 { if lateGate.continuation != nil { break }; await Task.yield() }
            let pending = late.batchTask
            let started = lateGate.continuation != nil
            if switchAccount { isolated.session = nil } else { late.close() }
            lateGate.release(); await pending?.value
            check(switchAccount ? "inbox batch completion rejects a replaced account" : "closed inbox batches reject delayed completion",
                  started && lateReads == 0 && session.unreadNotificationIDs == ["still-unread"] && (switchAccount || late.records.isEmpty))
            isolated.session = session
            late.close()
        }

        var attempts = 0
        let uncertain = CollectionWindow(owner: isolated, title: "Uncertain batch fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in attempts += 1; throw RavenError.transport }, markAllRead: { }, unreadIDs: { ["canonical-after-error"] }))
        defer { uncertain.close() }
        uncertain.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        uncertain.markSelectedRead(); await uncertain.batchTask?.value
        check("uncertain inbox mutations are never replayed and retain an explicit warning", attempts == 1 && uncertain.statusMessage.contains("Could not confirm") && session.unreadNotificationIDs == ["canonical-after-error"])

        let failedRead = CollectionWindow(owner: isolated, title: "Unread failure fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, markAllRead: { }, unreadIDs: { throw RavenError.transport }))
        defer { failedRead.close() }
        failedRead.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        failedRead.markSelectedRead(); await failedRead.batchTask?.value
        check("failed inbox reconciliation preserves known attention state and reports the gap", session.unreadNotificationIDs == ["canonical-after-error"] && failedRead.statusMessage.contains("unread status could not be refreshed"))

        let readGate = Gate()
        let closingRead = CollectionWindow(owner: isolated, title: "Late unread fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, markAllRead: { }, unreadIDs: { await readGate.submit([]); return ["must-not-apply"] }))
        closingRead.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        closingRead.markSelectedRead()
        for _ in 0..<100 { if readGate.continuation != nil { break }; await Task.yield() }
        let reading = closingRead.batchTask
        let readStarted = readGate.continuation != nil
        closingRead.close(); readGate.release(); await reading?.value
        check("closed inboxes reject a delayed canonical unread response", readStarted && closingRead.records.isEmpty && session.unreadNotificationIDs == ["canonical-after-error"])

        // Account-wide Mark All Read: independent of selection, filter and
        // pagination. It sends no row identities and reconciles the canonical
        // unread set, so rows beyond the visible page follow the server.
        let visitChannel = "mark-all-visit-fixture"
        session.interests[UUID()] = visitChannel
        session.recordTranscriptVisit(.timestamp("2026-01-02 03:04:05.000000"), channelID: visitChannel)
        session.lastSeen[visitChannel] = "2026-01-02 03:04:05.000000"
        session.intentionallyUnread.insert(visitChannel)
        session.knownThreads.insert("mark-all-thread-fixture")
        session.threadParents["mark-all-thread-fixture"] = visitChannel
        let lastSeenBefore = session.lastSeen[visitChannel]
        let intentionallyUnreadBefore = session.intentionallyUnread
        let knownThreadsBefore = session.knownThreads
        let threadParentsBefore = session.threadParents
        let visitStateBefore = session.transcriptVisit(for: visitChannel)
        let allGate = Gate()
        var allCalls = 0
        let allTransport = CollectionBatchActions.Transport(markRead: { _ in }, markAllRead: {
            allCalls += 1
            await allGate.submit([])
        }, unreadIDs: { ["first"] })
        let all = CollectionWindow(owner: isolated, title: "Mark all fixture", records: rows, kind: .inbox, batchTransport: allTransport)
        defer { all.close() }
        all.search.stringValue = "mention-1"
        all.applyFilter()
        all.pager.hasMore = true
        all.updateChrome()
        check("mark all read is available without a selection and despite a filter or unpaged rows",
              all.canMarkAllRead && all.markAllButton.isEnabled && all.selected == nil && all.records.count == 1 && all.pager.records.count == 3)
        check("mark all read is a distinct control plainly scoped to the account and hidden rows",
              all.markAllButton.title == "Mark All Read" && all.markReadButton.title == "Mark Selected Read" &&
              (all.markAllButton.accessibilityLabel() ?? "").contains("account") &&
              (all.markAllButton.toolTip ?? "").contains("filter") && (all.markAllButton.toolTip ?? "").contains("pages"))
        all.markAllRead()
        for _ in 0..<100 { if allGate.continuation != nil { break }; await Task.yield() }
        let allSuspended = all.isBatchRunning && !all.markAllButton.isEnabled && allCalls == 1
        let allTask = all.batchTask
        allGate.release(); await allTask?.value
        check("mark all read sends exactly one account-wide request with no row, filter or page arguments",
              allSuspended && allCalls == 1 && allGate.calls == [[]])
        check("mark all read reconciles every pager row from the canonical unread set",
              session.unreadNotificationIDs == ["first"] && all.pager.records.map { $0["is_read"].bool } == [false, true, false])
        check("mark all read leaves channel visits and threads untouched",
              session.lastSeen[visitChannel] == lastSeenBefore && session.intentionallyUnread == intentionallyUnreadBefore &&
              session.knownThreads == knownThreadsBefore && session.threadParents == threadParentsBefore &&
              session.transcriptVisit(for: visitChannel) == visitStateBefore)

        var uncertainAllCalls = 0
        let uncertainAll = CollectionWindow(owner: isolated, title: "Uncertain mark all fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, markAllRead: { uncertainAllCalls += 1; throw RavenError.transport }, unreadIDs: { ["canonical-all-after-error"] }))
        defer { uncertainAll.close() }
        uncertainAll.markAllRead(); await uncertainAll.batchTask?.value
        check("uncertain mark all mutations are never replayed and report the gap",
              uncertainAllCalls == 1 && uncertainAll.statusMessage.contains("Could not confirm that all notifications") &&
              session.unreadNotificationIDs == ["canonical-all-after-error"])

        let switchAllGate = Gate()
        var switchAllCalls = 0
        let switchedAll = CollectionWindow(owner: isolated, title: "Mark all account switch fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, markAllRead: { switchAllCalls += 1; await switchAllGate.submit([]) }, unreadIDs: { ["must-not-apply-all"] }))
        switchedAll.markAllRead()
        for _ in 0..<100 { if switchAllGate.continuation != nil { break }; await Task.yield() }
        let switchedAllTask = switchedAll.batchTask
        let switchedAllStarted = switchAllGate.continuation != nil
        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreInboxSwitch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let otherAccount = Account(origin: URL(string: "https://demo.invalid")!, user: "second-inbox", siteName: "Other fixture", clientID: "demo")
        let otherSession = try AccountSession(account: otherAccount, directory: otherDirectory, demo: true)
        defer { otherSession.stop() }
        otherSession.unreadNotificationIDs = ["second-account-unread"]
        isolated.use(otherSession)
        switchAllGate.release(); await switchedAllTask?.value
        check("mark all completion rejects a replaced account",
              switchedAllStarted && switchAllCalls == 1 && session.unreadNotificationIDs == ["canonical-all-after-error"]
                  && otherSession.unreadNotificationIDs == ["second-account-unread"]
                  && switchedAll.pager.records.allSatisfy { $0["is_read"].bool != true })
        check("a replaced account releases the in-flight Mark All state", !switchedAll.isBatchRunning && switchedAll.batchTask == nil)
        isolated.use(session)
        switchedAll.close()

        session.lastSeen.removeValue(forKey: visitChannel)
        session.intentionallyUnread.remove(visitChannel)
        session.knownThreads.remove("mark-all-thread-fixture")
        session.threadParents.removeValue(forKey: "mark-all-thread-fixture")
        session.interests = session.interests.filter { $0.value != visitChannel }
        return results
    }
}
