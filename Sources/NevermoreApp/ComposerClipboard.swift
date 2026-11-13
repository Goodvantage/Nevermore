import AppKit

@MainActor protocol MarkdownClipboardOwner: AnyObject {
    func validateSourceClipboard(_ command: ComposerClipboard.Command) -> Bool?
    func handleSourceClipboard(_ command: ComposerClipboard.Command, pasteboard: NSPasteboard) -> Bool
}

/// The library's rich-copy path imports generated HTML, and its smart paste
/// normalizes whitespace. Neither belongs in a literal Raven source editor.
/// Everywhere else, keep Cocoa's normal responder-chain clipboard behavior.
@MainActor final class ComposerClipboard: NSObject, NSMenuItemValidation {
    static let shared = ComposerClipboard()
    private final class Context { weak var owner: (any MarkdownClipboardOwner)?; init(_ owner: (any MarkdownClipboardOwner)?) { self.owner = owner } }
    private func owner(for sender: Any?) -> (any MarkdownClipboardOwner)? {
        ((sender as? NSMenuItem)?.representedObject as? Context)?.owner ?? NSApp.keyWindow?.delegate as? any MarkdownClipboardOwner
    }
    enum Command: Equatable {
        case copy, cut, paste, pastePlain
        var nativeAction: Selector {
            switch self {
            case .copy: #selector(NSText.copy(_:))
            case .cut: #selector(NSText.cut(_:))
            case .paste: #selector(NSText.paste(_:))
            case .pastePlain: #selector(NSTextView.pasteAsPlainText(_:))
            }
        }
        var action: Selector {
            switch self {
            case .copy: #selector(ComposerClipboard.copyText(_:))
            case .cut: #selector(ComposerClipboard.cutText(_:))
            case .paste: #selector(ComposerClipboard.pasteText(_:))
            case .pastePlain: #selector(ComposerClipboard.pastePlainText(_:))
            }
        }
        static func matching(_ action: Selector?) -> Self? {
            let commands: [Self] = [.copy, .cut, .paste, .pastePlain]
            return commands.first { $0.nativeAction == action || $0.action == action }
        }
    }

    @objc func copyText(_ sender: Any?) { perform(.copy, sender: sender) }
    @objc func cutText(_ sender: Any?) { perform(.cut, sender: sender) }
    @objc func pasteText(_ sender: Any?) { perform(.paste, sender: sender) }
    @objc func pastePlainText(_ sender: Any?) { perform(.pastePlain, sender: sender) }

    private func perform(_ command: Command, sender: Any?) {
        if let editor = owner(for: sender), editor.handleSourceClipboard(command, pasteboard: .general) { return }
        NSApp.sendAction(command.nativeAction, to: nil, from: sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = Command.matching(item.action) else { return false }
        if let editor = owner(for: item),
           let enabled = editor.validateSourceClipboard(command) { return enabled }
        guard let target = NSApp.target(forAction: command.nativeAction, to: nil, from: item), (target as AnyObject) !== self else { return false }
        if command == .paste, let composer = target as? ComposerView, composer.isEditable, ComposerView.hasAttachments(.general) { return true }
        let native = NSMenuItem(title: item.title, action: command.nativeAction, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(native) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(native) }
        return true
    }

    static func sourceMenu(_ menu: NSMenu, owner: (any MarkdownClipboardOwner)?) -> NSMenu {
        for item in menu.items {
            if let command = Command.matching(item.action) { item.action = command.action; item.target = shared; item.representedObject = Context(owner) }
            if let child = item.submenu { _ = sourceMenu(child, owner: owner) }
        }
        return menu
    }
}
