import AppKit

@MainActor extension ConversationWindow {
    /// Menu command uses the same inline mode switch as the toolbar. It
    /// toggles: in Markdown mode it switches back to Visual, so the menu is
    /// the way back as well as the way in.
    @objc func editMarkdown(_ sender: Any?) { inlineComposer.switchMode(inlineComposer.mode == .markdown ? .visual : .markdown) }
}
