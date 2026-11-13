import AppKit
import RavenProtocol

/// Add Account checks: the OAuth Client ID preset, and the link to a site's
/// OAuth Client list following the site field as it is typed. The windows
/// are never shown and the link's browser hand-off is replaced, so nothing
/// opens.
@MainActor enum OnboardingSelfChecks {
    private static let listPath = "/desk/integrations/oauth-client"

    static func run(app: AppDelegate) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        var opened: [URL] = []
        let login = LoginController(app: app)
        login.openInBrowser = { opened.append($0) }
        defer { login.close() }

        results.append(("Add Account starts with the preset OAuth Client ID", login.clientID.stringValue == LoginController.presetClientID && login.clientID.isEditable))
        login.clientIDLink.performClick(nil)
        let hintWithoutSite = login.clientIDHint.stringValue
        results.append(("Add Account offers no OAuth Client link before a site is entered", login.clientIDLink.isHidden && login.clientListURL == nil && !hintWithoutSite.isEmpty && opened.isEmpty))

        let typed = type("chat.example.com", into: login.site)
        let expected = URL(string: "https://chat.example.com" + listPath)
        let hintWithSite = login.clientIDHint.stringValue
        results.append(("typing a site address links to its OAuth Client list", typed && !login.clientIDLink.isHidden && login.clientListURL == expected && login.clientIDLink.attributedTitle.string == "chat.example.com" + listPath && login.clientIDLink.toolTip == expected?.absoluteString && !hintWithSite.isEmpty && hintWithSite != hintWithoutSite))
        login.clientIDLink.performClick(nil)
        results.append(("one click on the OAuth Client link hands that page to the browser", opened == [expected].compactMap { $0 }))

        let longHost = String(repeating: "department-", count: 8) + "chat.example.com"
        _ = type(longHost, into: login.site)
        login.window?.contentView?.layoutSubtreeIfNeeded()
        let titleStyle = login.clientIDLink.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let squeezed = login.clientIDLink.frame.width < login.clientIDLink.intrinsicContentSize.width
        results.append(("a long site address truncates the link inside the window and keeps Continue visible", login.clientListURL?.host == longHost && squeezed && titleStyle?.lineBreakMode == .byTruncatingMiddle && isInsideContent(login.clientIDLink) && isInsideContent(login.button)))

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
        results.append(("Sign In Again keeps the account's own OAuth Client ID and links to its site", reconnect.clientID.stringValue == "fixture-client" && !reconnect.clientIDLink.isHidden && reconnect.clientListURL == URL(string: "https://fixture.invalid:8443" + listPath)))
        return results
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
