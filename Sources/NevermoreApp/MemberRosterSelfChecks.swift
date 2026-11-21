import AppKit
import NevermoreCore
import RavenProtocol

/// Native roster checks with a synthetic 247-member response: no server,
/// account or real channel membership is touched.
@MainActor enum MemberRosterSelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, let channel = owner.channel, let parent = owner.window else {
            return [("member roster fixture has a window, account and channel", false)]
        }
        var results: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { results.append((label, value)) }

        let me = session.account.user
        var names = [me: "Sam Taylor"]
        var entries: [String: [String: JSONValue]] = [
            me: ["is_admin": .number(1), "channel_member_name": .string("RCM-ME")],
        ]
        // Three members share one display name; their user IDs differ.
        for (index, id) in ["zoe@example.com", "alex@example.com", "mia@example.com"].enumerated() {
            names[id] = "Alex Rivera"
            entries[id] = ["is_admin": .number(index == 1 ? 1 : 0), "channel_member_name": .string(String(format: "RCM-%03d", index))]
        }
        for index in 0..<243 {
            let id = String(format: "member-%03d@example.com", index)
            names[id] = String(format: "Member %03d", index)
            entries[id] = ["is_admin": .number(0), "channel_member_name": .string(String(format: "RCM-%03d", index + 10))]
        }
        let response = JSONValue.object(entries.mapValues(JSONValue.object))
        let previousNames = session.userNames
        session.userNames = names
        defer { session.userNames = previousNames }

        func awaitSheet() async throws -> NSWindow {
            for _ in 0..<100 {
                if let sheet = parent.attachedSheet {
                    sheet.contentView?.layoutSubtreeIfNeeded()
                    return sheet
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The member roster sheet did not appear.")
        }
        func awaitNoSheet() async {
            for _ in 0..<100 {
                if parent.attachedSheet == nil { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func makeRoster(assign: @escaping (String) -> Void) -> MemberRosterWindow {
            let roster = MemberRosterWindow(owner: owner, session: session, channel: channel, response: response)
            roster.onMessage = { assign($0) }
            return roster
        }

        var recipient: String?
        let roster = makeRoster { recipient = $0 }
        roster.present(on: parent)
        let sheet = try await awaitSheet()
        check("the roster shows every returned member beyond 200", roster.members.count == 247 && roster.table.numberOfRows == 247)
        check("the roster shows the returned count", roster.status.stringValue == "247 members")
        check("duplicate display names stay separate in deterministic ID order", roster.matches.filter { $0.displayName == "Alex Rivera" }.map(\.userID) == ["alex@example.com", "mia@example.com", "zoe@example.com"])
        if let alexRow = roster.matches.firstIndex(where: { $0.userID == "alex@example.com" }) {
            let cell = roster.tableView(roster.table, viewFor: roster.table.tableColumns.first, row: alexRow) as? NSTextField
            check("the returned admin role is displayed", cell?.stringValue.contains("Admin") == true)
        } else { check("the returned admin role is displayed", false) }

        roster.search.stringValue = "alex rivera"
        roster.updateMatches()
        check("search narrows to duplicate display names", roster.table.numberOfRows == 3 && roster.matches.map(\.userID) == ["alex@example.com", "mia@example.com", "zoe@example.com"])
        check("search shows the filtered count", roster.status.stringValue == "3 of 247 members")
        roster.search.stringValue = "RCM-000"
        roster.updateMatches()
        check("search matches the returned membership document ID", roster.table.numberOfRows == 1 && roster.matches.first?.userID == "zoe@example.com")
        roster.search.stringValue = ""
        roster.updateMatches()

        guard let meRow = roster.matches.firstIndex(where: { $0.userID == me }) else { throw AppError.message("The roster fixture has no current-user row.") }
        roster.table.selectRowIndexes(IndexSet(integer: meRow), byExtendingSelection: false)
        check("the current user is listed but cannot be messaged", roster.selectedEntry?.userID == me && !roster.messageButton.isEnabled)
        guard let alexRow = roster.matches.firstIndex(where: { $0.userID == "alex@example.com" }) else { throw AppError.message("The roster fixture has no other-user row.") }
        roster.table.selectRowIndexes(IndexSet(integer: alexRow), byExtendingSelection: false)
        check("a valid other user enables Message", roster.messageButton.isEnabled)
        if let event = InteractionSelfChecks.key(36, window: sheet) { roster.table.keyDown(with: event) }
        check("Return on a selected member hands its user ID to the DM flow", recipient == "alex@example.com" && parent.attachedSheet == nil)

        var cancelledRecipient: String?
        let cancelled = makeRoster { cancelledRecipient = $0 }
        cancelled.present(on: parent)
        _ = try await awaitSheet()
        cancelled.cancelButton.performClick(nil)
        await awaitNoSheet()
        check("Cancel closes the roster without opening a DM", cancelledRecipient == nil && parent.attachedSheet == nil)

        let accessRoster = makeRoster { recipient = $0 }
        accessRoster.present(on: parent)
        _ = try await awaitSheet()
        session.revokedChannels.insert(channel.id)
        session.notify()
        await awaitNoSheet()
        check("losing channel access closes the roster", parent.attachedSheet == nil)
        // A members response can finish while the same channel is still
        // selected but its membership has just been withdrawn.
        let late = makeRoster { recipient = $0 }
        var lateClosed = false
        late.onClose = { lateClosed = true }
        late.present(on: parent)
        check("a member response arriving after withdrawal cannot show its roster",
              lateClosed && parent.attachedSheet !== late.window)
        late.cancel()
        await awaitNoSheet()

        session.revokedChannels.remove(channel.id)
        session.notify()
        owner.select(channel)
        await owner.loadTask?.value
        await owner.renderTask?.value

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMemberRosterCheck-\(UUID())")
        let otherSession = try AccountSession(account: Account(origin: URL(string: "https://fixture.invalid")!, user: "other-fixture@example.invalid", siteName: "Fixture", clientID: "fixture"), directory: directory, demo: true)
        otherSession.channels = [channel]
        defer { otherSession.stop(); try? FileManager.default.removeItem(at: directory) }
        let accountRoster = makeRoster { recipient = $0 }
        owner.presentMemberRoster(accountRoster, on: parent)
        let accountSheet = try await awaitSheet()
        check("the window owns the roster it presents", owner.memberRoster === accountRoster && accountSheet === accountRoster.window)
        owner.use(otherSession)
        await awaitNoSheet()
        check("switching accounts closes the roster", owner.session === otherSession && owner.memberRoster == nil && parent.attachedSheet == nil)
        owner.use(session)
        owner.select(channel)
        await owner.loadTask?.value
        await owner.renderTask?.value
        return results
    }
}
