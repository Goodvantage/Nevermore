import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum PollSelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo, let channel = owner.channel else { throw AppError.message("Poll self-checks require the isolated demo account.") }
        var results: [(String, Bool)] = []
        func snapshot(id: String = "poll-fixture", multiple: Bool = false, anonymous: Bool = false, closed: Bool = false, selected: [String] = [], total: Int = 1) throws -> RavenPollSnapshot {
            try RavenPollSnapshot(getPoll: .object([
                "poll": .object(["name": .string(id), "owner": .string(session.account.user), "question": .string("Local poll fixture"), "is_multi_choice": .bool(multiple), "is_anonymous": .bool(anonymous), "is_disabled": .bool(closed), "max_choices": .number(multiple ? 2 : 0), "total_votes": .number(Double(total)), "options": .array((1...3).map { .object(["name": .string("option-\($0)"), "option": .string("Option \($0)"), "votes": .number(1)]) })]),
                "current_user_votes": .array(selected.map { .object(["option": .string($0)]) }),
                "votes": .object(["option-1": .array([.string("local-fixture-user")])])
            ]))
        }
        let message = RavenMessage(raw: .object(["name": .string("poll-message-fixture"), "channel_id": .string(channel.id), "message_type": .string("Poll"), "poll_id": .string("poll-fixture")]))
        let poll = owner.showPoll(message)
        defer { poll.close() }
        func controls() -> [NSButton] { poll.window?.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self) } ?? [] }
        func options() -> [NSButton] { controls().filter { $0.identifier?.rawValue.hasPrefix("option-") == true }.sorted { ($0.identifier?.rawValue ?? "") < ($1.identifier?.rawValue ?? "") } }
        func button(_ title: String) -> NSButton? { controls().first { $0.title == title } }
        func fields() -> [NSTextField] { poll.window?.contentView.map { InteractionSelfChecks.descendants($0, of: NSTextField.self) } ?? [] }
        poll.apply(try snapshot())
        poll.window?.contentView?.layoutSubtreeIfNeeded()
        let single = options()
        results.append(("native poll options have a visible bounded layout", single.count == 3 && single.allSatisfy { $0.frame.width > 0 && $0.superview?.frame.width ?? 0 > 100 }))
        single.first?.performClick(nil); single.last?.performClick(nil)
        results.append(("single-choice poll selection uses one stable option identity", single.filter { $0.state == .on }.count == 1 && single.last?.state == .on))
        results.append(("demo poll selection never enables network mutations", single.allSatisfy(\.isEnabled) && button("Submit Vote")?.isEnabled == false && button("Close Poll")?.isEnabled == false))
        poll.apply(try snapshot(multiple: true))
        let multi = options(); multi.forEach { $0.performClick(nil) }
        results.append(("multi-choice limits reject the new click without changing earlier choices", multi.prefix(2).allSatisfy { $0.state == .on } && multi.last?.state == .off))
        let stale = multi[0]
        poll.apply(try snapshot(multiple: true, selected: ["option-2"]))
        let voted = options()
        stale.performClick(nil)
        results.append(("existing votes stay immutable until retracted", voted.allSatisfy { !$0.isEnabled } && voted.filter { $0.state == .on }.map { $0.identifier!.rawValue } == ["option-2"]))
        poll.apply(try snapshot(anonymous: true))
        results.append(("anonymous poll results discard voter identities", fields().allSatisfy { !$0.stringValue.contains("local-fixture-user") } && InteractionSelfChecks.descendants(poll.window!.contentView!, of: NSTableView.self).allSatisfy { $0.numberOfRows == 0 }))
        do {
            let savedChannel = owner.channel, savedChannels = session.channels
            let savedRanges = owner.messageRanges, savedSelection = owner.transcript.selectedRange()
            defer {
                owner.channel = savedChannel; session.channels = savedChannels
                owner.messageRanges = savedRanges; owner.transcript.setSelectedRange(savedSelection)
            }
            var archived = channel.raw.object; archived["is_archived"] = .bool(true)
            owner.channel = RavenChannel(raw: .object(archived))
            session.channels = session.channels.map { $0.id == channel.id ? RavenChannel(raw: .object(archived)) : $0 }
            owner.messageRanges = [(NSRange(location: 0, length: 1), message)]
            owner.transcript.setSelectedRange(NSRange(location: 0, length: 0))
            poll.apply(try snapshot())
            let command = NSMenuItem(title: "View Poll", action: #selector(ConversationWindow.vote(_:)), keyEquivalent: "")
            results.append(("archived polls remain readable through the native menu", owner.validateMenuItem(command) && fields().contains { $0.stringValue == "Local poll fixture" } && options().allSatisfy { !$0.isEnabled }))
        }
        poll.apply(try snapshot(closed: true))
        results.append(("closed polls disable selection", options().allSatisfy { !$0.isEnabled }))
        poll.apply(try snapshot(id: "foreign-poll"))
        results.append(("a mismatched poll identity clears private content", options().isEmpty && fields().allSatisfy { $0.stringValue != "Local poll fixture" }))
        poll.apply(try snapshot())
        session.revokedChannels.insert(channel.id); session.notify()
        results.append(("permission revocation clears native poll content", options().isEmpty && fields().allSatisfy { $0.stringValue != "Local poll fixture" }))
        session.revokedChannels.remove(channel.id)
        poll.apply(try snapshot())
        poll.close()
        results.append(("closing a poll releases its owner and private labels", !owner.pollWindows.contains { $0 === poll } && fields().allSatisfy { $0.stringValue != "Local poll fixture" }))

        owner.createPoll(nil)
        for _ in 0..<100 { if owner.window?.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let hadPollComposer = owner.window?.attachedSheet != nil
        owner.closePollWindows()
        for _ in 0..<100 { if owner.window?.attachedSheet == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        results.append(("account-bound poll composition cancels through its owner", hadPollComposer && owner.window?.attachedSheet == nil))
        if let content = owner.window?.attachedSheet?.contentView {
            InteractionSelfChecks.descendants(content, of: NSButton.self).first { $0.title == "Cancel" }?.performClick(nil)
        }

        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let editor = PollEditorSheet(parent: parent, timeZone: .gmt)
        editor.question.stringValue = "Fixture"; editor.options.string = "One\nTwo\nThree"
        editor.multiple.state = .on; editor.limit.selectItem(at: 3); editor.accept()
        results.append(("poll editor rejects a finite limit equal to the option count", !editor.status.stringValue.isEmpty))
        editor.multiple.state = .off; editor.timed.state = .on; editor.deadline.dateValue = .distantPast; editor.accept()
        results.append(("poll editor rejects a closing time in the past", editor.status.stringValue.contains("future")))
        editor.cancel()
        parent.makeKeyAndOrderFront(nil)
        let pending = Task { try await PollEditorSheet.create(on: parent, timeZone: .gmt) }
        for _ in 0..<100 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        pending.cancel()
        let cancelled = try await pending.value
        for _ in 0..<100 { if parent.attachedSheet == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        results.append(("cancelling poll creation dismisses its native sheet", cancelled == nil && parent.attachedSheet == nil))
        let closing = Task { try await PollEditorSheet.create(on: parent, timeZone: .gmt) }
        for _ in 0..<100 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        parent.close()
        for _ in 0..<100 { if parent.attachedSheet == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        results.append(("closing a poll editor parent completes without submission", try await closing.value == nil && parent.attachedSheet == nil))
        return results
    }
}
