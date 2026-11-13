import AppKit
import NevermoreCore

extension ConversationWindow {
    var canJumpToLatest: Bool {
        guard let session, let channel, isCurrent(session, channelID: channel.id),
              !session.deletedIDs.contains(channel.id),
              !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents),
              channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true else { return false }
        return !isFollowing || historyUpperID != nil || requestedAnchor != nil
    }

    func clearReadPosition() {
        latestReadAttempt = UUID(); latestReadTask?.cancel(); latestReadTask = nil
        readPosition.reset(); jumpLatestButton.isHidden = true
        jumpLatestButton.title = "Jump to Latest"
    }

    func updateReadPositionControl() {
        let available = canJumpToLatest
        jumpLatestButton.isHidden = !available
        jumpLatestButton.isEnabled = available
        jumpLatestButton.title = readPosition.hasNewMessages ? "New Messages · Jump to Latest" : "Jump to Latest"
        jumpLatestButton.setAccessibilityLabel(readPosition.hasNewMessages ? "New messages available. Jump to latest messages" : "Jump to latest messages")
    }

    /// Decides to show the newest messages and follow them, leaving a page
    /// of history or the context of an opened message. The caller renders.
    func followLatest() {
        historyUpperID = nil; requestedAnchor = nil; isFollowing = true
        // A scroll before the render arrives must not undo the decision.
        isUpdatingTranscript = true
    }

    @objc func jumpToLatest(_ sender: Any?) {
        guard canJumpToLatest, let session, let channel else { return }
        followLatest()
        readPosition.caughtUp(); updateReadPositionControl(); render()
        latestReadTask?.cancel()
        let attempt = UUID(); latestReadAttempt = attempt
        latestReadTask = Task { [weak self] in
            guard let self, self.isCurrent(session, channelID: channel.id), !Task.isCancelled else { return }
            defer { if self.latestReadAttempt == attempt { self.latestReadTask = nil } }
            do { try await session.load(channelID: channel.id) }
            catch {
                guard !Task.isCancelled, self.latestReadAttempt == attempt, self.isCurrent(session, channelID: channel.id) else { return }
                self.status.stringValue = "Could not refresh the latest messages. Showing cached history."
            }
        }
    }
}
