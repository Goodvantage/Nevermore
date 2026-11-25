import AppKit
import NevermoreCore

enum ComposerShortcut: String, CaseIterable {
    case gif
    case emoji

    var usage: String {
        switch self {
        case .gif: "/gif [search]"
        case .emoji: "/emoji"
        }
    }

    var detail: String {
        switch self {
        case .gif: "Search for a GIF to send"
        case .emoji: "Open Emoji & Symbols"
        }
    }
}

struct ComposerShortcutInput: Equatable {
    let text: String
    private let name: String
    private let argument: String?
    var search: String { argument ?? "" }

    init?(_ text: String) {
        guard text.first == "/", !text.contains(where: \.isNewline) else { return nil }
        self.text = text
        let content = text.dropFirst()
        if let separator = content.firstIndex(where: \.isWhitespace) {
            name = content[..<separator].lowercased()
            argument = content[separator...].trimmingCharacters(in: .whitespaces)
        } else {
            name = content.lowercased()
            argument = nil
        }
    }

    var command: ComposerShortcut? {
        guard let shortcut = ComposerShortcut(rawValue: name), acceptsArguments(shortcut) else { return nil }
        return shortcut
    }

    func matches(_ shortcut: ComposerShortcut) -> Bool {
        if argument != nil { return shortcut == command }
        return shortcut.rawValue.hasPrefix(name)
    }

    func completion(for shortcut: ComposerShortcut) -> String {
        if command == shortcut, argument != nil { return text }
        return "/" + shortcut.rawValue + (shortcut == .gif ? " " : "")
    }

    private func acceptsArguments(_ shortcut: ComposerShortcut) -> Bool {
        shortcut == .gif || search.isEmpty
    }
}

@MainActor extension ConversationWindow {
    var shortcutInput: ComposerShortcutInput? {
        let editor = activeComposer
        guard editor.isEditable, !editor.hasMarkedText(), let input = ComposerShortcutInput(editor.string),
              ComposerShortcut.allCases.contains(where: input.matches) else { return nil }
        if editor.isRichText {
            let text = editor.attributedString()
            var isLiteral = false
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
                if attributes[.semantic] != nil || attributes[.attachment] != nil || attributes[.spoiler] != nil ||
                    attributes[.generated] != nil || attributes[.unsupported] != nil ||
                    (attributes[.font] as? NSFont).map({ NSFontManager.shared.traits(of: $0).contains(.fixedPitchFontMask) }) == true {
                    isLiteral = true
                    stop.pointee = true
                }
            }
            if isLiteral { return nil }
        }
        return input
    }

    private var canUseComposerShortcuts: Bool {
        guard let session, let channel, !session.stopped, !session.readOnly, !isArchivedConversation,
              editing == nil, !applyingDraft, !inlineComposer.applying, activeComposer.isEditable,
              !isAcceptingSend, window?.attachedSheet == nil, gifSelectionTask == nil, emojiSelectionTask == nil else { return false }
        return !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents) &&
            channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true
    }

    /// A shortcut owns the entire draft line, including search terms that may
    /// contain a mention trigger.
    func updateShortcutSuggestions() -> Bool {
        let editor = activeComposer
        guard let input = shortcutInput, canUseComposerShortcuts else {
            shortcutPopover.reset()
            return false
        }
        shortcutPopover.update(input, in: editor)
        return true
    }

    func handleCompletionKey(_ event: NSEvent) -> Bool {
        if shortcutPopover.popover.isShown, canUseComposerShortcuts, let input = shortcutInput {
            return shortcutPopover.handle(event, input: input, in: activeComposer)
        }
        return mentionPopover.handle(event)
    }

    func chooseShortcut(_ shortcut: ComposerShortcut, input: ComposerShortcutInput, action: SlashShortcutPopover.Action) {
        guard canUseComposerShortcuts, shortcutInput == input,
              SlashShortcutPopover.isAtEnd(of: activeComposer), input.matches(shortcut) else { return }
        switch action {
        case .complete: replaceShortcutText(with: input.completion(for: shortcut))
        case .run: runShortcut(shortcut, input: input)
        }
    }

    /// Send and Command-Return can run a complete command even when its
    /// suggestions are dismissed. Partial and unknown names are normal text.
    func submitShortcut() -> Bool {
        guard editing == nil, let input = shortcutInput, let shortcut = input.command else { return false }
        guard canUseComposerShortcuts else { NSSound.beep(); return true }
        runShortcut(shortcut, input: input)
        return true
    }

    private func runShortcut(_ shortcut: ComposerShortcut, input: ComposerShortcutInput) {
        guard !app.windows.contains(where: {
            $0 !== self && $0.session === session && $0.channel?.id == channel?.id && $0.activeComposer.hasMarkedText()
        }) else {
            status.stringValue = "Finish text composition in the other window before running a shortcut."
            return
        }
        shortcutPopover.close()
        replaceShortcutText(with: "")
        // AppKit may refuse a change to protected rich text. Run the action
        // only after the command was actually consumed.
        guard activeComposer.string.isEmpty else { return }
        switch shortcut {
        case .gif: openGIFPicker(query: input.search)
        case .emoji: showEmojiPalette(nil)
        }
    }

    private func replaceShortcutText(with replacement: String) {
        let editor = activeComposer
        editor.breakUndoCoalescing()
        editor.insertText(replacement, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
    }
}
