import AppKit
import RavenProtocol
import NevermoreCore

/// Completing a fired, unread reminder through the real Later reminders
/// collection against a credential-free loopback fixture. No live site.
@MainActor enum ReminderCompletionSelfChecks {
    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Reminder checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreReminderCompletionCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: origin, user: "reminder-fixture-user", siteName: "Local fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root)
        let channel = RavenChannel(raw: .object(["name": .string("reminder-fixture-channel"), "channel_name": .string("Reminder fixture"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        session.channels = [channel]
        let owner = ConversationWindow(app: app, session: session)
        app.windows.append(owner)
        owner.showWindow(nil)
        let collection = CollectionWindow(owner: owner, title: "Reminders", records: [], kind: .reminders, source: CollectionWindow.Kind.reminders.source)
        collection.showWindow(nil)
        defer { collection.close(); owner.close(); session.stop() }

        var results: [(String, Bool)] = []
        func wait(_ condition: @MainActor () -> Bool, _ limit: Int = 400) async throws -> Bool {
            for _ in 0..<limit { if condition() { return true }; try await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        func stats() async throws -> JSONValue { try await session.client.rpc("nevermore_fixture.reminder_stats") }
        func count(_ value: JSONValue) -> Int { if case .number(let number) = value { return Int(number) }; return 0 }
        func row(_ name: String) -> JSONValue? { collection.pager.records.first { $0["name"].string == name } }
        func select(_ name: String) {
            guard let index = collection.pager.records.firstIndex(where: { $0["name"].string == name }) else { return }
            collection.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        func waitSheet() async throws -> NSWindow {
            guard let window = collection.window else { throw AppError.message("The reminders collection has no window.") }
            for _ in 0..<300 {
                if let sheet = window.attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded(); return sheet }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The reminder action sheet did not appear.")
        }
        func buttons(_ sheet: NSWindow) -> [NSButton] { sheet.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self) } ?? [] }
        func picker(_ sheet: NSWindow) -> NSPopUpButton? { sheet.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSPopUpButton.self).first } }
        func cancelSheet() async throws {
            _ = try await wait { collection.window?.attachedSheet == nil }
            guard let sheet = collection.window?.attachedSheet else { return }
            buttons(sheet).first { $0.title == "Cancel" }?.performClick(nil)
            _ = try await wait { collection.window?.attachedSheet == nil }
        }
        /// Opens Actions… and returns the offered titles, then cancels.
        func offeredActions() async throws -> [String] {
            _ = try await wait { collection.window?.attachedSheet == nil }
            collection.manage()
            let sheet = try await waitSheet()
            let titles = picker(sheet)?.itemTitles ?? []
            try await cancelSheet()
            return titles
        }
        func choose(_ title: String) async throws {
            _ = try await wait { collection.window?.attachedSheet == nil }
            collection.manage()
            let sheet = try await waitSheet()
            guard let popup = picker(sheet) else { throw AppError.message("The reminder action picker is missing.") }
            popup.selectItem(withTitle: title)
            guard let confirm = buttons(sheet).first(where: { $0.title == "Continue" }) else { throw AppError.message("The reminder action confirm button is missing.") }
            confirm.performClick(nil)
        }

        // The initial list load must finish before the menu is meaningful.
        let loaded = try await wait { !collection.isLoading && collection.pager.records.count == 5 }
        results.append(("the loopback reminders list loads", loaded))
        guard loaded else { return results }

        // A future reminder has not fired: no completion is offered.
        select("reminder-future")
        let futureTitles = try await offeredActions()
        results.append(("a future reminder offers no Mark Complete and retains the existing actions",
                        !futureTitles.contains("Mark Complete") && futureTitles.contains("Snooze…") && futureTitles.contains("Edit Time…") && futureTitles.contains("Delete Reminder")))

        // A fired, unread reminder offers completion plus the existing actions.
        select("reminder-fired-a")
        let firedTitles = try await offeredActions()
        let hasComplete = firedTitles.first == "Mark Complete"
        results.append(("a fired unread reminder offers Mark Complete and retains the existing actions",
                        hasComplete && firedTitles.contains("Snooze…") && firedTitles.contains("Edit Time…") && firedTitles.contains("Delete Reminder")))
        guard hasComplete else { return results }

        let before = try await stats()
        try await choose("Mark Complete")
        let completed = try await wait { row("reminder-fired-a").map { !ReminderCompletion.isFiredUnread($0) } == true }
        let after = try await stats()
        let marked = Set(after["last_marked"].array.compactMap(\.string))
        results.append(("one POST marks every fired reminder on the message and leaves other messages alone",
                        completed && count(after["mark_requests"]) == count(before["mark_requests"]) + 1
                        && after["last_message_id"] == .string("reminder-message-fixture")
                        && marked == Set(["reminder-fired-a", "reminder-fired-b"])
                        && row("reminder-other").map(ReminderCompletion.isFiredUnread) == true
                        && row("reminder-fired-b").map { !ReminderCompletion.isFiredUnread($0) } == true))
        results.append(("the same user's other reminder and another user's reminder on the same message are untouched",
                        after["rows"].array.first(where: { $0["name"].string == "reminder-other" })?["is_read"] == .number(0)
                        && after["rows"].array.first(where: { $0["name"].string == "reminder-other-user" })?["is_read"] == .number(0)))
        results.append(("the list and Home refresh canonically after completion",
                        count(after["list_requests"]) >= count(before["list_requests"]) + 2
                        && session.home.snapshot.reminders.value?.contains(where: {
                            ReminderCompletion.messageID($0) == "reminder-message-fixture" && ReminderCompletion.isFiredUnread($0)
                        }) == false))

        // An unavailable endpoint (HTTP 404) is explicit, not a false success.
        _ = try await session.client.rpc("nevermore_fixture.reminder_control", arguments: ["unavailable": .bool(true)], mutation: true)
        select("reminder-other")
        try await choose("Mark Complete")
        let unavailable = try await wait { collection.statusMessage.contains("cannot complete reminders") }
        let unavailableStats = try await stats()
        results.append(("a server without mark_reminder_read is an explicit unavailable result",
                        unavailable && unavailableStats["mark_requests"] == after["mark_requests"]
                        && row("reminder-other").map(ReminderCompletion.isFiredUnread) == true))

        // A dropped POST is uncertain and is never replayed.
        _ = try await session.client.rpc("nevermore_fixture.reminder_control", arguments: ["unavailable": .bool(false), "drop_next": .bool(true)], mutation: true)
        select("reminder-other")
        try await choose("Mark Complete")
        let uncertain = try await wait { collection.statusMessage.contains("could not be confirmed") }
        let uncertainStats = try await stats()
        results.append(("a dropped POST is uncertain, never replayed, and leaves the reminder unread",
                        uncertain && count(uncertainStats["mark_requests"]) == count(after["mark_requests"]) + 1
                        && row("reminder-other").map(ReminderCompletion.isFiredUnread) == true))

        _ = try await session.client.rpc("nevermore_fixture.reminder_control", arguments: ["fail_list": .bool(true), "drop_next": .bool(true)], mutation: true)
        select("reminder-other")
        try await choose("Mark Complete")
        let detail = try await wait { collection.statusMessage.contains("could not be confirmed") && collection.statusMessage.contains("503") }
        results.append(("a failed canonical reminder read preserves the evidence of the failed refresh", detail))

        return results
    }
}
