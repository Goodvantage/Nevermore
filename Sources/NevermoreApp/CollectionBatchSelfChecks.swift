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
        let transport = CollectionBatchActions.Transport(markRead: { await gate.submit($0) }, unreadIDs: {
            reads += 1; return ["still-unread"]
        })
        let inbox = CollectionWindow(owner: isolated, title: "Batch fixture", records: rows, kind: .inbox, batchTransport: transport)
        defer { inbox.close() }
        inbox.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
        inbox.updateChrome()
        check("only inbox supports multiple selection and disables single-row actions", inbox.table.allowsMultipleSelection && inbox.markReadButton.isEnabled && !inbox.openButton.isEnabled && !inbox.manageButton.isEnabled && inbox.selected == nil)
        let search = CollectionWindow(owner: isolated, title: "Single selection fixture", records: rows, kind: .search, batchTransport: transport)
        defer { search.close() }
        check("other collections keep single selection and hide the batch action", !search.table.allowsMultipleSelection && search.markReadButton.isHidden && !search.canMarkSelectedRead)
        let command = NSMenuItem(title: "Mark Selected Notifications Read", action: #selector(CollectionWindow.markSelectedRead), keyEquivalent: "")
        check("inbox batch menu validation follows the selected account and rows", inbox.validateMenuItem(command) && !search.validateMenuItem(command))
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
                batchTransport: .init(markRead: { await lateGate.submit($0) }, unreadIDs: { lateReads += 1; return ["must-not-apply"] }))
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
            batchTransport: .init(markRead: { _ in attempts += 1; throw RavenError.transport }, unreadIDs: { ["canonical-after-error"] }))
        defer { uncertain.close() }
        uncertain.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        uncertain.markSelectedRead(); await uncertain.batchTask?.value
        check("uncertain inbox mutations are never replayed and retain an explicit warning", attempts == 1 && uncertain.statusMessage.contains("Could not confirm") && session.unreadNotificationIDs == ["canonical-after-error"])

        let failedRead = CollectionWindow(owner: isolated, title: "Unread failure fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, unreadIDs: { throw RavenError.transport }))
        defer { failedRead.close() }
        failedRead.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        failedRead.markSelectedRead(); await failedRead.batchTask?.value
        check("failed inbox reconciliation preserves known attention state and reports the gap", session.unreadNotificationIDs == ["canonical-after-error"] && failedRead.statusMessage.contains("unread status could not be refreshed"))

        let readGate = Gate()
        let closingRead = CollectionWindow(owner: isolated, title: "Late unread fixture", records: rows, kind: .inbox,
            batchTransport: .init(markRead: { _ in }, unreadIDs: { await readGate.submit([]); return ["must-not-apply"] }))
        closingRead.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        closingRead.markSelectedRead()
        for _ in 0..<100 { if readGate.continuation != nil { break }; await Task.yield() }
        let reading = closingRead.batchTask
        let readStarted = readGate.continuation != nil
        closingRead.close(); readGate.release(); await reading?.value
        check("closed inboxes reject a delayed canonical unread response", readStarted && closingRead.records.isEmpty && session.unreadNotificationIDs == ["canonical-after-error"])
        return results
    }
}
