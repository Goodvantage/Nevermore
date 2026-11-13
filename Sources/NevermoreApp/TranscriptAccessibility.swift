import AppKit
import NevermoreCore
import RavenProtocol

/// Adds navigation over the existing text view. No accessibility children or
/// per-message views replace NSTextView's native selection and text interface.
@MainActor final class TranscriptAccessibility: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    struct Entry {
        let id: String
        let range: NSRange
        let label: String
    }
    enum Action: String, CaseIterable, Sendable {
        case reply = "Reply", openThread = "Open Thread", copyLink = "Copy Message Link"
    }
    private final class Result: NSAccessibilityCustomRotor.ItemResult {
        let id: String
        let revision: UUID
        init(view: TranscriptView, entry: Entry, revision: UUID) {
            self.id = entry.id; self.revision = revision
            super.init(targetElement: view)
            targetRange = entry.range; customLabel = entry.label
        }
    }
    private weak var owner: ConversationWindow?
    private weak var session: AccountSession?
    private var channelID: String?
    private var revision = UUID()
    private var entries: [Entry] = []
    private(set) lazy var rotor = NSAccessibilityCustomRotor(label: "Messages", itemSearchDelegate: self)

    init(owner: ConversationWindow) { self.owner = owner; super.init() }

    func clear() {
        revision = UUID(); entries.removeAll(); session = nil; channelID = nil
    }

    func refresh() {
        clear()
        guard let owner, let session = owner.session, let channel = owner.channel,
              owner.isCurrent(session, channelID: channel.id),
              channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true,
              !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents),
              !session.deletedIDs.contains(channel.id) else { return }
        self.session = session; channelID = channel.id
        let length = owner.transcript.attributedString().length
        entries = owner.messageRanges.prefix(500).compactMap { range, message in
            guard message.channelID == channel.id, !session.deletedIDs.contains(message.id),
                  range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.location <= length, range.length <= length - range.location else { return nil }
            let author = session.authorName(message)
            let body: String
            if !message.html.isEmpty, case .parsed(let document) = session.messageDocument(for: message) {
                // Code may be collapsed in the transcript. A rotor summary
                // must not reveal its hidden source; spoilers remain masked
                // by the same plain-text policy as other reading surfaces.
                func summarize(_ node: RichNode) -> RichNode {
                    guard case .element(let tag, let attributes, let children) = node else { return node }
                    if tag == "pre", attributes["data-spoiler"] == nil { return .text("[Code]") }
                    return .element(tag, attributes, children.map(summarize))
                }
                body = RichTextCodec.plainText(RichDocument(nodes: document.nodes.map(summarize)))
            } else {
                switch message.messageType {
                case "File": body = "Attachment"
                case "Image": body = "Image attachment"
                case "Poll": body = "Poll"
                default: body = "Message"
                }
            }
            let summary = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let time = session.displayTimestamp(message.creation)
            let label = "\(author.prefix(100)), \(time), \(summary.prefix(240))"
            return Entry(id: message.id, range: range, label: label)
        }
    }

    private var currentOwner: ConversationWindow? {
        guard let owner, let session, let channelID,
              owner.isCurrent(session, channelID: channelID),
              owner.channel?.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true,
              !session.deletedIDs.contains(channelID),
              !ChannelPolicy.isRevoked(channelID: channelID, revoked: session.revokedChannels, threadParents: session.threadParents) else { return nil }
        return owner
    }

    private func valid(_ entry: Entry, owner: ConversationWindow) -> Bool {
        guard let session, !session.deletedIDs.contains(entry.id) else { return false }
        return owner.messageRanges.contains { $0.1.id == entry.id && $0.0 == entry.range && $0.1.channelID == channelID }
    }

    func result(for parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let owner = currentOwner else { return nil }
        let direction = parameters.searchDirection == .next ? 1 : -1
        var index = direction > 0 ? 0 : entries.count - 1
        if let current = parameters.currentItem {
            guard let current = current as? Result, current.revision == revision,
                  let position = entries.firstIndex(where: { $0.id == current.id }) else { return nil }
            index = position + direction
        }
        while entries.indices.contains(index) {
            let entry = entries[index]
            if valid(entry, owner: owner), parameters.filterString.isEmpty || entry.label.localizedCaseInsensitiveContains(parameters.filterString) {
                return Result(view: owner.transcript, entry: entry, revision: revision)
            }
            index += direction
        }
        return nil
    }

    // Accessibility can probe outside the main thread. Decline those probes
    // before reading AppKit or account state, as with native Quick Look.
    // The reply never crosses threads: this box only permits the synchronous
    // assumeIsolated return of the SDK's explicitly non-Sendable AppKit item.
    private struct MainThreadReply: @unchecked Sendable {
        let value: NSAccessibilityCustomRotor.ItemResult?
    }
    private struct MainThreadParameters: @unchecked Sendable {
        let value: NSAccessibilityCustomRotor.SearchParameters
    }
    nonisolated func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard Thread.isMainThread else { return nil }
        let parameters = MainThreadParameters(value: searchParameters)
        return MainActor.assumeIsolated { MainThreadReply(value: result(for: parameters.value)) }.value
    }

    private func selectedEntry(owner: ConversationWindow) -> Entry? {
        entries.first { NSLocationInRange(owner.transcript.selectedRange().location, $0.range) && valid($0, owner: owner) }
    }

    private func canPerform(_ action: Action, owner: ConversationWindow) -> Bool {
        guard selectedEntry(owner: owner) != nil, let session else { return false }
        switch action {
        case .copyLink: return true
        case .reply: return !session.readOnly && !owner.isArchivedConversation && owner.composer.isEditable
        case .openThread: return !session.readOnly && !session.demo && !owner.isArchivedConversation
        }
    }

    /// AppKit's handler type has no isolation annotation. Build its block in
    /// a nonisolated context so Swift cannot insert a MainActor entry check
    /// ahead of the thread guard when an AX client invokes it off-main.
    nonisolated static func mainThreadHandler(_ action: @escaping @MainActor @Sendable () -> Bool) -> @Sendable () -> Bool {
        { @Sendable in
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { action() }
        }
    }

    func actions() -> [NSAccessibilityCustomAction] {
        guard let owner = currentOwner, let entry = selectedEntry(owner: owner) else { return [] }
        let expectedRevision = revision
        let expectedID = entry.id
        return Action.allCases.filter { canPerform($0, owner: owner) }.map { action in
            let handler: @Sendable () -> Bool = Self.mainThreadHandler { [weak self] in
                guard let self, self.revision == expectedRevision, let owner = self.currentOwner,
                      self.selectedEntry(owner: owner)?.id == expectedID, self.canPerform(action, owner: owner) else { return false }
                switch action {
                case .reply: owner.reply(nil)
                case .openThread: owner.openThread(nil)
                case .copyLink: owner.copyMessageLink(nil)
                }
                return true
            }
            return NSAccessibilityCustomAction(name: action.rawValue, handler: handler)
        }
    }

    func canMove(forward: Bool) -> Bool { destination(forward: forward) != nil }

    private func destination(forward: Bool) -> Entry? {
        guard let owner = currentOwner else { return nil }
        let location = owner.transcript.selectedRange().location
        let available = entries.filter { valid($0, owner: owner) }
        if location == NSNotFound { return forward ? available.first : available.last }
        if let current = available.firstIndex(where: { NSLocationInRange(location, $0.range) }) {
            let next = current + (forward ? 1 : -1)
            return available.indices.contains(next) ? available[next] : nil
        }
        return forward ? available.first(where: { $0.range.location > location }) : available.last(where: { $0.range.location < location })
    }

    @discardableResult func move(forward: Bool) -> Bool {
        guard let owner = currentOwner, let entry = destination(forward: forward) else { return false }
        owner.isFollowing = false
        owner.transcript.setSelectedRange(entry.range)
        owner.transcript.scrollRangeToVisible(entry.range)
        owner.window?.makeFirstResponder(owner.transcript)
        return true
    }
}

extension ConversationWindow {
    @objc func nextMessage(_ sender: Any?) { transcriptAccessibility.move(forward: true) }
    @objc func previousMessage(_ sender: Any?) { transcriptAccessibility.move(forward: false) }
}
