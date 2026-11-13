import AppKit

/// Window-modal prompts. Each dialog belongs to the window whose command
/// raised it, so other windows stay usable (HIG: prefer sheets to app-modal
/// alerts). Without a visible parent window the prompt falls back to an
/// app-modal alert.
@MainActor enum SheetPrompt {
    static func run(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible, !window.isSheet else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    /// For destructive actions Cancel is the default button, so Return never
    /// performs an irreversible server change (the HIG's guidance, and the
    /// behaviour of the alerts this replaces).
    static func confirm(_ title: String, message: String, confirm: String, destructive: Bool = false, on window: NSWindow?) async -> Bool {
        let alert = confirmationAlert(title, message: message, confirm: confirm, destructive: destructive)
        return await run(alert, on: window) == (destructive ? .alertSecondButtonReturn : .alertFirstButtonReturn)
    }

    static func confirmationAlert(_ title: String, message: String, confirm: String, destructive: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if destructive {
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: confirm).hasDestructiveAction = true
        } else {
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Cancel")
        }
        return alert
    }

    static func inform(_ title: String, message: String, on window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await run(alert, on: window)
    }

    static func text(_ title: String, message: String? = nil, placeholder: String = "", value: String = "", confirm: String = "OK", on window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await run(alert, on: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func choose(_ title: String, message: String? = nil, items: [String], confirm: String = "Choose", on window: NSWindow?) async -> Int? {
        guard !items.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        picker.addItems(withTitles: items)
        alert.accessoryView = picker
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return await run(alert, on: window) == .alertFirstButtonReturn ? picker.indexOfSelectedItem : nil
    }

    /// Date and time in the site's timezone, which the server treats as
    /// authoritative; the caption says so rather than guessing local time.
    static func date(_ title: String, message: String, timeZone: TimeZone, confirm: String, initial: Date = Date().addingTimeInterval(3600), on window: NSWindow?) async -> Date? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.datePickerStyle = .textFieldAndStepper
        picker.timeZone = timeZone
        picker.dateValue = initial
        picker.minDate = Date()
        alert.accessoryView = picker
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = picker
        return await run(alert, on: window) == .alertFirstButtonReturn ? picker.dateValue : nil
    }
}
