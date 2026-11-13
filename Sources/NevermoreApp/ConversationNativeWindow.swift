import AppKit

/// A file dropped anywhere outside the editor uses the same attachment
/// pipeline as a drop into it. Ordinary text drags remain text-system work.
@MainActor final class ConversationNativeWindow: NSWindow, NSDraggingDestination {
    weak var conversation: ConversationWindow?
    private(set) lazy var attachmentFieldEditor: NSTextView = {
        let editor = ConversationFileFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    @objc func undo(_ sender: Any?) {
        guard let conversation, conversation.inlineComposer.mode == .markdown, firstResponder === conversation.activeComposer else { undoManager?.undo(); return }
        conversation.inlineComposer.performUndo(redo: false)
    }
    @objc func redo(_ sender: Any?) {
        guard let conversation, conversation.inlineComposer.mode == .markdown, firstResponder === conversation.activeComposer else { undoManager?.redo(); return }
        conversation.inlineComposer.performUndo(redo: true)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let conversation, conversation.inlineComposer.mode == .markdown, firstResponder === conversation.activeComposer,
           item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            let undo = conversation.composer.undoManager
            let isUndo = item.action == #selector(self.undo(_:))
            (item as? NSMenuItem)?.title = isUndo ? undo?.undoMenuItemTitle ?? "Undo" : undo?.redoMenuItemTitle ?? "Redo"
            return conversation.composer.isEditable && !conversation.activeComposer.hasMarkedText()
                && (isUndo ? undo?.canUndo == true : undo?.canRedo == true)
        }
        return super.validateUserInterfaceItem(item)
    }

    fileprivate static func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
        PromisedFileReceiver.containsPromises(pasteboard)
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func acceptsFiles(_ sender: any NSDraggingInfo) -> Bool {
        guard let conversation, !conversation.isClosed, conversation.composer.isEditable,
              conversation.editing == nil, attachedSheet == nil,
              sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return Self.containsFiles(sender.draggingPasteboard)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { acceptsFiles(sender) ? .copy : [] }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptsFiles(sender) }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsFiles(sender), let conversation else { return false }
        return conversation.composer.performDragOperation(sender)
    }
}

/// A focused search control installs a temporary text view above the window
/// destination. Forward files instead of inserting their paths into a query;
/// leave ordinary text dragging and all editing to AppKit.
@MainActor private final class ConversationFileFieldEditor: NSTextView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ConversationNativeWindow.containsFiles(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        return (window as? ConversationNativeWindow)?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ConversationNativeWindow.containsFiles(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return (window as? ConversationNativeWindow)?.draggingUpdated(sender) ?? []
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard ConversationNativeWindow.containsFiles(sender.draggingPasteboard) else { return super.prepareForDragOperation(sender) }
        return (window as? ConversationNativeWindow)?.prepareForDragOperation(sender) ?? false
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard ConversationNativeWindow.containsFiles(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        return (window as? ConversationNativeWindow)?.performDragOperation(sender) ?? false
    }
}
