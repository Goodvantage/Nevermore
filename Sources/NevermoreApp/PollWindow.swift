import AppKit
import NevermoreCore
import RavenProtocol

@MainActor
final class PollWindow: NSWindowController, NSWindowDelegate {
    private struct VoterRow {
        let optionID: String
        let optionText: String
        let userID: String
    }

    private enum PollError: LocalizedError {
        case unavailable
        case accessChanged
        case pollChanged
        case demoReadOnly
        case missingPollID
        case noVote

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This poll is not available."
            case .accessChanged:
                return "Access to this conversation changed."
            case .pollChanged:
                return "This poll changed. Refresh it before continuing."
            case .demoReadOnly:
                return "Demo mode does not send changes to Raven."
            case .missingPollID:
                return "This message does not identify a poll."
            case .noVote:
                return "You have not voted in this poll."
            }
        }
    }

    private weak var conversation: ConversationWindow?
    private weak var boundSession: AccountSession?
    private let boundChannelID: String
    private let boundMessageID: String
    private let boundPollID: String?

    private var snapshot: RavenPollSnapshot?
    private var pollID: String?
    private var readGeneration = 0
    private var mutationGeneration = 0
    private var readTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var observerToken: NSObjectProtocol?
    private var optionButtons: [NSButton] = []
    private var optionIDs: [String] = []
    private var voterRows: [VoterRow] = []
    private var closed = false
    private var busy = false
    private var needsRefresh = true
    private var confirmation: NSAlert?

    private let questionLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let optionsStack = NSStackView()
    private let optionsScroll = NSScrollView()
    private let votersTable = NSTableView()
    private let votersScroll = NSScrollView()
    private let votersTitle = NSTextField(labelWithString: "Voters")
    private let submitButton = NSButton(title: "Submit Vote", target: nil, action: nil)
    private let retractButton = NSButton(title: "Retract Vote", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Poll", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    var didClose: (() -> Void)?

    init(owner: ConversationWindow, message: RavenMessage) {
        self.conversation = owner
        self.boundSession = owner.session
        self.boundChannelID = message.channelID
        self.boundMessageID = message.id
        let rawPollID = message.raw["poll_id"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.boundPollID = rawPollID?.isEmpty == false ? rawPollID : nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Poll"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 400)
        window.center()

        configureUI()
        observeSessionChanges()
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func apply(_ snapshot: RavenPollSnapshot) {
        guard !closed, currentSession() != nil else { return }
        guard validateSnapshotBinding(snapshot) else {
            invalidate(reason: PollError.pollChanged.localizedDescription)
            return
        }
        self.snapshot = snapshot
        self.pollID = snapshot.id
        needsRefresh = false
        rebuildOptions(from: snapshot)
        rebuildVoters(from: snapshot, explicitVotes: nil)
        updateChrome()
        statusLabel.stringValue = ""
    }

    func refresh() {
        guard !closed, !busy else { return }
        guard let session = currentSession() else {
            invalidate(reason: PollError.accessChanged.localizedDescription)
            return
        }
        guard !session.demo else {
            statusLabel.stringValue = "Demo mode: use applied poll snapshots."
            updateChrome()
            return
        }
        let generation = beginRead()
        readTask = Task { [weak self] in
            await self?.performRefresh(session: session, generation: generation)
        }
    }

    override func close() {
        if let sheet = confirmation?.window, window?.attachedSheet === sheet {
            window?.endSheet(sheet, returnCode: .abort)
        }
        confirmation = nil
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        readTask?.cancel(); readTask = nil
        mutationTask?.cancel(); mutationTask = nil
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
            self.observerToken = nil
        }
        optionButtons.removeAll()
        optionIDs.removeAll()
        voterRows.removeAll()
        votersTable.reloadData()
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        snapshot = nil
        pollID = nil
        questionLabel.stringValue = ""
        metaLabel.stringValue = ""
        totalLabel.stringValue = ""
        statusLabel.stringValue = ""
        let callback = didClose
        didClose = nil
        callback?()
    }

    private func configureUI() {
        questionLabel.isSelectable = true
        metaLabel.isSelectable = true
        questionLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        questionLabel.setAccessibilityLabel("Poll question")
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.setAccessibilityLabel("Poll details")
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.setAccessibilityLabel("Total voters")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Poll status")
        votersTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        votersTitle.textColor = .secondaryLabelColor

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        let optionsDocument = PollDocumentView()
        optionsDocument.translatesAutoresizingMaskIntoConstraints = false
        optionsDocument.addSubview(optionsStack)
        NSLayoutConstraint.activate([
            optionsStack.leadingAnchor.constraint(equalTo: optionsDocument.leadingAnchor, constant: 4),
            optionsStack.trailingAnchor.constraint(equalTo: optionsDocument.trailingAnchor, constant: -4),
            optionsStack.topAnchor.constraint(equalTo: optionsDocument.topAnchor, constant: 4),
            optionsStack.bottomAnchor.constraint(equalTo: optionsDocument.bottomAnchor, constant: -4),
            optionsStack.widthAnchor.constraint(equalTo: optionsDocument.widthAnchor, constant: -8)
        ])
        optionsScroll.documentView = optionsDocument
        optionsDocument.widthAnchor.constraint(equalTo: optionsScroll.contentView.widthAnchor).isActive = true
        optionsScroll.hasVerticalScroller = true
        optionsScroll.borderType = .bezelBorder
        optionsScroll.setAccessibilityLabel("Poll options")

        let optionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("option"))
        optionColumn.title = "Option"
        let voterColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("voter"))
        voterColumn.title = "Voter"
        votersTable.addTableColumn(optionColumn)
        votersTable.addTableColumn(voterColumn)
        votersTable.headerView = NSTableHeaderView()
        votersTable.delegate = self
        votersTable.dataSource = self
        votersTable.allowsMultipleSelection = false
        votersTable.usesAlternatingRowBackgroundColors = true
        votersTable.setAccessibilityLabel("Poll voters")
        votersScroll.documentView = votersTable
        votersScroll.hasVerticalScroller = true
        votersScroll.borderType = .bezelBorder
        votersScroll.setAccessibilityLabel("Poll voter results")

        submitButton.target = self
        submitButton.action = #selector(submitVote)
        submitButton.setAccessibilityLabel("Submit selected vote")
        retractButton.target = self
        retractButton.action = #selector(retractVote)
        retractButton.setAccessibilityLabel("Retract vote")
        closeButton.target = self
        closeButton.action = #selector(closePoll)
        closeButton.setAccessibilityLabel("Close poll")
        refreshButton.target = self
        refreshButton.action = #selector(refreshAction)
        refreshButton.setAccessibilityLabel("Refresh poll")

        let buttons = NSStackView(views: [submitButton, retractButton, closeButton, NSView(), refreshButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.distribution = .fill

        let content = NSStackView(views: [questionLabel, metaLabel, totalLabel, optionsScroll, votersTitle, votersScroll, statusLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        guard let root = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = PollDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        root.addSubview(scroll)
        document.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            questionLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            metaLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            totalLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            optionsScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            optionsScroll.heightAnchor.constraint(equalToConstant: 180),
            votersTitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            votersScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            votersScroll.heightAnchor.constraint(equalToConstant: 160),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func observeSessionChanges() {
        observerToken = NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let session = note.object as? AccountSession
            MainActor.assumeIsolated {
                guard let session, session === self.boundSession else { return }
                if !self.isAuthorized(session: session) {
                    self.invalidate(reason: PollError.accessChanged.localizedDescription)
                } else {
                    self.updateChrome()
                    if !session.demo, !self.busy, self.readTask == nil {
                        let generation = self.beginRead()
                        self.readTask = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            await self?.performRefresh(session: session, generation: generation)
                        }
                    }
                }
            }
        }
    }

    private func beginRead() -> Int {
        readTask?.cancel()
        readGeneration += 1
        return readGeneration
    }

    private func beginMutation() -> Int {
        mutationGeneration += 1
        return mutationGeneration
    }

    private func currentSession() -> AccountSession? {
        guard !closed, let conversation, let session = boundSession, session === conversation.session, conversation.isCurrent(session) else { return nil }
        return isAuthorized(session: session) ? session : nil
    }

    private func isAuthorized(session: AccountSession) -> Bool {
        guard !session.stopped else { return false }
        guard !ChannelPolicy.isRevoked(channelID: boundChannelID, revoked: session.revokedChannels, threadParents: session.threadParents) else { return false }
        if let conversation, conversation.isClosed { return false }
        return conversation?.isCurrent(session) == true
    }

    private func validateSnapshotBinding(_ snapshot: RavenPollSnapshot) -> Bool {
        if let boundPollID, snapshot.id != boundPollID { return false }
        if let pollID, snapshot.id != pollID { return false }
        return true
    }

    private func performRefresh(session: AccountSession, generation: Int) async {
        defer { if generation == readGeneration { readTask = nil } }
        do {
            let raw = try await session.client.rpc("raven.api.raven_poll.get_poll", arguments: ["message_id": .string(boundMessageID)])
            let next = try RavenPollSnapshot(getPoll: raw)
            guard !Task.isCancelled, generation == readGeneration, currentSession() === session else { return }
            guard validateSnapshotBinding(next) else {
                invalidate(reason: PollError.pollChanged.localizedDescription)
                return
            }
            // Keep an unsubmitted choice across updates to vote counts only.
            let local = snapshot?.selectedOptionIDs.isEmpty == true && next.selectedOptionIDs.isEmpty &&
                optionIDs == next.options.map(\.id) ? Set(currentSelectedOptionIDs()) : nil
            apply(next)
            if let local {
                optionButtons.forEach { $0.state = local.contains($0.identifier?.rawValue ?? "") ? .on : .off }
                updateChrome()
            }
        } catch {
            guard !Task.isCancelled, generation == readGeneration, !closed else { return }
            // A failed canonical refresh cannot establish current access. Clear
            // private content until a successful read revalidates it.
            invalidate(reason: error.localizedDescription)
        }
    }

    private func rebuildOptions(from snapshot: RavenPollSnapshot) {
        optionButtons.removeAll()
        optionIDs = snapshot.options.map(\.id)
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let selected = selectedOptionIDsForDisplay(snapshot)
        let closedForInput = snapshot.closed
        for option in snapshot.options {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 8

            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(optionToggled(_:)))
            button.setButtonType(snapshot.multiChoice ? .switch : .radio)
            button.identifier = NSUserInterfaceItemIdentifier(option.id)
            button.state = selected.contains(option.id) ? .on : .off
            button.isEnabled = !closedForInput
            button.setAccessibilityLabel(option.text)
            optionButtons.append(button)

            let label = NSTextField(wrappingLabelWithString: "\(option.text) — \(option.voteCount)")
            label.setAccessibilityLabel("\(option.text), \(option.voteCount) votes")
            row.addArrangedSubview(button)
            row.addArrangedSubview(label)
            optionsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: optionsStack.widthAnchor).isActive = true
        }
    }

    private func selectedOptionIDsForDisplay(_ snapshot: RavenPollSnapshot) -> Set<String> {
        guard !snapshot.selectedOptionIDs.isEmpty else { return [] }
        let known = Set(snapshot.options.map(\.id))
        return snapshot.selectedOptionIDs.intersection(known)
    }

    private func rebuildVoters(from snapshot: RavenPollSnapshot, explicitVotes: [String: [String]]?) {
        voterRows.removeAll()
        defer { votersTable.reloadData() }
        guard !snapshot.anonymous else {
            votersTitle.stringValue = "Voters (anonymous)"
            return
        }
        let votes = explicitVotes ?? snapshot.votersByOption
        let optionText = Dictionary(uniqueKeysWithValues: snapshot.options.map { ($0.id, $0.text) })
        var rows: [VoterRow] = []
        for option in snapshot.options {
            let users = votes[option.id] ?? []
            for user in users.prefix(500) {
                rows.append(VoterRow(optionID: option.id, optionText: optionText[option.id] ?? option.text, userID: user))
                if rows.count >= 2000 { break }
            }
            if rows.count >= 2000 { break }
        }
        voterRows = rows
        let available = votes.values.reduce(0) { $0 + $1.count }
        let boundedNote = rows.count < available ? " · showing \(rows.count) of \(available) selections" : ""
        votersTitle.stringValue = rows.isEmpty && snapshot.totalVotes > 0 ? "Voter names unavailable" : "Voters\(boundedNote)"
    }

    private func updateChrome() {
        if let snapshot {
            questionLabel.stringValue = snapshot.question
            var details: [String] = []
            details.append(snapshot.multiChoice ? "Multiple choice" : "Single choice")
            if snapshot.anonymous { details.append("Anonymous") }
            if snapshot.closed { details.append("Closed") }
            if snapshot.multiChoice, snapshot.maxChoices > 0 { details.append("Up to \(snapshot.maxChoices) choices") }
            if let endDate = snapshot.endDate, !endDate.isEmpty { details.append("Closes: \(endDate)") }
            metaLabel.stringValue = details.joined(separator: " · ")
            totalLabel.stringValue = "Total voters: \(snapshot.totalVotes)"

            let session = currentSession()
            let demo = session?.demo == true
            let writable = session.map { !$0.readOnly && !ChannelPolicy.isArchived(channelID: boundChannelID, channels: $0.channels, threadParents: $0.threadParents) } ?? false
            let canSelect = writable && !busy && !needsRefresh && !snapshot.closed
            let canWrite = canSelect && !demo
            let hasExistingVote = !snapshot.selectedOptionIDs.isEmpty
            let selectedCount = currentSelectedOptionIDs().count
            submitButton.isEnabled = canWrite && !hasExistingVote && selectedCount > 0
            retractButton.isEnabled = canWrite && hasExistingVote
            let isOwner = session?.account.user == snapshot.owner
            closeButton.isEnabled = canWrite && isOwner
            refreshButton.isEnabled = session != nil && !demo && !busy
            optionButtons.forEach { button in
                button.isEnabled = canSelect && !hasExistingVote
            }
            votersScroll.isHidden = snapshot.anonymous
            votersTitle.isHidden = snapshot.anonymous
        } else {
            questionLabel.stringValue = "Poll"
            metaLabel.stringValue = ""
            totalLabel.stringValue = ""
            submitButton.isEnabled = false
            retractButton.isEnabled = false
            closeButton.isEnabled = false
            refreshButton.isEnabled = currentSession()?.demo == false
            votersScroll.isHidden = true
            votersTitle.isHidden = true
        }
    }

    private func currentSelectedOptionIDs() -> [String] {
        let known = Set(optionIDs)
        return optionButtons.compactMap { button in
            guard button.state == .on, let id = button.identifier?.rawValue, known.contains(id) else { return nil }
            return id
        }
    }

    private func invalidate(reason: String) {
        readTask?.cancel(); readTask = nil
        mutationTask?.cancel(); mutationTask = nil
        readGeneration += 1
        mutationGeneration += 1
        busy = false
        needsRefresh = true
        snapshot = nil
        pollID = boundPollID
        optionButtons.removeAll()
        optionIDs.removeAll()
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        voterRows.removeAll()
        votersTable.reloadData()
        statusLabel.stringValue = reason
        updateChrome()
    }

    private func performMutation(
        preflightPollID: String,
        actionName: String,
        operation: @escaping (AccountSession, String, RavenPollSnapshot) async throws -> Void
    ) {
        guard !busy, !needsRefresh else { return }
        guard let session = currentSession() else {
            invalidate(reason: PollError.accessChanged.localizedDescription)
            return
        }
        guard !session.demo else {
            statusLabel.stringValue = PollError.demoReadOnly.localizedDescription
            updateChrome()
            return
        }
        busy = true
        readTask?.cancel(); readTask = nil; readGeneration += 1
        let generation = beginMutation()
        statusLabel.stringValue = "\(actionName)…"
        updateChrome()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.mutationGeneration {
                    self.busy = false
                    self.mutationTask = nil
                    self.updateChrome()
                }
            }
            do {
                guard !Task.isCancelled, generation == self.mutationGeneration, !self.closed else { return }
                guard let liveSession = self.currentSession(), liveSession === session else {
                    self.invalidate(reason: PollError.accessChanged.localizedDescription)
                    return
                }
                let raw = try await liveSession.client.rpc("raven.api.raven_poll.get_poll", arguments: ["message_id": .string(self.boundMessageID)])
                let fresh = try RavenPollSnapshot(getPoll: raw)
                guard !Task.isCancelled, generation == self.mutationGeneration, !self.closed else { return }
                guard let currentSession = self.currentSession(), currentSession === liveSession else {
                    self.invalidate(reason: PollError.accessChanged.localizedDescription)
                    return
                }
                guard fresh.id == preflightPollID, self.validateSnapshotBinding(fresh) else {
                    self.invalidate(reason: PollError.pollChanged.localizedDescription)
                    return
                }
                guard !fresh.closed else { throw RavenPollSnapshot.SelectionError.closed }
                try await currentSession.requireWritableConversation(self.boundChannelID)
                guard !Task.isCancelled, generation == self.mutationGeneration, self.currentSession() === currentSession else { return }
                self.needsRefresh = true
                try await operation(currentSession, fresh.id, fresh)
                guard !Task.isCancelled, generation == self.mutationGeneration, !self.closed else { return }
                guard self.currentSession() != nil else {
                    self.invalidate(reason: PollError.accessChanged.localizedDescription)
                    return
                }
                self.statusLabel.stringValue = "\(actionName) completed."
                self.busy = false
                self.refresh()
            } catch {
                guard !Task.isCancelled, generation == self.mutationGeneration, !self.closed else { return }
                self.needsRefresh = true
                // A local no-op (nothing to retract) needs no server re-check.
                if case PollError.noVote = error { self.statusLabel.stringValue = error.localizedDescription }
                else { self.statusLabel.stringValue = error.localizedDescription + " Refresh to check the server before trying again." }
                self.updateChrome()
            }
        }
    }

    @objc private func refreshAction() {
        refresh()
    }

    @objc private func optionToggled(_ sender: NSButton) {
        guard !closed, !busy, !needsRefresh, currentSession() != nil, let snapshot, !snapshot.closed, snapshot.selectedOptionIDs.isEmpty else { return }
        guard optionButtons.contains(where: { $0 === sender }), let optionID = sender.identifier?.rawValue, snapshot.options.contains(where: { $0.id == optionID }) else {
            if sender.state == .on { sender.state = .off }
            statusLabel.stringValue = PollError.pollChanged.localizedDescription
            updateChrome()
            return
        }
        if !snapshot.multiChoice, sender.state == .on {
            for button in optionButtons where button !== sender {
                button.state = .off
            }
        } else if snapshot.multiChoice, snapshot.maxChoices > 0, currentSelectedOptionIDs().count > snapshot.maxChoices {
            sender.state = .off
            statusLabel.stringValue = "Choose up to \(snapshot.maxChoices) options."
        }
        updateChrome()
    }

    @objc private func submitVote() {
        guard let snapshot, validateSnapshotBinding(snapshot) else {
            statusLabel.stringValue = PollError.unavailable.localizedDescription
            return
        }
        let selected = currentSelectedOptionIDs()
        do {
            try snapshot.validateSelection(selected)
        } catch {
            statusLabel.stringValue = error.localizedDescription
            return
        }
        performMutation(preflightPollID: snapshot.id, actionName: "Submitting vote") { session, _, fresh in
            try fresh.validateSelection(selected)
            _ = try await session.mutate("raven.api.raven_poll.add_vote", [
                "message_id": .string(self.boundMessageID),
                "option_id": .array(selected.map(JSONValue.string))
            ])
        }
    }

    @objc private func retractVote() {
        guard let snapshot else {
            statusLabel.stringValue = PollError.unavailable.localizedDescription
            return
        }
        let pollID = snapshot.id
        performMutation(preflightPollID: pollID, actionName: "Retracting vote") { session, currentPollID, fresh in
            // The vote may already be gone when the preflight snapshot arrives;
            // report that instead of letting the wrapper claim completion.
            guard !fresh.selectedOptionIDs.isEmpty else { throw PollError.noVote }
            _ = try await session.mutate("raven.api.raven_poll.retract_vote", ["poll_id": .string(currentPollID)])
        }
    }

    @objc private func closePoll() {
        guard let snapshot else {
            statusLabel.stringValue = PollError.unavailable.localizedDescription
            return
        }
        guard let session = currentSession(), session.account.user == snapshot.owner else {
            statusLabel.stringValue = "Only the poll owner can close the poll."
            return
        }
        guard !busy, !needsRefresh, confirmation == nil, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Close this poll?"
        alert.informativeText = "People will no longer be able to vote."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Poll")
        confirmation = alert
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            self.confirmation = nil
            guard result == .alertSecondButtonReturn, !self.closed else { return }
            self.performMutation(preflightPollID: snapshot.id, actionName: "Closing poll") { session, currentPollID, fresh in
                guard session.account.user == fresh.owner else {
                    throw AppError.message("Only the poll owner can close the poll.")
                }
                _ = try await session.mutate("raven.api.raven_poll.close_poll", ["poll_id": .string(currentPollID)])
            }
        }
    }
}

extension PollWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        voterRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < voterRows.count else { return nil }
        let entry = voterRows[row]
        let text: String
        if tableColumn?.identifier.rawValue == "option" {
            text = entry.optionText
        } else {
            if let session = currentSession(), let name = session.userNames[entry.userID], !name.isEmpty {
                text = name
            } else {
                text = entry.userID
            }
        }
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(text)
        return field
    }
}

@MainActor private final class PollDocumentView: NSView {
    override var isFlipped: Bool { true }
}
