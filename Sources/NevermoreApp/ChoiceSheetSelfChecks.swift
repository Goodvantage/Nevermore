import AppKit

@MainActor enum ChoiceSheetSelfChecks {
    static func run(on parent: NSWindow) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let choices = [ChoiceSheet.Choice(id: "a", title: "Alpha"), .init(id: "b", title: "Beta"), .init(id: "c", title: "Gamma")]
        func awaitSheet(on target: NSWindow? = nil) async throws -> NSWindow {
            for _ in 0..<100 {
                if let sheet = (target ?? parent).attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded(); return sheet }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("The choice sheet did not appear.")
        }
        func buttons(_ sheet: NSWindow) -> [NSButton] { sheet.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self) } ?? [] }
        let multiple = Task { try await ChoiceSheet.choose(title: "Choice self-check", prompt: "Choose two fixtures", choices: choices, maximum: 2, on: parent) }
        let sheet = try await awaitSheet()
        let controls = buttons(sheet)
        guard let accept = controls.first(where: { $0.title == "Choose" }), let alpha = controls.first(where: { $0.title == "Alpha" }), let gamma = controls.first(where: { $0.title == "Gamma" }) else { multiple.cancel(); throw AppError.message("Choice controls are missing.") }
        results.append(("choice sheets begin without a selected option or an enabled acceptance", !accept.isEnabled && alpha.state == .off && gamma.state == .off))
        gamma.performClick(nil); alpha.performClick(nil); accept.performClick(nil)
        results.append(("multiple choices return stable input-order identities", try await multiple.value == ["a", "c"] && parent.attachedSheet == nil))

        let single = Task { try await ChoiceSheet.choose(title: "Single choice self-check", prompt: "Choose one fixture", choices: choices, allowsMultiple: false, on: parent) }
        let singleSheet = try await awaitSheet(); let singleControls = buttons(singleSheet)
        guard let first = singleControls.first(where: { $0.title == "Alpha" }), let second = singleControls.first(where: { $0.title == "Beta" }), let singleAccept = singleControls.first(where: { $0.title == "Choose" }) else { single.cancel(); throw AppError.message("Single-choice controls are missing.") }
        first.performClick(nil); second.performClick(nil); singleAccept.performClick(nil)
        results.append(("single-choice sheets replace the previous selection", try await single.value == ["b"]))

        let cancelled = Task { try await ChoiceSheet.choose(title: "Cancel choice self-check", prompt: "Cancel this fixture", choices: choices, on: parent) }
        _ = try await awaitSheet(); cancelled.cancel()
        results.append(("cancelling a choice task dismisses its native sheet without a result", try await cancelled.value == nil && parent.attachedSheet == nil))
        let temporaryParent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        temporaryParent.isReleasedWhenClosed = false
        temporaryParent.orderFrontRegardless()
        let parentClosed = Task { try await ChoiceSheet.choose(title: "Parent close self-check", prompt: "Close the fixture parent", choices: choices, on: temporaryParent) }
        _ = try await awaitSheet(on: temporaryParent); temporaryParent.close()
        results.append(("closing a choice sheet’s parent cancels its continuation", try await parentClosed.value == nil && temporaryParent.attachedSheet == nil))
        let invalid = Task { try await ChoiceSheet.choose(title: "Invalid choices", prompt: "", choices: [.init(id: "", title: "Invalid")], on: parent) }
        let watchdog = Task { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { invalid.cancel() } }
        defer { watchdog.cancel() }
        do {
            _ = try await invalid.value
            results.append(("choice sheets reject missing identities before presentation", false))
        } catch { results.append(("choice sheets reject missing identities before presentation", !(error is CancellationError) && parent.attachedSheet == nil)) }
        return results
    }
}
