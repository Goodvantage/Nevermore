import AppKit

/// Main-menu commands address the focused representation. Other text fields
/// continue to use their ordinary responder-chain actions.
@MainActor final class ComposerCommandRouting: NSObject, NSMenuItemValidation {
    static let shared = ComposerCommandRouting()
    private var sourceOwner: ConversationWindow? {
        guard let owner = NSApp.keyWindow?.delegate as? ConversationWindow,
              owner.inlineComposer.mode == .markdown, owner.window?.firstResponder === owner.activeComposer else { return nil }
        return owner
    }
    @objc func performFormatting(_ sender: NSMenuItem) {
        guard let command = ComposerFormattingBar.Command(rawValue: sender.tag) else { return }
        if let owner = sourceOwner { owner.inlineComposer.format(command) }
        else if NSApp.sendAction(command.selector, to: nil, from: sender) {
            // A caret-only format changes the typing attributes, not the
            // selection, so no selection notification refreshes the toolbar.
            // sendAction applies the handler synchronously, so the refresh
            // below already sees the new typing attributes — and only runs
            // when something in the responder chain actually handled it.
            (NSApp.keyWindow?.windowController as? ConversationWindow)?.composerFormatting.updateSelection()
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = ComposerFormattingBar.Command(rawValue: item.tag) else { return false }
        if let owner = sourceOwner { return owner.activeComposer.isEditable && !owner.activeComposer.hasMarkedText() }
        guard let target = NSApp.target(forAction: command.selector) else { return false }
        let native = NSMenuItem(title: item.title, action: command.selector, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(native) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(native) }
        return true
    }
    func install(in menu: NSMenu) {
        for item in menu.items {
            guard let command = ComposerFormattingBar.Command.allCases.first(where: { $0.selector == item.action }) else { continue }
            item.tag = command.rawValue; item.action = #selector(performFormatting(_:)); item.target = self
        }
    }
}
