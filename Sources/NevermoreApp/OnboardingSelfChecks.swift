import AppKit
import RavenProtocol

/// Add Account checks: the OAuth Client ID preset, the persistent field
/// labels, and the link to a site's OAuth Client list following the site
/// field as it is typed. The windows are never shown and the link's browser
/// hand-off is replaced, so nothing opens.
@MainActor enum OnboardingSelfChecks {
    private static let listPath = "/desk/integrations/oauth-client"

    static func run(app: AppDelegate) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        var opened: [URL] = []
        let login = LoginController(app: app)
        login.openInBrowser = { opened.append($0) }
        defer { login.close() }

        results.append(("Add Account starts with the preset OAuth Client ID", login.clientID.stringValue == LoginController.presetClientID && login.clientID.isEditable))
        let visibleSiteLabel = visibleLabel(matching: { $0 == "Raven Site URL" }, in: login.window?.contentView)
        let visibleClientIDLabel = visibleLabel(matching: { $0 == "OAuth Client ID" }, in: login.window?.contentView)
        results.append(("Add Account labels the site and client ID fields", visibleSiteLabel != nil && visibleClientIDLabel != nil))
        results.append(("Add Account says the prefilled client ID belongs to one site", visibleLabel(matching: { $0.contains("one site") && $0.contains("own client ID") }, in: login.window?.contentView) != nil))
        results.append(("Add Account keeps the fields' accessibility labels and link role", login.site.accessibilityLabel() == "Raven site URL" && login.clientID.accessibilityLabel() == "OAuth Client ID" && login.clientIDLink.accessibilityRole() == .link && visibleSiteLabel?.isAccessibilityElement() == false && visibleClientIDLabel?.isAccessibilityElement() == false))
        login.clientIDLink.performClick(nil)
        let hintWithoutSite = login.clientIDHint.stringValue
        results.append(("Add Account offers no OAuth Client link before a site is entered", login.clientIDLink.isHidden && login.clientListURL == nil && !hintWithoutSite.isEmpty && opened.isEmpty))

        let typed = type("chat.example.com", into: login.site)
        let expected = URL(string: "https://chat.example.com" + listPath)
        let hintWithSite = login.clientIDHint.stringValue
        results.append(("typing a site address links to its OAuth Client list", typed && !login.clientIDLink.isHidden && login.clientListURL == expected && login.clientIDLink.attributedTitle.string == "chat.example.com" + listPath && login.clientIDLink.toolTip == expected?.absoluteString && login.clientIDLink.accessibilityLabel() == "Open the OAuth Client list on chat.example.com in your browser" && !hintWithSite.isEmpty && hintWithSite != hintWithoutSite))
        let manualID = type("manual-client-id", into: login.clientID)
        results.append(("manual client ID edits survive and the labels stay visible", manualID && login.clientID.stringValue == "manual-client-id" && hasVisibleLabel("Raven Site URL", in: login.window?.contentView) && hasVisibleLabel("OAuth Client ID", in: login.window?.contentView)))
        let presetNote = visibleLabelText(matching: { $0.contains("one site") && $0.contains("own client ID") }, in: login.window?.contentView)
        results.append(("the client ID note names no origin for the preset", presetNote != nil && !presetNote!.contains("http") && !presetNote!.contains("www.")))
        login.clientIDLink.performClick(nil)
        results.append(("one click on the OAuth Client link hands that page to the browser", opened == [expected].compactMap { $0 }))

        let longHost = String(repeating: "department-", count: 8) + "chat.example.com"
        _ = type(longHost, into: login.site)
        login.window?.contentView?.layoutSubtreeIfNeeded()
        let titleStyle = login.clientIDLink.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let squeezed = login.clientIDLink.frame.width < login.clientIDLink.intrinsicContentSize.width
        results.append(("a long site address truncates the link inside the window and keeps Continue visible", login.clientListURL?.host == longHost && squeezed && titleStyle?.lineBreakMode == .byTruncatingMiddle && isInsideContent(login.clientIDLink) && isInsideContent(login.button)))
        let fieldLabels = [visibleSiteLabel, visibleClientIDLabel].compactMap { $0 }
        let presetNoteView = visibleLabel(matching: { $0.contains("one site") && $0.contains("own client ID") }, in: login.window?.contentView)
        let labelsInside = fieldLabels.count == 2 && fieldLabels.allSatisfy(isInsideContent) && presetNoteView.map(isInsideContent) == true
        results.append(("the field labels and preset note stay inside the window", labelsInside))

        opened.removeAll()
        let refused = ["http://chat.example.com", "chat.example.com/raven", "https://user:secret@chat.example.com", "https://"].allSatisfy { address in
            _ = type(address, into: login.site)
            login.clientIDLink.performClick(nil)
            return login.clientIDLink.isHidden && login.clientListURL == nil && login.clientIDHint.stringValue == hintWithoutSite
        }
        results.append(("an address Continue would refuse withdraws the OAuth Client link", refused && opened.isEmpty))

        let account = Account(origin: URL(string: "https://fixture.invalid:8443")!, user: "fixture@example.invalid", siteName: "fixture", clientID: "fixture-client")
        let reconnect = LoginController(app: app, account: account)
        defer { reconnect.close() }
        results.append(("Sign In Again keeps the account's own OAuth Client ID and links to its site", reconnect.clientID.stringValue == "fixture-client" && !reconnect.clientIDLink.isHidden && reconnect.clientListURL == URL(string: "https://fixture.invalid:8443" + listPath) && hasVisibleLabel("Raven Site URL", in: reconnect.window?.contentView) && hasVisibleLabel("OAuth Client ID", in: reconnect.window?.contentView)))
        return results
    }

    /// The visible, non-empty label with exactly this text, or nil. Placeholder
    /// text does not count: a persistent label is a view of its own.
    private static func hasVisibleLabel(_ text: String, in view: NSView?) -> Bool {
        visibleLabel(matching: { $0 == text }, in: view) != nil
    }

    private static func visibleLabel(matching predicate: @escaping (String) -> Bool, in view: NSView?) -> NSView? {
        guard let view, !view.isHidden else { return nil }
        if let field = view as? NSTextField, predicate(field.stringValue) { return field }
        return view.subviews.lazy.compactMap { visibleLabel(matching: predicate, in: $0) }.first
    }

    private static func visibleLabelText(matching predicate: @escaping (String) -> Bool, in view: NSView?) -> String? {
        (visibleLabel(matching: predicate, in: view) as? NSTextField)?.stringValue
    }

    /// Replaces the field's text through its field editor, as typing does,
    /// so the field's delegate hears the change.
    private static func type(_ text: String, into field: NSTextField) -> Bool {
        guard let window = field.window, window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { return false }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        return field.stringValue == text
    }

    private static func isInsideContent(_ view: NSView) -> Bool {
        guard let content = view.window?.contentView, !view.isHidden, view.frame.width > 0 else { return false }
        return content.bounds.contains(view.convert(view.bounds, to: content))
    }
}
