import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum CollectionAttachmentActions {
    struct Transport {
        let message: @MainActor (String) async throws -> JSONValue
        let channelContext: @MainActor (String) async throws -> RavenChannelWriteContext
        let download: @MainActor (URL) async throws -> DownloadedAttachment
    }
    static func transport(_ session: AccountSession) -> Transport {
        Transport(message: { try await session.client.resource("Raven Message", name: $0, values: nil) }, channelContext: {
            // Reuse canonical channel/ancestor resource permission checks.
            // Archived conversations remain readable, so ignore isArchived.
            try await session.client.channelReadContext($0)
        }, download: {
            try await session.client.download($0, to: FileManager.default.temporaryDirectory)
        })
    }
}

extension CollectionWindow {
    var supportsSearchAttachments: Bool { kind == .search && source?.method == "raven.api.search.sqlite_search" }
    var selectedSearchAttachment: SearchAttachment? {
        guard supportsSearchAttachments, active, !isLoading, !isBatchRunning, let session,
              !session.demo || attachmentTransport != nil, let selected,
              let identity = SearchAttachment(selected), !session.deletedIDs.contains(identity.messageID),
              !session.deletedIDs.contains(identity.channelID),
              attachmentCanonicalParents.allSatisfy({ !session.revokedChannels.contains($0) && !session.deletedIDs.contains($0) }),
              identity.parentChannelID.map(session.revokedChannels.contains) != true,
              !ChannelPolicy.isRevoked(channelID: identity.channelID, revoked: session.revokedChannels, threadParents: session.threadParents) else { return nil }
        return identity
    }
    var canReadSearchAttachment: Bool { selectedSearchAttachment != nil && attachmentTask == nil }

    func cancelSearchAttachment() {
        if attachmentTask != nil && statusMessage == "Downloading selected attachment…" { statusMessage = "" }
        attachmentRevision = UUID(); attachmentTask?.cancel(); attachmentTask = nil; attachmentIdentity = nil; attachmentCanonicalParents = []
        let windows = searchAttachmentWindows; searchAttachmentWindows.removeAll()
        for window in windows { window.close() }
    }
    func validateSearchAttachment() {
        if attachmentIdentity != nil && attachmentIdentity != selectedSearchAttachment { cancelSearchAttachment() }
    }
    func installSearchAttachmentObservers() {
        guard supportsSearchAttachments, let session else { return }
        attachmentObservers.append(NotificationCenter.default.addObserver(forName: .sessionChanged, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateSearchAttachment(); self?.updateChrome() }
        })
        if let parent = conversationOwner?.window {
            attachmentObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelSearchAttachment() }
            })
        }
    }
    @objc func previewSearchAttachment() { readSearchAttachment(save: false) }
    @objc func saveSearchAttachment() { readSearchAttachment(save: true) }
    private func readSearchAttachment(save: Bool) {
        guard canReadSearchAttachment, let identity = selectedSearchAttachment, let session, let source,
              (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        cancelSearchAttachment()
        attachmentIdentity = identity
        let revision = attachmentRevision, generation = pager.generation, sourceKey = source.cacheKey
        let transport = attachmentTransport ?? CollectionAttachmentActions.transport(session)
        func current(_ collection: CollectionWindow) -> Bool {
            collection.attachmentRevision == revision && collection.pager.generation == generation && collection.source?.cacheKey == sourceKey && collection.active && collection.selectedSearchAttachment == identity
        }
        statusMessage = "Downloading selected attachment…"
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.attachmentRevision == revision {
                    self.attachmentTask = nil
                    if self.statusMessage == "Downloading selected attachment…" { self.statusMessage = "" }
                    self.updateChrome()
                }
            }
            do {
                guard current(self), !Task.isCancelled else { return }
                let message = try await transport.message(identity.messageID)
                guard current(self), !Task.isCancelled else { return }
                let context = try await transport.channelContext(identity.channelID)
                guard current(self), !Task.isCancelled else { return }
                guard context.channelID == identity.channelID else { throw RavenError.invalidResponse }
                // Retain authoritative ancestry just as canonical send preflight
                // does, so later parent revocation also invalidates this row.
                let chain = [identity.channelID] + context.parentChannelIDs
                for (child, parent) in zip(chain, chain.dropFirst()) { session.threadParents[child] = parent }
                self.attachmentCanonicalParents = context.parentChannelIDs
                guard current(self) else { return }
                let url = try identity.canonicalURL(message, origin: session.account.origin)
                let attachment = try await transport.download(url)
                guard current(self), !Task.isCancelled else { return }
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
                let link = identity.messageID.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "/raven/message/" + $0, relativeTo: session.account.origin)?.absoluteURL }
                let controller = AttachmentWindow(attachment: attachment, messageLink: link, active: { [weak self] in
                    guard let self else { return false }; return current(self)
                }, reportError: { [weak self] error in
                    guard let self, current(self) else { return }; self.conversationOwner?.app.showError(error)
                })
                controller.didClose = { [weak self, weak controller] in self?.searchAttachmentWindows.removeAll { $0 === controller } }
                self.searchAttachmentWindows.append(controller)
                self.statusMessage = ""
                controller.showWindow(nil)
                if save { controller.saveAs() } else { controller.previewDownloadedFile() }
            } catch {
                guard current(self), !Task.isCancelled, !(error is CancellationError) else { return }
                self.statusMessage = "Attachment unavailable: \(StatusLocalization.errorDescription(error))"
            }
        }
        updateChrome()
    }
}
