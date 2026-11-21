import AppKit
import RavenProtocol
import NevermoreCore
import SQLite3

/// Drives Conversation ▸ Schedule against a credential-free loopback fixture,
/// covering the one create POST in each outcome: confirmed acceptance, an
/// ambiguous failure, navigation away from the conversation, a newer shared
/// draft revision, and a switch to another account mid-request.
@MainActor enum ScheduleNetworkSelfChecks {
    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Schedule checks require the local fixture runner.") }
        let channelA = RavenChannel(raw: .object(["name": .string("schedule-fixture-channel"), "channel_name": .string("Schedule A")]))
        // Same identities as the loopback fixture's schedule routes.
        let channelB = RavenChannel(raw: .object(["name": .string("schedule-fixture-elsewhere"), "channel_name": .string("Schedule B")]))
        var results: [(String, Bool)] = []

        func stats(_ session: AccountSession) async throws -> JSONValue { try await session.client.rpc("nevermore_fixture.schedule_stats") }
        func control(_ session: AccountSession, _ arguments: [String: JSONValue]) async throws { _ = try await session.client.rpc("nevermore_fixture.schedule_control", arguments: arguments) }
        func waitForRequests(_ session: AccountSession, _ expected: Double) async throws -> Bool {
            for _ in 0..<400 {
                if (try await stats(session))["requests"] == .number(expected) { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return (try await stats(session))["requests"] == .number(expected)
        }
        func wait(_ condition: @autoclosure () -> Bool) async throws -> Bool {
            for _ in 0..<400 {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        func makeSession(_ root: URL) throws -> AccountSession {
            let account = Account(origin: origin, user: "schedule-fixture-user", siteName: "Local fixture", clientID: "local-fixture")
            let session = try AccountSession(account: account, directory: root)
            session.channels = [channelA, channelB]
            return session
        }
        /// A fresh account and window per scenario, so drafts and revisions
        /// start empty and cannot leak between checks.
        func freshWindow(_ session: AccountSession) async -> ConversationWindow {
            let owner = ConversationWindow(app: app, session: session)
            app.windows.append(owner); owner.showWindow(nil); owner.select(channelA)
            await owner.loadTask?.value; await owner.renderTask?.value
            return owner
        }
        func awaitSheet(for owner: ConversationWindow) async throws -> NSWindow {
            for _ in 0..<200 {
                if let sheet = owner.window?.attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded(); return sheet }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The schedule date sheet did not appear.")
        }
        func type(_ session: AccountSession, _ text: String, into owner: ConversationWindow) async throws {
            owner.composer.insertText(text, replacementRange: NSRange(location: 0, length: owner.composer.string.utf16.count))
            await owner.saveTask?.value
            // The durable save must finish before the schedule snapshot, so a
            // late write cannot land after the acceptance clears the draft.
            for _ in 0..<200 {
                if session.unpersistedDraftRevisions[channelA.id] == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The durable schedule fixture draft did not finish saving.")
        }
        /// Opens the date sheet and confirms the picker's default time. The
        /// caller decides what happens while the single POST is in flight.
        func startSchedule(_ owner: ConversationWindow) async throws {
            owner.schedule(nil)
            let sheet = try await awaitSheet(for: owner)
            let content = sheet.contentView ?? NSView()
            guard InteractionSelfChecks.descendants(content, of: NSDatePicker.self).first != nil else { throw AppError.message("The schedule sheet has no date picker.") }
            guard let accept = InteractionSelfChecks.descendants(content, of: NSButton.self).first(where: { $0.title == "Schedule" }) else { throw AppError.message("The schedule sheet has no confirmation button.") }
            accept.performClick(nil)
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleAccepted-\(UUID())")
            let session = try makeSession(root)
            defer { session.stop(); Task { await session.client.invalidate() }; try? FileManager.default.removeItem(at: root) }
            let owner = await freshWindow(session)
            // Confirmed acceptance clears this conversation's shared draft and
            // reports the server's accepted time.
            try await control(session, ["mode": .string("success")])
            try await type(session, "Scheduled fixture", into: owner)
            try await startSchedule(owner)
            let cleared = try await wait(owner.status.stringValue.contains("Scheduled on server") && owner.composer.string.isEmpty)
            let clearedDraft = try await session.store.draft(channelID: channelA.id)
            let afterClear = try await stats(session)
            results.append(("a confirmed schedule reports acceptance and clears the shared draft", cleared && clearedDraft?.html.isEmpty == true && afterClear["requests"] == .number(1)))
            owner.close()
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleUncertain-\(UUID())")
            let session = try makeSession(root)
            defer { session.stop(); Task { await session.client.invalidate() }; try? FileManager.default.removeItem(at: root) }
            let owner = await freshWindow(session)
            // An ambiguous failure must be reviewed, never replayed. The
            // composer and its durable draft stay intact.
            try await control(session, ["mode": .string("fail")])
            try await type(session, "Uncertain fixture", into: owner)
            try await startSchedule(owner)
            let reviewed = try await wait(owner.status.stringValue.contains("result is uncertain"))
            let preserved = try await session.store.draft(channelID: channelA.id)
            let afterFailure = try await stats(session)
            results.append(("an indeterminate create directs review without a second POST and keeps the draft",
                            reviewed && owner.composer.string.contains("Uncertain fixture") && preserved?.html.contains("Uncertain fixture") == true && afterFailure["requests"] == .number(2)))
            owner.close()
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleNavigated-\(UUID())")
            let session = try makeSession(root)
            defer { session.stop(); Task { await session.client.invalidate() }; try? FileManager.default.removeItem(at: root) }
            let owner = await freshWindow(session)
            // Navigating to another conversation of the same account still hears
            // about the acceptance, but the original draft belongs to its
            // conversation and is left there.
            try await control(session, ["mode": .string("success"), "hold": .string("1")])
            try await type(session, "Navigated fixture", into: owner)
            try await startSchedule(owner)
            _ = try await waitForRequests(session, 3)
            owner.select(channelB); await owner.loadTask?.value; await owner.renderTask?.value
            try await control(session, ["release": .string("1")])
            let navigated = try await wait(owner.status.stringValue.contains("Scheduled on server"))
            let navigatedDraft = try await session.store.draft(channelID: channelA.id)
            results.append(("acceptance survives navigation and preserves the original draft",
                            navigated && owner.channel?.id == channelB.id && navigatedDraft?.html.contains("Navigated fixture") == true))
            owner.close()
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleRevision-\(UUID())")
            let session = try makeSession(root)
            defer { session.stop(); Task { await session.client.invalidate() }; try? FileManager.default.removeItem(at: root) }
            let owner = await freshWindow(session)
            // Another window's newer shared revision outranks the scheduled
            // snapshot, even though its content differs from it.
            try await control(session, ["mode": .string("success"), "hold": .string("1")])
            try await type(session, "Original fixture", into: owner)
            let originalRevision = session.draftRevisions[channelA.id, default: 0]
            try await startSchedule(owner)
            _ = try await waitForRequests(session, 4)
            let peer = ConversationWindow(app: app, session: session)
            app.windows.append(peer); peer.showWindow(nil); peer.select(channelA)
            await peer.loadTask?.value; await peer.renderTask?.value
            try await type(session, "newer shared edit", into: peer)
            let newerRevision = session.draftRevisions[channelA.id, default: 0]
            try await control(session, ["release": .string("1")])
            let keptNewer = try await wait(owner.status.stringValue.contains("Scheduled on server"))
            let newerDraft = try await session.store.draft(channelID: channelA.id)
            results.append(("a newer shared revision is preserved instead of being cleared",
                            keptNewer && newerRevision > originalRevision && newerDraft?.html.contains("newer shared edit") == true))
            peer.close(); owner.close()
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleCrossAccount-\(UUID())")
            let session = try makeSession(root)
            let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleOtherAccount-\(UUID())")
            defer { session.stop(); Task { await session.client.invalidate() }; try? FileManager.default.removeItem(at: root) }
            let owner = await freshWindow(session)
            // A different account owns the window when the answer arrives, so
            // it receives none of this account's feedback or draft changes.
            try await control(session, ["mode": .string("success"), "hold": .string("1")])
            try await type(session, "Cross-account fixture", into: owner)
            try await startSchedule(owner)
            _ = try await waitForRequests(session, 5)
            let otherAccount = Account(id: UUID(), origin: URL(string: "https://other-fixture.invalid")!, user: "other-fixture-user", siteName: "Other fixture", clientID: "other-fixture")
            let other = try AccountSession(account: otherAccount, directory: otherRoot, demo: true)
            defer { other.stop(); try? FileManager.default.removeItem(at: otherRoot) }
            owner.use(other)
            try await control(session, ["release": .string("1")])
            try await Task.sleep(for: .milliseconds(500))
            let crossDraft = try await session.store.draft(channelID: channelA.id)
            results.append(("switching accounts suppresses another account's schedule feedback",
                            !owner.status.stringValue.contains("Scheduled on server") && owner.session === other && crossDraft?.html.contains("Cross-account fixture") == true))
            owner.close()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreScheduleCleanup-\(UUID())")
        let cleanupSession = try makeSession(root)
        defer { cleanupSession.stop(); try? FileManager.default.removeItem(at: root) }
        let original = Draft(channelID: channelA.id, html: "<p>Keep my scheduled draft</p>")
        try await cleanupSession.save(original)
        var db: OpaquePointer?
        let openResult = sqlite3_open(root.appendingPathComponent(AccountStore.databaseFileName).path, &db)
        defer { sqlite3_close(db) }
        guard openResult == SQLITE_OK else {
            throw AppError.message("Could not open the schedule cleanup fixture.")
        }
        let abort = "CREATE TRIGGER reject_cleanup BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'unavailable'); END"
        guard sqlite3_exec(db, abort, nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not arm the schedule cleanup fixture.") }
        do {
            _ = try await cleanupSession.clearScheduledDraft(original, revision: cleanupSession.draftRevisions[channelA.id, default: 0])
            results.append(("the local cleanup fixture rejected its draft write", false))
        } catch {
            let durable = try await cleanupSession.store.draft(channelID: channelA.id)
            results.append(("a failed scheduled cleanup preserves both the durable and recoverable draft",
                            durable == original && cleanupSession.recoverableDrafts[channelA.id] == original))
        }
        return results
    }
}
