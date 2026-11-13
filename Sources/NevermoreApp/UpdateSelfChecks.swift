import AppKit
import NevermoreCore

@MainActor enum UpdateSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let suite = "NevermoreUpdateSelfCheck-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let version = ReleaseVersion("0.1.0-beta.2")!
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "app": "nevermore", "channel": "beta", "version": "0.1.0-beta.3",
            "downloads": ["macos": ["url": "https://apps.goodvantage.cloud/nevermore/0.1.0-beta.3/Nevermore.dmg", "file": "Nevermore.dmg", "size": 10, "sha256": String(repeating: "a", count: 64)]]])
        let offer = try ReleaseOffer.decode(data, running: version)
        let monitor = UpdateMonitor(runningVersion: version, defaults: defaults, fetch: { _ in offer })
        var openedURLs: [URL] = []
        var browserAvailable = true
        let updates = AppUpdateController(monitor: monitor, openURL: { openedURLs.append($0); return browserAvailable })
        // No permission prompts or real notifications from automated fixtures.
        var announcements = 0
        monitor.onAnnouncement = { _ in announcements += 1 }
        defer { monitor.stop() }
        let first = UpdateNoticeView(updates: updates), second = UpdateNoticeView(updates: updates)
        var results = [("update notices are hidden before a newer release is known", first.isHidden && second.isHidden)]
        await monitor.check(.manual)
        results.append(("one validated update refreshes notices across windows", !first.isHidden && !second.isHidden && updates.menuTitle == "Update Available…" && announcements == 1))
        monitor.dismiss()
        results.append(("dismissing an update hides every notice without disabling manual review", first.isHidden && second.isHidden && monitor.offer != nil && updates.statusText.contains("0.1.0-beta.3")))
        let originalWindow = NSApp.keyWindow
        let originalResponder = originalWindow?.firstResponder
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        updates.show()
        guard let panel = NSApp.windows.first(where: { !existing.contains(ObjectIdentifier($0)) && $0.title == "Nevermore Updates" }) else {
            results.append(("update review opens a native window", false)); return results
        }
        defer {
            panel.close()
            originalWindow?.makeKeyAndOrderFront(nil)
            if let originalResponder { originalWindow?.makeFirstResponder(originalResponder) }
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = panel.contentView.map(descendants) ?? []
        let buttons = views.compactMap { $0 as? NSButton }
        results.append(("update review offers browser download, website and manual check without installation", buttons.contains { $0.title == "Download" && !$0.isHidden } && buttons.contains { $0.title == "Open Website" } && buttons.contains { $0.title == "Check for Updates Now" } && !buttons.contains { $0.title.contains("Install") } && panel.frame.width >= 440 && panel.frame.height > 150))
        buttons.first(where: { $0.title == "Download" })?.performClick(nil)
        buttons.first(where: { $0.title == "Open Website" })?.performClick(nil)
        results.append(("update actions hand only the validated installer and fixed website to the browser", openedURLs == [offer!.downloadURL, ReleaseOffer.websiteURL]))
        browserAvailable = false
        buttons.first(where: { $0.title == "Download" })?.performClick(nil)
        results.append(("a failed browser launch is reported instead of claiming a download started", views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Could not open your browser") }))
        updates.setChecksAutomatically(false)
        results.append(("automatic checks can be disabled while explicit checks remain available", !updates.checksAutomatically && buttons.first(where: { $0.title == "Check for Updates Now" })?.isEnabled == true))
        let settings = SettingsController(app: app)
        defer { settings.close() }
        results.append(("General settings expose update checks and preserve the existing message controls", settings.automaticUpdates.title == "Check for updates automatically" && settings.updateCheck.action == #selector(AppDelegate.checkForUpdates) && settings.sendKey.numberOfItems == ComposerSendKey.allCases.count))
        return results
    }
}
