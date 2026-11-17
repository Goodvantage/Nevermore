import AppKit

/// Table view for collection windows with native keyboard dispatch.
///
/// Return opens the selected row, Escape closes the window, and Command-R
/// refreshes only when the collection has a verified source. Modified keys
/// are forwarded to AppKit's native table behavior, and no key acts while
/// the current text input has marked (composing) text.
@MainActor final class CollectionTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// Mirrors whether the collection has a source; Command-R is inert without one.
    var canRefresh = false

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 36 || event.keyCode == 76 {
            guard flags.isEmpty, !hasMarkedText() else { super.keyDown(with: event); return }
            // Plain Return always belongs to the collection; with no selection it is a no-op.
            if selectedRow >= 0 { onOpen?() }
            return
        }
        if event.keyCode == 53 {
            guard flags.isEmpty, !hasMarkedText() else { super.keyDown(with: event); return }
            onClose?()
            return
        }
        if event.keyCode == 15, flags == .command {
            guard !hasMarkedText() else { super.keyDown(with: event); return }
            if canRefresh { onRefresh?() }
            return
        }
        super.keyDown(with: event)
    }

    private func hasMarkedText() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return (responder as? NSTextView)?.hasMarkedText() ?? false
    }
}
