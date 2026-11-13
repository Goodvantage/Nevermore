import AppKit

@MainActor extension ConversationWindow {
    /// Menu command uses the same inline mode switch as the toolbar.
    @objc func editMarkdown(_ sender: Any?) { inlineComposer.switchMode(.markdown) }
}
