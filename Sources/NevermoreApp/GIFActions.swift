import AppKit
import NevermoreCore

@MainActor extension ConversationWindow {
    /// The GIF picker's services for this conversation. Self-checks set
    /// `gifSourcesOverride` to use fixtures.
    func gifPickerSources(_ session: AccountSession) -> GIFPickerSheet.Sources {
        if let gifSourcesOverride { return gifSourcesOverride }
        let provider = GIFProvider(storedValue: UserDefaults.standard.string(forKey: GIFProvider.defaultsKey))
        return GIFPickerSheet.Sources(search: GIFPreferences.searchClient(), provider: provider, media: session.gifMedia)
    }

    /// Whether a GIF can be sent from this conversation now.
    var canSendGIF: Bool {
        guard let session, channel != nil, window?.attachedSheet == nil, gifSelectionTask == nil, emojiSelectionTask == nil, editing == nil else { return false }
        return !session.readOnly && !isArchivedConversation && activeComposer.isEditable
    }

    /// Chooses a GIF from the reader's GIF service and sends it as its own
    /// message. A reply being written goes with the GIF, as with a typed
    /// message; the draft's text stays in the composer.
    @objc func sendGIF(_ sender: Any?) {
        guard canSendGIF, let session, let channel, let parent = window else { NSSound.beep(); return }
        let sources = gifPickerSources(session)
        gifSelectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.gifSelectionTask = nil; self.updateComposerAvailability() }
            do {
                let result = try await GIFPickerSheet.pick(on: parent, sources: sources, active: { [weak self] in self?.isCurrent(session, channelID: channel.id) == true && self?.editing == nil })
                switch result {
                case .cancelled: return
                case .settings: self.app.showSettingsPane(.gifs); return
                case .chosen(let item):
                    guard !Task.isCancelled, self.isCurrent(session, channelID: channel.id), self.editing == nil else { return }
                    guard let silent = self.sendsSilently(session) else { return }
                    let reply = self.replyTo
                    _ = try await session.sendGIF(item, channelID: channel.id, replyTo: reply, sendSilently: silent)
                    if reply != nil, self.isCurrent(session, channelID: channel.id), self.replyTo == reply { self.cancelContext() }
                    self.isFollowing = true
                    self.focusComposer()
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(session, channelID: channel.id) { self.app.showError(error) }
            }
        }
        updateComposerAvailability()
    }

    /// The site's working hours decide whether a send notifies, as for a
    /// typed message. Nil when the reader cancelled.
    private func sendsSilently(_ session: AccountSession) -> Bool? {
        switch OutgoingPolicy.decision(now: Date(), workingHours: session.workingHours, timezone: session.account.timezone, preference: session.userPreferences?.supportedQuietHoursNudge ?? .noNudge) {
        case .normal: return false
        case .silent: return true
        case .ask:
            let alert = NSAlert(); alert.messageText = "Outside site working hours"
            alert.informativeText = "Send without notifying your teammates? The site timezone is \(session.account.timezone)."
            alert.addButton(withTitle: "Send Silently"); alert.addButton(withTitle: "Send Normally"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return true
            case .alertSecondButtonReturn: return false
            default: return nil
            }
        }
    }
}
