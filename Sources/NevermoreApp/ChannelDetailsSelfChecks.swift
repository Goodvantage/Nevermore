import AppKit
import NevermoreCore
import RavenProtocol

/// Native checks for Conversation Info ▸ Channel Details. Everything is built
/// from local channel snapshots in a disposable demo session; opening the
/// sheet makes no request, and the fixture window is closed afterwards.
@MainActor enum ChannelDetailsSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreChannelDetailsCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "details-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }

        func channel(_ id: String, _ extra: [String: JSONValue] = [:]) -> RavenChannel {
            RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)].merging(extra) { _, new in new }))
        }
        let description = "First line of the fixture description.\nSecond line with a much longer run of words that should wrap inside the sheet because it cannot fit on one line at the panel width."
        let full = channel("details-full", ["channel_name": .string("Full fixture"), "type": .string("Private"), "workspace": .string("Acme"), "channel_description": .string(description)])
        let direct = channel("details-dm", ["channel_name": .string("Morgan"), "is_direct_message": .bool(true), "type": .string("Public")])
        let thread = channel("details-thread", ["is_thread": .bool(true), "parent_channel_id": .string("details-full")])
        let sparse = channel("details-sparse", ["channel_name": .string("Sparse fixture"), "type": .string(""), "workspace": .string("  "), "channel_description": .string(" \n ")])
        session.channels = [full, direct, thread, sparse]

        let fixture = ConversationWindow(app: app, session: session)
        defer { fixture.close() }
        fixture.window?.orderFrontRegardless()
        fixture.channel = full

        let menu = NSMenu(title: "Conversation")
        fixture.populateConversationMenu(menu)
        let kept = ["Members…", "Pinned Messages", "Files", "Copy Link to Conversation"]
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        check("Channel Details keeps Members, Pins, Files and Copy Link reachable", kept.allSatisfy { title in menu.items.contains { $0.title == title } })
        guard let detailsItem = menu.items.first(where: { $0.title == "Channel Details" }), let action = detailsItem.action else {
            checks.append(("Conversation Info offers a scoped Channel Details item", false))
            return checks
        }
        check("Conversation Info offers a scoped Channel Details item", true)

        func awaitSheet() async throws -> NSWindow {
            for _ in 0..<100 {
                if let sheet = fixture.window?.attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded(); return sheet }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The channel details sheet did not appear.")
        }
        func awaitNoSheet() async throws {
            for _ in 0..<100 {
                if fixture.window?.attachedSheet == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The channel details sheet did not close.")
        }
        func selectableValues(_ sheet: NSWindow) -> [NSTextView] {
            (sheet.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSTextView.self) })?.filter { $0.isSelectable && !$0.isEditable } ?? []
        }
        func value(_ label: String, _ sheet: NSWindow) -> NSTextView? { selectableValues(sheet).first { $0.accessibilityLabel() == label } }
        func close(_ sheet: NSWindow) {
            (sheet.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSButton.self) })?.first { $0.title == "Close" }?.performClick(nil)
        }
        func notice(_ sheet: NSWindow) -> NSTextField? {
            sheet.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSTextField.self) }?.first { $0.accessibilityLabel() == "Channel details unavailable" }
        }

        _ = detailsItem.target?.perform(action, with: nil)
        let sheet = try await awaitSheet()
        let fields = [value("Name", sheet), value("Channel ID", sheet), value("Type", sheet), value("Workspace", sheet), value("Description", sheet)]
        let name = fields[0], id = fields[1], type = fields[2], workspace = fields[3], details = fields[4]
        check("Channel Details shows the current channel identity", name?.string == "Full fixture" && id?.string == "details-full")
        check("Channel Details shows type, workspace and nonempty description", type?.string == "Private" && workspace?.string == "Acme" && details?.string == description)
        check("Channel Details fields are native and selectable", fields.compactMap { $0 }.count == 5 && fields.compactMap { $0 }.allSatisfy { $0.isSelectable && !$0.isEditable && $0.accessibilityLabel()?.isEmpty == false })

        check("Channel Details gives the description the width of the sheet", (details?.enclosingScrollView?.contentView.bounds.width ?? 0) >= 460)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: details?.font ?? .systemFont(ofSize: 14))
        check("Channel Details wraps a multiline description", details?.textContainer?.widthTracksTextView == true && details?.isHorizontallyResizable == false && (details?.frame.height ?? 0) > lineHeight * 2)

        let closeButton = (sheet.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSButton.self) })?.first { $0.title == "Close" }
        let chain = fields.compactMap { $0 }
        var linked = true
        for (index, field) in chain.enumerated() where index + 1 < chain.count {
            if field.nextKeyView !== chain[index + 1] { linked = false }
        }
        if let first = chain.first, let last = chain.last { linked = linked && last.nextKeyView === closeButton && closeButton?.nextKeyView === first }
        check("Channel Details tab order runs through every field to Close and back", linked && sheet.initialFirstResponder === chain.first)
        check("Channel Details fields accept native key focus", chain.allSatisfy { $0.acceptsFirstResponder })

        let storedFontSize = UserDefaults.standard.double(forKey: "fontSize")
        defer { UserDefaults.standard.set(storedFontSize, forKey: "fontSize") }
        close(sheet); try await awaitNoSheet()
        UserDefaults.standard.set(24, forKey: "fontSize")
        _ = detailsItem.target?.perform(action, with: nil)
        let large = try await awaitSheet()
        check("Channel Details follows the reading text size", value("Name", large)?.font?.pointSize == 24)
        close(large); try await awaitNoSheet()
        UserDefaults.standard.set(storedFontSize, forKey: "fontSize")

        _ = detailsItem.target?.perform(action, with: nil)
        let escapeSheet = try await awaitSheet()
        escapeSheet.cancelOperation(nil)
        try await awaitNoSheet()
        check("Channel Details dismisses on Escape", fixture.window?.attachedSheet == nil)

        for (candidate, expectedType, label) in [(direct, "Direct message", "a direct message"), (thread, "Thread", "a thread"), (sparse, nil, "a channel with missing fields")] {
            fixture.channel = candidate
            _ = detailsItem.target?.perform(action, with: nil)
            let candidateSheet = try await awaitSheet()
            check("Channel Details adapts \(label) without empty labels", value("Type", candidateSheet)?.string == expectedType && value("Workspace", candidateSheet) == nil && value("Description", candidateSheet) == nil)
            check("Channel Details uses the available sheet width for \(label)", (value("Name", candidateSheet)?.enclosingScrollView?.contentView.bounds.width ?? 0) >= 460)
            close(candidateSheet); try await awaitNoSheet()
        }

        fixture.channel = full
        _ = detailsItem.target?.perform(action, with: nil)
        let permissionSheet = try await awaitSheet()
        session.revokedChannels.insert(full.id); session.notify()
        try await Task.sleep(for: .milliseconds(120))
        check("a permission change clears stale channel fields", value("Name", permissionSheet) == nil && notice(permissionSheet).map { !$0.isHidden && !$0.stringValue.isEmpty } == true)
        session.revokedChannels.remove(full.id); session.notify()
        try await Task.sleep(for: .milliseconds(120))
        check("restoring access restores the current channel details", value("Name", permissionSheet)?.string == "Full fixture" && notice(permissionSheet)?.isHidden == true)
        close(permissionSheet); try await awaitNoSheet()

        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreChannelDetailsSwitch-\(UUID())")
        let other = try AccountSession(account: Account(origin: URL(string: "https://demo.invalid")!, user: "details-other@example.invalid", siteName: "Fixture", clientID: "demo"), directory: otherDirectory, demo: true)
        defer { other.stop(); try? FileManager.default.removeItem(at: otherDirectory) }
        fixture.channel = full
        _ = detailsItem.target?.perform(action, with: nil)
        let heldSheet = try await awaitSheet()
        let heldField = value("Description", heldSheet)
        session.notify()
        try await Task.sleep(for: .milliseconds(120))
        check("ordinary account activity preserves the selected details field", heldField != nil && value("Description", heldSheet) === heldField)
        other.notify()
        try await Task.sleep(for: .milliseconds(120))
        check("activity in a second account leaves the details sheet open", fixture.window?.attachedSheet === heldSheet)
        fixture.use(other)
        try await awaitNoSheet()
        check("switching accounts closes Channel Details", fixture.window?.attachedSheet == nil)
        return checks
    }
}
