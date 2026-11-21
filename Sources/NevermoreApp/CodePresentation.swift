import AppKit
import NevermoreCore
import RavenProtocol

extension NSAttributedString.Key {
    static let nevermoreReadingControl = NSAttributedString.Key("NevermoreReadingControl")
    /// Marks the unread divider label; the transcript draws rules beside it.
    /// The "Nevermore." prefix keeps it out of copied text.
    static let nevermoreUnreadDivider = NSAttributedString.Key("Nevermore.UnreadDivider")
}

struct CodeReference: Equatable {
    let messageID: String
    let channelID: String
    let block: RichCodeBlock
    let parentChannelID: String?
    init(messageID: String, channelID: String, block: RichCodeBlock, parentChannelID: String? = nil) { self.messageID = messageID; self.channelID = channelID; self.block = block; self.parentChannelID = parentChannelID }
    var key: String { messageID + ":" + block.id }
}
struct CodeCommand {
    enum Action { case open, copy, toggle }
    let reference: CodeReference
    let action: Action
}

@MainActor enum CodePresentation {
    struct Output {
        let text: NSAttributedString
        let commands: [URL: CodeCommand]
        let references: [CodeReference]
    }
    static func lineCount(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }
    static func render(_ document: RichDocument, message: RavenMessage, fontSize: CGFloat, expanded: Set<String>, parentChannelID: String? = nil) -> Output {
        let blocks = CodeBlocks.extract(from: document)
        guard !blocks.isEmpty else { return Output(text: NativeRichText.readingString(document: document, fontSize: fontSize), commands: [:], references: []) }
        var next = 0
        var replacements: [(String, RichCodeBlock)] = []
        func replace(_ node: RichNode) -> RichNode {
            guard case .element(let tag, let attrs, let children) = node, attrs["data-spoiler"] == nil else { return node }
            if tag == "pre", blocks.indices.contains(next) {
                let token = "\u{F0000}\(UUID().uuidString)\u{F0001}"
                replacements.append((token, blocks[next])); next += 1
                return .element("p", [:], [.text(token)])
            }
            return .element(tag, attrs, children.map(replace))
        }
        let skeleton = RichDocument(nodes: document.nodes.map(replace), canEdit: false)
        let output = NSMutableAttributedString(attributedString: NativeRichText.readingString(document: skeleton, fontSize: fontSize))
        var commands: [URL: CodeCommand] = [:]
        var references: [CodeReference] = []
        for (token, block) in replacements.reversed() {
            let range = (output.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            let reference = CodeReference(messageID: message.id, channelID: message.channelID, block: block, parentChannelID: parentChannelID)
            references.append(reference)
            let replacement = NSMutableAttributedString(string: "Code\(block.language.map { " · \($0)" } ?? "") · \(lineCount(block.lineCount)) · ", attributes: [.font: NSFont.systemFont(ofSize: max(11, fontSize - 2)), .foregroundColor: NSColor.themeSecondaryText])
            func link(_ title: String, _ action: CodeCommand.Action) {
                let url = URL(string: "nevermore-code://block/\(UUID().uuidString)")!
                commands[url] = CodeCommand(reference: reference, action: action)
                replacement.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: max(11, fontSize - 2)), .foregroundColor: NSColor.themeLink, .link: url]))
            }
            link("Open Reader", .open); replacement.append(NSAttributedString(string: " · ")); link("Copy Code", .copy)
            let isExpanded = !block.isLong || expanded.contains(reference.key)
            if block.isLong { replacement.append(NSAttributedString(string: " · ")); link(isExpanded ? "Collapse" : "Expand", .toggle) }
            replacement.addAttribute(.nevermoreReadingControl, value: true, range: NSRange(location: 0, length: replacement.length))
            replacement.append(NSAttributedString(string: "\n"))
            if isExpanded {
                replacement.append(NSAttributedString(string: block.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 1), weight: .regular), .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]))
            } else {
                replacement.append(NSAttributedString(string: "[Code collapsed · expand here or open the reader]", attributes: [.font: NSFont.systemFont(ofSize: max(11, fontSize - 1)), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            for key: NSAttributedString.Key in [.nevermoreBodyQuote, .paragraphStyle] {
                if let value = output.attribute(key, at: range.location, effectiveRange: nil) {
                    replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
                }
            }
            output.replaceCharacters(in: range, with: replacement)
        }
        return Output(text: output, commands: commands, references: references.reversed())
    }
}

@MainActor extension ConversationWindow {
    func executeCode(_ command: CodeCommand, pasteboard: NSPasteboard = .general) {
        let reference = command.reference
        guard let session, !session.stopped, !session.revokedChannels.contains(reference.channelID), reference.parentChannelID.map(session.revokedChannels.contains) != true, !session.deletedIDs.contains(reference.messageID),
              let message = messages.first(where: { $0.id == reference.messageID && $0.channelID == reference.channelID }),
              let document = try? RichTextCodec.parse(message.html), CodeBlocks.extract(from: document).contains(where: { $0.id == reference.block.id }) else { return }
        switch command.action {
        case .copy: pasteboard.clearContents(); pasteboard.setString(reference.block.text, forType: .string)
        case .toggle:
            if expandedCode.remove(reference.key) == nil { expandedCode.insert(reference.key) }
            render()
        case .open:
            let reader = codeReaders[reference.key] ?? CodeReaderWindow(session: session, reference: reference)
            reader.onClose = { [weak self] in self?.codeReaders.removeValue(forKey: reference.key) }
            codeReaders[reference.key] = reader; reader.showWindow(nil)
        }
    }
    @objc func openCodeReader(_ sender: Any?) {
        guard let message = selectedMessage, let document = try? RichTextCodec.parse(message.html) else { return }
        let blocks = CodeBlocks.extract(from: document)
        guard !blocks.isEmpty else { return }
        let parent = channel?.raw["parent_channel_id"].string
        Task { [weak self] in
            guard let self else { return }
            let index = blocks.count == 1 ? 0 : await self.choose("Open Code Block", items: blocks.map { "Code \($0.index + 1) · \($0.language ?? "plain text") · \(CodePresentation.lineCount($0.lineCount))" }, confirm: "Open")
            guard let index, blocks.indices.contains(index), !self.isClosed else { return }
            self.executeCode(CodeCommand(reference: CodeReference(messageID: message.id, channelID: message.channelID, block: blocks[index], parentChannelID: parent), action: .open))
        }
    }
    func closeCodeReaders() {
        for reader in Array(codeReaders.values) { reader.close() }
        codeReaders.removeAll(); codeCommands.removeAll(); expandedCode.removeAll()
    }
}
